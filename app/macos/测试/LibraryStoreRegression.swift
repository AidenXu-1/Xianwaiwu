import AVFoundation
import Combine
import Foundation

struct CheckFailure: Error { let message: String }

@main
struct LibraryStoreRegression {
    static let manager = FileManager.default
    static var passed = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(message: message) }
        passed += 1
        print("PASS \(passed)  \(message)")
        fflush(stdout)
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch { passed += 1; print("PASS \(passed)  \(message)"); fflush(stdout); return }
        throw CheckFailure(message: message)
    }

    static func audio(_ url: URL, frames: AVAudioFrameCount = 17640, phase: Float = 0) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100,
                                      AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
                                      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for index in 0..<Int(frames) {
                buffer.floatChannelData![channel][index] = sin(Float(index) * 0.071 + phase) * 0.1
            }
        }
        try file.write(from: buffer)
    }

    static func pair(_ store: LibraryStore, project: ProjectRecord, start: Double = 0, frames: AVAudioFrameCount = 8820) throws -> (URL, ResultRecord) {
        let temporary = try store.temporaryResultURL(projectID: project.id)
        let tracks = [ResultTrackRecord(id: "vocals", label: "人声", filename: "vocals.wav"),
                      ResultTrackRecord(id: "instrumental", label: "伴奏", filename: "instrumental.wav")]
        for track in tracks { try audio(temporary.appendingPathComponent(track.filename), frames: frames) }
        return (temporary, ResultRecord(mode: "pair", range: AudioRange(start: start, end: start + 0.2), tracks: tracks))
    }

    static func vocalResult(_ store: LibraryStore, project: ProjectRecord, mode: String, ids: [String], start: Double = 0) throws -> (URL, ResultRecord) {
        let temporary = try store.temporaryResultURL(projectID: project.id)
        let tracks = ids.map { ResultTrackRecord(id: $0, label: $0, filename: $0 + ".wav") }
        for (index, track) in tracks.enumerated() { try audio(temporary.appendingPathComponent(track.filename), frames: 8820, phase: Float(index) * 0.4) }
        return (temporary, ResultRecord(mode: mode, range: AudioRange(start: start, end: start+0.2), tracks: tracks))
    }

    struct FileState: Equatable {
        var bytes: Data
        var modified: Date
        var inode: UInt64
    }

    static func fileState(_ url: URL) throws -> FileState {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        return FileState(bytes: try Data(contentsOf: url), modified: attributes[.modificationDate] as! Date,
                         inode: (attributes[.systemFileNumber] as! NSNumber).uint64Value)
    }

    static func projectMirror(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent("Projects/\(id.uuidString)/project.json")
    }

    final class BackgroundListeningResult: @unchecked Sendable {
        var result: Result<(project: ProjectRecord, document: LibraryDocument), Error>?
        var ranOffMain = false
    }

    final class FileGateResult: @unchecked Sendable {
        var releasedBySignal = false
    }

    static func backgroundListening(_ store: LibraryStore, update: ListeningUpdate) throws -> (project: ProjectRecord, document: LibraryDocument) {
        let box = BackgroundListeningResult()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "LibraryStoreRegression.listening").async {
            box.ranOffMain = !Thread.isMainThread
            box.result = Result { try store.persistListening(update) }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 20) == .success, box.ranOffMain, let result = box.result else {
            throw CheckFailure(message: "后台试听保存未在独立队列完成")
        }
        return try result.get()
    }

    static func adoptWhileSaveIsBlocked(_ store: LibraryStore, update: ListeningUpdate, completed: LibraryDocument, output: URL) throws {
        // Observe the actual private lock without adding a production test hook or replacing save behavior.
        guard let saveLock = Mirror(reflecting: store).children.first(where: { $0.label == "localLock" })?.value as? NSRecursiveLock else {
            throw CheckFailure(message: "无法观察实际资料库保存锁")
        }
        let descriptor = Darwin.open(store.rootURL.appendingPathComponent(".library-lock").path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw CheckFailure(message: "无法建立真实文件锁等待夹具")
        }
        let releaseFile = DispatchSemaphore(value: 0)
        let fileReleased = DispatchSemaphore(value: 0)
        let saveFinished = DispatchSemaphore(value: 0)
        let gate = FileGateResult()
        let save = BackgroundListeningResult()
        DispatchQueue(label: "LibraryStoreRegression.file-gate").async {
            // A timeout only prevents the old implementation deadlocking the regression process.
            gate.releasedBySignal = releaseFile.wait(timeout: .now() + 2) == .success
            flock(descriptor, LOCK_UN)
            fileReleased.signal()
        }
        DispatchQueue(label: "LibraryStoreRegression.blocked-save").async {
            save.ranOffMain = !Thread.isMainThread
            save.result = Result { try store.persistListening(update) }
            saveFinished.signal()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var observedHeldSaveLock = false
        repeat {
            if !saveLock.try() { observedHeldSaveLock = true; break }
            saveLock.unlock()
            sched_yield()
        } while ProcessInfo.processInfo.systemUptime < deadline
        let started = ProcessInfo.processInfo.systemUptime
        store.adoptListeningDocument(completed)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        // Deliberately release only AFTER main-thread adoption returned.
        releaseFile.signal()
        let gateCompleted = fileReleased.wait(timeout: .now() + 5) == .success
        let workerCompleted = saveFinished.wait(timeout: .now() + 5) == .success
        Darwin.close(descriptor)
        let metrics: [String: Any] = ["workerActuallyHeldSaveLock": observedHeldSaveLock,
                                      "workerRanOffMain": save.ranOffMain,
                                      "fileLockReleasedOnlyAfterAdoptReturned": gate.releasedBySignal,
                                      "adoptSeconds": elapsed, "workerCompleted": workerCompleted]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("主线程发布不等保存锁.json"), options: .atomic)
        try check(observedHeldSaveLock && gateCompleted && workerCompleted && save.ranOffMain && gate.releasedBySignal,
                  "真实后台保存持锁等待文件锁时，主线程采用已完成快照先返回，才释放文件锁继续保存")
        guard let result = save.result else { throw CheckFailure(message: "受阻保存未返回结果") }
        store.adoptListeningDocument(try result.get().document)
    }

    static func writeAmplification(_ output: URL, source: SourceRecord) throws {
        let root = output.appendingPathComponent("100项目写入资料库", isDirectory: true)
        let store = try LibraryStore(rootURL: root)
        var created: [ProjectRecord] = []
        for index in 0..<100 {
            created.append(try store.createProject(source: source, name: "保存检查 \(index)"))
        }
        // Include real result metadata with multi-element Sets and subsecond in-memory Dates.
        let (temporary, result) = try pair(store, project: created[99])
        _ = try store.commitResult(projectID: created[99].id, temporaryURL: temporary, record: result)
        let ids = created.map(\.id)
        let indexURL = root.appendingPathComponent("library.json")
        let oldDate = Date(timeIntervalSince1970: 978307200)
        for id in ids { try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: projectMirror(root, id).path) }
        try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: indexURL.path)
        var before: [UUID: FileState] = [:]
        for id in ids { before[id] = try fileState(projectMirror(root, id)) }
        let indexBefore = try fileState(indexURL)
        var changed = store.projects.first(where: { $0.id == ids[0] })!
        changed.sourceListening.absoluteTime = 0.13
        _ = try store.saveProject(changed)
        var touched: [UUID] = []
        for id in ids where try fileState(projectMirror(root, id)) != before[id] { touched.append(id) }
        let indexTouched = try fileState(indexURL) != indexBefore
        let metrics: [String: Any] = ["projectCount": 100, "changedProjectSnapshots": touched.count,
                                      "indexChanged": indexTouched, "totalChangedJSONFiles": touched.count + (indexTouched ? 1 : 0),
                                      "method": "actual bytes, modification date and inode before/after one project save"]
        let metricBytes = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        try metricBytes.write(to: output.appendingPathComponent("100项目写入测量.json"), options: .atomic)
        print("WRITE_METRICS \(String(decoding: metricBytes, as: UTF8.self))")
        fflush(stdout)
        try check(touched == [ids[0]] && indexTouched, "100项目只改一个试听位置，仅该项目副本及索引被替换；其余99份内容、修改时间和inode不变")

        before.removeAll()
        for id in ids { before[id] = try fileState(projectMirror(root, id)) }
        var preferences = store.preferences
        preferences.volume = 0.37
        try store.savePreferences(preferences)
        try check(try ids.allSatisfy { try fileState(projectMirror(root, $0)) == before[$0] }, "只改全局偏好不重写任何项目，包括多音轨Set和日期往返")

        // Compare with the locked disk snapshot, never this instance's stale published document.
        let staleStore = try LibraryStore(rootURL: root)
        let otherStore = try LibraryStore(rootURL: root)
        var otherProject = otherStore.projects.first(where: { $0.id == ids[1] })!
        otherProject.title = "另一实例已保存的新名称"
        _ = try otherStore.saveProject(otherProject)
        let otherMirror = try fileState(projectMirror(root, ids[1]))
        var staleProject = staleStore.projects.first(where: { $0.id == ids[0] })!
        staleProject.sourceListening.absoluteTime = 0.21
        _ = try staleStore.saveProject(staleProject)
        let afterOtherInstance = try LibraryStore(rootURL: root)
        try check(afterOtherInstance.projects.first(where: { $0.id == ids[1] })?.title == otherProject.title && fileState(projectMirror(root, ids[1])) == otherMirror,
                  "旧内存实例保存另一项目，保留其他实例的新记录且不重写其副本")
        try rejects("多实例优化后同一项目过期revision仍拒绝覆盖") { _ = try otherStore.saveProject(otherProject) }

        // A crash before the index commit can leave a valid but newer recovery copy.
        let missingURL = projectMirror(root, ids[2])
        let brokenURL = projectMirror(root, ids[3])
        let aheadURL = projectMirror(root, ids[4])
        try manager.removeItem(at: missingURL)
        let broken = Data("{ interrupted project mirror".utf8)
        try broken.write(to: brokenURL)
        var ahead = afterOtherInstance.projects.first(where: { $0.id == ids[4] })!
        ahead.title = "尚未提交索引的超前副本"
        ahead.revision += 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ahead).write(to: aheadURL, options: .atomic)
        before.removeAll()
        for id in ids where id != ids[2] { before[id] = try fileState(projectMirror(root, id)) }
        _ = try staleStore.createFolder(name: "恢复副本")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let repairedIDs = [ids[2], ids[3], ids[4]]
        let authoritative = try LibraryStore(rootURL: root)
        try check(try repairedIDs.allSatisfy { id in
            try decoder.decode(ProjectRecord.self, from: Data(contentsOf: projectMirror(root, id))) == authoritative.projects.first(where: { $0.id == id })
        }, "缺失、损坏及中断留下的超前副本均从最新权威索引恢复")
        try check(try ids.filter { !repairedIDs.contains($0) }.allSatisfy { try fileState(projectMirror(root, $0)) == before[$0] }, "副本修复不重写其余97份健康项目")
        let recovery = try manager.contentsOfDirectory(at: root.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil)
        try check(recovery.contains { (try? Data(contentsOf: $0)) == broken }, "增量保存仍保留损坏副本的原始字节")
        var onceMore: [UUID: FileState] = [:]
        for id in ids { onceMore[id] = try fileState(projectMirror(root, id)) }
        _ = try authoritative.createFolder(name: "再次保存")
        try check(try ids.allSatisfy { try fileState(projectMirror(root, $0)) == onceMore[$0] }, "副本恢复后再次保存不会重复重写健康副本")

        let backgroundStore = try LibraryStore(rootURL: root)
        var documentPublications: [Bool] = []
        var warningPublications: [Bool] = []
        let documentObserver = backgroundStore.$document.dropFirst().sink { _ in documentPublications.append(Thread.isMainThread) }
        let warningObserver = backgroundStore.$warnings.dropFirst().sink { _ in warningPublications.append(Thread.isMainThread) }
        defer { documentObserver.cancel(); warningObserver.cancel() }
        let editor = try LibraryStore(rootURL: root)
        let resultProjectID = ids[99]
        let resultProject = editor.projects.first(where: { $0.id == resultProjectID })!
        let (secondTemporary, secondResult) = try pair(editor, project: resultProject, start: 0.2)
        _ = try editor.commitResult(projectID: resultProjectID, temporaryURL: secondTemporary, record: secondResult)
        let folder = try editor.createFolder(name: "后台保存仍保留分组")
        try editor.moveProject(resultProjectID, to: folder.id)
        var latest = editor.projects.first(where: { $0.id == resultProjectID })!
        latest.title = "新名称与新结果不可被试听覆盖"
        let receipt = ExportRecord(format: "wav24", trackIDs: ["instrumental"], path: output.appendingPathComponent("用户已有导出.wav").path)
        latest.results[0].exports.append(receipt)
        _ = try editor.saveProject(latest)
        let expectedExports = try LibraryStore(rootURL: root).projects.first(where: { $0.id == resultProjectID })!.results[0].exports
        let publishedBefore = backgroundStore.document
        let brokenDuringBackground = Data("{ background repair snapshot".utf8)
        try brokenDuringBackground.write(to: projectMirror(root, ids[98]))
        var update = ListeningUpdate(projectID: resultProjectID, mode: "pair", range: AudioRange(start: 0, end: 0.2),
                                     selectedResultID: result.id, listeningToResult: true,
                                     listening: ListeningRecord(absoluteTime: 0.14, enabled: ["vocals"], solo: ["vocals", "instrumental"]),
                                     sourceListening: ListeningRecord(absoluteTime: 0.32, enabled: ["original"]))
        let committed = try backgroundListening(backgroundStore, update: update)
        try check(documentPublications.isEmpty && warningPublications.isEmpty && backgroundStore.document == publishedBefore,
                  "真实后台队列保存及损坏副本修复均不发布document或warnings")
        try check(committed.project.title == latest.title && committed.project.folderID == folder.id && committed.project.results.count == 2 && committed.project.results[0].exports == expectedExports,
                  "后台窄更新从最新磁盘合并，保留其他操作的新名称、文件夹、新结果及导出记录")
        try check(committed.project.results[0].listening == update.listening && committed.project.sourceListening == update.sourceListening && committed.project.modeStates?["pair"]?.selectedResultID == result.id,
                  "后台保存只更新指定结果试听、原曲状态及当前板块")
        backgroundStore.adoptListeningDocument(committed.document)
        try check(backgroundStore.document == committed.document && documentPublications == [true] && warningPublications == [true] && !backgroundStore.warnings.isEmpty,
                  "后台完成后仅主线程采用新快照并发布修复通知")
        update.listening.absoluteTime = 0.19
        let newer = try backgroundListening(backgroundStore, update: update)
        backgroundStore.adoptListeningDocument(newer.document)
        let publicationsBeforeOldCallback = documentPublications.count
        backgroundStore.adoptListeningDocument(committed.document)
        try check(backgroundStore.document.revision == newer.document.revision && backgroundStore.projects.first(where: { $0.id == resultProjectID })?.results[0].listening.absoluteTime == 0.19 && documentPublications.count == publicationsBeforeOldCallback,
                  "晚到的旧保存回调不能回退界面文档或重复发布")
        try adoptWhileSaveIsBlocked(backgroundStore, update: update, completed: committed.document, output: output)
        var wrongBoard = update
        wrongBoard.mode = "lead3"
        try rejects("后台保存不能把其他板块结果带入当前板块") { _ = try backgroundListening(backgroundStore, update: wrongBoard) }

        let lateProject = try editor.createProject(source: source, name: "晚到试听不能复活")
        let lateUpdate = ListeningUpdate(projectID: lateProject.id, mode: "pair", range: nil, selectedResultID: nil,
                                         listeningToResult: false, listening: ListeningRecord(absoluteTime: 0.1, enabled: ["original"]),
                                         sourceListening: ListeningRecord(absoluteTime: 0.1, enabled: ["original"]))
        try editor.deleteProject(lateProject.id)
        try rejects("项目删除后的晚到后台试听不能复活项目") { _ = try backgroundListening(backgroundStore, update: lateUpdate) }

        let verifiedURL = output.appendingPathComponent("已后台核对的新原曲位置.wav")
        try Data(contentsOf: source.url).write(to: verifiedURL)
        let verified = try LibraryStore.makeSource(url: verifiedURL, duration: source.duration, sampleRate: source.sampleRate, channels: source.channels)
        var latestBeforeRelocate = editor.projects.first(where: { $0.id == resultProjectID })!
        // Refresh this editor after background writes before an explicit whole-record edit.
        try editor.reload()
        latestBeforeRelocate = editor.projects.first(where: { $0.id == resultProjectID })!
        latestBeforeRelocate.title = "原曲核对期间另一次改名"
        _ = try editor.saveProject(latestBeforeRelocate)
        let relocated = try backgroundStore.relocateSource(projectID: resultProjectID, verifiedSource: verified)
        try check(relocated.source.url == verifiedURL && relocated.title == latestBeforeRelocate.title && relocated.folderID == folder.id && relocated.results.count == 2 && relocated.results[0].exports == expectedExports && relocated.results[0].listening.absoluteTime == 0.19,
                  "已核对原曲入口读取最新项目，仅更换原曲位置并保留并行新状态")
        var wrongMetadata = verified
        wrongMetadata.sampleRate = 48000
        try rejects("已核对入口仍拒绝与原曲不符的声音元数据") { _ = try backgroundStore.relocateSource(projectID: resultProjectID, verifiedSource: wrongMetadata) }
        let previousDate = verified.modificationDate
        try manager.setAttributes([.modificationDate: previousDate.addingTimeInterval(2)], ofItemAtPath: verifiedURL.path)
        try rejects("后台核对后文件修改时间又变化，主线程入口拒绝直接采用") { _ = try backgroundStore.relocateSource(projectID: resultProjectID, verifiedSource: verified) }
        var internalSource = verified
        internalSource.path = projectMirror(root, resultProjectID).path
        try rejects("已核对入口仍拒绝把资料库内部文件作为原曲") { _ = try backgroundStore.relocateSource(projectID: resultProjectID, verifiedSource: internalSource) }
    }

    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--orphan" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let store = try LibraryStore(rootURL: root)
            let temporary = try store.temporaryResultURL(projectID: store.projects[0].id)
            try Data("unfinished audio".utf8).write(to: temporary.appendingPathComponent("half.wav"))
            let stage = temporary.deletingLastPathComponent().appendingPathComponent(".分离-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: stage, withIntermediateDirectories: true)
            try Data("unfinished staged audio".utf8).write(to: stage.appendingPathComponent("half.wav"))
            try JSONSerialization.data(withJSONObject: [temporary.path, stage.path]).write(to: root.appendingPathComponent("orphan-info.json"))
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--stress" {
            let store = try LibraryStore(rootURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            while true {
                var project = store.projects[0]
                project.title = "中断写入检查 \(project.revision)"
                try store.saveProject(project)
                let marker = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("stress-started.txt")
                if !manager.fileExists(atPath: marker.path) { try Data("first atomic save completed".utf8).write(to: marker) }
            }
        }
        let requestedOutput = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/Xianwaiwu-Library-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: requestedOutput, withIntermediateDirectories: true)
        let output = requestedOutput.standardizedFileURL.resolvingSymlinksInPath()
        print("LibraryStore executable regression")
        print("Artifacts \(output.path)")
        let sourceURL = output.appendingPathComponent("原曲 🎵.wav")
        let exportURL = output.appendingPathComponent("用户已有导出.wav")
        try audio(sourceURL)
        try audio(exportURL)
        let originalBytes = try Data(contentsOf: sourceURL)
        let originalExport = try Data(contentsOf: exportURL)
        let source = try LibraryStore.makeSource(url: sourceURL, duration: 0.4, sampleRate: 44100, channels: 2)
        let root = output.appendingPathComponent("Library", isDirectory: true)
        let store = try LibraryStore(rootURL: root)
        let project = try store.createProject(source: source)
        try check(store.projects.count == 1 && project.title == "原曲 🎵", "真实 WAV 建项目，中文与 emoji 保留")
        if case .available = store.sourceStatus(for: source) { try check(true, "完整 SHA-256 原曲核验通过") }
        else { throw CheckFailure(message: "原曲核验") }

        let folder = try store.createFolder(name: "  大冰  ")
        try check(folder.name == "大冰", "文件夹首尾空白规范化")
        try rejects("空白文件夹拒绝") { _ = try store.createFolder(name: " \n ") }
        try rejects("超过 24 字符的文件夹拒绝") { _ = try store.createFolder(name: String(repeating: "歌", count: 25)) }
        try rejects("同名文件夹拒绝") { _ = try store.createFolder(name: "大冰") }
        _ = try store.createFolder(name: "Live")
        try rejects("大小写同名文件夹拒绝") { _ = try store.createFolder(name: "live") }
        try store.moveProject(project.id, to: folder.id)
        try check(store.projects.first?.folderID == folder.id, "项目真实归入分组")
        try store.moveProject(project.id, to: nil)
        try check(store.projects.first?.folderID == nil, "项目移回全部项目")
        try store.moveProject(project.id, to: folder.id)
        try store.deleteFolder(folder.id)
        try check(store.projects.count == 1 && store.projects.first?.folderID == nil, "删除分组保留项目并解除归属")
        try rejects("失效文件夹不能接收项目") { try store.moveProject(project.id, to: folder.id) }
        try rejects("过期项目快照不能覆盖新状态") { _ = try store.saveProject(project) }

        let (temporary, first) = try pair(store, project: project)
        _ = try store.commitResult(projectID: project.id, temporaryURL: temporary, record: first)
        let firstURL = store.resultURL(projectID: project.id, resultID: first.id)
        try check(!manager.fileExists(atPath: temporary.path) && manager.fileExists(atPath: firstURL.path), "完整结果从任务暂存原子移入固定目录")
        try check(store.projects[0].results.count == 1 && first.listening.enabled == ["vocals", "instrumental"], "完整双轨及默认试听状态已入库")
        let (secondTemporary, second) = try pair(store, project: project, start: 0.2)
        _ = try store.commitResult(projectID: project.id, temporaryURL: secondTemporary, record: second)
        try check(store.projects[0].results.count == 2 && store.projects[0].currentResultID == second.id, "不同范围同分法保留两份结果")
        var saved = store.projects[0]
        saved.currentResultID = first.id
        saved.range = AudioRange(start: 0, end: 0.2)
        saved.results[0].listening = ListeningRecord(absoluteTime: 0.12, enabled: ["instrumental"], solo: ["vocals", "instrumental"])
        saved.sourceListening = ListeningRecord(absoluteTime: 0.31, enabled: ["original"])
        saved.results[0].exports = [ExportRecord(format: "wav24", trackIDs: ["instrumental"], path: exportURL.path)]
        _ = try store.saveProject(saved)
        try store.saveWaveform([0, 0.5, 1], projectID: project.id)
        try store.saveWaveform([0.1, 0.7], projectID: project.id, resultID: first.id, trackID: "vocals")
        var preferences = store.preferences
        preferences.exportFormat = "mp3"
        preferences.lastExportPath = output.path
        preferences.volume = 0.42
        try store.savePreferences(preferences)
        let reopened = try LibraryStore(rootURL: root)
        try check(reopened.projects[0].results.count == 2 && reopened.projects[0].currentResultID == first.id, "独立实例重开恢复两份结果及当前结果")
        try check(reopened.projects[0].results[0].listening.solo.count == 2 && reopened.projects[0].results[0].listening.absoluteTime == 0.12, "组合独奏、开关和绝对位置恢复")
        try check(reopened.projects[0].sourceListening.absoluteTime == 0.31 && reopened.projects[0].results[0].exports[0].path == exportURL.path, "原曲试听和每份导出记录恢复")
        try check(reopened.loadWaveform(projectID: project.id) == [0, 0.5, 1] && reopened.loadWaveform(projectID: project.id, resultID: first.id, trackID: "vocals") == [0.1, 0.7], "原曲与分轨真实波形缓存恢复")
        try check(reopened.preferences == preferences, "全局音量、格式及导出位置恢复")

        let unfinished = try reopened.temporaryResultURL(projectID: project.id)
        let afterUnfinished = try LibraryStore(rootURL: root)
        try check(afterUnfinished.projects[0].results.count == 2, "未完成临时任务不伪装成有效结果")
        try check(manager.fileExists(atPath: unfinished.path), "重开资料库保留仍在运行进程的任务暂存")
        try reopened.discardTemporaryResult(unfinished, projectID: project.id)
        try check(!manager.fileExists(atPath: unfinished.path), "取消仅删除指定任务暂存")
        let (invalidTemporary, invalidRecord) = try pair(reopened, project: project, frames: 8810)
        try rejects("采样数不对的文件不能入库") { _ = try reopened.commitResult(projectID: project.id, temporaryURL: invalidTemporary, record: invalidRecord) }
        try check(reopened.projects[0].results.count == 2, "失败结果不会覆盖旧结果")
        try reopened.discardTemporaryResult(invalidTemporary, projectID: project.id)
        let (missingTemporary, missingRecord) = try pair(reopened, project: project)
        try manager.removeItem(at: missingTemporary.appendingPathComponent("vocals.wav"))
        try rejects("缺一轨不能入库") { _ = try reopened.commitResult(projectID: project.id, temporaryURL: missingTemporary, record: missingRecord) }
        try reopened.discardTemporaryResult(missingTemporary, projectID: project.id)
        let (linkTemporary, linkRecord) = try pair(reopened, project: project)
        try manager.removeItem(at: linkTemporary.appendingPathComponent("vocals.wav"))
        try manager.createSymbolicLink(at: linkTemporary.appendingPathComponent("vocals.wav"), withDestinationURL: sourceURL)
        try rejects("外部符号链接不能作为内部结果") { _ = try reopened.commitResult(projectID: project.id, temporaryURL: linkTemporary, record: linkRecord) }
        try reopened.discardTemporaryResult(linkTemporary, projectID: project.id)
        try rejects("音轨路径穿越拒绝") {
            _ = try reopened.trackURL(projectID: project.id, resultID: first.id, track: ResultTrackRecord(id: "x", label: "x", filename: "../../原曲 🎵.wav"))
        }
        try rejects("外部目录不能作为任务暂存清理") { try reopened.discardTemporaryResult(output, projectID: project.id) }

        try manager.removeItem(at: sourceURL)
        if case .missing = reopened.sourceStatus(for: source) { try check(true, "原曲丢失被识别") }
        else { throw CheckFailure(message: "原曲丢失") }
        let withoutSource = try LibraryStore(rootURL: root)
        let trackURL = try withoutSource.trackURL(projectID: project.id, resultID: first.id, track: first.tracks[0])
        try check(try AVAudioFile(forReading: trackURL).length == 8820, "原曲丢失后完整结果仍可解码")
        let relocatedURL = output.appendingPathComponent("移动后的原曲.wav")
        try originalBytes.write(to: relocatedURL)
        _ = try withoutSource.relocateSource(projectID: project.id, to: relocatedURL)
        try check(withoutSource.projects[0].source.url == relocatedURL && withoutSource.projects[0].results.count == 2, "匹配内容重定位保留所有结果")
        let differentURL = output.appendingPathComponent("同名不同内容.wav")
        try audio(differentURL, phase: 0.5)
        try rejects("内容不同的文件不可静默重关联") { _ = try withoutSource.relocateSource(projectID: project.id, to: differentURL) }
        let priorAttributes = try manager.attributesOfItem(atPath: relocatedURL.path)
        try audio(relocatedURL, phase: 0.7)
        try manager.setAttributes([.modificationDate: priorAttributes[.modificationDate]!], ofItemAtPath: relocatedURL.path)
        if case .changed = withoutSource.sourceStatus(for: withoutSource.projects[0].source) { try check(true, "同大小同修改时间的替换仍由内容指纹识别") }
        else { throw CheckFailure(message: "同大小替换检测") }
        try originalBytes.write(to: relocatedURL)

        let parallelA = try LibraryStore(rootURL: root)
        let parallelB = try LibraryStore(rootURL: root)
        let pa = try parallelA.createProject(source: source, name: "另一项目 A")
        _ = try parallelB.createProject(source: source, name: "另一项目 B")
        try parallelA.reload()
        try check(parallelA.projects.count == 3, "两个实例交替保存不丢对方新增项目")
        let mirror = root.appendingPathComponent("Projects/\(pa.id.uuidString)/project.json")
        let brokenMirror = Data("{ bad project snapshot".utf8)
        try brokenMirror.write(to: mirror)
        _ = try parallelA.createFolder(name: "修复副本测试")
        let recoveryFiles = try manager.contentsOfDirectory(at: root.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil)
        try check(recoveryFiles.contains(where: { (try? Data(contentsOf: $0)) == brokenMirror }), "损坏项目副本保留备份后由完整索引恢复")

        let stress = Process()
        stress.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        stress.arguments = ["--stress", root.path]
        let preStressRevision = parallelA.document.revision
        try stress.run()
        defer {
            if stress.isRunning { kill(stress.processIdentifier, SIGKILL); stress.waitUntilExit() }
        }
        let marker = root.appendingPathComponent("stress-started.txt")
        for _ in 0..<300 where !manager.fileExists(atPath: marker.path) { usleep(10000) }
        guard manager.fileExists(atPath: marker.path) else { throw CheckFailure(message: "中断测试子进程没有开始实际保存") }
        usleep(60000)
        kill(stress.processIdentifier, SIGKILL)
        stress.waitUntilExit()
        let afterKill = try LibraryStore(rootURL: root)
        try check(afterKill.document.revision > preStressRevision, "强制结束前子进程已实际提交保存")
        try check(afterKill.projects.count == 3 && afterKill.projects.contains(where: { $0.id == project.id && $0.results.count == 2 }), "高频保存时强制结束进程，重开索引和完整结果仍有效")

        let orphan = Process()
        orphan.executableURL = stress.executableURL
        orphan.arguments = ["--orphan", root.path]
        try orphan.run()
        orphan.waitUntilExit()
        guard orphan.terminationStatus == 0 else { throw CheckFailure(message: "退出任务子进程失败") }
        let orphanPaths = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("orphan-info.json"))) as! [String]
        try check(orphanPaths.allSatisfy({ manager.fileExists(atPath: $0) }), "实际退出的子进程留下未完成任务和阶段文件")
        _ = try LibraryStore(rootURL: root)
        try check(orphanPaths.allSatisfy({ !manager.fileExists(atPath: $0) }), "新实例自动清理已退出进程留下的未完成音频")

        try afterKill.deleteProject(project.id)
        try check(!manager.fileExists(atPath: root.appendingPathComponent("Projects/\(project.id.uuidString)").path), "删除项目清理 App 自有结果与波形")
        try check(try Data(contentsOf: relocatedURL) == originalBytes && Data(contentsOf: exportURL) == originalExport, "删除项目原曲及用户已导出文件逐字节不变")
        let afterDelete = try LibraryStore(rootURL: root)
        try check(!afterDelete.projects.contains(where: { $0.id == project.id }), "删除项目重开不复活")
        try rejects("晚到的波形回调不能复活已删项目") { try afterDelete.saveWaveform([0.1], projectID: project.id) }

        let protectedProject = try afterDelete.createProject(source: LibraryStore.makeSource(url: relocatedURL, duration: 0.4, sampleRate: 44100, channels: 2), name: "保护边界")
        let (protectedTemporary, protectedResult) = try pair(afterDelete, project: protectedProject)
        _ = try afterDelete.commitResult(projectID: protectedProject.id, temporaryURL: protectedTemporary, record: protectedResult)
        let protectedTrack = try afterDelete.trackURL(projectID: protectedProject.id, resultID: protectedResult.id, track: protectedResult.tracks[0])
        let protectedBytes = try Data(contentsOf: protectedTrack)
        var protectedRecord = afterDelete.projects.first(where: { $0.id == protectedProject.id })!
        protectedRecord.results[0].exports.append(ExportRecord(format: "wav24", trackIDs: ["vocals"], path: protectedTrack.path))
        _ = try afterDelete.saveProject(protectedRecord)
        try afterDelete.deleteProject(protectedProject.id)
        try check((try? Data(contentsOf: protectedTrack)) == protectedBytes && !afterDelete.warnings.isEmpty, "即使导出记录误指向内部结果，删除也保留被保护文件")

        let indexURL = root.appendingPathComponent("library.json")
        let goodIndex = try Data(contentsOf: indexURL)
        let badIndex = Data("{ truncated library".utf8)
        try badIndex.write(to: indexURL)
        try rejects("损坏资料库停止加载，不能自动当作空库") { _ = try LibraryStore(rootURL: root) }
        try check(try Data(contentsOf: indexURL) == badIndex, "损坏库原文件完整保留")
        let recovered = try manager.contentsOfDirectory(at: root.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil)
        try check(recovered.contains(where: { (try? Data(contentsOf: $0)) == badIndex }), "损坏库另有独立诊断副本")
        try goodIndex.write(to: indexURL, options: .atomic)
        let repaired = try LibraryStore(rootURL: root)
        try check(repaired.projects.count == 2, "保留快照恢复后项目可继续读取")

        let vocalsRoot = output.appendingPathComponent("Lead3兼容资料库", isDirectory: true)
        let vocalsStore = try LibraryStore(rootURL: vocalsRoot)
        let vocalSource = try LibraryStore.makeSource(url: relocatedURL, duration: 0.4, sampleRate: 44100, channels: 2)
        let vocalProject = try vocalsStore.createProject(source: vocalSource)
        let (legacyTemporary, legacyResult) = try vocalResult(vocalsStore, project: vocalProject, mode: "leadback", ids: ["lead", "backing"])
        _ = try vocalsStore.commitResult(projectID: vocalProject.id, temporaryURL: legacyTemporary, record: legacyResult)
        try check(vocalsStore.projects[0].results[0].mode == "leadback" && vocalsStore.projects[0].results[0].tracks.count == 2, "旧leadback两轨契约继续有效")
        let (threeTemporary, threeResult) = try vocalResult(vocalsStore, project: vocalProject, mode: "lead3", ids: ["lead", "harmony", "instrumental"], start: 0.2)
        _ = try vocalsStore.commitResult(projectID: vocalProject.id, temporaryURL: threeTemporary, record: threeResult)
        try check(vocalsStore.projects[0].results.count == 2 && threeResult.listening.enabled == ["lead", "harmony", "instrumental"] && threeResult.listening.absoluteTime == 0.2, "新lead3三轨顺序与默认试听完整保存")
        var vocalSaved = vocalsStore.projects[0]
        vocalSaved.results[0].listening = ListeningRecord(absoluteTime: 0.1, enabled: ["backing"], solo: ["backing"])
        vocalSaved.results[1].listening = ListeningRecord(absoluteTime: 0.3, enabled: ["harmony"], solo: ["lead", "harmony"])
        vocalSaved.results[1].exports = [ExportRecord(format: "wav24", trackIDs: ["harmony"], path: exportURL.path)]
        vocalSaved.currentResultID = legacyResult.id
        vocalSaved.mode = "leadback"
        _ = try vocalsStore.saveProject(vocalSaved)
        try vocalsStore.saveWaveform([0.2, 0.6], projectID: vocalProject.id, resultID: threeResult.id, trackID: "harmony")
        let vocalReopened = try LibraryStore(rootURL: vocalsRoot)
        let vocalRestored = vocalReopened.projects[0]
        try check(vocalRestored.mode == "leadback" && vocalRestored.results.map(\.mode) == ["leadback", "lead3"] && vocalRestored.results.map(\.id) == [legacyResult.id, threeResult.id], "schema1重开保留新旧模式身份及版本ID")
        try check(vocalRestored.results[0].listening.solo == ["backing"] && vocalRestored.results[1].listening.enabled == ["harmony"] && vocalRestored.results[1].listening.solo == ["lead", "harmony"], "新旧两轨三轨各自开关与组合独奏独立恢复")
        try check(vocalRestored.results[1].exports.first?.trackIDs == ["harmony"] && vocalReopened.loadWaveform(projectID: vocalProject.id, resultID: threeResult.id, trackID: "harmony") == [0.2, 0.6], "和声单轨导出记录与真实波形缓存恢复")
        let newHarmony = try vocalReopened.trackURL(projectID: vocalProject.id, resultID: threeResult.id, track: threeResult.tracks[1])
        let oldBacking = try vocalReopened.trackURL(projectID: vocalProject.id, resultID: legacyResult.id, track: legacyResult.tracks[1])
        try check(newHarmony != oldBacking && (try AVAudioFile(forReading: newHarmony)).length == 8820 && (try AVAudioFile(forReading: oldBacking)).length == 8820, "新和声与旧和声伴奏是各自真实文件")
        for (ids, label) in [(["lead", "harmony"], "lead3缺伴奏不能入库"), (["lead", "backing", "instrumental"], "lead3不能借用旧backing身份"), (["lead", "instrumental", "harmony"], "lead3错序不能入库")] {
            let (invalid, record) = try vocalResult(vocalReopened, project: vocalProject, mode: "lead3", ids: ids)
            try rejects(label) { _ = try vocalReopened.commitResult(projectID: vocalProject.id, temporaryURL: invalid, record: record) }
            try vocalReopened.discardTemporaryResult(invalid, projectID: vocalProject.id)
        }
        try check(vocalReopened.projects[0].results.count == 2 && vocalReopened.projects[0].results[0].mode == "leadback", "失败三轨任务不覆盖旧两轨历史或有效三轨")
        try vocalReopened.deleteProject(vocalProject.id)
        try check((try Data(contentsOf: relocatedURL)) == originalBytes && (try Data(contentsOf: exportURL)) == originalExport, "删除新旧混合结果项目不影响原曲或导出")
        try writeAmplification(output, source: vocalSource)
        print("COMPLETED \(passed) checks")
    }
}
