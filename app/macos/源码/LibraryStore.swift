import AVFoundation
import Combine
import CryptoKit
import Darwin
import Foundation

struct AudioRange: Codable, Equatable {
    var start: Double
    var end: Double
    var closedRange: ClosedRange<Double> { start...end }
}

struct ListeningRecord: Codable, Equatable {
    var absoluteTime: Double = 0
    var enabled: Set<String> = []
    var solo: Set<String> = []
}

struct SourceRecord: Codable, Equatable {
    var path: String
    var duration: Double
    var sampleRate: Double
    var channels: UInt32
    var bytes: Int64
    var modificationDate: Date
    var sha256: String
    var bookmarkData: Data?
    var url: URL { URL(fileURLWithPath: path) }
}

struct ResultTrackRecord: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var filename: String
    var peakDB: Double? = nil
}

struct ExportRecord: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var format: String
    var trackIDs: [String]
    var path: String
    var gainDB: Double = 0
    var url: URL { URL(fileURLWithPath: path) }
}

struct ResultRecord: Codable, Equatable, Identifiable {
    var schemaVersion: Int = 1
    var id: UUID
    var mode: String
    var range: AudioRange
    var tracks: [ResultTrackRecord]
    var elapsed: Double
    var device: String?
    var backend: String?
    var engineGainDB: Double?
    var createdAt: Date
    var listening: ListeningRecord
    var exports: [ExportRecord]
    var relativePath: String { "Results/\(id.uuidString)" }

    init(id: UUID = UUID(), mode: String, range: AudioRange, tracks: [ResultTrackRecord],
         elapsed: Double = 0, device: String? = nil, backend: String? = nil, engineGainDB: Double? = nil) {
        self.id = id
        self.mode = mode
        self.range = range
        self.tracks = tracks
        self.elapsed = elapsed
        self.device = device
        self.backend = backend
        self.engineGainDB = engineGainDB
        self.createdAt = Date()
        self.listening = ListeningRecord(absoluteTime: range.start, enabled: Set(tracks.map(\.id)))
        self.exports = []
    }
}

enum SeparationModeIdentity {
    static func board(_ mode: String) -> String {
        ["leadback", "lead", "backing"].contains(mode) ? "lead3" : mode
    }
}

struct ModeWorkspaceState: Codable, Equatable {
    var range: AudioRange? = nil
    var selectedResultID: UUID? = nil
    var listeningToResult = false
    var sourceListening = ListeningRecord(absoluteTime: 0, enabled: ["original"])
}

/// A narrow patch: background saves cannot replace results, export receipts, or folder membership.
struct ListeningUpdate {
    var projectID: UUID
    var mode: String
    var range: AudioRange?
    var selectedResultID: UUID?
    var listeningToResult: Bool
    var listening: ListeningRecord
    var sourceListening: ListeningRecord
}

struct ProjectRecord: Codable, Equatable, Identifiable {
    var schemaVersion: Int = 1
    var id: UUID = UUID()
    var title: String
    var source: SourceRecord
    var mode: String = "pair"
    var range: AudioRange? = nil
    var currentResultID: UUID? = nil
    var listeningToResult = false
    var sourceListening = ListeningRecord(absoluteTime: 0, enabled: ["original"])
    // Optional so every existing schema-1 project remains readable without migration.
    var modeStates: [String: ModeWorkspaceState]? = nil
    var lyrics: LyricsDocument? = nil
    var score: ScoreDocument? = nil
    var results: [ResultRecord] = []
    var folderID: UUID? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var revision: Int = 0
}

struct FolderRecord: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
}

struct LibraryPreferences: Codable, Equatable {
    var exportFormat = "wav24"
    var lastExportPath: String? = nil
    var lastExportBookmark: Data? = nil
    var volume: Float = 0.85
}

struct LibraryDocument: Codable, Equatable {
    var schemaVersion: Int = 1
    var revision: Int = 0
    var projects: [ProjectRecord] = []
    var folders: [FolderRecord] = []
    var preferences = LibraryPreferences()
}

enum SourceStatus {
    case available(URL)
    case missing
    case changed
    case unreadable(String)
}

