import AppKit
import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Runs the same public commands as the UI against real files, player and worker, in an isolated library.
enum NativeAcceptance {
    private static var started = false
    static func run(work: Workspace, window: NSWindow, destination: URL) {
        guard !started else { return }
        started = true
        Task { @MainActor in
            let runner = Runner(work: work, window: window, destination: destination)
            do {
                try await runner.execute()
                try runner.finish(success: true, message: "原生真实任务验收完成")
                if ProcessInfo.processInfo.environment["XIANWAIWU_LYRICS_ONLY"] == "1",
                   ProcessInfo.processInfo.environment["XIANWAIWU_LYRICS_HOLD"] == "1" { return }
                work.quit()
                Darwin.exit(0)
            } catch {
                try? runner.finish(success: false, message: error.localizedDescription)
                work.cancel()
                for _ in 0..<200 where work.hasRunningProcess { try? await Task.sleep(nanoseconds: 100_000_000) }
                work.player.stop()
                Darwin.exit(1)
            }
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Check: Codable {
        let name: String
        let detail: String
        let elapsed: Double
    }

    private struct ProtectedFile: Codable {
        let path: String
        let sha256: String
    }

    private struct ReopenCheckpoint: Codable {
        let project: ProjectRecord
        let folder: FolderRecord
        let projectCount: Int
        let protectedFiles: [ProtectedFile]
        var legacyProject: ProjectRecord? = nil
    }

    private struct ModeIsolationCheckpoint: Codable {
        let projectID: UUID
        let leadID: UUID
        let firstSixID: UUID
        let secondSixID: UUID
        let pairID: UUID
    }

    private struct QualityCheckpoint: Codable {
        let processID: Int32
        let longProjectID: UUID
        let longSourcePath: String
        let folderID: UUID
        let pairRange: AudioRange
        let pairPosition: Double
        let resultProjectID: UUID
        let resultID: UUID
        let resultRange: AudioRange
        let resultPosition: Double
        let resultSolo: Set<String>
        let protectedFiles: [ProtectedFile]
    }

    private final class QualityGate: @unchecked Sendable {
        private let lock = NSLock()
        private let released = DispatchSemaphore(value: 0)
        private var entered = false
        var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func block() {
            lock.lock(); entered = true; lock.unlock()
            _ = released.wait(timeout: .now() + 20)
        }
        func open() { released.signal() }
    }

    @MainActor
    private final class Runner {
        let work: Workspace
        let window: NSWindow
        let destination: URL
        let manager = FileManager.default
        let began = ProcessInfo.processInfo.systemUptime
        var checks: [Check] = []
        var lines: [String] = []
        var exports: [URL] = []
        var legacyProjectID: UUID?
        private var qualityHeartbeats = 0
        var input: URL { destination.appendingPathComponent("输入", isDirectory: true) }
        var output: URL { destination.appendingPathComponent("真实导出", isDirectory: true) }

        init(work: Workspace, window: NSWindow, destination: URL) {
            self.work = work
            self.window = window
            self.destination = destination
        }

        func log(_ message: String) throws {
            lines.append(message)
            print(message)
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").appending("\n").write(to: destination.appendingPathComponent("原生验收.log"), atomically: true, encoding: .utf8)
        }

        func check(_ condition: @autoclosure () -> Bool, _ name: String, _ detail: String = "") throws {
            guard condition() else {
                throw Failure(message: "FAIL \(name)\n\(detail)\n界面状态：\(work.status)\n实际错误：\(work.error ?? "无")")
            }
            checks.append(Check(name: name, detail: detail, elapsed: ProcessInfo.processInfo.systemUptime-began))
            try log("PASS \(checks.count) \(name)\(detail.isEmpty ? "" : " · " + detail)")
        }

        func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

        func wait(_ name: String, timeout: Double = 30, condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "等待超时：\(name)；\(work.status)；\(work.error ?? "无错误消息")") }
                try await pause(0.1)
            }
        }

        func settled(_ name: String, timeout: Double = 1800) async throws {
            try await wait(name, timeout: timeout) { !work.busy && !work.hasRunningProcess }
            try check(work.error == nil, name, work.error ?? "真实引擎已结束")
        }

        func screenshot(_ name: String, width: Double = 1120, height: Double = 740, prepare: (() throws -> Void)? = nil) async throws {
            window.setContentSize(NSSize(width: width, height: height))
            try await pause(0.3)
            guard let view = window.contentView else { throw Failure(message: "窗口缺少真实内容视图") }
            view.layoutSubtreeIfNeeded()
            try prepare?()
            CATransaction.flush()
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "无法截取原生窗口") }
            view.cacheDisplay(in: view.bounds, to: image)
            guard let bytes = image.representation(using: .png, properties: [:]) else { throw Failure(message: "原生截图无法编码") }
            let folder = destination.appendingPathComponent("截图", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
            try log("SCREEN \(name) \(Int(view.bounds.width))×\(Int(view.bounds.height))")
        }

        func command(_ arguments: [String]) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: Project.ffmpeg)
                    process.arguments = arguments
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    do {
                        try process.run()
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        let text = String(data: data, encoding: .utf8) ?? ""
                        guard process.terminationStatus == 0 else { throw Failure(message: "FFmpeg 真实转换失败（\(process.terminationStatus)）\n\(text)") }
                        continuation.resume(returning: text)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }

        func importAudio(_ url: URL) async throws -> UUID {
            let count = work.library.projects.count
            work.importURLs([url])
            try await wait("导入 \(url.lastPathComponent)") { !work.importing }
            try check(work.error == nil && work.library.projects.count == count+1, "真实导入 \(url.pathExtension.uppercased())", work.error ?? url.lastPathComponent)
            guard let id = work.currentProject?.id else { throw Failure(message: "导入后没有项目") }
            try await wait("原曲解码与波形") { !work.sourceChecking && (work.sourceIssue != nil || (!work.wave.isEmpty && work.readyToRun)) }
            try check(work.sourceIssue == nil && work.wave.contains(where: { $0 > 0 }) && work.source != nil, "原曲真实信息与非空波形", "\(url.lastPathComponent)，\(work.source?.duration ?? 0) 秒")
            return id
        }

        func validateTracks(_ expected: [String], length: Double) throws {
            try check(work.player.tracks.map(\.id) == expected && work.manifest?.tracks.map(\.id) == expected, "真实结果音轨顺序", expected.joined(separator: ", "))
            var lengths: [Int64] = []
            var bytes: [Data] = []
            for track in work.player.tracks {
                let file = try AVAudioFile(forReading: track.url)
                lengths.append(file.length)
                bytes.append(try Data(contentsOf: track.url))
                try check(file.processingFormat.sampleRate == 44100 && file.processingFormat.channelCount == 2 && abs(Double(file.length)-length*44100) <= 1,
                          "\(track.id) 真实可解码且时长对齐", "\(file.length) samples / 44100 Hz / 2 channels")
            }
            try check(Set(lengths).count == 1, "所有结果轨道采样数一致")
            try check(Set(bytes).count == bytes.count, "结果轨道内容各不相同")
        }

        func activeHarmonyPreview(_ url: URL) throws -> (time: Double, rmsDB: Double) {
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(rate.rounded())
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { throw Failure(message: "无法读取和声试听片段") }
            var bestEnergy = 0.0, bestTime = 0.0
            while file.framePosition < file.length {
                let start = file.framePosition
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), file.length-start)))
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                var energy = 0.0
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) { let value = Double(channels[channel][frame]); energy += value*value }
                }
                energy /= Double(buffer.frameLength) * Double(buffer.format.channelCount)
                if energy > bestEnergy { bestEnergy = energy; bestTime = Double(start)/rate }
            }
            return (min(max(0, Double(file.length)/rate-2), bestTime), 10*log10(max(1e-12, bestEnergy)))
        }

        func synchronizedNodes(_ expected: [String], label: String) throws {
            let clocks = work.player.nodePlaybackTimes
            let values = expected.compactMap { clocks[$0] }
            let spread = (values.max() ?? 0) - (values.min() ?? 0)
            try check(values.count == expected.count && values.allSatisfy({ $0.isFinite && $0 >= 0 }) && spread <= 1/44100.0 + 0.000001,
                      label, "render 时钟差 \(spread) 秒，\(clocks)")
        }

        func runLegacyFixture() async throws {
            let environment = ProcessInfo.processInfo.environment
            let sourceURL = environment["XIANWAIWU_LEGACY_SOURCE"].map { URL(fileURLWithPath: $0) }
                ?? Project.root.appendingPathComponent("app/audio/模型对照/主唱和声/Cantoria样本/YSM/混音.wav")
            let resultURL = environment["XIANWAIWU_LEGACY_RESULT"].map { URL(fileURLWithPath: $0) }
                ?? Project.root.appendingPathComponent("app/macos/测试/fixtures/legacy-leadback")
            let manifestURL = resultURL.appendingPathComponent("拾声分轨.json")
            let bytes = try Data(contentsOf: manifestURL)
            let old = try JSONDecoder().decode(Manifest.self, from: bytes)
            let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            let sourceSHA = try fileFingerprint(sourceURL).sha256
            try check(old.mode == "leadback" && old.tracks.map(\.id) == ["lead", "backing"] && raw?["sourceSHA256"] as? String == sourceSHA,
                      "旧版真实两轨夹具与其原输入内容指纹匹配", manifestURL.path)
            let projectID = try await importAudio(sourceURL)
            work.showHome()
            let temporary = try work.library.temporaryResultURL(projectID: projectID)
            for track in old.tracks {
                guard track.filename == (track.filename as NSString).lastPathComponent else { throw Failure(message: "旧版夹具文件名无效") }
                try manager.copyItem(at: resultURL.appendingPathComponent(track.filename), to: temporary.appendingPathComponent(track.filename))
            }
            try bytes.write(to: temporary.appendingPathComponent("拾声分轨.json"))
            let record = ResultRecord(mode: old.mode, range: AudioRange(start: old.start, end: old.end),
                                      tracks: old.tracks.map { ResultTrackRecord(id: $0.id, label: $0.label, filename: $0.filename, peakDB: $0.peakDB) },
                                      elapsed: old.elapsed, device: old.device, backend: old.backend, engineGainDB: old.engineGainDB)
            let committed = try work.library.commitResult(projectID: projectID, temporaryURL: temporary, record: record)
            // This inserts an already-existing historical artifact, before opening it through the normal UI commands.
            work.currentProject = nil
            work.openProject(projectID)
            try await wait("旧版两轨历史恢复") { !work.sourceChecking && work.player.tracks.count == 2 }
            work.switchResult(committed.id)
            try check(work.mode == "lead3" && work.manifest?.mode == "leadback" && work.canExportCurrentSelection, "主唱和声板保留旧结果leadback身份和两轨导出入口")
            try validateTracks(["lead", "backing"], length: old.end-old.start)
            work.setAll(false)
            work.toggleSolo("backing")
            let position = min(old.end-0.5, old.start+0.5)
            work.seekAbsolute(position)
            work.togglePlayback()
            try await pause(0.3)
            try check(work.player.playing && work.absoluteTime>position && work.player.audibleTracks == ["backing"], "旧版和声伴奏历史真实独听")
            try synchronizedNodes(["lead", "backing"], label: "旧两轨历史节点保持同步")
            work.togglePlayback()
            _ = try await exportTracks(["backing"], format: "wav24", label: "旧版历史仅导和声伴奏")
            _ = try await exportTracks(["lead", "backing"], format: "flac", label: "旧版历史两轨全导出")
            work.saveListening()
            let disk = try LibraryStore(rootURL: work.library.rootURL)
            try check(disk.projects.first(where: { $0.id == projectID })?.results.first?.mode == "leadback" && disk.projects.first(where: { $0.id == projectID })?.results.first?.tracks.count == 2,
                      "旧schema1历史落盘仍为两轨，未改名为新三轨")
            legacyProjectID = projectID
            try await screenshot("旧版两轨历史兼容")
            work.showHome()
        }

        func exportTracks(_ ids: Set<String>, format: String, label: String) async throws -> URL {
            work.exportDirectory = output
            work.format = format
            work.export(selected: ids)
            try check(work.exporting, "\(label) 启动真实导出")
            try await settled("\(label) 编码完成", timeout: 180)
            guard let url = work.lastExport else { throw Failure(message: "导出未返回真实路径") }
            var isDirectory: ObjCBool = false
            try check(manager.fileExists(atPath: url.path, isDirectory: &isDirectory), "\(label) 实际文件存在", url.path)
            let audioFiles: [URL]
            if isDirectory.boolValue {
                audioFiles = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { ["wav", "mp3", "flac", "aiff", "aif", "m4a", "aac"].contains($0.pathExtension.lowercased()) }
            } else { audioFiles = [url] }
            try check(audioFiles.count == ids.count && isDirectory.boolValue == (ids.count > 1), "\(label) 单文件与多轨目录合同", "\(audioFiles.count) 条，选择 \(ids.sorted())")
            let duration = (work.manifest?.end ?? 0) - (work.manifest?.start ?? 0)
            for fileURL in audioFiles {
                let file = try AVAudioFile(forReading: fileURL)
                let decoded = Double(file.length)/file.processingFormat.sampleRate
                let tolerance = format == "mp3" ? 0.15 : 1/44100.0 + 0.000001
                try check(file.length > 0 && abs(decoded-duration) <= tolerance, "\(label) 文件可解码且时长正确", "\(fileURL.lastPathComponent) / \(decoded) 秒")
                if format == "wav24" || format == "wav16" {
                    let bits = file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int
                    try check(bits == (format == "wav24" ? 24 : 16), "\(label) WAV 位深正确", "\(bits ?? 0) bit")
                }
            }
            try check(work.currentProject?.results.first(where: { $0.id == work.selectedResultID })?.exports.last?.trackIDs == ids.sorted(), "\(label) 导出记录随当前结果保存")
            exports.append(url)
            return url
        }

        func execute() async throws {
            try manager.createDirectory(at: input, withIntermediateDirectories: true)
            try manager.createDirectory(at: output, withIntermediateDirectories: true)
            try log("Native acceptance started \(ISO8601DateFormatter().string(from: Date()))")
            try log("OS \(ProcessInfo.processInfo.operatingSystemVersionString) / device \(ProcessInfo.processInfo.environment["XIANWAIWU_DEVICE"] ?? "auto")")
            try log("Project \(Project.root.path)\nIsolated library \(work.library.rootURL.path)")
            try check(ProcessInfo.processInfo.environment["XIANWAIWU_DATA"] != nil, "验收使用隔离资料库")
            if ProcessInfo.processInfo.environment["XIANWAIWU_WAVEFORM_ONLY"] == "1" {
                try await runWaveformGuide()
                return
            }
            if ProcessInfo.processInfo.environment["XIANWAIWU_LYRICS_ONLY"] == "1" {
                try await runLyrics()
                return
            }
            if ProcessInfo.processInfo.environment["XIANWAIWU_QUALITY_ONLY"] == "1" {
                if ProcessInfo.processInfo.environment["XIANWAIWU_QUALITY_REOPEN"] == "1" {
                    try await runQualityReopen()
                } else { try await runQualityIntegration() }
                return
            }
            if ProcessInfo.processInfo.environment["XIANWAIWU_RANGE_ONLY"] == "1" {
                try await runRangeInteraction()
                return
            }
            if ProcessInfo.processInfo.environment["XIANWAIWU_MODE_ISOLATION_ONLY"] == "1" {
                if ProcessInfo.processInfo.environment["XIANWAIWU_MODE_ISOLATION_REOPEN"] == "1" {
                    try await runModeIsolationReopen()
                } else { try await runModeIsolation() }
                return
            }
            if ProcessInfo.processInfo.environment["XIANWAIWU_WINDOW_CLOSE_ONLY"] == "1" {
                try await runWindowClose()
                return
            }
            if ProcessInfo.processInfo.environment["XIANWAIWU_REOPEN_ONLY"] == "1" {
                try await runReopen()
                return
            }
            if ProcessInfo.processInfo.environment["XIANWAIWU_PLAYBACK_ONLY"] == "1" {
                try await runPlayback()
                return
            }
            try check(work.library.projects.isEmpty, "独立首次启动为空项目库")
            try await screenshot("01-首页-1120x740")
            try await screenshot("02-首页-880x620", width: 880, height: 620)
            let title = "长歌名验证🎵 " + String(repeating: "春风与月光2026 ", count: 5)
            let wav = input.appendingPathComponent(title + ".wav")
            let externalInput = ProcessInfo.processInfo.environment["XIANWAIWU_TEST_AUDIO"]
            let audioInput = externalInput.map { URL(fileURLWithPath: $0) } ?? Project.sample
            let durationArguments = externalInput == nil ? ["-t", "7"] : []
            _ = try await command(["-v", "error", "-y", "-i", audioInput.path] + durationArguments + ["-ar", "44100", "-ac", "2", "-c:a", "pcm_s24le", wav.path])
            let originalData = try Data(contentsOf: wav)
            let formats: [(String, [String])] = [
                ("mp3", ["-c:a", "libmp3lame", "-b:a", "320k"]),
                ("flac", ["-c:a", "flac", "-sample_fmt", "s32"]),
                ("m4a", ["-c:a", "aac", "-b:a", "256k"]),
                ("aac", ["-c:a", "aac", "-b:a", "256k", "-f", "adts"]),
                ("aiff", ["-c:a", "pcm_s24be"]), ("aif", ["-c:a", "pcm_s24be"])
            ]
            let songID = try await importAudio(wav)
            for (ext, codec) in formats {
                let converted = input.appendingPathComponent("真实导入格式.\(ext)")
                _ = try await command(["-v", "error", "-y", "-i", wav.path] + codec + [converted.path])
                _ = try await importAudio(converted)
            }
            let beforeInvalid = work.library.projects.count
            work.importURLs([wav, wav])
            try check(work.error != nil && work.library.projects.count == beforeInvalid, "多首拖入不创建项目")
            let broken = input.appendingPathComponent("损坏音频.wav")
            try Data("not an audio file".utf8).write(to: broken)
            work.importURLs([broken])
            try await wait("坏文件读取结束") { !work.importing }
            try check(work.error != nil && work.library.projects.count == beforeInvalid, "损坏文件不创建项目且保留已有库")
            work.error = nil
            try await runLegacyFixture()
            work.openProject(songID)
            try await wait("主测试项目波形就绪") { !work.sourceChecking && work.readyToRun && !work.wave.isEmpty }
            let duration = work.source?.duration ?? 0
            try check(duration >= 5.6 && (externalInput != nil || abs(duration-7) < 0.001), "主测试使用真实源音频", "\(duration) 秒，\(audioInput.path)；\(externalInput == nil ? "默认七秒回归" : "外部整首输入，未截短")")
            try await screenshot("03-原曲-长中文emoji名")
            work.seekAbsolute(0.7)
            work.togglePlayback()
            try await pause(0.4)
            try check(work.player.playing && work.absoluteTime > 0.85, "原曲真实播放时钟前进")
            work.togglePlayback()
            let paused = work.absoluteTime
            try await pause(0.15)
            try check(!work.player.playing && abs(work.absoluteTime-paused)<0.015, "暂停后播放位置稳定")
            work.player.volume = 0.37
            work.seekAbsolute(0.7)
            try check(abs(work.absoluteTime-0.7)<0.001, "原曲绝对坐标定位")
            work.selectMode("pair")
            work.start()
            try check(work.processing, "人声与伴奏真实任务启动")
            let countWhileRunning = work.library.projects.first(where: { $0.id == songID })?.results.count ?? -1
            work.start()
            try check(work.processing && (work.library.projects.first(where: { $0.id == songID })?.results.count ?? -1) == countWhileRunning, "运行中重复开始不新增任务结果")
            try await screenshot("04-真实处理中")
            try await settled("人声与伴奏完成")
            try validateTracks(["vocals", "instrumental"], length: duration)
            guard let pairID = work.selectedResultID else { throw Failure(message: "双轨完成后缺结果ID") }
            try await wait("双轨真实波形") { work.trackWaves.count == 2 }
            try await screenshot("05-双轨-1120x740")
            try await screenshot("06-双轨-880x620", width: 880, height: 620)

            work.setAll(false)
            try check(work.player.audibleTracks.isEmpty && work.player.solo.isEmpty, "全关清除独奏并真正全部静音")
            work.toggleTrack("instrumental")
            try check(work.player.audibleTracks == ["instrumental"], "静音开关控制实际发声轨")
            work.toggleSolo("vocals")
            work.toggleSolo("instrumental")
            try check(work.player.audibleTracks == ["vocals", "instrumental"], "双轨组合独奏")
            work.clearSolo()
            try check(work.player.audibleTracks == ["instrumental"], "清除独奏恢复之前开关组合")
            work.setAll(true)
            work.seekAbsolute(0.7)
            work.togglePlayback()
            try await pause(0.2)
            let beforeOriginal = work.absoluteTime
            work.original()
            try check(!work.listeningToResult && work.player.playing && abs(work.absoluteTime-beforeOriginal)<0.08, "播放中切原曲保留绝对位置与播放状态")
            let beforeResult = work.absoluteTime
            work.separated()
            try check(work.listeningToResult && work.player.playing && abs(work.absoluteTime-beforeResult)<0.08, "播放中切分轨保留绝对位置与播放状态")
            work.togglePlayback()

            let firstExport = try await exportTracks(["instrumental"], format: "wav24", label: "I01仅伴奏WAV24")
            let firstExportData = try Data(contentsOf: firstExport)
            let repeatedExport = try await exportTracks(["instrumental"], format: "wav24", label: "重名再次保存")
            try check(firstExport != repeatedExport && (try? Data(contentsOf: firstExport)) == firstExportData, "重名自动编号且旧文件逐字节不变")
            _ = try await exportTracks(["vocals", "instrumental"], format: "wav16", label: "双轨全选WAV16")
            _ = try await exportTracks(["instrumental"], format: "flac", label: "单轨FLAC")
            _ = try await exportTracks(["instrumental"], format: "mp3", label: "单轨MP3")

            work.seekAbsolute(0.7)
            work.toggleSolo("instrumental")
            let previousRange = work.range
            work.beginRange()
            work.updateDraft(1.2, 5.6)
            work.previewDraft()
            try await pause(0.2)
            try check(work.range == previousRange && work.absoluteTime >= 1.2 && work.absoluteTime < 5.6 && work.player.playing, "草选真实试听但尚未应用")
            try await screenshot("07-选段草稿")
            work.cancelRange()
            try check(work.listeningToResult && work.selectedResultID == pairID && !work.player.playing && abs(work.absoluteTime-0.7)<0.03 && work.player.solo == ["instrumental"], "取消草选恢复暂停结果及原开关独奏")
            work.togglePlayback()
            try await pause(0.15)
            let beforeDraft = work.absoluteTime
            work.beginRange()
            work.updateDraft(1.2, 5.6)
            work.previewDraft()
            try await pause(0.15)
            work.cancelRange()
            try check(work.player.playing && work.listeningToResult && abs(work.absoluteTime-beforeDraft)<0.12, "播放中取消草选恢复原结果播放位置")
            work.togglePlayback()
            work.clearSolo()
            work.selectMode("lead3")
            try check(!work.listeningToResult && work.selectedResultID == nil && work.manifest == nil && work.mode == "lead3" && !work.hasResultForCurrentMode && work.availableResults.isEmpty && work.player.tracks.map(\.id) == ["original"], "未分离的新板块只听原曲，结果入口灰态且没有外板音轨")
            work.start()
            try await settled("主唱、和声与伴奏完成")
            try validateTracks(["lead", "harmony", "instrumental"], length: duration)
            guard let leadID = work.selectedResultID else { throw Failure(message: "主唱分离缺结果ID") }
            try await wait("三轨真实波形") { work.trackWaves.count == 3 }
            try await screenshot("08-主唱和声伴奏-1120x740")
            try await screenshot("08-主唱和声伴奏-880x620", width: 880, height: 620)
            work.setAll(false)
            work.toggleTrack("harmony")
            try check(work.player.audibleTracks == ["harmony"], "三轨单独和声开关控制实际发声轨")
            guard let harmonyTrack = work.player.tracks.first(where: { $0.id == "harmony" }) else { throw Failure(message: "没有可试听的真实和声音轨") }
            let preview = try activeHarmonyPreview(harmonyTrack.url)
            try check(preview.rmsDB > -60, "真实和声音轨有可听内容", String(format: "最大一秒RMS %.2f dBFS；从 %.2f 秒单独试听", preview.rmsDB, preview.time))
            work.seekAbsolute(preview.time)
            work.togglePlayback()
            try await pause(1.2)
            try log("DIAGNOSTICS harmony \(work.player.playbackDiagnostics)")
            try check(work.player.playing && work.absoluteTime>preview.time+0.8, "和声单轨有声段真实持续播放")
            try synchronizedNodes(["lead", "harmony", "instrumental"], label: "三轨独听和声时节点同步")
            work.togglePlayback()
            work.toggleSolo("lead")
            work.toggleSolo("harmony")
            try check(work.player.audibleTracks == ["lead", "harmony"], "三轨主唱加和声组合独奏")
            work.seekAbsolute(1.3)
            work.togglePlayback()
            try await pause(0.25)
            try synchronizedNodes(["lead", "harmony", "instrumental"], label: "三轨定位后组合播放节点同步")
            work.togglePlayback()
            work.clearSolo()
            try check(work.player.audibleTracks == ["harmony"], "三轨清除独奏恢复和声单轨开关")
            _ = try await exportTracks(["harmony"], format: "wav24", label: "和声单轨WAV24")
            _ = try await exportTracks(["lead", "harmony"], format: "flac", label: "三轨中主唱和声组合")
            _ = try await exportTracks(["lead", "harmony", "instrumental"], format: "wav24", label: "主唱和声伴奏全三轨")
            work.toggleSolo("harmony")
            work.seekAbsolute(2.1)
            work.saveListening()
            work.selectMode("pair")
            work.switchResult(pairID)
            try check(work.selectedResultID == pairID && work.manifest?.mode == "pair", "I02切回第一份人声伴奏结果")
            work.selectMode("lead3")
            work.switchResult(leadID)
            try check(work.selectedResultID == leadID && work.player.solo == ["harmony"] && work.manifest?.mode == "lead3", "I02切回三轨结果恢复和声独奏")
            work.saveListening()
            do {
                let disk = try LibraryStore(rootURL: work.library.rootURL)
                let replay = Workspace(library: disk)
                replay.openProject(songID)
                try await wait("重开Workspace恢复结果") { !replay.sourceChecking && replay.manifest != nil && !replay.trackWaves.isEmpty }
                try check(replay.versions.count == 2 && replay.selectedResultID == leadID && replay.player.solo == ["harmony"] && replay.player.tracks.map(\.id) == ["lead", "harmony", "instrumental"] && abs(replay.absoluteTime-2.1)<0.05, "I02独立Store和Workspace恢复三轨、多结果、范围、和声试听状态")
            }

            work.selectMode("music6")
            work.beginRange()
            work.updateDraft(5.6, 1.2)
            try check(work.draftError != nil, "反向范围拒绝")
            work.updateDraft(1, 1.1)
            try check(work.draftError != nil, "少于0.2秒范围拒绝")
            work.updateDraft(-1, 2)
            try check(work.draftError != nil, "越界范围拒绝")
            work.updateDraft(1.2, 5.6)
            work.applyRange()
            try check(work.range == 1.2...5.6 && !work.listeningToResult && work.player.limit == 1.2...5.6, "应用选段同时限制原曲预听")
            work.selectMode("music6")
            work.start()
            try check(work.processing, "I03六轨第一次任务真实启动")
            try await pause(0.8)
            work.cancel()
            try await wait("取消六轨停止进程", timeout: 60) { !work.busy && !work.hasRunningProcess }
            try check(work.error == nil && work.currentProject?.results.count == 2 && work.range == 1.2...5.6, "取消六轨保留旧结果和已应用范围", work.error ?? work.status)
            work.error = nil
            work.start()
            try await settled("音乐六轨选段重跑完成")
            try validateTracks(["vocals", "drums", "bass", "guitar", "piano", "other"], length: 4.4)
            try check(work.currentProject?.results.count == 3 && work.manifest?.start == 1.2 && work.manifest?.end == 5.6, "I03选段新结果保留原曲绝对坐标和旧版本")
            try await wait("六轨真实波形") { work.trackWaves.count == 6 }
            try await screenshot("09-六轨-1120x740")
            try await screenshot("10-六轨-880x620", width: 880, height: 620)
            work.setAll(false)
            work.toggleSolo("guitar")
            work.toggleSolo("drums")
            try check(work.player.audibleTracks == ["guitar", "drums"], "I03吉他叠加鼓组合独奏")
            try log("TRACE six before seek playing=\(work.player.playing) absolute=\(work.absoluteTime) relative=\(work.player.time) bounds=\(work.player.limit)")
            work.seekAbsolute(2.3)
            try log("TRACE six after seek playing=\(work.player.playing) absolute=\(work.absoluteTime) relative=\(work.player.time)")
            work.togglePlayback()
            try log("TRACE six after play playing=\(work.player.playing) absolute=\(work.absoluteTime) relative=\(work.player.time)")
            try await pause(0.2)
            try log("DIAGNOSTICS six 0.2s \(work.player.playbackDiagnostics)")
            try check(work.player.playing && work.absoluteTime > 2.3, "选段六轨同步播放器真实前进", "playing=\(work.player.playing), absolute=\(work.absoluteTime), relative=\(work.player.time), bounds=\(work.player.limit)")
            let sixTime = work.absoluteTime
            work.original()
            try check(work.player.playing && abs(work.absoluteTime-sixTime)<0.08, "选段结果与原曲按绝对秒切换")
            work.separated()
            work.togglePlayback()
            let guitarExport = try await exportTracks(["guitar"], format: "wav24", label: "I03只保存吉他")
            let guitarData = try Data(contentsOf: guitarExport)
            _ = try await exportTracks(["guitar", "drums"], format: "flac", label: "六轨中仅选吉他与鼓")
            _ = try await exportTracks(["vocals", "drums", "bass", "guitar", "piano", "other"], format: "wav24", label: "六轨全选")
            let sixID = work.selectedResultID
            work.clearRange()
            try check(work.range.lowerBound == 0 && abs(work.range.upperBound-duration)<0.001 && work.currentProject?.results.count == 3, "恢复整首只改下一次范围并保留选段结果")
            if let sixID { work.switchResult(sixID) }

            let folder = try work.library.createFolder(name: "大冰验收")
            work.moveProject(songID, to: folder.id)
            try check(work.currentProject?.folderID == folder.id, "原生工作流移动项目归属")
            work.selectedFolderID = folder.id
            work.deleteFolder(folder.id)
            try check(work.selectedFolderID == nil && work.currentProject?.folderID == nil && work.library.projects.contains(where: { $0.id == songID }), "删除当前筛选文件夹保留项目并回全部")
            work.showHome()
            try await screenshot("11-持久化项目首页")

            let moved = input.appendingPathComponent("重新定位后的原音频.wav")
            // A same-volume move is followed by macOS security bookmarks. Unlink the old inode
            // after writing a distinct copy so this fixture actually represents a missing source.
            try originalData.write(to: moved, options: .atomic)
            try manager.removeItem(at: wav)
            work.openProject(songID)
            try await wait("丢失原曲提示") { !work.sourceChecking && work.sourceIssue != nil }
            try check(work.listeningToResult && !work.player.tracks.isEmpty && !work.readyToRun, "原曲丢失时保留结果试听并阻止重新分离")
            work.seekAbsolute(2.1)
            work.togglePlayback()
            try await pause(0.2)
            try check(work.player.playing, "原曲丢失后内部结果仍能真实播放")
            work.togglePlayback()
            _ = try await exportTracks(["guitar"], format: "wav24", label: "原曲丢失后导出现有结果")
            work.relocateSource(to: moved)
            try await wait("重定位原曲") { !work.sourceChecking && work.sourceIssue == nil && work.source != nil && work.readyToRun }
            try check(work.currentProject?.source.url == moved && work.currentProject?.results.count == 3, "重新定位同内容原曲保留全部结果")

            if ProcessInfo.processInfo.environment["XIANWAIWU_KEEP_PROJECT"] == "1" {
                try await keepForReopen(projectID: songID, source: moved)
                return
            }

            let originalHash = originalData
            let receipts = exports
            let receiptSizes = receipts.map { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? -1 : ((try? Data(contentsOf: $0).count) ?? -2) }
            work.showHome()
            work.deleteProject(songID)
            if let legacyProjectID { work.deleteProject(legacyProjectID) }
            try check(!work.library.projects.contains(where: { $0.id == songID }), "原生删除项目从索引移除")
            try check((try? Data(contentsOf: moved)) == originalHash && (try? Data(contentsOf: guitarExport)) == guitarData, "删除项目不动原曲与已导出吉他文件")
            try check(zip(receipts, receiptSizes).allSatisfy { url, size in manager.fileExists(atPath: url.path) && (size == -1 || (try? Data(contentsOf: url).count) == size) }, "删除项目保留所有格式导出文件与目录")
            let finalStore = try LibraryStore(rootURL: work.library.rootURL)
            try check(!finalStore.projects.contains(where: { $0.id == songID }) && finalStore.projects.count == formats.count, "重开后已删除项目不复活，其他格式项目完整保留")
            try await screenshot("12-删除项目后的首页")
        }

        func runWindowClose() async throws {
            _ = try await importAudio(Project.sample)
            work.start()
            try await wait("关闭窗口验收真实任务启动") { work.processing && work.hasRunningProcess }
            func button(in view: NSView) -> NSButton? {
                if let candidate = view as? NSButton, candidate.title == "继续处理" { return candidate }
                for child in view.subviews { if let found = button(in: child) { return found } }
                return nil
            }
            var pressed = false
            var attempts = 0
            let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
                attempts += 1
                if let content = NSApp.modalWindow?.contentView, let control = button(in: content) {
                    pressed = true; control.performClick(nil); timer.invalidate()
                } else if attempts > 50 { NSApp.abortModal(); timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            window.performClose(nil)
            timer.invalidate()
            try check(pressed && window.isVisible && work.hasRunningProcess, "关闭处理中窗口选择继续后，真实窗口与任务保持")
            work.cancel()
            try await wait("关闭窗口验收取消任务") { !work.busy && !work.hasRunningProcess }
            try check(work.currentProject != nil && work.currentProject?.results.isEmpty == true, "退出提示取消后的项目保留且无假结果")
        }

        private func nativeViews(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(nativeViews)
        }

        private func originalCanvas() -> XWWaveformCanvas? {
            guard let content = window.contentView else { return nil }
            return nativeViews(content).compactMap { $0 as? XWWaveformCanvas }.first {
                $0.identifier?.rawValue == "xw.waveform.original" && !$0.isHidden && $0.visibleRect.width > 100 && $0.visibleRect.height > 20
            }
        }

        private func rangeMouse(_ type: NSEvent.EventType, canvas: XWWaveformCanvas, time: Double, extraX: CGFloat = 0) throws {
            let span = canvas.displayBounds.upperBound-canvas.displayBounds.lowerBound
            let x = 6 + CGFloat((time-canvas.displayBounds.lowerBound)/span)*(canvas.bounds.width-12) + extraX
            let local = NSPoint(x: x, y: canvas.bounds.midY)
            guard let event = NSEvent.mouseEvent(with: type, location: canvas.convert(local, to: nil), modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                throw Failure(message: "无法创建原生鼠标事件")
            }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: throw Failure(message: "选段验收收到错误事件类型")
            }
        }

        private func dragOriginal(from start: Double, to end: Double, extraX: CGFloat = 0) async throws {
            guard let canvas = originalCanvas() else { throw Failure(message: "实际窗口找不到原曲波形视图") }
            try rangeMouse(.leftMouseDown, canvas: canvas, time: start, extraX: extraX)
            for fraction in [0.15, 0.4, 0.7, 1.0] {
                try rangeMouse(.leftMouseDragged, canvas: canvas, time: start+(end-start)*fraction, extraX: extraX)
                try await pause(0.04)
            }
            try rangeMouse(.leftMouseUp, canvas: canvas, time: end, extraX: extraX)
            try await pause(0.1)
            try log("MOUSE drag \(start)→\(end), editing=\(work.rangeEditing), draft=\(work.draftRange), applied=\(work.range)")
        }

        private struct AccessibleItem {
            let object: AnyObject
            let identifier: String
            let frame: NSRect
        }

        private func accessibleItems() -> [AccessibleItem] {
            guard let content = window.contentView else { return [] }
            var visited = Set<ObjectIdentifier>()
            var found = [AccessibleItem]()
            func visit(_ object: AnyObject) {
                if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
                if let host = object as? XWRetainedContainer, !host.interactive { return }
                guard visited.count < 5000, visited.insert(ObjectIdentifier(object)).inserted else { return }
                if let item = object as? NSAccessibilityProtocol {
                    if let id = item.accessibilityIdentifier(), !id.isEmpty { found.append(AccessibleItem(object: object, identifier: id, frame: item.accessibilityFrame())) }
                    for child in item.accessibilityChildren() ?? [] { visit(child as AnyObject) }
                } else if let item = object as? NSAccessibilityElementProtocol, let id = item.accessibilityIdentifier?(), !id.isEmpty {
                    found.append(AccessibleItem(object: object, identifier: id, frame: item.accessibilityFrame()))
                }
                // SwiftUI's group nodes expose the public children selector without adopting
                // NSAccessibilityProtocol. Do not stop traversal at the narrower element protocol.
                if !(object is NSAccessibilityProtocol), let item = object as? NSObject {
                    for name in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder"] {
                        let selector = NSSelectorFromString(name)
                        if item.responds(to: selector), let children = item.perform(selector)?.takeUnretainedValue() as? [Any] {
                            for child in children { visit(child as AnyObject) }
                        }
                    }
                }
                if let view = object as? NSView { for child in view.subviews { visit(child) } }
            }
            visit(content)
            return found
        }

        private func accessibleItem(_ id: String) throws -> AccessibleItem {
            let items = accessibleItems()
            guard let item = items.first(where: { $0.identifier == id && !$0.frame.isEmpty }) else {
                throw Failure(message: "实际原生辅助功能树找不到 \(id)。已见ID \(items.map(\.identifier).joined(separator: ", "))")
            }
            return item
        }

        private func visibleRangeControl(_ id: String) throws {
            let item = try accessibleItem(id)
            guard let content = window.contentView else { throw Failure(message: "窗口缺内容") }
            let visible = window.convertToScreen(content.convert(content.bounds, to: nil))
            let intersection = item.frame.intersection(visible)
            let ratio = intersection.width*intersection.height/(item.frame.width*item.frame.height)
            if id == "xw.range.editor" {
                let controls = try ["xw.range.start", "xw.range.end", "xw.range.apply", "xw.range.cancel"].map(accessibleItem)
                try check(item.frame.width>300 && item.frame.height>=29 && controls.allSatisfy { item.frame.insetBy(dx: -1, dy: -1).contains($0.frame) },
                          "常驻选段栏完整包含时间字段和完成取消按钮", "editor=\(item.frame), children=\(controls.map(\.frame))")
            }
            try check(ratio > 0.98, "原生控件完整显示 \(id)", "frame=\(item.frame), window=\(visible)")
        }

        private func pressRangeControl(_ id: String, pauseAfter: Double = 0.15) async throws {
            try visibleRangeControl(id)
            let object = try accessibleItem(id).object
            let pressed: Bool
            if let button = object as? NSAccessibilityButton { pressed = button.accessibilityPerformPress() }
            else if let item = object as? NSAccessibilityProtocol { pressed = item.accessibilityPerformPress() }
            else if let item = object as? NSObject, item.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                let selector = NSSelectorFromString("accessibilityPerformPress")
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                let action = unsafeBitCast(item.method(for: selector), to: Press.self)
                pressed = action(item, selector)
            }
            else { pressed = false }
            try check(pressed, "真实原生按钮动作 \(id)")
            try await pause(pauseAfter)
        }

        private func typeRangeValue(_ value: String, fieldID: String) async throws {
            let item = try accessibleItem(fieldID)
            guard let content = window.contentView else { throw Failure(message: "窗口缺内容") }
            let fields = nativeViews(content).compactMap { $0 as? NSTextField }
            guard let field = fields.first(where: { field in
                let rect = window.convertToScreen(field.convert(field.bounds, to: nil))
                return rect.intersects(item.frame) && field.isEditable && !field.isHidden
            }) else { throw Failure(message: "找不到 \(fieldID) 对应的原生可编辑输入框") }
            window.makeFirstResponder(field)
            field.selectText(nil)
            guard let editor = field.currentEditor() as? NSTextView else { throw Failure(message: "时间输入框未取得原生文字编辑器") }
            editor.selectAll(nil)
            editor.insertText(value, replacementRange: editor.selectedRange())
            try await pause(0.05)
            var axValues: [String: String] = [:]
            for id in ["xw.range.start", "xw.range.end"] {
                if let object = try? accessibleItem(id).object {
                    if let accessible = object as? NSAccessibilityProtocol {
                        axValues[id] = String(describing: accessible.accessibilityValue() ?? "nil")
                    } else if let object = object as? NSObject, object.responds(to: NSSelectorFromString("accessibilityValue")) {
                        if let value = object.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() {
                            axValues[id] = String(describing: value)
                        } else { axValues[id] = "nil" }
                    } else { axValues[id] = "no AX value getter" }
                } else { axValues[id] = "not found" }
            }
            let responderType = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let detail = "expected=\(value), editor=\(editor.string), field=\(field.stringValue), firstResponder=\(responderType), sameEditor=\(window.firstResponder === editor), AX=\(axValues), draft=\(work.draftRange), draftError=\(work.draftError ?? "nil")"
            try check(window.firstResponder === editor && editor.string == value, "真实输入时间且保持字段焦点 \(fieldID)", detail)
        }

        private func pressRangeEscape() async throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
                throw Failure(message: "无法创建真实 Escape 事件")
            }
            NSApp.sendEvent(event)
            try await pause(0.2)
        }

        private func qualityDocument() throws -> LibraryDocument {
            // Decode the index only: a second Store/Workspace could perform writes or cleanup.
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LibraryDocument.self, from: Data(contentsOf: work.library.rootURL.appendingPathComponent("library.json")))
        }

        private func qualityProject(_ id: UUID) throws -> ProjectRecord {
            guard let project = try qualityDocument().projects.first(where: { $0.id == id }) else {
                throw Failure(message: "独立只读索引找不到专项项目 \(id)")
            }
            return project
        }

        private func qualityResponsive(while gate: QualityGate, label: String) async throws {
            let before = qualityHeartbeats
            let timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.qualityHeartbeats += 1 }
            }
            defer { timer.invalidate() }
            try await pause(0.18)
            try check(gate.isWaiting && qualityHeartbeats >= before + 2, label,
                      "后台核对仍挂起，主线程计时器实际执行 \(qualityHeartbeats-before) 次")
        }

        private func qualityOpen(_ id: UUID) async throws {
            work.openProject(id)
            try await wait("专项打开项目并完成原曲核对") { work.currentProject?.id == id && !work.sourceChecking }
            try check(work.sourceIssue == nil && !work.player.tracks.isEmpty, "专项项目真实播放器已准备")
        }

        private func qualityFixture() async throws -> (projectID: UUID, resultID: UUID) {
            let environment = ProcessInfo.processInfo.environment
            let sourceURL = environment["XIANWAIWU_LEGACY_SOURCE"].map { URL(fileURLWithPath: $0) }
                ?? Project.root.appendingPathComponent("app/audio/模型对照/主唱和声/Cantoria样本/YSM/混音.wav")
            let resultURL = environment["XIANWAIWU_LEGACY_RESULT"].map { URL(fileURLWithPath: $0) }
                ?? Project.root.appendingPathComponent("app/macos/测试/fixtures/legacy-leadback")
            let bytes = try Data(contentsOf: resultURL.appendingPathComponent("拾声分轨.json"))
            let old = try JSONDecoder().decode(Manifest.self, from: bytes)
            let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            let fingerprint = try fileFingerprint(sourceURL)
            try check(old.mode == "leadback" && old.tracks.map(\.id) == ["lead", "backing"] && raw?["sourceSHA256"] as? String == fingerprint.sha256,
                      "质量专项复用同源真实旧两轨，无新模型推理")
            let id = try await importAudio(sourceURL)
            work.showHome()
            let temporary = try work.library.temporaryResultURL(projectID: id)
            for track in old.tracks {
                guard track.filename == (track.filename as NSString).lastPathComponent else { throw Failure(message: "旧结果夹具文件名无效") }
                try manager.copyItem(at: resultURL.appendingPathComponent(track.filename), to: temporary.appendingPathComponent(track.filename))
            }
            try bytes.write(to: temporary.appendingPathComponent("拾声分轨.json"))
            let record = ResultRecord(mode: old.mode, range: AudioRange(start: old.start, end: old.end),
                                      tracks: old.tracks.map { ResultTrackRecord(id: $0.id, label: $0.label, filename: $0.filename, peakDB: $0.peakDB) },
                                      elapsed: old.elapsed, device: old.device, backend: old.backend, engineGainDB: old.engineGainDB)
            let saved = try work.library.commitResult(projectID: id, temporaryURL: temporary, record: record)
            work.currentProject = nil
            try await qualityOpen(id)
            work.switchResult(saved.id)
            try check(work.manifest?.mode == "leadback" && work.player.tracks.map(\.id) == ["lead", "backing"],
                      "真实旧两轨在新工作区按原身份加载")
            return (id, saved.id)
        }

        func runQualityIntegration() async throws {
            window.setContentSize(NSSize(width: 1120, height: 740)); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try check(work.library.projects.isEmpty, "质量专项首次真实App使用空隔离库")
            let environment = ProcessInfo.processInfo.environment
            let sourceURL = environment["XIANWAIWU_QUALITY_SOURCE"].map { URL(fileURLWithPath: $0) }
                ?? Project.root.appendingPathComponent("app/audio/样本/原始分轨混音/混音.wav")
            let longURL = input.appendingPathComponent("真实七秒录音循环70秒-仅交互验收.wav")
            _ = try await command(["-v", "error", "-y", "-stream_loop", "9", "-i", sourceURL.path,
                                   "-t", "70", "-ar", "44100", "-ac", "2", "-c:a", "pcm_s24le", longURL.path])
            let longID = try await importAudio(longURL)
            let longFingerprint = try fileFingerprint(longURL)
            try check(abs((work.source?.duration ?? 0)-70)<1/44100.0, "真实录音经FFmpeg循环形成70秒交互输入，未生成模型结果")
            work.selectMode("pair")
            work.beginRange(); work.updateDraft(20, 40); work.applyRange()
            try check(work.range == 20...40, "质量专项起始已应用20到40秒")
            work.beginRange(); try await pause(0.15)
            try await typeRangeValue("50", fieldID: "xw.range.start")
            try await typeRangeValue("60", fieldID: "xw.range.end")
            try await pressRangeControl("xw.range.apply")
            try check(!work.rangeEditing && work.range == 50...60 && work.player.limit == 50...60,
                      "真实AX先改开始50再改结束60，点击完成原子应用50到60")
            work.beginRange(); try await pause(0.15)
            try await typeRangeValue("oops", fieldID: "xw.range.start")
            try await pressRangeControl("xw.range.apply")
            try check(work.rangeEditing && work.range == 50...60 && work.draftError != nil,
                      "非法时间未退出编辑且保留上次有效处理范围")
            try await typeRangeValue("70", fieldID: "xw.range.start")
            try await typeRangeValue("60", fieldID: "xw.range.end")
            try await pressRangeControl("xw.range.apply")
            try check(work.rangeEditing && work.range == 50...60 && !work.rangeValid,
                      "反向非法起止未覆盖上次有效范围")
            try await typeRangeValue("0:50.25", fieldID: "xw.range.start")
            try await typeRangeValue("1:00.50", fieldID: "xw.range.end")
            try await pressRangeControl("xw.range.preview")
            try check(work.rangeEditing && work.range == 50...60 && work.draftRange == 50.25...60.5 &&
                      work.player.limit == work.draftRange && work.player.playing && work.absoluteTime >= 50.25 && work.absoluteTime < 60.5,
                      "修正非法字段后mm:ss与小数成对生效并真实试听，尚未覆盖已应用范围")
            try await pressRangeControl("xw.range.cancel")
            try check(work.range == 50...60 && !work.rangeEditing, "非法修正试听取消后仍保持50到60秒")
            work.clearRange(); work.seekAbsolute(25); work.saveListening()

            do {
                let gate = QualityGate(), library = work.library
                work.sourceInspector = { source in gate.block(); return library.sourceStatus(for: source) }
                defer { work.sourceInspector = nil; gate.open() }
                work.openProject(longID)
                try await wait("原曲校验注入门闩已进入") { gate.isWaiting }
                try check(work.sourceChecking && work.player.tracks.isEmpty, "校验中原曲播放器尚未准备，不能拿0覆盖位置")
                work.selectMode("lead3"); work.selectMode("pair")
                work.quit()
                let pending = try qualityProject(longID)
                try check(abs((pending.modeStates?["pair"]?.sourceListening.absoluteTime ?? -1)-25)<0.001 &&
                          abs(pending.sourceListening.absoluteTime-25)<0.001,
                          "原曲校验中切板与quit保存，独立只读索引仍保留pair25秒")
                try await qualityResponsive(while: gate, label: "原曲校验挂起时主线程Task与真实Timer仍响应")
                work.sourceInspector = nil; gate.open()
                try await wait("释放原曲校验后恢复播放器") { !work.sourceChecking && !work.player.tracks.isEmpty }
                try check(work.mode == "pair" && abs(work.absoluteTime-25)<0.03 && work.sourceIssue == nil,
                          "校验释放后正确准备原曲并恢复25秒")
            }

            work.seekAbsolute(26.25)
            try await wait("0.25秒后台自动保存真实落盘") {
                guard let saved = try? self.qualityProject(longID) else { return false }
                return abs((saved.modeStates?["pair"]?.sourceListening.absoluteTime ?? -1)-26.25)<0.03
            }
            try check(work.error == nil, "停播定位的后台保存未出现存储错误")
            work.togglePlayback()
            try await pause(3.4)
            try await wait("周期自动保存实际落盘，兼容Timer初始相位", timeout: 4) {
                guard let saved = try? self.qualityProject(longID) else { return false }
                return (saved.modeStates?["pair"]?.sourceListening.absoluteTime ?? 0)>27.25
            }
            let timed = try qualityProject(longID)
            try check(work.player.playing && (timed.modeStates?["pair"]?.sourceListening.absoluteTime ?? 0)>27.25 && work.error == nil,
                      "播放超过3秒的实际定时自动保存落盘前进，无额外Workspace写库", "disk=\(timed.modeStates?["pair"]?.sourceListening.absoluteTime ?? -1)")
            work.togglePlayback()
            let folder = try work.library.createFolder(name: "六项修复后台归档")
            work.seekAbsolute(31.25); work.moveProject(longID, to: folder.id)
            let archived = try qualityProject(longID)
            try check(archived.folderID == folder.id && abs((archived.modeStates?["pair"]?.sourceListening.absoluteTime ?? -1)-31.25)<0.03,
                      "有待保存定位时归档，项目归属与pair位置都落盘")
            work.seekAbsolute(32.5); work.selectMode("lead3"); work.seekAbsolute(12.25); work.selectMode("pair")
            try check(abs(work.absoluteTime-32.5)<0.03, "后台保存与切板交错后恢复pair独立位置")

            let fixture = try await qualityFixture()
            work.setAll(false); work.toggleSolo("backing"); work.seekAbsolute(2.25)
            work.moveProject(fixture.projectID, to: folder.id)
            var savedResultProject = try qualityProject(fixture.projectID)
            var savedResult = savedResultProject.results.first { $0.id == fixture.resultID }
            try check(savedResultProject.folderID == folder.id && savedResult?.listening.solo == ["backing"] &&
                      abs((savedResult?.listening.absoluteTime ?? -1)-2.25)<0.03,
                      "真实旧结果独奏与定位遇到归档仍保存，不丢结果身份")
            work.selectMode("pair"); work.seekAbsolute(3.25); work.selectMode("lead3")
            try check(work.manifest?.mode == "leadback" && work.player.solo == ["backing"] && abs(work.absoluteTime-2.25)<0.03,
                      "切板后真实结果重载仍恢复backing独奏与2.25秒")

            try await qualityOpen(longID)
            let bookmarkURL = input.appendingPathComponent("真实长录音-自动书签同字节位置.wav")
            try manager.copyItem(at: longURL, to: bookmarkURL)
            do {
                let board = work.mode, bounds = work.range
                work.sourceInspector = { _ in .available(bookmarkURL) }
                defer { work.processing = false; work.sourceInspector = nil }
                work.processing = true
                work.openProject(longID)
                try await wait("假busy下自动书签新路径后台验证并恢复") { !work.sourceChecking }
                let recovered = try qualityProject(longID)
                try check(work.processing && !work.hasRunningProcess && work.source?.url == bookmarkURL &&
                          recovered.source.url == bookmarkURL && recovered.source.sha256 == longFingerprint.sha256,
                          "状态注入假busy无模型进程，自动书签新路径仍完成后台核对与真实库提交")
                try check(work.sourceIssue == nil && !work.player.tracks.isEmpty && work.mode == board && work.range == bounds,
                          "自动书签在busy时恢复原曲播放器且不跳板或丢范围")
            }
            try await qualityOpen(longID)
            try check(!work.busy && !work.hasRunningProcess && work.activeTaskProjectID == nil,
                      "自动书签专项撤销假busy与检查器，无任务状态遗留")
            let relocated = input.appendingPathComponent("真实长录音-同字节重新定位.wav")
            try manager.copyItem(at: longURL, to: relocated)
            do {
                let gate = QualityGate()
                work.sourceRelocationInspector = { url, source in
                    gate.block()
                    return try LibraryStore.makeSource(url: url, duration: source.duration, sampleRate: source.sampleRate, channels: source.channels)
                }
                defer { work.sourceRelocationInspector = nil; gate.open() }
                work.relocateSource(to: relocated)
                try await wait("重新定位后台校验已进入") { gate.isWaiting }
                try check(work.sourceRelocationProjectID == longID, "后台重新定位标识绑定原项目")
                try await qualityResponsive(while: gate, label: "重新定位挂起时主线程Task与Timer仍实际响应")
                try await qualityOpen(fixture.projectID)
                gate.open()
                try await wait("后台重新定位完成") { work.sourceRelocationProjectID == nil }
                let relocatedProject = try qualityProject(longID)
                try check(work.currentProject?.id == fixture.projectID && relocatedProject.source.url == relocated &&
                          relocatedProject.source.sha256 == longFingerprint.sha256,
                          "校验期间切另一项目，原项目后台更新且界面不跳回")
            }
            try await qualityOpen(longID)
            let beforeFailure = try qualityProject(longID)
            work.relocateSource(to: sourceURL)
            try await wait("错误文件重新定位失败并恢复") { work.sourceRelocationProjectID == nil && !work.sourceChecking }
            let afterFailure = try qualityProject(longID)
            try check(work.error != nil && afterFailure.source == beforeFailure.source, "真实不同文件校验失败，不覆盖原来源与归档")
            work.error = nil

            let disposableInput = input.appendingPathComponent("待删除项目-真实录音.wav")
            let disposableMoved = input.appendingPathComponent("待删除项目-同字节新位置.wav")
            try manager.copyItem(at: sourceURL, to: disposableInput); try manager.copyItem(at: sourceURL, to: disposableMoved)
            let disposableID = try await importAudio(disposableInput)
            do {
                let gate = QualityGate()
                work.sourceRelocationInspector = { url, source in
                    gate.block()
                    return try LibraryStore.makeSource(url: url, duration: source.duration, sampleRate: source.sampleRate, channels: source.channels)
                }
                defer { work.sourceRelocationInspector = nil; gate.open() }
                work.relocateSource(to: disposableMoved)
                try await wait("待删除项目后台重新定位已进入") { gate.isWaiting }
                work.deleteProject(disposableID)
                try await qualityOpen(fixture.projectID)
                gate.open()
                try await wait("删除后迟到重新定位完成") { work.sourceRelocationProjectID == nil }
                let deleted = try qualityDocument()
                try check(!deleted.projects.contains { $0.id == disposableID } && work.currentProject?.id == fixture.projectID,
                          "后台验证期间删除项目，迟到完成不复活项目也不跳走")
            }

            work.switchResult(fixture.resultID); work.seekAbsolute(2.25); work.setAll(false); work.clearSolo(); work.toggleSolo("backing")
            work.saveListening()
            try await qualityOpen(longID); work.selectMode("pair")
            work.beginRange(); work.updateDraft(50, 60); work.applyRange(); work.seekAbsolute(55.25)
            work.format = "mp3"
            work.quit()
            let finalLong = try qualityProject(longID)
            savedResultProject = try qualityProject(fixture.projectID)
            savedResult = savedResultProject.results.first { $0.id == fixture.resultID }
            try check(finalLong.modeStates?["pair"]?.range == AudioRange(start: 50, end: 60) &&
                      abs((finalLong.modeStates?["pair"]?.sourceListening.absoluteTime ?? -1)-55.25)<0.03,
                      "quit显式flush保留最终pair50到60范围与55.25秒")
            try check(savedResult?.listening.solo == ["backing"] && abs((savedResult?.listening.absoluteTime ?? -1)-2.25)<0.03,
                      "quit前切项目与结果加载不丢旧两轨独奏位置")
            let finalDocument = try qualityDocument()
            try check(finalDocument.preferences.exportFormat == "mp3" && work.format == "mp3", "MP3导出格式真实落盘供新App进程读取")
            let resultFolder = work.library.resultURL(projectID: fixture.projectID, resultID: fixture.resultID)
            var protected = [try fileFingerprint(longURL), try fileFingerprint(bookmarkURL), try fileFingerprint(relocated)]
            if let result = savedResult { for track in result.tracks { protected.append(try fileFingerprint(resultFolder.appendingPathComponent(track.filename))) } }
            guard let finalResult = savedResult else { throw Failure(message: "质量专项退出前旧结果记录缺失") }
            let checkpoint = QualityCheckpoint(processID: getpid(), longProjectID: longID, longSourcePath: relocated.path,
                    folderID: folder.id, pairRange: AudioRange(start: 50, end: 60), pairPosition: 55.25,
                    resultProjectID: fixture.projectID, resultID: fixture.resultID,
                    resultRange: finalResult.range, resultPosition: 2.25, resultSolo: ["backing"], protectedFiles: protected)
            try JSONEncoder().encode(checkpoint).write(to: work.library.rootURL.appendingPathComponent("native-quality-checkpoint.json"), options: .atomic)
            try await screenshot("质量专项-首次进程范围与格式已保存")
            try log("QUALITY CHECKPOINT 首次进程结束；用相同DATA及QUALITY_ONLY=1、QUALITY_REOPEN=1启动真实新App进程")
        }

        func runQualityReopen() async throws {
            let checkpoint = try JSONDecoder().decode(QualityCheckpoint.self, from: Data(contentsOf: work.library.rootURL.appendingPathComponent("native-quality-checkpoint.json")))
            try check(checkpoint.processID != getpid(), "质量重开来自不同真实App进程", "before=\(checkpoint.processID), now=\(getpid())")
            let initial = try qualityDocument()
            try check(work.format == "mp3" && initial.preferences.exportFormat == "mp3", "全新App进程直接恢复MP3导出格式")
            try await qualityOpen(checkpoint.longProjectID)
            try check(work.mode == "pair" && work.range == checkpoint.pairRange.closedRange &&
                      abs(work.absoluteTime-checkpoint.pairPosition)<0.03 && work.currentProject?.folderID == checkpoint.folderID,
                      "新App恢复pair50到60秒范围、55.25秒原曲位置与归档")
            try check(work.currentProject?.source.path == checkpoint.longSourcePath, "新App恢复后台重新定位后的来源路径")
            try await qualityOpen(checkpoint.resultProjectID)
            try check(work.mode == "lead3" && work.manifest?.mode == "leadback" && work.selectedResultID == checkpoint.resultID &&
                      work.range == checkpoint.resultRange.closedRange && work.player.tracks.map(\.id) == ["lead", "backing"],
                      "新App恢复既有真实两轨结果，身份和范围保持")
            try check(work.player.solo == checkpoint.resultSolo && abs(work.absoluteTime-checkpoint.resultPosition)<0.03,
                      "新App结果恢复独奏及绝对试听位置")
            work.togglePlayback(); try await pause(0.25)
            try check(work.player.playing && work.absoluteTime>checkpoint.resultPosition && work.player.audibleTracks == checkpoint.resultSolo,
                      "新App既有真实结果仍可实际独听播放")
            work.togglePlayback()
            for protected in checkpoint.protectedFiles {
                let actual = try fileFingerprint(URL(fileURLWithPath: protected.path))
                try check(actual.sha256 == protected.sha256, "跨真实App进程原曲或既有结果文件内容不变", URL(fileURLWithPath: protected.path).lastPathComponent)
            }
            try check(work.format == "mp3" && work.error == nil, "新进程切项目与结果播放后格式仍为MP3且无存储错误")
            try await qualityOpen(checkpoint.longProjectID)
            try await screenshot("质量专项-新App进程恢复通过")
        }

        func runRangeInteraction() async throws {
            try check(work.library.projects.isEmpty, "选段专项使用独立空资料库")
            work.player.volume = 0
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let environment = ProcessInfo.processInfo.environment
            let sourceURL = environment["XIANWAIWU_RANGE_SOURCE"].map { URL(fileURLWithPath: $0) }
                ?? Project.root.appendingPathComponent("app/audio/模型对照/主唱和声/Cantoria样本/YSM/混音.wav")
            let fixture = environment["XIANWAIWU_RANGE_RESULT"].map { URL(fileURLWithPath: $0) }
                ?? Project.root.appendingPathComponent("app/macos/测试/fixtures/lead3-bs")
            let manifestBytes = try Data(contentsOf: fixture.appendingPathComponent("拾声分轨.json"))
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestBytes)
            let raw = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any]
            let sourceFingerprint = try fileFingerprint(sourceURL)
            try check(manifest.mode == "lead3" && manifest.tracks.map(\.id) == ["lead", "harmony", "instrumental"] && raw?["sourceSHA256"] as? String == sourceFingerprint.sha256,
                      "选段夹具为同源真实三轨模型结果", fixture.path)
            let projectID = try await importAudio(sourceURL)
            work.showHome()
            var inserted = [ResultRecord]()
            for bounds in [AudioRange(start: manifest.start, end: manifest.end), AudioRange(start: 1.2, end: 5.6)] {
                let temporary = try work.library.temporaryResultURL(projectID: projectID)
                for track in manifest.tracks {
                    let source = fixture.appendingPathComponent(track.filename)
                    let target = temporary.appendingPathComponent(track.filename)
                    if bounds.start == manifest.start && bounds.end == manifest.end { try manager.copyItem(at: source, to: target) }
                    else {
                        let first = Int(((bounds.start-manifest.start)*44100).rounded())
                        let end = Int(((bounds.end-manifest.start)*44100).rounded())
                        _ = try await command(["-v", "error", "-y", "-i", source.path, "-af", "atrim=start_sample=\(first):end_sample=\(end),asetpts=PTS-STARTPTS", "-c:a", "pcm_s24le", target.path])
                    }
                }
                var metadata = raw ?? [:]
                metadata["start"] = bounds.start; metadata["end"] = bounds.end
                metadata["frames"] = Int(((bounds.end-bounds.start)*44100).rounded())
                metadata["fixtureScope"] = "既有真实分离结果的采样裁切，专项不启动新模型推理"
                try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted).write(to: temporary.appendingPathComponent("拾声分轨.json"))
                let record = ResultRecord(mode: "lead3", range: bounds, tracks: manifest.tracks.map { ResultTrackRecord(id: $0.id, label: $0.label, filename: $0.filename, peakDB: $0.peakDB) },
                                          elapsed: manifest.elapsed, device: manifest.device, backend: manifest.backend, engineGainDB: manifest.engineGainDB)
                inserted.append(try work.library.commitResult(projectID: projectID, temporaryURL: temporary, record: record))
            }
            let sliced = inserted[1]
            work.currentProject = nil; work.openProject(projectID)
            try await wait("选段专项恢复真实结果") { !work.sourceChecking && work.player.tracks.count == 3 }
            work.original(); work.clearRange()
            try await wait("实际原曲波形视图") { originalCanvas() != nil && !work.wave.isEmpty }
            let duration = work.source?.duration ?? 0
            try check(duration >= 6.9 && work.range == 0...duration && work.availableResults.count == 2, "整首原曲及两份真实历史版本就绪")
            guard let initialCanvas = originalCanvas() else { throw Failure(message: "原曲波形不存在") }
            try rangeMouse(.leftMouseDown, canvas: initialCanvas, time: 0.7)
            try rangeMouse(.leftMouseUp, canvas: initialCanvas, time: 0.7)
            try await pause(0.1)
            try check(!work.rangeEditing && abs(work.absoluteTime-0.7)<0.02 && !work.hasCustomRange, "真实单击只定位，不进入选段")
            try rangeMouse(.leftMouseDown, canvas: initialCanvas, time: 0.7)
            try rangeMouse(.leftMouseDragged, canvas: initialCanvas, time: 0.7, extraX: 3)
            try rangeMouse(.leftMouseUp, canvas: initialCanvas, time: 0.7, extraX: 3)
            try check(!work.rangeEditing, "小于四像素鼠标抖动保持定位行为")
            let beforeSelection = work.absoluteTime
            try await dragOriginal(from: 1.2, to: 5.6)
            try check(work.rangeEditing && abs(work.draftRange.lowerBound-1.2)<0.03 && abs(work.draftRange.upperBound-5.6)<0.03 && work.range == 0...duration,
                      "普通原曲波形真实正向拖动进入草选，松开尚未应用")
            let draft = work.draftRange
            work.beginRange()
            try check(work.draftRange == draft, "重复进入选段不清空草选或返回上下文")
            work.togglePlayback()
            try await pause(0.15)
            try check(work.player.playing && work.player.limit == work.draftRange && work.absoluteTime >= work.draftRange.lowerBound && work.absoluteTime < work.draftRange.upperBound && work.range == 0...duration,
                      "草选时普通播放按钮只试听草选，尚未应用范围")
            work.togglePlayback()
            let draftPause = work.absoluteTime
            work.togglePlayback()
            try await pause(0.1)
            try check(work.player.playing && work.absoluteTime >= draftPause && work.player.limit == work.draftRange, "草选普通播放暂停后继续保持位置与草选边界")
            work.togglePlayback()
            for (width, height) in [(1120.0, 740.0), (880.0, 620.0)] {
                try await screenshot("选段编辑-\(Int(width))x\(Int(height))", width: width, height: height)
                try visibleRangeControl("xw.range.editor")
                try visibleRangeControl("xw.range.apply")
                try visibleRangeControl("xw.range.cancel")
            }
            try await dragOriginal(from: work.draftRange.lowerBound, to: 1.6)
            try check(abs(work.draftRange.lowerBound-1.6)<0.03 && abs(work.draftRange.upperBound-5.6)<0.03, "真实左手柄调整起点")
            try await dragOriginal(from: work.draftRange.upperBound, to: 5.2)
            try check(abs(work.draftRange.lowerBound-1.6)<0.03 && abs(work.draftRange.upperBound-5.2)<0.03, "真实右手柄调整终点")
            try await dragOriginal(from: work.draftRange.lowerBound, to: 6.8)
            try check(work.rangeValid && abs(work.draftRange.upperBound-work.draftRange.lowerBound-0.2)<0.001, "手柄反向越过另一端仍保留有效0.2秒")
            let narrowStart = work.draftRange.lowerBound
            try await dragOriginal(from: work.draftRange.upperBound, to: 5.8, extraX: -6)
            try check(abs(work.draftRange.lowerBound-narrowStart)<0.03 && abs(work.draftRange.upperBound-5.8)<0.03, "窄选区手柄命中区重叠时仍抓住更近的右端")
            try await pressRangeEscape()
            try check(!work.rangeEditing && work.range == 0...duration && abs(work.absoluteTime-beforeSelection)<0.03, "真实Escape取消草选并恢复进入前原曲位置")
            try await dragOriginal(from: 5.6, to: 1.2)
            try check(work.rangeEditing && abs(work.draftRange.lowerBound-1.2)<0.03 && abs(work.draftRange.upperBound-5.6)<0.03, "普通波形真实反向拖动正确框选")
            try await pressRangeControl("xw.range.cancel")
            try check(!work.rangeEditing && work.range == 0...duration, "实际取消按钮丢弃草选")
            try await dragOriginal(from: 1.2, to: 5.6)
            try await typeRangeValue("2.50", fieldID: "xw.range.start")
            try await pressRangeControl("xw.range.apply")
            try check(!work.rangeEditing && abs(work.range.lowerBound-2.5)<0.001 && abs(work.range.upperBound-5.6)<0.03 && work.player.limit == work.range,
                      "真实输入时间后直接点完成，采用新值并限制原曲预听")
            try visibleRangeControl("xw.range.reset")
            try await screenshot("已应用范围-常驻恢复整首", width: 880, height: 620)
            work.seekAbsolute(3.1); work.togglePlayback(); try await pause(0.15)
            let beforeReset = work.absoluteTime
            try await pressRangeControl("xw.range.reset")
            try check(!work.rangeEditing && !work.hasCustomRange && !work.listeningToResult && work.range == 0...duration && work.player.limit == 0...duration && work.player.playing && abs(work.absoluteTime-beforeReset)<0.3,
                      "非编辑状态一键恢复整首原曲，保留当前位置与播放")
            work.togglePlayback()
            try await pressRangeControl("xw.range.begin")
            try await typeRangeValue("0.005", fieldID: "xw.range.start")
            try await pressRangeControl("xw.range.apply")
            try check(work.hasCustomRange && abs(work.range.lowerBound-0.005)<0.000001, "合法裁掉五毫秒也识别为自定义范围")
            try visibleRangeControl("xw.range.reset")
            try await pressRangeControl("xw.range.reset")
            work.switchResult(sliced.id)
            work.setAll(false); work.toggleSolo("harmony"); work.seekAbsolute(2.2); work.saveListening()
            work.player.setA(0.4); work.player.setB(2.8); work.player.updateLoop(true)
            try await wait("三轨结果页完成布局") { !accessibleItems().contains { $0.identifier.hasPrefix("xw.range.") } }
            try check(!accessibleItems().contains { $0.identifier.hasPrefix("xw.range.") }, "三轨结果页同样不显示处理范围设置")
            try await pressRangeControl("xw.listen.original")
            work.player.setA(1.5); work.player.setB(4.4); work.player.updateLoop(true)
            let originalLoop = (work.player.loop, work.player.a, work.player.b)
            try await pressRangeControl("xw.range.begin")
            try await dragOriginal(from: 0.8, to: 1.8)
            work.previewDraft(); try await pause(0.15)
            try check(work.player.playing && !work.listeningToResult, "真实鼠标草选能够实际试听原曲")
            try await pressRangeControl("xw.range.cancel")
            try check(!work.listeningToResult && work.selectedResultID == sliced.id && !work.player.playing && abs(work.absoluteTime-2.2)<0.03,
                      "原曲页取消选段后留在原曲，恢复暂停和绝对位置")
            try check(work.player.loop == originalLoop.0 && abs(work.player.a-originalLoop.1)<0.001 && abs(work.player.b-originalLoop.2)<0.001,
                      "取消草选恢复进入前的原曲A/B与循环状态")
            try await pressRangeControl("xw.listen.result")
            try check(work.player.solo == ["harmony"] && work.selectedResultID == sliced.id && abs(work.absoluteTime-2.2)<0.03,
                      "返回结果后和声独奏、结果身份和试听位置保留")
            work.player.updateLoop(false)
            work.togglePlayback(); try await pause(0.15)
            try await pressRangeControl("xw.listen.original")
            let playingReturn = work.absoluteTime
            try await pressRangeControl("xw.range.begin")
            try await typeRangeValue("3.00", fieldID: "xw.range.start")
            try await pressRangeEscape()
            try check(!work.rangeEditing && !work.listeningToResult && work.player.playing && abs(work.absoluteTime-playingReturn)<0.35 && work.range == sliced.range.closedRange,
                      "原曲时间输入焦点内Escape取消，恢复原曲播放且无晚到提交")
            work.togglePlayback()
            try await pressRangeControl("xw.range.begin")
            try await dragOriginal(from: 3.0, to: 4.0)
            work.previewDraft(); try await pause(0.15)
            let beforeEditorReset = work.absoluteTime
            try await pressRangeControl("xw.range.reset.editor")
            try check(!work.rangeEditing && !work.listeningToResult && work.range == 0...duration && work.player.limit == 0...duration && work.player.playing && abs(work.absoluteTime-beforeEditorReset)<0.35,
                      "编辑中恢复整首退出编辑，保留当前原曲试听与所有版本")
            work.togglePlayback()
            try check(work.currentProject?.results.map(\.id) == inserted.map(\.id), "所有选段操作保留两份历史结果编号")

            work.selectMode("pair")
            try await wait("空双轨板原曲波形") { originalCanvas() != nil }
            try await dragOriginal(from: 0.6, to: 2.4)
            try await pressRangeControl("xw.range.apply")
            let pairRange = work.range
            try check(work.mode == "pair" && abs(pairRange.lowerBound-0.6)<0.03 && abs(pairRange.upperBound-2.4)<0.03 && !work.hasResultForCurrentMode && !work.canExportCurrentSelection, "未分离双轨板独立保存自己的鼠标选段，结果仍灰态")
            work.selectMode("lead3")
            try check(work.mode == "lead3" && work.range == 0...duration && work.availableResults.count == 2, "回三轨板保留自己的整首范围和结果版本")
            work.selectMode("pair")
            try check(work.range == pairRange && work.availableResults.isEmpty, "回双轨板恢复自己的范围，不借用外板结果")
            work.showHome()
            do {
                let disk = try LibraryStore(rootURL: work.library.rootURL)
                let restored = Workspace(library: disk)
                restored.openProject(projectID)
                try await wait("选段范围跨Store和Workspace恢复") { !restored.sourceChecking }
                restored.selectMode("pair")
                try check(restored.range == pairRange && !restored.hasResultForCurrentMode, "独立Store和Workspace恢复双轨板已应用范围")
                restored.selectMode("lead3")
                try check(restored.range == 0...duration && restored.availableResults.map(\.id).sorted(by: { $0.uuidString < $1.uuidString }) == inserted.map(\.id).sorted(by: { $0.uuidString < $1.uuidString }), "独立重开恢复三轨板整首范围及两份历史")
                restored.showHome()
                restored.currentProject = nil
            }
            // The independent workspace has legitimately saved newer revisions. Detach both
            // test sessions before loading its final snapshot into the visible workspace.
            work.currentProject = nil
            try work.library.reload()
            work.openProject(projectID); work.selectMode("lead3")
            try await wait("恢复三轨板原曲") { !work.sourceChecking }
            work.switchResult(sliced.id)
            work.clearRange()
            work.separated()
            try check(work.listeningToResult && work.manifest?.start == 1.2 && work.manifest?.end == 5.6 && work.player.tracks.count == 3, "恢复整首后仍可重新听旧选段结果")
            try check(work.canExportCurrentSelection, "恢复整首后当前旧选段结果仍可导出")
            _ = try await exportTracks(["harmony"], format: "wav24", label: "恢复整首后导出旧选段和声")
            let finalFingerprint = try fileFingerprint(sourceURL)
            try check(finalFingerprint.sha256 == sourceFingerprint.sha256 && work.currentProject?.results.map(\.id) == inserted.map(\.id), "专项未改原曲和任何已完成结果身份")
            try await screenshot("选段专项完成-旧选段仍可导出", width: 1120, height: 740)
        }

        func runModeIsolation() async throws {
            let environment = ProcessInfo.processInfo.environment
            try check(environment["XIANWAIWU_DEVICE"] == "cpu", "分板专项真实任务仅使用CPU，不占GPU")
            try check(work.library.projects.isEmpty, "分板专项从独立空资料库开始")
            let sourceURL = environment["XIANWAIWU_MODE_SOURCE"].map { URL(fileURLWithPath: $0) }
                ?? Project.root.appendingPathComponent("app/audio/模型对照/主唱和声/Cantoria样本/YSM/混音.wav")
            let resultURL = environment["XIANWAIWU_MODE_LEAD_RESULT"].map { URL(fileURLWithPath: $0) }
                ?? Project.root.appendingPathComponent("app/macos/测试/fixtures/lead3-kara")
            let bytes = try Data(contentsOf: resultURL.appendingPathComponent("拾声分轨.json"))
            let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
            let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            let fingerprint = try fileFingerprint(sourceURL)
            try check(manifest.mode == "lead3" && manifest.tracks.map(\.id) == ["lead", "harmony", "instrumental"] && raw?["sourceSHA256"] as? String == fingerprint.sha256,
                      "分板夹具是真实三轨且与原曲内容指纹一致", resultURL.path)
            let projectID = try await importAudio(sourceURL)
            work.showHome()
            let temporary = try work.library.temporaryResultURL(projectID: projectID)
            for track in manifest.tracks {
                guard track.filename == (track.filename as NSString).lastPathComponent else { throw Failure(message: "分板夹具文件名无效") }
                try manager.copyItem(at: resultURL.appendingPathComponent(track.filename), to: temporary.appendingPathComponent(track.filename))
            }
            try bytes.write(to: temporary.appendingPathComponent("拾声分轨.json"))
            let record = ResultRecord(mode: manifest.mode, range: AudioRange(start: manifest.start, end: manifest.end),
                                      tracks: manifest.tracks.map { ResultTrackRecord(id: $0.id, label: $0.label, filename: $0.filename, peakDB: $0.peakDB) },
                                      elapsed: manifest.elapsed, device: manifest.device, backend: manifest.backend, engineGainDB: manifest.engineGainDB)
            let lead = try work.library.commitResult(projectID: projectID, temporaryURL: temporary, record: record)
            work.currentProject = nil
            work.openProject(projectID)
            try await wait("三轨板夹具恢复") { !work.sourceChecking && work.player.tracks.count == 3 }
            work.selectMode("lead3"); work.switchResult(lead.id)
            work.setAll(true)
            let resultPreviewGain = work.player.previewGain
            let expectedOriginalGain = resultPreviewGain * Float(pow(10, (work.manifest?.engineGainDB ?? 0) / 20))
            work.setAll(false); work.toggleSolo("harmony"); work.seekAbsolute(1.3)
            work.togglePlayback(); try await pause(0.15)
            let beforeComparison = work.absoluteTime
            work.original()
            try check(abs(work.player.previewGain-expectedOriginalGain)<0.00001 && work.player.playing && abs(work.absoluteTime-beforeComparison)<0.08,
                      "同板原曲试听按结果安全增益及引擎共同增益校准，切换位置和播放连续",
                      "resultGain=\(resultPreviewGain), engineGainDB=\(work.manifest?.engineGainDB ?? 0), originalGain=\(work.player.previewGain), expected=\(expectedOriginalGain)")
            let beforeReturningResult = work.absoluteTime
            work.separated()
            try check(abs(work.player.previewGain-resultPreviewGain)<0.00001 && work.player.solo == ["harmony"] && work.player.playing && abs(work.absoluteTime-beforeReturningResult)<0.08,
                      "回分离结果安全增益不变，和声独奏、位置与播放状态保留")
            work.togglePlayback()
            work.clearSolo()
            work.setAll(false); work.toggleSolo("harmony"); work.seekAbsolute(1.3); work.saveListening()
            try check(work.availableResults.map(\.id) == [lead.id] && work.hasResultForCurrentMode && work.player.audibleTracks == ["harmony"], "三轨板仅含自己的真实结果，和声独奏已保存")
            try await screenshot("01-三轨板自己的结果", width: 880, height: 620)

            for board in ["pair", "music6"] {
                work.selectMode(board)
                try check(work.mode == board && !work.hasResultForCurrentMode && work.availableResults.isEmpty && work.manifest == nil && work.selectedResultID == nil && !work.listeningToResult && work.player.tracks.map(\.id) == ["original"] && !work.canExportCurrentSelection,
                          "未分离\(board)板灰态，只能听原曲且不能导外板结果")
                if board == "pair" {
                    try check(abs(work.player.previewGain-0.95)<0.00001, "空双轨板原曲保持默认0.95试听增益，不继承三轨校准", "originalGain=\(work.player.previewGain)")
                }
                work.separated(); work.switchResult(lead.id)
                try check(work.mode == board && !work.listeningToResult && work.manifest == nil && work.selectedResultID == nil && work.player.tracks.map(\.id) == ["original"], "\(board)板拒绝分离结果命令及外板结果ID")
                try await screenshot("02-未分离\(board)板结果灰态", width: 880, height: 620)
            }
            work.selectMode("lead3")
            try check(work.listeningToResult && work.selectedResultID == lead.id && work.player.solo == ["harmony"] && abs(work.absoluteTime-1.3)<0.02 && work.range == manifest.start...manifest.end,
                      "回三轨板恢复自己的结果、和声独奏、位置与范围")

            work.selectMode("music6")
            work.beginRange(); work.updateDraft(0, 6); work.applyRange(); work.start()
            try check(work.processing && work.processingCurrentProject, "六轨板启动六秒CPU真实任务")
            try await settled("六轨板第一份真实结果完成")
            try validateTracks(["vocals", "drums", "bass", "guitar", "piano", "other"], length: 6)
            guard let firstSix = work.selectedResultID else { throw Failure(message: "六轨板第一结果缺编号") }
            work.setAll(false); work.toggleSolo("guitar"); work.seekAbsolute(2.2); work.saveListening()
            try check(work.availableResults.count == 1 && work.availableResults.allSatisfy { $0.manifest.mode == "music6" } && work.versions.count == 2, "六轨菜单仅一份本板结果，全项目仍保留三轨")
            work.selectMode("lead3")
            try check(work.availableResults.map(\.id) == [lead.id] && work.selectedResultID == lead.id && work.player.solo == ["harmony"] && abs(work.absoluteTime-1.3)<0.02, "加六轨后回三轨，结果数量和试听状态各自独立")
            work.selectMode("music6")
            try check(work.selectedResultID == firstSix && work.player.solo == ["guitar"] && work.range == 0...6 && abs(work.absoluteTime-2.2)<0.02, "回六轨恢复吉他独奏、六秒范围与自己的位置")

            work.beginRange(); work.updateDraft(1, 3); work.applyRange(); work.start(force: true)
            try check(work.processing, "六轨板启动第二份两秒真实版本")
            work.selectMode("lead3")
            try check(work.processing && !work.processingCurrentProject && work.mode == "lead3" && work.selectedResultID == lead.id && work.player.solo == ["harmony"], "六轨任务运行中可切三轨试听，三轨不显示六轨进度卡")
            try await settled("后台六轨第二版本完成")
            try check(work.mode == "lead3" && work.selectedResultID == lead.id && work.manifest?.mode == "lead3" && work.player.tracks.map(\.id) == ["lead", "harmony", "instrumental"] && work.player.solo == ["harmony"] && abs(work.absoluteTime-1.3)<0.02,
                      "后台六轨完成不跳板、不替换当前三轨试听")
            work.selectMode("music6")
            guard let secondSix = work.availableResults.first(where: { $0.id != firstSix })?.id else { throw Failure(message: "六轨板第二版本未保存") }
            try check(work.availableResults.count == 2 && work.availableResults.allSatisfy { $0.manifest.mode == "music6" }, "同板两份版本可见，菜单不包含三轨结果")
            let beforeVersionSwitch = work.absoluteTime
            work.switchResult(firstSix)
            try check(work.range == 0...6 && work.player.solo == ["guitar"] && abs(work.absoluteTime-beforeVersionSwitch)<0.02,
                      "同板切旧版本恢复吉他独奏与旧范围，保持播放位置连续", "range=\(work.range), solo=\(work.player.solo), time=\(work.absoluteTime)")
            work.switchResult(secondSix)
            try check(work.range == 1...3 && work.player.tracks.count == 6, "同板切新六轨版本恢复自己的两秒范围")
            work.setAll(false); work.toggleSolo("drums"); work.seekAbsolute(1.6); work.saveListening()
            try await screenshot("03-六轨板两份版本", width: 880, height: 620)

            work.selectMode("pair")
            try check(!work.hasResultForCurrentMode && work.availableResults.isEmpty && work.manifest == nil, "已有三轨与六轨仍不会点亮未分离的双轨板")
            work.beginRange(); work.updateDraft(0, 2); work.applyRange(); work.start()
            try check(work.processing && work.processingCurrentProject, "双轨板启动两秒CPU真实任务")
            work.selectMode("lead3")
            try check(!work.processingCurrentProject && work.player.solo == ["harmony"], "双轨运行中回三轨仍恢复和声独奏")
            try await settled("后台双轨结果完成")
            try check(work.mode == "lead3" && work.selectedResultID == lead.id && work.availableResults.map(\.id) == [lead.id] && work.player.solo == ["harmony"] && abs(work.absoluteTime-1.3)<0.02,
                      "后台双轨完成不加载到三轨板")
            work.selectMode("pair")
            guard let pair = work.availableResults.first?.id else { throw Failure(message: "后台双轨结果未保存到双轨板") }
            work.switchResult(pair)
            try check(work.availableResults.count == 1 && work.manifest?.mode == "pair" && work.player.tracks.map(\.id) == ["vocals", "instrumental"] && work.range == 0...2, "回双轨板可打开它自己完成的结果")
            work.setAll(false); work.toggleSolo("vocals"); work.seekAbsolute(0.7)
            work.original()
            try check(!work.listeningToResult && work.hasResultForCurrentMode && work.player.tracks.map(\.id) == ["original"], "同板切原曲保留自己的结果入口")
            work.separated()
            try check(work.listeningToResult && work.selectedResultID == pair && work.player.solo == ["vocals"] && abs(work.absoluteTime-0.7)<0.02, "同板分离结果按钮恢复本板试听")
            work.original(); work.seekAbsolute(0.9); work.saveListening()
            work.selectMode("lead3"); work.saveListening()
            try check(work.currentProject?.results.count == 4, "三板共四份真实结果均保留")
            let checkpoint = ModeIsolationCheckpoint(projectID: projectID, leadID: lead.id, firstSixID: firstSix, secondSixID: secondSix, pairID: pair)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let checkpointURL = work.library.rootURL.appendingPathComponent("mode-isolation-checkpoint.json")
            try encoder.encode(checkpoint).write(to: checkpointURL, options: .atomic)
            try check(manager.fileExists(atPath: checkpointURL.path), "已保存供独立App进程重开的分板检查点", checkpointURL.path)
            try await screenshot("04-完成后台任务后仍在三轨板", width: 880, height: 620)
            try log("CHECKPOINT 使用相同XIANWAIWU_DATA，设置XIANWAIWU_MODE_ISOLATION_ONLY=1和XIANWAIWU_MODE_ISOLATION_REOPEN=1启动新App进程继续验收")
        }

        func runModeIsolationReopen() async throws {
            let checkpointURL = work.library.rootURL.appendingPathComponent("mode-isolation-checkpoint.json")
            let checkpoint = try JSONDecoder().decode(ModeIsolationCheckpoint.self, from: Data(contentsOf: checkpointURL))
            guard let project = work.library.projects.first(where: { $0.id == checkpoint.projectID }) else { throw Failure(message: "新App进程缺分板项目") }
            try check(project.results.count == 4 && Set(project.results.map(\.id)) == [checkpoint.leadID, checkpoint.firstSixID, checkpoint.secondSixID, checkpoint.pairID], "新App进程恢复三板四份真实版本")
            work.openProject(project.id)
            try await wait("新App进程分板原曲核验") { !work.sourceChecking && work.player.tracks.count == 3 }
            try check(work.mode == "lead3" && work.selectedResultID == checkpoint.leadID && work.availableResults.map(\.id) == [checkpoint.leadID] && work.player.solo == ["harmony"] && abs(work.absoluteTime-1.3)<0.02, "新App进程恢复最后所在三轨板及和声独奏位置")
            work.selectMode("music6")
            try check(work.availableResults.count == 2 && work.selectedResultID == checkpoint.secondSixID && work.range == 1...3 && work.player.solo == ["drums"] && abs(work.absoluteTime-1.6)<0.02, "新App进程回六轨板恢复所选版本、范围及鼓独奏")
            work.switchResult(checkpoint.firstSixID)
            try check(work.range == 0...6 && work.player.solo == ["guitar"] && abs(work.absoluteTime-1.6)<0.02, "新App进程同板旧版本恢复吉他独奏并保持绝对位置连续")
            work.selectMode("pair")
            try check(work.availableResults.map(\.id) == [checkpoint.pairID] && work.selectedResultID == checkpoint.pairID && !work.listeningToResult && work.player.tracks.map(\.id) == ["original"] && work.range == 0...2 && abs(work.absoluteTime-0.9)<0.02, "新App进程双轨板保留原曲视图及独立范围位置")
            work.switchResult(checkpoint.leadID)
            try check(work.mode == "pair" && !work.listeningToResult && work.selectedResultID == checkpoint.pairID, "新App进程拒绝跨板结果ID")
            work.separated()
            try check(work.manifest?.mode == "pair" && work.player.solo == ["vocals"], "新App进程同板结果入口恢复双轨人声独奏")
            work.selectMode("lead3")
            try check(work.manifest?.mode == "lead3" && work.player.solo == ["harmony"], "新App进程各板反复切换不串结果")
            try await screenshot("05-跨App进程恢复三轨板", width: 880, height: 620)
        }

        func runPlayback() async throws {
            guard let project = work.library.projects.first(where: { $0.results.contains(where: { $0.mode == "music6" }) }),
                  let result = project.results.last(where: { $0.mode == "music6" }) else {
                throw Failure(message: "快速播放诊断需要隔离资料库内已有的真实六轨结果")
            }
            work.openProject(project.id)
            try await wait("快速诊断源文件核验") { !work.sourceChecking }
            work.selectMode("music6")
            work.switchResult(result.id)
            try await wait("快速诊断六轨准备") { work.player.tracks.count == 6 }
            work.setAll(false)
            work.toggleSolo("guitar")
            work.toggleSolo("drums")
            work.seekAbsolute(result.range.start + 1.1)
            try log("PLAYBACK before \(work.player.playbackDiagnostics)")
            work.togglePlayback()
            for index in 1...10 {
                try await pause(0.1)
                try log("PLAYBACK \(index*100)ms \(work.player.playbackDiagnostics)")
            }
            try check(work.player.playing && work.absoluteTime > result.range.start+1.2, "快速诊断六轨播放头真实前进", "absolute=\(work.absoluteTime)")
            work.togglePlayback()
            try await screenshot("快速六轨播放诊断")
        }

        func fileFingerprint(_ url: URL) throws -> ProtectedFile {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256()
            while let data = try file.read(upToCount: 1024*1024), !data.isEmpty { digest.update(data: data) }
            return ProtectedFile(path: url.path, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
        }

        func keepForReopen(projectID: UUID, source: URL) async throws {
            guard let six = work.currentProject?.results.last(where: { $0.mode == "music6" }) else { throw Failure(message: "跨进程检查缺六轨结果") }
            work.selectMode("music6")
            work.switchResult(six.id)
            work.setAll(false)
            work.toggleTrack("guitar")
            work.toggleSolo("guitar")
            work.toggleSolo("drums")
            work.seekAbsolute(2.5)
            let folder = try work.library.createFolder(name: "跨进程恢复验收")
            work.moveProject(projectID, to: folder.id)
            work.saveListening()
            work.showHome()
            let disk = try LibraryStore(rootURL: work.library.rootURL)
            guard let project = disk.projects.first(where: { $0.id == projectID }) else { throw Failure(message: "保存跨进程检查点失败") }
            var protected = [try fileFingerprint(source)]
            for url in exports {
                let isDirectory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
                if isDirectory {
                    let files = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey])
                    for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { protected.append(try fileFingerprint(file)) }
                } else { protected.append(try fileFingerprint(url)) }
            }
            let legacy = legacyProjectID.flatMap { id in disk.projects.first(where: { $0.id == id }) }
            if let legacy { protected.append(try fileFingerprint(legacy.source.url)) }
            let checkpoint = ReopenCheckpoint(project: project, folder: folder, projectCount: disk.projects.count, protectedFiles: protected, legacyProject: legacy)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let path = work.library.rootURL.appendingPathComponent("native-reopen-checkpoint.json")
            try encoder.encode(checkpoint).write(to: path, options: .atomic)
            try check(project.results.count == 3 && project.folderID == folder.id && project.currentResultID == six.id, "保存供下一次App进程读取的完整项目检查点", path.path)
            try await screenshot("12-保留项目供跨进程重开")
            try log("CHECKPOINT 主项目和全部导出已保留。下一次进程使用相同XIANWAIWU_DATA及XIANWAIWU_REOPEN_ONLY=1继续。")
        }

        func runReopen() async throws {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let checkpointURL = work.library.rootURL.appendingPathComponent("native-reopen-checkpoint.json")
            let checkpoint = try decoder.decode(ReopenCheckpoint.self, from: Data(contentsOf: checkpointURL))
            guard let project = work.library.projects.first(where: { $0.id == checkpoint.project.id }) else { throw Failure(message: "新App进程未恢复主项目") }
            try check(work.library.projects.count == checkpoint.projectCount, "新App进程恢复全部项目数")
            try check(project.results.count == 3 && project.results.map(\.id) == checkpoint.project.results.map(\.id), "新App进程恢复三份完整结果及版本编号")
            try check(Set(project.results.map(\.mode)) == ["pair", "lead3", "music6"], "新App进程恢复三种分法")
            try check(project.results.map(\.listening) == checkpoint.project.results.map(\.listening), "新App进程恢复每份结果的试听位置、开关与组合独奏")
            try check(project.results.map(\.exports) == checkpoint.project.results.map(\.exports), "新App进程恢复每份结果全部导出记录")
            try check(project.source == checkpoint.project.source && project.sourceListening == checkpoint.project.sourceListening, "新App进程恢复重定位原曲与独立原曲试听状态")
            try check(project.folderID == checkpoint.folder.id && work.library.folders.contains(where: { $0.id == checkpoint.folder.id && $0.name == checkpoint.folder.name }), "新App进程恢复文件夹和项目归档关系")
            work.openProject(project.id)
            try await wait("新App进程恢复原曲与六轨") { !work.sourceChecking && work.player.tracks.count == 6 && work.trackWaves.count == 6 }
            try check(work.sourceIssue == nil && work.listeningToResult && work.selectedResultID == checkpoint.project.currentResultID && work.range == checkpoint.project.range?.closedRange, "新App进程恢复当前结果及其绝对范围")
            try check(abs(work.absoluteTime-2.5)<0.001 && work.player.enabled == ["guitar"] && work.player.solo == ["guitar", "drums"] && !work.player.playing, "新App进程恢复已存试听组合并保持暂停")
            try await screenshot("01-跨App进程重开六轨")
            work.togglePlayback()
            try await pause(0.4)
            try log("REOPEN playback \(work.player.playbackDiagnostics)")
            try check(work.player.playing && work.absoluteTime>2.5, "新App进程的恢复结果真实起播")
            work.togglePlayback()
            for result in project.results {
                work.selectMode(result.mode == "leadback" ? "lead3" : result.mode)
                work.switchResult(result.id)
                try check(work.manifest?.mode == result.mode && work.player.tracks.map(\.id) == result.tracks.map(\.id), "新App进程切换\(result.mode)旧结果可播放", "\(result.id)")
                for track in work.player.tracks { _ = try AVAudioFile(forReading: track.url) }
                if result.mode == "lead3" {
                    work.setAll(false)
                    work.toggleSolo("harmony")
                    work.seekAbsolute(0.7)
                    work.togglePlayback()
                    try await pause(0.3)
                    try check(work.player.playing && work.absoluteTime>0.7 && work.player.audibleTracks == ["harmony"], "新App进程恢复三轨后和声单轨真实播放")
                    try synchronizedNodes(["lead", "harmony", "instrumental"], label: "新App进程三轨节点同步")
                    work.togglePlayback()
                }
            }
            if let legacy = checkpoint.legacyProject {
                guard let restored = work.library.projects.first(where: { $0.id == legacy.id }) else { throw Failure(message: "新App进程没有恢复旧两轨历史项目") }
                try check(restored.results == legacy.results && restored.source == legacy.source, "新App进程完整恢复旧leadback两轨身份、试听与导出")
                work.openProject(legacy.id)
                try await wait("新App进程旧两轨历史准备") { !work.sourceChecking && work.player.tracks.count == 2 }
                try check(work.mode == "lead3" && work.manifest?.mode == "leadback" && work.player.tracks.map(\.id) == ["lead", "backing"] && work.canExportCurrentSelection, "新App进程在主唱和声板恢复旧leadback两轨并可导出")
                work.setAll(false)
                work.toggleSolo("backing")
                work.seekAbsolute(0.7)
                work.togglePlayback()
                try await pause(0.3)
                try check(work.player.playing && work.absoluteTime>0.7, "新App进程旧两轨和声伴奏真实播放")
                work.togglePlayback()
                _ = try await exportTracks(["backing"], format: "wav24", label: "新App进程旧历史导出和声伴奏")
                work.openProject(project.id)
                try await wait("恢复主项目") { !work.sourceChecking }
            }
            for receipt in checkpoint.protectedFiles {
                let actual = try fileFingerprint(URL(fileURLWithPath: receipt.path))
                try check(actual.sha256 == receipt.sha256, "新App进程原曲或导出文件内容保持", URL(fileURLWithPath: receipt.path).lastPathComponent)
            }
            if ProcessInfo.processInfo.environment["XIANWAIWU_KEEP_PROJECT"] == "1" {
                work.showHome()
                try await screenshot("02-跨App进程保留归档项目")
                return
            }
            work.showHome()
            work.deleteProject(project.id)
            if let legacy = checkpoint.legacyProject { work.deleteProject(legacy.id) }
            try check(!work.library.projects.contains(where: { $0.id == project.id }), "跨App进程验收后真实删除主项目")
            for receipt in checkpoint.protectedFiles {
                let actual = try fileFingerprint(URL(fileURLWithPath: receipt.path))
                try check(actual.sha256 == receipt.sha256, "跨App进程删除后原曲或导出逐字节不变", URL(fileURLWithPath: receipt.path).lastPathComponent)
            }
            let finalStore = try LibraryStore(rootURL: work.library.rootURL)
            let removedCount = checkpoint.legacyProject == nil ? 1 : 2
            try check(finalStore.projects.count == checkpoint.projectCount-removedCount && !finalStore.projects.contains(where: { $0.id == project.id }), "跨App进程删除重开不复活且其他项目保留")
            try await screenshot("02-跨App进程删除后的首页")
        }

        func runWaveformGuide() async throws {
            try check(work.library.projects.isEmpty, "波形专项使用新的隔离资料库")
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let downloads = manager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let audio = downloads.appendingPathComponent("入海.mp3")
            let lrc = downloads.appendingPathComponent("入海歌词.lrc")
            let sourceHash = try fileFingerprint(audio)
            let lyricHash = try fileFingerprint(lrc)
            let id = try await importAudio(audio)
            work.player.volume = 0
            work.importLyrics(lrc)
            try await wait("波形专项歌词就绪") { !work.importingLyrics && work.currentProject?.lyrics != nil && !work.wave.isEmpty }
            let temporary = try work.library.temporaryResultURL(projectID: id)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let count: AVAudioFrameCount = 264600
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            let names = [("vocals", "人声"), ("drums", "鼓"), ("bass", "贝斯"), ("guitar", "吉他"), ("piano", "钢琴"), ("other", "其他")]
            var tracks: [ResultTrackRecord] = []
            for (index, pair) in names.enumerated() {
                for channel in 0..<2 {
                    for sample in 0..<Int(count) {
                        let time = Double(sample) / 44100
                        let beat = time.truncatingRemainder(dividingBy: 1)
                        let amplitude = beat > Double(index) * 0.035 + 0.12 ? 0.12 * (1 - beat * 0.75) : 0
                        buffer.floatChannelData![channel][sample] = Float(sin(time * 2 * .pi * Double(110 + index * 80)) * amplitude)
                    }
                }
                let row = ResultTrackRecord(id: pair.0, label: pair.1, filename: pair.0 + ".wav")
                let file = try AVAudioFile(forWriting: temporary.appendingPathComponent(row.filename), settings: format.settings)
                try file.write(from: buffer); tracks.append(row)
            }
            // Silent/musical test signals exercise six-row geometry, not model separation quality.
            let fixture = try work.library.commitResult(projectID: id, temporaryURL: temporary,
                record: ResultRecord(mode: "music6", range: AudioRange(start: 15, end: 21), tracks: tracks))
            work.openProject(id); work.selectMode("music6"); work.switchResult(fixture.id)
            try await wait("六轨布局与波形就绪") { !work.sourceChecking && work.player.tracks.count == 6 && work.trackWaves.count == 6 }
            let resultFingerprints = try Dictionary(uniqueKeysWithValues: tracks.map { track in
                (track.id, try fileFingerprint(work.library.trackURL(projectID: id, resultID: fixture.id, track: track)).sha256)
            })
            work.seekAbsolute(16.43); work.saveListening()
            try await pause(0.35)
            try check(!accessibleItems().contains { $0.identifier.hasPrefix("xw.range.") }, "分离结果页没有处理范围设置")

            func surface() throws -> XWWaveformGuideView {
                guard let content = window.contentView,
                      let view = nativeViews(content).compactMap({ $0 as? XWWaveformGuideView }).first(where: { !$0.isHidden && $0.visibleRect.height > 20 }) else {
                    throw Failure(message: "没有找到真实波形鼠标预览层")
                }
                return view
            }
            func move(_ time: Double, over canvas: XWWaveformCanvas, ruler: Bool = false) async throws {
                let fraction = (time - canvas.displayBounds.lowerBound) / (canvas.displayBounds.upperBound - canvas.displayBounds.lowerBound)
                let local = NSPoint(x: 6 + CGFloat(fraction) * (canvas.bounds.width - 12), y: canvas.bounds.midY)
                var point = canvas.convert(local, to: nil)
                let guide = try surface()
                if ruler { point.y = guide.convert(NSPoint(x: guide.convert(point, from: nil).x, y: 10), to: nil).y }
                guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0) else { throw Failure(message: "鼠标移动事件创建失败") }
                // Dispatch synchronously, before a physical-pointer refresh can replace this synthetic event.
                NSApp.sendEvent(event)
                try log("POINTER expected=\(time) actual=\(guide.hoverTime ?? -1)")
                if abs((guide.hoverTime ?? -1) - time) > 0.000001 {
                    let reference = guide.guide.reference
                    let observed = guide.hoverTime
                    let pointInGuide = guide.convert(point, from: nil)
                    guide.mouseMoved(with: event)
                    throw Failure(message: "鼠标派发核对失败 expected=\(time), observed=\(observed ?? -1), direct=\(guide.hoverTime ?? -1), key=\(window.isKeyWindow), point=\(pointInGuide), bounds=\(guide.bounds), visible=\(guide.visibleRect), reference=\(reference.map { $0.convert($0.bounds, to: guide) } ?? .zero), referenceBounds=\(String(describing: reference?.displayBounds)), attached=\(reference?.window === window)")
                }
            }
            let canvases = nativeViews(window.contentView!).compactMap { $0 as? XWWaveformCanvas }.filter { $0.window === window && !$0.isHidden && $0.identifier?.rawValue != "xw.waveform.original" }
            try check(canvases.count == 6, "真实六轨窗口含六个可交互波形")
            let narrow = canvases[0].bounds.width
            let identities = Set(canvases.map(ObjectIdentifier.init))
            var motion: [[String: Double]] = []
            var performance: [[String: Any]] = []
            let profiling = ProcessInfo.processInfo.environment["XIANWAIWU_SWITCH_PROFILE"] == "1"
            for opening in (profiling ? [false, true, false, true, false, true, false, true] : [false, true]) {
                let probe = SwitchFrameProbe(view: window.contentView!)
                if profiling { probe.start() }
                try await pressRangeControl("xw.lyrics.toggle", pauseAfter: 0)
                let began = ProcessInfo.processInfo.systemUptime
                var intermediate = Set<Int>()
                for sample in 0..<24 {
                    try await pause(0.012)
                    let widths = canvases.map { $0.bounds.width }
                    guard widths.allSatisfy({ abs($0 - widths[0]) < 0.5 }) else {
                        throw Failure(message: "六轨在侧栏动效期间未保持同一横向比例")
                    }
                    if widths[0] > narrow + 2 && widths[0] < narrow + 302 { intermediate.insert(Int(widths[0].rounded())) }
                    motion.append(["opening": opening ? 1 : 0, "seconds": ProcessInfo.processInfo.systemUptime - began,
                                   "waveWidth": widths[0]])
                    if sample == 2 { try await move(17.25, over: canvases[0]) }
                }
                if profiling { performance.append(["opening": opening, "frameGapsMs": probe.finish()]) }
                try check(intermediate.count >= 3, "六轨\(opening ? "展开" : "收起")侧栏时连续变化宽度且六轨始终对齐")
                let current = nativeViews(window.contentView!).compactMap { $0 as? XWWaveformCanvas }
                try check(Set(current.map(ObjectIdentifier.init)) == identities, "六轨动效保留全部波形实例")
            }
            try JSONSerialization.data(withJSONObject: motion, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("six-track-sidebar-geometry.json"))
            if profiling {
                try JSONSerialization.data(withJSONObject: performance, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("six-track-switch-performance.json"))
            }
            let beforeHover = work.absoluteTime
            let selectionBefore = work.range
            for (index, canvas) in canvases.enumerated() {
                try await move(17.25, over: canvas)
                let guide = try surface()
                try check(abs((guide.hoverTime ?? -1) - 17.25) < 0.000001 && guide.hoverText == "0:17.250",
                          "第 \(index + 1) 轨原生鼠标移动显示整首歌曲时间", "hover=\(guide.hoverTime ?? -1)")
            }
            try check(abs(work.absoluteTime - beforeHover) < 0.0001 && work.range == selectionBefore && !work.rangeEditing,
                      "只移动鼠标不跳播放、不改变选区")
            try await move(18.75, over: canvases[0], ruler: true)
            let rulerHover = try surface().hoverTime
            try check(abs((rulerHover ?? -1) - 18.75) < 0.000001, "时间刻度区同样显示定位线")
            let guide = try surface()
            let outside = guide.convert(NSPoint(x: 10, y: 10), to: nil)
            let exit = NSEvent.mouseEvent(with: .mouseMoved, location: outside, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
            NSApp.sendEvent(exit)
            try check(guide.hoverTime == nil, "鼠标移到左侧控制区后定位线消失")
            let canvas = canvases[0]
            let target = NSPoint(x: 6 + 0.375 * (canvas.bounds.width - 12), y: canvas.bounds.midY)
            try log("CLICK before=\(work.absoluteTime), active=\(NSApp.isActive), key=\(window.isKeyWindow), canvas=\(canvas.bounds), attached=\(canvas.window === window)")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: canvas.convert(target, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                // Address this test window explicitly while another experience window may remain open.
                window.sendEvent(event); try await pause(0.04)
            }
            try check(abs(work.absoluteTime - 17.25) < 0.0001, "透明定位线不拦截点击，预览时间与实际定位一致",
                      "actual=\(work.absoluteTime), active=\(NSApp.isActive), key=\(window.isKeyWindow)")
            try await screenshot("01-六轨鼠标定位线", prepare: {
                let view = try surface()
                let preview = NSPoint(x: 6 + 0.625 * (canvas.bounds.width - 12), y: canvas.bounds.midY)
                let point = canvas.convert(preview, to: nil)
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: self.window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
                view.mouseMoved(with: event)
            })

            let resultPlotHeight = try surface().bounds.height
            try await pressRangeControl("xw.listen.original")
            try await wait("原曲处理范围栏就绪") { originalCanvas() != nil }
            let editorHeight = try accessibleItem("xw.range.editor").frame.height
            let originalPlotHeight = try surface().bounds.height
            try check(resultPlotHeight - originalPlotHeight >= editorHeight - 0.5, "结果页移除整排设置后，空间实际还给波形")
            try await pressRangeControl("xw.range.begin")
            try await dragOriginal(from: 60, to: 90)
            try await pressRangeControl("xw.range.apply")
            try check(!work.listeningToResult && abs(work.range.lowerBound - 60) < 0.0001 && abs(work.range.upperBound - 90) < 0.0001 &&
                      !work.canExportCurrentSelection && work.mainActionLabel == "开始分离", "原曲改范围后明确等待下一次分离")
            try await pressRangeControl("xw.listen.result")
            try await wait("原有六轨结果重新显示") { work.trackWaves.count == 6 }
            try check(work.listeningToResult && work.selectedResultID == fixture.id && work.timeBounds == 15...21 && work.canExportCurrentSelection,
                      "切回结果仍试听和导出原有六秒结果")
            try check(!accessibleItems().contains { $0.identifier.hasPrefix("xw.range.") }, "改过原曲范围后结果页仍无可编辑选区")
            let afterFingerprints = try Dictionary(uniqueKeysWithValues: tracks.map { track in
                (track.id, try fileFingerprint(work.library.trackURL(projectID: id, resultID: fixture.id, track: track)).sha256)
            })
            try check(afterFingerprints == resultFingerprints && work.currentProject?.results.first(where: { $0.id == fixture.id })?.range == AudioRange(start: 15, end: 21),
                      "改原曲处理范围不改写既有结果文件或保存范围")
            try await pressRangeControl("xw.listen.original")
            try check(abs(work.range.lowerBound - 60) < 0.0001 && abs(work.range.upperBound - 90) < 0.0001, "返回原曲保留待处理范围")
            work.clearRange()
            try await wait("原曲波形布局") { originalCanvas() != nil }
            let controlIDs = ["xw.range.begin", "xw.range.start", "xw.range.end", "xw.range.apply", "xw.range.cancel"]
            func frame(_ canvas: XWWaveformCanvas) -> NSRect { window.convertToScreen(canvas.convert(canvas.bounds, to: nil)) }
            func equal(_ a: NSRect, _ b: NSRect) -> Bool {
                abs(a.minX-b.minX) < 0.5 && abs(a.minY-b.minY) < 0.5 && abs(a.width-b.width) < 0.5 && abs(a.height-b.height) < 0.5
            }
            var frames: [[String: Any]] = []
            for (width, height) in [(1120.0, 740.0), (1030.0, 740.0), (880.0, 620.0)] {
                window.setContentSize(NSSize(width: width, height: height)); try await pause(0.25)
                guard let original = originalCanvas() else {
                    try await screenshot("失败-原曲波形不可见-\(Int(width))", width: width, height: height)
                    throw Failure(message: "缺少可见原曲波形")
                }
                let before = frame(original)
                let controls = try controlIDs.map { try accessibleItem($0).frame }
                for control in controlIDs { try visibleRangeControl(control) }
                try await pressRangeControl("xw.range.begin")
                try check(equal(before, frame(originalCanvas()!)), "\(Int(width)) 宽窗口进入选段后波形完全同位同尺寸")
                try await dragOriginal(from: 61.29376, to: 291.36669)
                try check(equal(before, frame(originalCanvas()!)), "\(Int(width)) 宽窗口框选拖动不挤压波形")
                let editingControls = try controlIDs.map { try accessibleItem($0).frame }
                try check(zip(controls, editingControls).allSatisfy { equal($0.0, $0.1) }, "\(Int(width)) 宽窗口选段按钮及时间字段始终固定")
                try await move(130.75, over: originalCanvas()!)
                let hover = try surface().hoverTime
                try check(abs((hover ?? -1)-130.75) < 0.000001 && !work.draftRange.isEmpty, "\(Int(width)) 宽窗口框选区内鼠标线与时间准确")
                try await screenshot("02-固定选段与定位线-\(Int(width))", width: width, height: height, prepare: {
                    let canvas = self.originalCanvas()!
                    let point = NSPoint(x: 6 + CGFloat(130.75 / canvas.displayBounds.upperBound) * (canvas.bounds.width - 12), y: canvas.bounds.midY)
                    let event = NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: self.window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
                    try surface().mouseMoved(with: event)
                })
                try await pressRangeControl("xw.range.apply")
                try check(!work.rangeEditing && equal(before, frame(originalCanvas()!)), "\(Int(width)) 宽窗口完成选段也不改变波形尺寸")
                frames.append(["width": width, "before": NSStringFromRect(before), "after": NSStringFromRect(frame(originalCanvas()!))])
                try await pressRangeControl("xw.range.reset")
            }
            try await pressRangeControl("xw.range.begin")
            let beforeError = frame(originalCanvas()!)
            try await typeRangeValue("invalid", fieldID: "xw.range.start")
            try await pressRangeControl("xw.range.apply")
            try check(work.rangeEditing && work.draftError != nil && equal(beforeError, frame(originalCanvas()!)), "错误时间提示也不推挤波形")
            try await pressRangeControl("xw.range.cancel")
            try await pressRangeControl("xw.range.begin")
            try await pressRangeControl("xw.range.apply")
            try check(!work.rangeEditing && work.draftError == nil, "取消后重新选段，常驻时间字段恢复有效值")
            try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted]).write(to: destination.appendingPathComponent("波形尺寸对比.json"))
            let afterSource = try fileFingerprint(audio), afterLyrics = try fileFingerprint(lrc)
            try check(afterSource.sha256 == sourceHash.sha256 && afterLyrics.sha256 == lyricHash.sha256, "原始音乐和歌词均未被改写")
        }

        func runLyrics() async throws {
            let checkpoint = work.library.rootURL.deletingLastPathComponent().appendingPathComponent("lyrics-checkpoint.json")
            work.player.volume = 0 // XIANWAIWU_DATA keeps this out of daily preferences.
            if ProcessInfo.processInfo.environment["XIANWAIWU_LYRICS_REOPEN"] == "1" {
                let data = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as! [String: String]
                let id = UUID(uuidString: data["projectID"]!)!
                work.openProject(id)
                try await wait("歌词项目跨进程重开") { !work.sourceChecking && !work.player.tracks.isEmpty }
                guard let lyrics = work.currentProject?.lyrics else { throw Failure(message: "新进程没有恢复歌词") }
                try check(lyrics.cues.count == 84 && lyrics.offsetMilliseconds == 100, "新 App 进程恢复全部时间项及同步微调")
                work.seekAbsolute(16.33)
                try check(lyrics.activeIndex(at: work.absoluteTime) == 4, "跨进程重开后的准确句起点")
                try await screenshot("04-新进程恢复歌词")
                return
            }
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let audioURL = ProcessInfo.processInfo.environment["XIANWAIWU_TEST_AUDIO"].map { URL(fileURLWithPath: $0) }
                ?? downloads.appendingPathComponent("入海.mp3")
            let lyricsURL = ProcessInfo.processInfo.environment["XIANWAIWU_TEST_LYRICS"].map { URL(fileURLWithPath: $0) }
                ?? downloads.appendingPathComponent("入海歌词.lrc")
            let audioBefore = try SHA256.hash(data: Data(contentsOf: audioURL))
            let lyricsBefore = try Data(contentsOf: lyricsURL)
            work.importFile(audioURL)
            try await wait("真实入海音频导入") { !work.importing && !work.sourceChecking && !work.player.tracks.isEmpty }
            guard let projectID = work.currentProject?.id else { throw Failure(message: "实际歌曲没有导入") }
            work.importLyrics(lyricsURL)
            try await wait("用户 LRC 导入") { !work.importingLyrics }
            guard let lyrics = work.currentProject?.lyrics else { throw Failure(message: "歌词导入失败：\(work.error ?? "无错误")") }
            try check(lyrics.cues.count == 84 && lyrics.cues[4].startMilliseconds == 16430, "真实入海歌词经 App 入口导入")
            work.seekAbsolute(16.429)
            try check(lyrics.activeIndex(at: work.absoluteTime) != 4, "原曲首句之前不提前切行")
            work.seekAbsolute(16.43)
            try check(lyrics.activeIndex(at: work.absoluteTime) == 4, "原曲准确起点切到第一句")
            let paused = work.absoluteTime
            try await pause(0.2)
            try check(abs(work.absoluteTime - paused) < 0.001, "暂停时歌词时间保持")
            work.player.speed = 1.5
            work.togglePlayback()
            try await pause(0.35)
            work.player.stop()
            try check(work.absoluteTime > 16.65 && work.absoluteTime < 17.5, "真实播放器变速后歌词继续使用音频时间")
            let second = Double(lyrics.cues[5].startMilliseconds) / 1000
            work.player.setA(16.43); work.player.setB(second + 0.25); work.player.updateLoop(true)
            work.seekAbsolute(second + 0.20)
            work.togglePlayback()
            try await pause(0.3)
            work.player.stop()
            try check(work.absoluteTime >= 16.43 && work.absoluteTime < second && lyrics.activeIndex(at: work.absoluteTime) == 4,
                      "真实 A/B 循环回跳后歌词返回第一句", "time=\(work.absoluteTime)")
            work.player.clearLoop(); work.player.speed = 1

            // Three seconds of silent fixture tracks test clip offsets; no model inference is claimed.
            let temporary = try work.library.temporaryResultURL(projectID: projectID)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132300)!
            buffer.frameLength = 132300
            for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 132300) }
            let rows = [ResultTrackRecord(id: "vocals", label: "人声", filename: "vocals.wav"),
                        ResultTrackRecord(id: "instrumental", label: "伴奏", filename: "instrumental.wav")]
            for row in rows {
                let file = try AVAudioFile(forWriting: temporary.appendingPathComponent(row.filename), settings: format.settings)
                try file.write(from: buffer)
            }
            let result = try work.library.commitResult(projectID: projectID, temporaryURL: temporary,
                record: ResultRecord(mode: "pair", range: AudioRange(start: 15, end: 18), tracks: rows))
            work.openProject(projectID)
            try await wait("片段歌词同步检查") { !work.sourceChecking && work.currentProject?.results.count == 1 }
            work.switchResult(result.id)
            work.seekAbsolute(16.43)
            try check(work.listeningToResult && abs(work.player.time - 1.43) < 0.001 && lyrics.activeIndex(at: work.absoluteTime) == 4,
                      "片段内部 1.43 秒对应整首 16.43 秒的歌词")
            try await screenshot("01-入海歌词与片段")
            work.selectMode("lead3")
            try check(work.currentProject?.lyrics == lyrics, "切换三轨板块共享同一份歌词")
            work.selectMode("pair")
            work.original(); work.clearRange()
            work.shiftLyrics(100)
            try check(work.currentProject?.lyrics?.offsetMilliseconds == 100, "歌词提前 0.1 秒保存")
            work.seekAbsolute(16.33)
            try check(work.currentProject?.lyrics?.activeIndex(at: work.absoluteTime) == 4, "微调后点击位置与显示保持一致")
            work.saveListening()
            let saved = work.currentProject!.lyrics!
            let invalid = input.appendingPathComponent("时间残缺.txt")
            try "[00:16]第一句\n第二句没有时间".write(to: invalid, atomically: true, encoding: .utf8)
            work.importLyrics(invalid)
            try await wait("残缺歌词拒绝") { !work.importingLyrics }
            try check(work.error?.contains("缺少时间") == true && work.currentProject?.lyrics == saved, "失败导入保留原有歌词")
            work.error = nil
            let other = try work.library.createProject(source: work.currentProject!.source, name: "歌词隔离测试")
            work.importLyrics(lyricsURL)
            work.openProject(other.id)
            try await pause(0.3)
            try check(work.currentProject?.id == other.id && work.currentProject?.lyrics == nil && !work.importingLyrics,
                      "导入期间切换歌曲，晚到回调不会污染新项目")
            work.openProject(projectID)
            try await wait("恢复入海歌词项目") { !work.sourceChecking && !work.player.tracks.isEmpty }
            work.seekAbsolute(16.33)
            work.saveListening()
            let reopened = try LibraryStore(rootURL: work.library.rootURL)
            try check(reopened.projects.first(where: { $0.id == projectID })?.lyrics == saved, "重新读取资料库完整保留歌词和微调")
            try await screenshot("02-入海歌词宽窗口")
            try await screenshot("03-入海歌词窄窗口", width: 880, height: 620)
            let audioAfter = try SHA256.hash(data: Data(contentsOf: audioURL))
            let lyricsAfter = try Data(contentsOf: lyricsURL)
            try check(audioAfter == audioBefore && lyricsAfter == lyricsBefore, "用户原始 MP3 与 LRC 均未改写")
            try JSONSerialization.data(withJSONObject: ["projectID": projectID.uuidString], options: [.prettyPrinted])
                .write(to: checkpoint, options: .atomic)
        }

        func finish(success: Bool, message: String) throws {
            try log("\(success ? "COMPLETED" : "FAILED") \(checks.count) checks / \(ProcessInfo.processInfo.systemUptime-began) seconds\n\(message)")
            let boundary = ProcessInfo.processInfo.environment["XIANWAIWU_WAVEFORM_ONLY"] == "1"
                ? "独立资料库、正式原生视图及原生鼠标事件、真实入海原曲与歌词；六轨使用六秒合成夹具，未做模型分离或云端调用。波形/按钮坐标逐项比较，非人工鼠标验收。"
                : ProcessInfo.processInfo.environment["XIANWAIWU_RANGE_ONLY"] == "1"
                ? "独立资料库、正式原生视图、鼠标/键盘事件与辅助功能按钮、真实播放器和导出；复用同源既有真实三轨结果，未启动新的模型推理或云端调用。"
                : ProcessInfo.processInfo.environment["XIANWAIWU_LYRICS_ONLY"] == "1"
                ? "正式 App 隔离资料库，用户入海 MP3/LRC 导入，真实播放器暂停、变速、循环及跨进程恢复；片段音轨为静音夹具，无分离模型推理、云端调用或人工听音验收。"
                : ProcessInfo.processInfo.environment["XIANWAIWU_QUALITY_ONLY"] == "1"
                ? "正式App真实窗口、AX时间输入、播放器、后台源校验与自动保存；70秒仅由既有7秒录音循环，复用既有真实两轨，无新模型推理。跨进程恢复仅QUALITY_REOPEN真实新进程专项证明。"
                : "真实原生窗口、公开工作流命令、真实引擎、音频解码与播放时钟。音质听感与逐像素视觉验收另行记录。"
            let report: [String: Any] = ["success": success, "message": message, "passedChecks": checks.count,
                                         "elapsed": ProcessInfo.processInfo.systemUptime-began,
                                         "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                         "library": work.library.rootURL.path,
                                         "checks": checks.map { ["name": $0.name, "detail": $0.detail, "elapsed": $0.elapsed] },
                                         "exports": exports.map(\.path),
                                         "validationBoundary": boundary]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("原生验收.json"), options: .atomic)
        }
    }
}