struct LibraryFailure: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The atomic library snapshot is authoritative. Per-project JSON files are recovery copies.
/// Call mutations from the UI thread. A process lock also serializes separate app instances.
final class LibraryStore: ObservableObject {
    @Published private(set) var document = LibraryDocument()
    @Published private(set) var warnings: [String] = []
    let rootURL: URL
    var projects: [ProjectRecord] { document.projects.sorted { $0.updatedAt > $1.updatedAt } }
    var folders: [FolderRecord] { document.folders }
    var preferences: LibraryPreferences { document.preferences }
    private let manager = FileManager.default
    private let localLock = NSRecursiveLock()
    private let persistenceWarningsLock = NSLock()
    private var pendingPersistenceWarnings: [String] = []
    private var indexURL: URL { rootURL.appendingPathComponent("library.json") }

    init(rootURL: URL? = nil) throws {
        let base = try rootURL ?? FileManager.default.url(for: .applicationSupportDirectory,
                                                        in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Xianwaiwu", isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        self.rootURL = base.standardizedFileURL.resolvingSymlinksInPath()
        try withLock {
            if manager.fileExists(atPath: indexURL.path) {
                document = try readDocument()
                cleanupAbandonedTemporary()
            } else {
                let projectsURL = self.rootURL.appendingPathComponent("Projects", isDirectory: true)
                let contents = (try? manager.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: nil)) ?? []
                guard contents.isEmpty else {
                    throw LibraryFailure("项目索引缺失，原有项目目录已保留。请先恢复资料库，避免覆盖已有内容。\n\(projectsURL.path)")
                }
                try writeJSON(document, to: indexURL)
            }
        }
    }

    static func makeSource(url: URL, duration: Double, sampleRate: Double, channels: UInt32) throws -> SourceRecord {
        guard url.isFileURL, duration.isFinite, (0.2...14400).contains(duration),
              sampleRate.isFinite, sampleRate > 0, (1...2).contains(channels) else {
            throw LibraryFailure("原音频的时长或声音信息无效。")
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
              let modified = values.contentModificationDate else { throw LibraryFailure("原音频不是可读取的文件。") }
        let digest = try fileDigest(url)
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard after.fileSize == size, after.contentModificationDate == modified else {
            throw LibraryFailure("读取时原音频发生了变化，请等文件保存完成再导入。")
        }
        return SourceRecord(path: url.standardizedFileURL.path, duration: duration, sampleRate: sampleRate,
                            channels: channels, bytes: Int64(size), modificationDate: modified, sha256: digest,
                            bookmarkData: try? url.bookmarkData(options: .withSecurityScope,
                                                               includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    func sourceStatus(for source: SourceRecord) -> SourceStatus {
        var stale = false
        let resolved = source.bookmarkData.flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI],
                     relativeTo: nil, bookmarkDataIsStale: &stale)
        } ?? source.url
        let accessed = resolved.startAccessingSecurityScopedResource()
        defer { if accessed { resolved.stopAccessingSecurityScopedResource() } }
        guard manager.fileExists(atPath: resolved.path) else { return .missing }
        do {
            let size = try resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == source.bytes else { return .changed }
            guard try Self.fileDigest(resolved) == source.sha256 else { return .changed }
            return .available(resolved)
        } catch { return .unreadable(error.localizedDescription) }
    }

    @discardableResult
    func createProject(source: SourceRecord, name: String? = nil) throws -> ProjectRecord {
        guard !contains(source.url, in: rootURL) else {
            throw LibraryFailure("请从应用资料库之外选择原音频，避免把内部缓存作为原曲。")
        }
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (clean?.isEmpty == false ? clean : nil) ?? source.url.deletingPathExtension().lastPathComponent
        let project = ProjectRecord(title: title, source: source)
        try mutate { $0.projects.append(project) }
        return project
    }

    @discardableResult
    func saveProject(_ project: ProjectRecord) throws -> ProjectRecord {
        var saved = project
        try mutate { doc in
            guard let index = doc.projects.firstIndex(where: { $0.id == project.id }) else {
                throw LibraryFailure("项目已被删除，无法保存。")
            }
            guard doc.projects[index].revision == project.revision else {
                throw LibraryFailure("项目已在其他操作中更新，请重新打开后继续。")
            }
            guard project.folderID == nil || doc.folders.contains(where: { $0.id == project.folderID }) else {
                throw LibraryFailure("目标文件夹已不存在。")
            }
            saved.revision += 1
            saved.updatedAt = Date()
            doc.projects[index] = saved
        }
        return saved
    }

    /// Only the attachment changes; concurrent listening, folders and results retain their latest values.
    @discardableResult
    func setLyrics(_ lyrics: LyricsDocument?, projectID: UUID, replacing expected: LyricsDocument?) throws -> ProjectRecord {
        var saved: ProjectRecord?
        try mutate { doc in
            guard let index = doc.projects.firstIndex(where: { $0.id == projectID }) else {
                throw LibraryFailure("项目已被删除，无法保存歌词。")
            }
            guard doc.projects[index].lyrics == expected else {
                throw LyricsFailure(.changed, "歌词已在其他操作中更新，请重新打开后再编辑。")
            }
            try lyrics?.validate(duration: doc.projects[index].source.duration)
            doc.projects[index].lyrics = lyrics
            doc.projects[index].revision += 1
            doc.projects[index].updatedAt = Date()
            saved = doc.projects[index]
        }
        return saved!
    }

    /// Patch only the score attachment, preserving concurrent playback, lyrics and separation work.
    @discardableResult
    func setScore(_ score: ScoreDocument, projectID: UUID, replacing expected: ScoreDocument?) throws -> ProjectRecord {
        var saved: ProjectRecord?
        try mutate { doc in
            guard let index = doc.projects.firstIndex(where: { $0.id == projectID }) else {
                throw LibraryFailure("项目已被删除，乐谱没有保存到其他歌曲。")
            }
            guard doc.projects[index].score == expected else {
                throw LibraryFailure("乐谱已在其他操作中更新，已保留较新的修改，请重新打开后再试。")
            }
            try score.validate(source: doc.projects[index].source)
            doc.projects[index].score = score
            doc.projects[index].revision += 1
            doc.projects[index].updatedAt = Date()
            saved = doc.projects[index]
        }
        return saved!
    }

    /// Safe on a serial background queue. Uses the latest locked index and never publishes UI state.
    func persistListening(_ update: ListeningUpdate) throws -> (project: ProjectRecord, document: LibraryDocument) {
        try withLock {
            var current = try readDocument()
            guard let index = current.projects.firstIndex(where: { $0.id == update.projectID }) else {
                throw LibraryFailure("项目已被删除，无法保存试听。")
            }
            let board = SeparationModeIdentity.board(update.mode)
            guard ["pair", "lead3", "music6"].contains(board),
                  update.listening.absoluteTime.isFinite, update.sourceListening.absoluteTime.isFinite,
                  update.selectedResultID == nil || current.projects[index].results.contains(where: {
                      $0.id == update.selectedResultID && SeparationModeIdentity.board($0.mode) == board
                  }), !update.listeningToResult || update.selectedResultID != nil else {
                throw LibraryFailure("试听记录与当前分离板块不匹配。")
            }
            current.projects[index].mode = update.mode
            current.projects[index].range = update.range
            current.projects[index].currentResultID = update.selectedResultID
            current.projects[index].listeningToResult = update.listeningToResult
            current.projects[index].sourceListening = update.sourceListening
            if update.listeningToResult,
               let resultIndex = current.projects[index].results.firstIndex(where: { $0.id == update.selectedResultID }) {
                current.projects[index].results[resultIndex].listening = update.listening
            } else {
                current.projects[index].sourceListening = update.listening
            }
            var states = current.projects[index].modeStates ?? [:]
            states[board] = ModeWorkspaceState(range: update.range, selectedResultID: update.selectedResultID,
                                               listeningToResult: update.listeningToResult,
                                               sourceListening: current.projects[index].sourceListening)
            current.projects[index].modeStates = states
            current.projects[index].revision += 1
            current.projects[index].updatedAt = Date()
            try persist(&current)
            return (current.projects[index], current)
        }
    }

    /// Adopt completed background writes only on the main thread, without moving the UI backwards.
    func adoptListeningDocument(_ committed: LibraryDocument) {
        precondition(Thread.isMainThread, "资料库界面状态只能在主线程更新。")
        if committed.revision >= document.revision { document = committed }
        // UI publication must never wait for another save's file I/O.
        persistenceWarningsLock.lock()
        let notices = pendingPersistenceWarnings
        pendingPersistenceWarnings.removeAll()
        persistenceWarningsLock.unlock()
        if !notices.isEmpty { warnings.append(contentsOf: notices) }
    }

    @discardableResult
    func createFolder(name: String) throws -> FolderRecord {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !clean.isEmpty, clean.count <= 24, !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LibraryFailure("文件夹名称需要 1 至 24 个字符，请去掉换行等特殊字符。")
        }
        let folder = FolderRecord(name: clean)
        try mutate { doc in
            guard !doc.folders.contains(where: { $0.name.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
                throw LibraryFailure("已经有同名文件夹了。")
            }
            doc.folders.append(folder)
        }
        return folder
    }

    func moveProject(_ id: UUID, to folderID: UUID?) throws {
        try mutate { doc in
            guard folderID == nil || doc.folders.contains(where: { $0.id == folderID }) else {
                throw LibraryFailure("目标文件夹已不存在。")
            }
            guard let index = doc.projects.firstIndex(where: { $0.id == id }) else { throw LibraryFailure("项目已不存在。") }
            doc.projects[index].folderID = folderID
            doc.projects[index].revision += 1
            doc.projects[index].updatedAt = Date()
        }
    }

    func deleteFolder(_ id: UUID) throws {
        try mutate { doc in
            guard doc.folders.contains(where: { $0.id == id }) else { throw LibraryFailure("文件夹已不存在。") }
            doc.folders.removeAll { $0.id == id }
            for index in doc.projects.indices where doc.projects[index].folderID == id {
                doc.projects[index].folderID = nil
                doc.projects[index].revision += 1
                doc.projects[index].updatedAt = Date()
            }
        }
    }

    func deleteProject(_ id: UUID) throws {
        try withLock {
            let current = try readDocument()
            guard current.projects.contains(where: { $0.id == id }) else { throw LibraryFailure("项目已不存在。") }
            let directory = projectURL(id)
            try assertOwned(directory)
            let protected = current.projects.flatMap { project in
                [project.source.url] + project.results.flatMap { $0.exports.map(\.url) }
            }
            var updated = current
            updated.projects.removeAll { $0.id == id }
            try persist(&updated)
            adoptListeningDocument(updated)
            // Never recurse into a directory containing a user source or an export receipt.
            if protected.contains(where: { contains($0, in: directory) }) {
                warnings.append("项目记录已删除，内部目录含原曲或导出文件，已保留该目录。\n\(directory.path)")
            } else if manager.fileExists(atPath: directory.path) {
                do { try manager.removeItem(at: directory) }
                catch { warnings.append("项目记录已删除，部分内部缓存暂未清理。\n\(error.localizedDescription)") }
            }
        }
    }

    @discardableResult
    func relocateSource(projectID: UUID, to url: URL) throws -> ProjectRecord {
        let previous = try withLock { () throws -> SourceRecord in
            guard let project = try readDocument().projects.first(where: { $0.id == projectID }) else { throw LibraryFailure("项目已不存在。") }
            return project.source
        }
        let verified = try Self.makeSource(url: url, duration: previous.duration,
                                          sampleRate: previous.sampleRate, channels: previous.channels)
        return try relocateSource(projectID: projectID, verifiedSource: verified)
    }

    @discardableResult
    func relocateSource(projectID: UUID, verifiedSource: SourceRecord) throws -> ProjectRecord {
        try withLock {
            var current = try readDocument()
            guard let index = current.projects.firstIndex(where: { $0.id == projectID }) else { throw LibraryFailure("项目已不存在。") }
            let previous = current.projects[index].source
            guard !contains(verifiedSource.url, in: rootURL) else { throw LibraryFailure("请定位到应用资料库之外的原音频。") }
            guard verifiedSource.sha256 == previous.sha256, verifiedSource.bytes == previous.bytes,
                  verifiedSource.duration == previous.duration, verifiedSource.sampleRate == previous.sampleRate,
                  verifiedSource.channels == previous.channels else {
                throw LibraryFailure("这份文件与原音频内容不同，请选择原来的音频。已有分轨仍可继续使用。")
            }
            let accessed = verifiedSource.url.startAccessingSecurityScopedResource()
            defer { if accessed { verifiedSource.url.stopAccessingSecurityScopedResource() } }
            let values = try verifiedSource.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.fileSize.map(Int64.init) == verifiedSource.bytes,
                  values.contentModificationDate == verifiedSource.modificationDate else {
                throw LibraryFailure("核对后原音频又发生了变化，请重新选择。")
            }
            current.projects[index].source = verifiedSource
            current.projects[index].revision += 1
            current.projects[index].updatedAt = Date()
            try persist(&current)
            adoptListeningDocument(current)
            return current.projects[index]
        }
    }

    func temporaryResultURL(projectID: UUID, taskID: UUID = UUID()) throws -> URL {
        try withLock {
            guard try readDocument().projects.contains(where: { $0.id == projectID }) else { throw LibraryFailure("项目已不存在。") }
            let url = projectURL(projectID).appendingPathComponent("Temporary/\(taskID.uuidString)", isDirectory: true)
            try assertOwned(url)
            guard !manager.fileExists(atPath: url.path) else { throw LibraryFailure("本次任务目录已存在，请使用新的任务。") }
            try writeJSON(TaskLease(projectID: projectID, taskID: taskID, processID: getpid()), to: leaseURL(projectID: projectID, taskID: taskID))
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    func discardTemporaryResult(_ url: URL, projectID: UUID) throws {
        try withLock {
            let parent = projectURL(projectID).appendingPathComponent("Temporary", isDirectory: true)
            try assertOwned(url)
            guard url.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL,
                  UUID(uuidString: url.lastPathComponent) != nil else { throw LibraryFailure("无法清理不属于本次任务的目录。") }
            guard !hasProtectedFile(in: url, document: try readDocument()) else { throw LibraryFailure("任务目录含原曲或导出文件，已保留。") }
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            if let taskID = UUID(uuidString: url.lastPathComponent) { try? manager.removeItem(at: leaseURL(projectID: projectID, taskID: taskID)) }
        }
    }

    @discardableResult
    func commitResult(projectID: UUID, temporaryURL: URL, record: ResultRecord, activate: Bool = true) throws -> ResultRecord {
        try withLock {
            var current = try readDocument()
            guard let index = current.projects.firstIndex(where: { $0.id == projectID }) else { throw LibraryFailure("项目已被删除，本次结果未加入资料库。") }
            let temporaryParent = projectURL(projectID).appendingPathComponent("Temporary", isDirectory: true)
            try assertOwned(temporaryURL)
            guard temporaryURL.deletingLastPathComponent().standardizedFileURL == temporaryParent.standardizedFileURL,
                  UUID(uuidString: temporaryURL.lastPathComponent) != nil else { throw LibraryFailure("结果必须来自本项目的临时任务目录。") }
            try validateResult(record, source: current.projects[index].source, directory: temporaryURL)
            guard !current.projects[index].results.contains(where: { $0.id == record.id }) else { throw LibraryFailure("这份结果已经保存。") }
            let destination = resultURL(projectID: projectID, resultID: record.id)
            try assertOwned(destination)
            guard !manager.fileExists(atPath: destination.path) else { throw LibraryFailure("结果目录已存在，已有文件已保留。") }
            try writeJSON(record, to: temporaryURL.appendingPathComponent("result.json"))
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: temporaryURL, to: destination)
            current.projects[index].results.append(record)
            let key = SeparationModeIdentity.board(record.mode)
            var states = current.projects[index].modeStates ?? [:]
            var state = states[key] ?? ModeWorkspaceState(sourceListening: ListeningRecord(absoluteTime: record.range.start, enabled: ["original"]))
            state.selectedResultID = record.id
            state.listeningToResult = true
            state.range = record.range
            states[key] = state
            current.projects[index].modeStates = states
            if activate {
                current.projects[index].currentResultID = record.id
                current.projects[index].listeningToResult = true
                current.projects[index].mode = record.mode
                current.projects[index].range = record.range
            }
            current.projects[index].updatedAt = Date()
            current.projects[index].revision += 1
            do { try persist(&current) }
            catch {
                // The library snapshot still refers to the previous state. Keep the completed files recoverable.
                try? manager.moveItem(at: destination, to: temporaryURL)
                throw error
            }
            adoptListeningDocument(current)
            if let taskID = UUID(uuidString: temporaryURL.lastPathComponent) { try? manager.removeItem(at: leaseURL(projectID: projectID, taskID: taskID)) }
            return record
        }
    }

    func resultURL(projectID: UUID, resultID: UUID) -> URL {
        projectURL(projectID).appendingPathComponent("Results/\(resultID.uuidString)", isDirectory: true)
    }

    func trackURL(projectID: UUID, resultID: UUID, track: ResultTrackRecord) throws -> URL {
        guard validFilename(track.filename) else { throw LibraryFailure("分轨文件名无效。") }
        let directory = resultURL(projectID: projectID, resultID: resultID)
        let url = directory.appendingPathComponent(track.filename)
        try assertOwned(url)
        guard contains(url, in: directory), !isSymlink(url) else { throw LibraryFailure("分轨文件路径超出本项目。") }
        return url
    }

    func savePreferences(_ preferences: LibraryPreferences) throws {
        guard preferences.volume.isFinite, (0...1).contains(preferences.volume),
              ["wav24", "wav16", "flac", "mp3"].contains(preferences.exportFormat) else { throw LibraryFailure("试听或导出设置无效。") }
        try mutate { $0.preferences = preferences }
    }

    func saveWaveform(_ peaks: [Float], projectID: UUID, resultID: UUID? = nil, trackID: String = "original") throws {
        try withLock {
            let current = try readDocument()
            guard let project = current.projects.first(where: { $0.id == projectID }),
                  peaks.count <= 100000, peaks.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw LibraryFailure("波形缓存无效或项目已被删除。") }
            if let resultID {
                guard project.results.contains(where: { $0.id == resultID && $0.tracks.contains(where: { $0.id == trackID }) }) else { throw LibraryFailure("波形对应的分轨已不存在。") }
            }
            let url = try waveformURL(projectID: projectID, resultID: resultID, trackID: trackID)
            try writeJSON(WaveformRecord(sourceSHA256: project.source.sha256, peaks: peaks), to: url)
        }
    }

    func loadWaveform(projectID: UUID, resultID: UUID? = nil, trackID: String = "original") -> [Float]? {
        guard let project = document.projects.first(where: { $0.id == projectID }),
              let url = try? waveformURL(projectID: projectID, resultID: resultID, trackID: trackID),
              let data = try? Data(contentsOf: url), let wave = try? decoder().decode(WaveformRecord.self, from: data),
              wave.schemaVersion == 1, wave.sourceSHA256 == project.source.sha256,
              wave.peaks.count <= 100000, wave.peaks.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return wave.peaks
    }

    func reload() throws {
        try withLock { adoptListeningDocument(try readDocument()) }
    }

    private struct WaveformRecord: Codable {
        var schemaVersion = 1
        var sourceSHA256: String
        var peaks: [Float]
    }

    private struct TaskLease: Codable {
        var projectID: UUID
        var taskID: UUID
        var processID: Int32
    }

    private func leaseURL(projectID: UUID, taskID: UUID) -> URL {
        projectURL(projectID).appendingPathComponent("Tasks/\(taskID.uuidString).json")
    }

    private func hasProtectedFile(in directory: URL, document: LibraryDocument) -> Bool {
        document.projects.contains { project in
            contains(project.source.url, in: directory) || project.results.contains { result in
                result.exports.contains { contains($0.url, in: directory) }
            }
        }
    }

    private func cleanupAbandonedTemporary() {
        for project in document.projects {
            let taskFolder = projectURL(project.id).appendingPathComponent("Tasks", isDirectory: true)
            guard (try? assertOwned(taskFolder)) != nil,
                  let files = try? manager.contentsOfDirectory(at: taskFolder, includingPropertiesForKeys: nil) else { continue }
            let leases = files.compactMap { url -> TaskLease? in
                guard (try? assertOwned(url)) != nil, let bytes = try? Data(contentsOf: url),
                      let lease = try? decoder().decode(TaskLease.self, from: bytes), lease.projectID == project.id,
                      lease.processID > 0, url.lastPathComponent == "\(lease.taskID.uuidString).json" else { return nil }
                return lease
            }
            let abandoned = leases.filter { kill($0.processID, 0) != 0 && errno == ESRCH }
            for lease in abandoned {
                let temporary = projectURL(project.id).appendingPathComponent("Temporary/\(lease.taskID.uuidString)", isDirectory: true)
                guard (try? assertOwned(temporary)) != nil, !hasProtectedFile(in: temporary, document: document) else { continue }
                if manager.fileExists(atPath: temporary.path) { try? manager.removeItem(at: temporary) }
                try? manager.removeItem(at: leaseURL(projectID: project.id, taskID: lease.taskID))
            }
            // The worker makes randomized staging directories beside the final task directory.
            // Clean these only when no task for this project belongs to a live process.
            if !abandoned.isEmpty && abandoned.count == leases.count {
                let parent = projectURL(project.id).appendingPathComponent("Temporary", isDirectory: true)
                let stages = (try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
                for stage in stages where stage.lastPathComponent.hasPrefix(".分离-") {
                    guard (try? assertOwned(stage)) != nil, !hasProtectedFile(in: stage, document: document) else { continue }
                    try? manager.removeItem(at: stage)
                }
            }
        }
    }

    private func waveformURL(projectID: UUID, resultID: UUID?, trackID: String) throws -> URL {
        let key = SHA256.hash(data: Data(trackID.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = resultID?.uuidString ?? "Original"
        let url = projectURL(projectID).appendingPathComponent("Waveforms/\(folder)/\(key).json")
        try assertOwned(url)
        return url
    }

    private func mutate(_ change: (inout LibraryDocument) throws -> Void) throws {
        try withLock {
            var updated = try readDocument()
            try change(&updated)
            try persist(&updated)
            adoptListeningDocument(updated)
        }
    }

    private func persist(_ updated: inout LibraryDocument) throws {
        try validateDocument(updated)
        updated.revision += 1
        for project in updated.projects {
            let url = projectURL(project.id).appendingPathComponent("project.json")
            try assertOwned(url)
            if let existing = try? Data(contentsOf: url) {
                if let snapshot = try? decoder().decode(ProjectRecord.self, from: existing) {
                    // Compare actual disk content, never this instance's possibly stale published document.
                    // Codable equality also ignores Set ordering and JSON formatting differences.
                    if snapshot == project { continue }
                } else {
                    try writeData(existing, to: rootURL.appendingPathComponent("Recovery/\(UUID().uuidString)-project.json"))
                    persistenceWarningsLock.lock()
                    pendingPersistenceWarnings.append("有一份项目副本损坏，已保留损坏文件，并从完整索引恢复。")
                    persistenceWarningsLock.unlock()
                }
            }
            try writeJSON(project, to: url)
        }
        // Commit last. A crash while writing recovery copies cannot replace the previous valid snapshot.
        try writeJSON(updated, to: indexURL)
    }

    private func readDocument() throws -> LibraryDocument {
        try assertOwned(indexURL)
        let bytes = try Data(contentsOf: indexURL)
        do {
            let loaded = try decoder().decode(LibraryDocument.self, from: bytes)
            try validateDocument(loaded)
            return loaded
        } catch {
            let recovery = rootURL.appendingPathComponent("Recovery/\(UUID().uuidString)-library.json")
            try? writeData(bytes, to: recovery)
            throw LibraryFailure("项目资料库暂时无法读取，原始资料库已保留。请从保留文件恢复后重试。\n\(indexURL.path)\n\(error.localizedDescription)")
        }
    }

    private func validateDocument(_ doc: LibraryDocument) throws {
        guard doc.schemaVersion == 1 else { throw LibraryFailure("项目资料库版本暂不受支持，原文件已保留。") }
        guard Set(doc.projects.map(\.id)).count == doc.projects.count,
              Set(doc.folders.map(\.id)).count == doc.folders.count else { throw LibraryFailure("项目资料库有重复记录。") }
        for project in doc.projects {
            guard project.schemaVersion == 1, project.source.duration.isFinite, project.source.duration >= 0.2,
                  project.source.sampleRate.isFinite, project.source.sampleRate > 0,
                  project.source.bytes > 0, project.source.sha256.count == 64,
                  project.sourceListening.absoluteTime.isFinite,
                  Set(project.results.map(\.id)).count == project.results.count,
                  project.currentResultID == nil || project.results.contains(where: { $0.id == project.currentResultID }),
                  project.folderID == nil || doc.folders.contains(where: { $0.id == project.folderID }) else { throw LibraryFailure("项目记录不完整。") }
            try project.score?.validate(source: project.source)
            if let range = project.range { try validateRange(range, duration: project.source.duration) }
            for result in project.results {
                try validateRange(result.range, duration: project.source.duration)
                guard result.schemaVersion == 1, !result.tracks.isEmpty, Set(result.tracks.map(\.id)).count == result.tracks.count,
                      result.tracks.allSatisfy({ validFilename($0.filename) }), result.listening.absoluteTime.isFinite else { throw LibraryFailure("已保存的分轨记录不完整。") }
            }
            for (key, state) in project.modeStates ?? [:] {
                if let range = state.range { try validateRange(range, duration: project.source.duration) }
                guard state.sourceListening.absoluteTime.isFinite,
                      state.selectedResultID == nil || project.results.contains(where: { $0.id == state.selectedResultID && SeparationModeIdentity.board($0.mode) == key }) else {
                    throw LibraryFailure("板块的结果或试听记录不完整。")
                }
            }
        }
    }

    private func validateRange(_ range: AudioRange, duration: Double) throws {
        guard range.start.isFinite, range.end.isFinite, range.start >= 0,
              range.end <= duration + 0.000001, range.end - range.start >= 0.2 - 0.000001 else { throw LibraryFailure("处理范围无效。") }
    }

    private func validateResult(_ result: ResultRecord, source: SourceRecord, directory: URL) throws {
        try validateRange(result.range, duration: source.duration)
        let expected = ["pair": ["vocals", "instrumental"], "leadback": ["lead", "backing"],
                        "lead3": ["lead", "harmony", "instrumental"],
                        "music6": ["vocals", "drums", "bass", "guitar", "piano", "other"]]
        guard let ids = expected[result.mode], result.tracks.map(\.id) == ids,
              Set(result.tracks.map(\.filename)).count == result.tracks.count else { throw LibraryFailure("分离结果的音轨数量或顺序不完整。") }
        var length: AVAudioFramePosition?
        for track in result.tracks {
            guard validFilename(track.filename) else { throw LibraryFailure("分离结果有无效文件名。") }
            let url = directory.appendingPathComponent(track.filename)
            try assertOwned(url)
            guard contains(url, in: directory), !isSymlink(url) else { throw LibraryFailure("分离结果包含外部文件链接。") }
            let audio = try AVAudioFile(forReading: url)
            let expectedFrames = ((result.range.end - result.range.start) * 44100).rounded()
            guard audio.length > 0, audio.processingFormat.sampleRate == 44100,
                  audio.processingFormat.channelCount == 2,
                  abs(Double(audio.length) - expectedFrames) <= 1,
                  length == nil || audio.length == length else { throw LibraryFailure("分离音轨不完整或没有正确对齐。") }
            length = audio.length
        }
    }

    private func projectURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent("Projects/\(id.uuidString)", isDirectory: true)
    }

    private func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private func contains(_ item: URL, in directory: URL) -> Bool {
        let path = item.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return path == parent || path.hasPrefix(parent + "/")
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func assertOwned(_ url: URL) throws {
        let normalized = url.standardizedFileURL
        guard normalized.path.hasPrefix(rootURL.path + "/"), contains(normalized, in: rootURL) else { throw LibraryFailure("资料库路径超出应用目录。") }
        var current = normalized
        while current.path != rootURL.path {
            guard !isSymlink(current) else { throw LibraryFailure("资料库目录包含外部链接，操作已停止。") }
            current.deleteLastPathComponent()
        }
    }

    private func withLock<T>(_ work: () throws -> T) throws -> T {
        localLock.lock()
        defer { localLock.unlock() }
        let lockURL = rootURL.appendingPathComponent(".library-lock")
        try assertOwned(lockURL)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LibraryFailure("无法锁定项目资料库。") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw LibraryFailure("项目资料库正在使用中，请稍后重试。") }
        defer { flock(descriptor, LOCK_UN) }
        return try work()
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeData(encoder.encode(value), to: url)
    }

    private func writeData(_ bytes: Data, to url: URL) throws {
        try assertOwned(url)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }

    private static func fileDigest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
