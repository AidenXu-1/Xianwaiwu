import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

struct Manifest: Codable {
    struct Row: Codable { let id, label, filename: String; let peakDB: Double? }
    let title, mode: String
    let start, end, elapsed: Double
    let device: String?
    let quality: String?
    let backend: String?
    let engineGainDB: Double?
    let tracks: [Row]
    let fallbacks: [String]?
}
struct SeparationVersion: Identifiable {
    let id: UUID
    let url: URL
    let manifest: Manifest
    let createdAt: Date
}
struct AudioSource {
    let url: URL
    let duration, rate: Double
    let channels: UInt32
    let bytes: Int
}
enum Project {
    static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["SHISHENG_ROOT"] { return URL(fileURLWithPath: path) }
        var candidate = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<7 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("app/audio/引擎/run-engine.command").path) { return candidate }
            candidate.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()
    static let data: URL = {
        if let path = ProcessInfo.processInfo.environment["XIANWAIWU_DATA"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Xianwaiwu")
    }()
    static let source = root.appendingPathComponent("app/macos/源码/audio_job.py")
    static let engine = root.appendingPathComponent("app/audio/引擎")
    static let sample = root.appendingPathComponent("app/audio/样本/原始分轨混音/混音.wav")
    static let ffmpeg = ProcessInfo.processInfo.environment["SHISHENG_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"
}

/// Owns navigation and tasks; the store owns durable records and the player owns its clock.
final class Workspace: ObservableObject {
    let library: LibraryStore
    let player = PracticePlayer()
    let scoreTask = ScoreTask()
    private var scoreObservation: AnyCancellable?
    @Published var showingScore = false
    @Published var scoreExportURL: URL?

    private let listeningPersistence: ListeningPersistence
    @Published var currentProject: ProjectRecord?
    @Published var showingHome = true
    @Published var selectedFolderID: UUID?
    @Published var source: AudioSource?
    @Published var sourceIssue: String?
    @Published var sourceChecking = false
    @Published var mode = "pair"
    @Published var range: ClosedRange<Double> = 0...0
    @Published var wave: [Float] = []
    @Published var trackWaves: [String: [Float]] = [:]
    @Published var manifest: Manifest?
    @Published var versions: [SeparationVersion] = []
    @Published var selectedResultID: UUID?
    @Published var listeningToResult = false
    @Published var processing = false
    @Published var exporting = false
    @Published var cancelling = false
    @Published var importing = false
    @Published private(set) var importingLyrics = false
    private var lyricsImportToken = UUID()
    @Published var status = "等待导入一首歌"
    @Published var progress: Double?
    @Published var elapsed = 0.0
    @Published var error: String?
    @Published var lastExport: URL?
    @Published var lastExportGainDB = 0.0
    @Published var format = "wav24" {
        didSet { if preferencesReady && format != oldValue { saveExportFormat() } }
    }
    @Published var exportDirectory: URL?
    @Published var rangeEditing = false
    @Published var draftRange: ClosedRange<Double> = 0...0
    @Published var draftError: String?
    private var process: Process?
    private var jobID: UUID?
    private var jobProjectID: UUID?
    private var jobRoot: URL?
    private var jobDestination: URL?
    private var jobResultID: UUID?
    private var jobMode: String?
    private var exportingIDs: Set<String> = []
    private var exportingFormat = "wav24"
    private var projectErrors: [String: String] = [:]
    private var jobStatus = ""
    private var meter: Timer?
    private var savingTimer: Timer?
    private var pendingSave: DispatchWorkItem?
    private var started = 0.0
    private var suppressPlayerSave = false
    private var importToken = UUID()
    private var waveToken = UUID()
    private var draftReturn: (result: Bool, id: UUID?, state: PracticePlayer.ListeningState, playing: Bool)?
    private var decodedURL: URL?
    private var preparedProjectID: UUID?
    private var preparedBoard: String?
    private var preferencesReady = false
    @Published private(set) var sourceRelocationProjectID: UUID?
    private var sourceRelocationToken: UUID?
    // Injectable inspectors keep slow-source and navigation races reproducible without changing real files.
    var sourceInspector: ((SourceRecord) -> SourceStatus)?
    var sourceRelocationInspector: ((URL, SourceRecord) throws -> SourceRecord)?
    private var hasPreparedPlayback: Bool {
        !player.tracks.isEmpty && preparedProjectID == currentProject?.id && preparedBoard == SeparationModeIdentity.board(mode)
    }
    var busy: Bool { processing || exporting || scoreTask.running }
    var activeTaskProjectID: UUID? { scoreTask.running ? scoreTask.projectID : busy ? jobProjectID : nil }
    private var taskBelongsToCurrentBoard: Bool {
        jobProjectID == currentProject?.id && jobMode.map { SeparationModeIdentity.board($0) == SeparationModeIdentity.board(mode) } == true
    }
    var processingCurrentProject: Bool { processing && taskBelongsToCurrentBoard }
    var availableResults: [SeparationVersion] { versions.filter { SeparationModeIdentity.board($0.manifest.mode) == SeparationModeIdentity.board(mode) } }
    var hasResultForCurrentMode: Bool { !availableResults.isEmpty }
    var canEditRange: Bool { !busy && !importing && sourceIssue == nil && source != nil }
    var hasCustomRange: Bool {
        guard let duration = currentProject?.source.duration else { return false }
        return range.lowerBound > 0.000001 || range.upperBound < duration - 0.000001
    }
    private func errorKey(_ projectID: UUID, _ selectedMode: String) -> String { projectID.uuidString + "/" + SeparationModeIdentity.board(selectedMode) }
    var readyToRun: Bool { currentProject != nil && source != nil && sourceIssue == nil && !busy && !importing && !rangeEditing && range.upperBound - range.lowerBound >= 0.199999 }
    var currentTitle: String { currentProject?.title ?? "弦外屋" }
    var absoluteTime: Double { player.time + (listeningToResult ? manifest?.start ?? 0 : 0) }
    var timeBounds: ClosedRange<Double> {
        if rangeEditing { return 0...(currentProject?.source.duration ?? 0) }
        if listeningToResult, let manifest { return manifest.start...manifest.end }
        return 0...(currentProject?.source.duration ?? 0)
    }
    var rangeValid: Bool { draftError == nil && draftRange.upperBound - draftRange.lowerBound >= 0.199999 }
    var matchingResult: SeparationVersion? {
        versions.first { $0.manifest.mode == mode && abs($0.manifest.start-range.lowerBound)<0.0001 && abs($0.manifest.end-range.upperBound)<0.0001 }
    }
    var mainActionLabel: String {
        if scoreTask.running {
            return scoreTask.projectID == currentProject?.id ? "正在生成乐谱" : "其他项目正在生成乐谱"
        }
        if busy && jobProjectID != currentProject?.id { return "其他项目处理中" }
        if busy && !taskBelongsToCurrentBoard { return "其他板块处理中" }
        if exporting { return "正在导出…" }
        if processing { return "正在分离…" }
        if canExportCurrentSelection { return "导出音轨" }
        if matchingResult != nil { return "打开已有结果" }
        return error == nil ? "开始分离" : "重试分离"
    }
    var canExportCurrentSelection: Bool {
        guard let manifest, let id = selectedResultID,
              availableResults.contains(where: { $0.id == id }),
              SeparationModeIdentity.board(manifest.mode) == SeparationModeIdentity.board(mode) else { return false }
        return listeningToResult || matchingResult?.id == id || sourceIssue != nil
    }
    init(library: LibraryStore? = nil) {
        do { self.library = try library ?? LibraryStore(rootURL: Project.data) }
        catch {
            let alert = NSAlert(); alert.messageText = "项目资料库暂时无法读取"
            alert.informativeText = "原有资料已保留。请检查磁盘与读取权限，或从保留的 project.json 恢复索引后重开。\n\(error.localizedDescription)"
            alert.addButton(withTitle: "查看资料位置"); alert.addButton(withTitle: "退出")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([Project.data]) }
            Darwin.exit(1)
        }
        listeningPersistence = ListeningPersistence(library: self.library)
        exportDirectory = UserDefaults.standard.url(forKey: "xwExportDirectory")
        format = self.library.preferences.exportFormat
        player.volume = Float(UserDefaults.standard.object(forKey: "xwVolume") as? Double ?? 0.85)
        player.onFailure = { [weak self] in self?.error = $0 }
        player.onStateChange = { [weak self] in self?.scheduleListeningSave() }
        listeningPersistence.onCompletion = { [weak self] in self?.adoptListeningCompletions() }
        savingTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.player.playing else { return }; self.enqueueListeningSave()
        }
        scoreObservation = scoreTask.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        preferencesReady = true
    }
    deinit { meter?.invalidate(); savingTimer?.invalidate(); pendingSave?.cancel() }
    func chooseLyrics() {
        guard currentProject != nil, !importingLyrics, !showingHome, NSApp.mainWindow?.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "导入带时间的歌词"; panel.prompt = "导入歌词"
        panel.allowedContentTypes = LyricsImport.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importLyrics(url) }
    }

    func importLyrics(_ url: URL) {
        guard let project = currentProject, !showingHome, !importingLyrics else { return }
        let token = UUID(); lyricsImportToken = token; importingLyrics = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try LyricsImport.read(url, duration: project.source.duration) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lyricsImportToken == token else { return }
                self.importingLyrics = false
                guard self.currentProject?.id == project.id, !self.showingHome else { return }
                do {
                    try self.saveLyrics(result.get(), projectID: project.id, replacing: project.lyrics)
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    func saveLyrics(_ lyrics: LyricsDocument?, projectID: UUID, replacing expected: LyricsDocument?) throws {
        guard currentProject?.id == projectID, !showingHome else {
            throw LyricsFailure(.changed, "项目已切换，歌词没有保存到其他歌曲。请回到原项目后再试。")
        }
        flushListeningWrites()
        let saved = try library.setLyrics(lyrics, projectID: projectID, replacing: expected)
        currentProject = saved
        error = nil
    }

    func shiftLyrics(_ deltaMilliseconds: Int) {
        guard let project = currentProject, var lyrics = project.lyrics else { return }
        lyrics.offsetMilliseconds += deltaMilliseconds
        do { try saveLyrics(lyrics, projectID: project.id, replacing: project.lyrics) }
        catch { self.error = error.localizedDescription }
    }

    func exportLyrics() {
        guard let project = currentProject, let lyrics = project.lyrics, NSApp.mainWindow?.attachedSheet == nil else { return }
        let panel = NSSavePanel(); panel.title = "导出歌词"; panel.prompt = "导出"
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText]
        panel.nameFieldStringValue = project.title + ".lrc"
        if panel.runModal() == .OK, let url = panel.url {
            do { try lyrics.lrcText.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = "歌词未能导出：\(error.localizedDescription)" }
        }
    }
    func chooseInput() {
        guard !busy, !importing, NSApp.mainWindow?.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.title = "打开一首歌"; panel.prompt = "创建项目"
        panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }
    func importURLs(_ urls: [URL]) {
        guard urls.count == 1 else { error = "一次创建一个新项目，请只拖入一首歌"; return }
        importFile(urls[0])
    }
    func importFile(_ url: URL) {
        guard !importing, !busy else { return }
        saveListening(); importing = true; error = nil
        let token = UUID(); importToken = token
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let info = try Self.readSource(url)
                let record = try LibraryStore.makeSource(url: url, duration: info.duration, sampleRate: info.rate, channels: info.channels)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.importToken == token else { return }
                    self.importing = false
                    do {
                        let project = try self.library.createProject(source: record, name: url.deletingPathExtension().lastPathComponent)
                        self.openProject(project.id)
                    } catch { self.error = error.localizedDescription }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard self?.importToken == token else { return }
                    self?.importing = false; self?.error = "打不开这份音频。请确认文件完整、可以读取。\n\(error.localizedDescription)"
                }
            }
        }
    }
    static func readSource(_ url: URL) throws -> AudioSource {
        let audio = try AVAudioFile(forReading: url)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration.isFinite, duration >= 0.2, duration <= 14400, (1...2).contains(audio.processingFormat.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1024) else { throw PlayerFailure("请选择 0.2 秒至 4 小时的单声道或双声道音频。") }
        try audio.read(into: buffer)
        guard buffer.frameLength > 0 else { throw PlayerFailure("没有读到音频内容。") }
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return AudioSource(url: url, duration: duration, rate: audio.processingFormat.sampleRate, channels: audio.processingFormat.channelCount, bytes: bytes)
    }
    func showHome() {
        guard NSApp.mainWindow?.attachedSheet == nil else { return }
        lyricsImportToken = UUID(); importingLyrics = false
        showingScore = false
        cancelRangeIfNeeded(); saveListening(); player.stop(); showingHome = true
    }
    func deleteProject(_ id: UUID) {
        guard !(busy && activeTaskProjectID == id) else { error = "这个项目正在处理，取消任务后可以移除。"; return }
        flushListeningWrites()
        do {
            if currentProject?.id == id {
                suppressPlayerSave = true; preparedProjectID = nil; preparedBoard = nil; player.clear(); currentProject = nil; source = nil; versions = []; manifest = nil; selectedResultID = nil; wave = []; trackWaves = [:]; showingHome = true; suppressPlayerSave = false; waveToken = UUID()
            }
            try library.deleteProject(id)
        } catch { self.error = error.localizedDescription }
    }
    func deleteFolder(_ id: UUID) {
        saveListening()
        do {
            try library.deleteFolder(id)
            if selectedFolderID == id { selectedFolderID = nil }
            if let pid = currentProject?.id { currentProject = library.projects.first { $0.id == pid } }
        } catch { self.error = error.localizedDescription }
    }
    func moveProject(_ id: UUID, to folder: UUID?) {
        do {
            saveListening(); try library.moveProject(id, to: folder)
            if currentProject?.id == id { currentProject = library.projects.first { $0.id == id } }
        } catch { self.error = error.localizedDescription }
    }
    func openProject(_ id: UUID) {
        showingScore = false; scoreExportURL = nil
        lyricsImportToken = UUID(); importingLyrics = false
        cancelRangeIfNeeded(); saveListening()
        guard let project = library.projects.first(where: { $0.id == id }) else { return }
        suppressPlayerSave = true; preparedProjectID = nil; preparedBoard = nil; player.clear(); suppressPlayerSave = false
        currentProject = project; showingHome = false; source = nil; sourceIssue = "正在核对原音频…"; sourceChecking = true
        mode = SeparationModeIdentity.board(project.mode)
        error = projectErrors[errorKey(id, mode)]
        versions = project.results.sorted { $0.createdAt > $1.createdAt }.map { version($0, projectID: id) }
        wave = []; trackWaves = [:]; waveToken = UUID()
        let token = waveToken
        // Stat checks are cheap; fingerprint verification runs off the UI thread.
        if FileManager.default.isReadableFile(atPath: project.source.path),
           let info = try? Self.readSource(project.source.url) { source = info }
        else { sourceIssue = "原音频已移动或无法读取，请重新定位原音频" }
        restoreBoard(boardState(for: mode, project: project), resume: false)
        status = busy ? (taskBelongsToCurrentBoard ? jobStatus : "其他板块或项目正在处理，可以先试听") : "已恢复项目，可以继续试听"
        let inspect = sourceInspector
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let state = inspect?(project.source) ?? self.library.sourceStatus(for: project.source)
            let relocated: Result<SourceRecord, Error>?
            if case .available(let resolved) = state, resolved.standardizedFileURL != project.source.url.standardizedFileURL {
                relocated = Result { try LibraryStore.makeSource(url: resolved, duration: project.source.duration,
                                                                 sampleRate: project.source.sampleRate, channels: project.source.channels) }
            } else { relocated = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentProject?.id == id, self.waveToken == token else { return }
                self.sourceChecking = false
                switch state {
                case .available(let resolved):
                    self.sourceIssue = nil
                    if let relocated {
                        do {
                            self.flushListeningWrites()
                            let saved = try self.library.relocateSource(projectID: id, verifiedSource: relocated.get())
                            self.restoreVerifiedSource(saved)
                        } catch {
                            self.sourceIssue = "原曲已找到，但位置未能恢复：\(error.localizedDescription)"
                            self.error = self.sourceIssue
                        }
                    } else {
                        self.source = try? Self.readSource(resolved)
                        self.loadWave(projectID: id, resultID: nil, trackID: "original", url: resolved, token: token)
                        if !self.listeningToResult { self.prepareOriginal(position: self.currentProject?.sourceListening.absoluteTime ?? 0, resume: false) }
                    }
                case .missing: self.sourceIssue = "原音频已移动，请重新定位原音频"
                case .changed: self.sourceIssue = "原音频内容已变化，请定位创建项目时的原音频，或重新导入新项目"
                case .unreadable(let reason): self.sourceIssue = "原音频无法读取：\(reason)"
                }
                if self.sourceIssue != nil && !self.listeningToResult { self.player.stop() }
            }
        }
    }
    private func version(_ result: ResultRecord, projectID: UUID) -> SeparationVersion {
        let m = Manifest(title: currentProject?.title ?? "音频", mode: result.mode, start: result.range.start, end: result.range.end, elapsed: result.elapsed, device: result.device, quality: "standard", backend: result.backend, engineGainDB: result.engineGainDB, tracks: result.tracks.map { Manifest.Row(id: $0.id, label: $0.label, filename: $0.filename, peakDB: $0.peakDB) }, fallbacks: nil)
        return SeparationVersion(id: result.id, url: library.resultURL(projectID: projectID, resultID: result.id), manifest: m, createdAt: result.createdAt)
    }
    func selectMode(_ selected: String) {
        guard ["pair", "lead3", "music6"].contains(selected), !rangeEditing else { return }
        guard mode != selected, let projectID = currentProject?.id else { return }
        saveListening()
        guard let project = currentProject else { return }
        let resume = player.playing
        let position = hasPreparedPlayback ? absoluteTime : project.sourceListening.absoluteTime
        let hadState = project.modeStates?[selected] != nil
        mode = selected
        var state = boardState(for: selected, project: project)
        if !hadState && state.selectedResultID == nil { state.sourceListening.absoluteTime = position }
        restoreBoard(state, resume: resume)
        error = projectErrors[errorKey(projectID, mode)]
        status = busy ? (taskBelongsToCurrentBoard ? jobStatus : "其他板块正在处理，可以先试听") : hasResultForCurrentMode ? "已切换到当前板块" : "这个板块还没有分离结果，可以先听原曲"
        saveListening()
    }
    private func boardState(for selected: String, project: ProjectRecord) -> ModeWorkspaceState {
        let key = SeparationModeIdentity.board(selected)
        let own = project.results.filter { SeparationModeIdentity.board($0.mode) == key }.sorted { $0.createdAt > $1.createdAt }
        if var saved = project.modeStates?[key] {
            if saved.selectedResultID.map({ id in !own.contains { $0.id == id } }) == true { saved.selectedResultID = nil; saved.listeningToResult = false }
            return saved
        }
        let isCurrent = SeparationModeIdentity.board(project.mode) == key
        let selectedResult = own.first { $0.id == project.currentResultID } ?? own.first
        return ModeWorkspaceState(range: isCurrent ? project.range : selectedResult?.range,
                                  selectedResultID: selectedResult?.id,
                                  listeningToResult: isCurrent ? project.listeningToResult && selectedResult != nil : selectedResult != nil,
                                  sourceListening: isCurrent ? project.sourceListening : ListeningRecord(absoluteTime: selectedResult?.range.start ?? 0, enabled: ["original"]))
    }
    private func restoreBoard(_ state: ModeWorkspaceState, resume: Bool) {
        guard var project = currentProject else { return }
        suppressPlayerSave = true; preparedProjectID = nil; preparedBoard = nil; player.clear(); suppressPlayerSave = false
        range = state.range?.closedRange ?? 0...project.source.duration
        selectedResultID = state.selectedResultID
        manifest = availableResults.first { $0.id == selectedResultID }?.manifest
        trackWaves = [:]; lastExport = nil; lastExportGainDB = 0; listeningToResult = false
        project.sourceListening = state.sourceListening
        currentProject = project
        if let result = project.results.first(where: { $0.id == selectedResultID }),
           SeparationModeIdentity.board(result.mode) == SeparationModeIdentity.board(mode) {
            lastExport = result.exports.last?.url
            lastExportGainDB = result.exports.last?.gainDB ?? 0
            if state.listeningToResult || source == nil { loadResult(result, position: result.listening.absoluteTime, resume: resume) }
        }
        if !listeningToResult { prepareOriginal(position: state.sourceListening.absoluteTime, resume: resume) }
    }
    private func listeningRecord() -> ListeningRecord { ListeningRecord(absoluteTime: absoluteTime, enabled: player.enabled, solo: player.solo) }
    private func listeningUpdate() -> ListeningUpdate? {
        guard !suppressPlayerSave, !rangeEditing, hasPreparedPlayback, let project = currentProject else { return nil }
        let state = listeningRecord()
        return ListeningUpdate(projectID: project.id, mode: mode, range: AudioRange(start: range.lowerBound, end: range.upperBound),
                               selectedResultID: selectedResultID, listeningToResult: listeningToResult, listening: state,
                               sourceListening: listeningToResult ? project.sourceListening : state)
    }
    private func saveVolumePreference() {
        if ProcessInfo.processInfo.environment["XIANWAIWU_DATA"] == nil {
            UserDefaults.standard.set(Double(player.volume), forKey: "xwVolume")
        }
    }
    private func adoptListeningCompletions() {
        for completion in listeningPersistence.takeCompletions() {
            switch completion.result {
            case .success(let saved):
                library.adoptListeningDocument(saved.document)
                if currentProject?.id == saved.project.id,
                   (currentProject?.revision ?? -1) <= saved.project.revision { currentProject = saved.project }
            case .failure(let failure):
                let message = "项目未能保存：\(failure.localizedDescription)"
                projectErrors[errorKey(completion.update.projectID, completion.update.mode)] = message
                if currentProject?.id == completion.update.projectID { error = message }
            }
        }
    }
    private func flushListeningWrites() {
        listeningPersistence.flush()
        adoptListeningCompletions()
    }
    private func enqueueListeningSave() {
        guard !showingHome, let update = listeningUpdate() else { return }
        saveVolumePreference()
        listeningPersistence.enqueue(update)
    }
    func saveListening() {
        pendingSave?.cancel(); pendingSave = nil
        flushListeningWrites()
        saveVolumePreference()
        guard let update = listeningUpdate() else { return }
        do {
            let saved = try library.persistListening(update)
            library.adoptListeningDocument(saved.document)
            currentProject = saved.project
        } catch { self.error = "项目未能保存：\(error.localizedDescription)" }
    }
    private func saveExportFormat() {
        guard ["wav24", "wav16", "flac", "mp3"].contains(format) else { return }
        flushListeningWrites()
        do {
            var preferences = library.preferences
            preferences.exportFormat = format
            try library.savePreferences(preferences)
        } catch { self.error = "导出格式未能保存：\(error.localizedDescription)" }
    }
    private func scheduleListeningSave() {
        guard !suppressPlayerSave, !rangeEditing else { return }
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.enqueueListeningSave() }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: save)
    }
    private func playerState(_ record: ListeningRecord, offset: Double) -> PracticePlayer.ListeningState {
        PracticePlayer.ListeningState(time: record.absoluteTime-offset, a: player.limit.lowerBound, b: player.limit.upperBound, loop: false, enabled: record.enabled, solo: record.solo)
    }
    private func prepareOriginal(position: Double, resume: Bool) {
        guard let source, let project = currentProject, sourceIssue == nil else { return }
        suppressPlayerSave = true; defer { suppressPlayerSave = false }
        do {
            // Compare at the same group level as the selected result, including its linked engine gain.
            // This only changes audition volume; the source and exported samples are never rewritten.
            let comparisonGain: Float?
            if let manifest, let engineGain = manifest.engineGainDB, engineGain.isFinite,
               availableResults.contains(where: { $0.id == selectedResultID }) {
                let tracks = manifest.tracks.map { Track(id: $0.id, label: $0.label, url: source.url, peakDB: $0.peakDB) }
                comparisonGain = PracticePlayer.safePreviewGain(for: tracks) * Float(pow(10, engineGain / 20))
            } else { comparisonGain = nil }
            try player.prepare([Track(id: "original", label: "原曲", url: source.url, peakDB: nil)], range: rangeEditing ? 0...source.duration : range, comparisonGain: comparisonGain)
            preparedProjectID = project.id; preparedBoard = SeparationModeIdentity.board(mode)
            listeningToResult = false
            var state = project.sourceListening; state.enabled = ["original"]
            player.restoreListening(playerState(state, offset: 0), at: position, resume: resume)
            if position < player.limit.lowerBound || position > player.limit.upperBound { status = "已移到原曲预听范围内的最近位置" }
        } catch { self.error = error.localizedDescription }
    }
    func original() {
        guard sourceIssue == nil, source != nil, !rangeEditing else { return }
        let position = absoluteTime, resume = player.playing; saveListening()
        prepareOriginal(position: position, resume: resume); saveListening()
    }
    func separated() {
        guard !rangeEditing, let project = currentProject else { return }
        let own = project.results.filter { SeparationModeIdentity.board($0.mode) == SeparationModeIdentity.board(mode) }.sorted { $0.createdAt > $1.createdAt }
        guard let result = own.first(where: { $0.id == selectedResultID }) ?? own.first else { return }
        let position = absoluteTime, resume = player.playing; saveListening(); loadResult(result, position: position, resume: resume); saveListening()
    }
    func switchResult(_ id: UUID) {
        guard !rangeEditing, let result = currentProject?.results.first(where: { $0.id == id }),
              SeparationModeIdentity.board(result.mode) == SeparationModeIdentity.board(mode) else { return }
        let position = absoluteTime, resume = player.playing; saveListening()
        range = result.range.closedRange
        loadResult(result, position: position, resume: resume)
        saveListening()
    }
    private func loadResult(_ record: ResultRecord, position: Double, resume: Bool) {
        guard let project = currentProject,
              SeparationModeIdentity.board(record.mode) == SeparationModeIdentity.board(mode) else { return }
        suppressPlayerSave = true; defer { suppressPlayerSave = false }
        do {
            let tracks = try record.tracks.map { Track(id: $0.id, label: $0.label, url: try library.trackURL(projectID: project.id, resultID: record.id, track: $0), peakDB: $0.peakDB) }
            try player.prepare(tracks)
            preparedProjectID = project.id; preparedBoard = SeparationModeIdentity.board(mode)
            selectedResultID = record.id; manifest = version(record, projectID: project.id).manifest; listeningToResult = true
            let clamped = min(record.range.end, max(record.range.start, position))
            player.restoreListening(playerState(record.listening, offset: record.range.start), at: clamped-record.range.start, resume: resume)
            if abs(position-clamped)>0.01 { status = "已移到这份结果的有效范围" }
            lastExport = record.exports.last.map { URL(fileURLWithPath: $0.path) }
            lastExportGainDB = record.exports.last?.gainDB ?? 0
            trackWaves = [:]
            for track in tracks { loadWave(projectID: project.id, resultID: record.id, trackID: track.id, url: track.url, token: waveToken) }
        } catch { self.error = "这份结果无法读取：\(error.localizedDescription)" }
    }
    func togglePlayback() {
        guard !showingHome, !player.tracks.isEmpty, listeningToResult || sourceIssue == nil else { return }
        if rangeEditing {
            guard rangeValid else { return }
            if player.limit != draftRange { player.useRange(draftRange) }
        }
        player.toggle(); saveListening()
    }
    func seekAbsolute(_ seconds: Double) { player.seek(seconds-(listeningToResult ? manifest?.start ?? 0 : 0)); scheduleListeningSave() }
    func toggleTrack(_ id: String) { player.toggleTrack(id) }
    func toggleSolo(_ id: String) { player.toggleSolo(id) }
    func clearSolo() { player.clearSolo() }
    func setAll(_ value: Bool) { player.setAll(value) }
    func beginRange() {
        guard canEditRange, !rangeEditing else { return }
        saveListening(); draftReturn = (listeningToResult, selectedResultID, player.listeningState(), player.playing)
        draftRange = range; draftError = nil; rangeEditing = true
        prepareOriginal(position: draftRange.lowerBound, resume: false)
    }
    func updateDraft(_ lower: Double, _ upper: Double) {
        guard rangeEditing, let source else { return }
        guard lower.isFinite, upper.isFinite, lower >= 0, upper <= source.duration, upper-lower >= 0.199999 else {
            draftError = "起止需在歌曲内，且至少相隔 0.2 秒"; return
        }
        draftRange = lower...upper; draftError = nil
        if player.playing { player.useRange(draftRange); player.toggle() }
    }
    func previewDraft() {
        guard rangeEditing, rangeValid else { return }
        player.useRange(draftRange); player.seek(draftRange.lowerBound); player.toggle()
    }
    func cancelRangeIfNeeded() { if rangeEditing { cancelRange() } }
    func cancelRange() {
        guard rangeEditing else { return }
        player.stop(); rangeEditing = false; draftError = nil
        if let previous = draftReturn {
            if previous.result, let result = currentProject?.results.first(where: { $0.id == previous.id }) {
                loadResult(result, position: previous.state.time + result.range.start, resume: false)
            } else {
                prepareOriginal(position: previous.state.time, resume: false)
            }
            player.restoreListening(previous.state, at: previous.state.time, resume: previous.playing)
        }
        draftReturn = nil; saveListening()
    }
    func applyRange() {
        guard rangeEditing, rangeValid else { return }
        player.stop(); range = draftRange; rangeEditing = false; draftReturn = nil
        prepareOriginal(position: range.lowerBound, resume: false)
        status = "已应用选段，下次分离将使用这个范围"; saveListening()
    }
    func clearRange() {
        guard canEditRange, let source else { return }
        let position = absoluteTime, resume = player.playing
        // Keep the existing result's audition state before returning to the full source.
        // A draft has already saved that state in beginRange; it must never overwrite it.
        if !rangeEditing { saveListening() }
        player.stop(); rangeEditing = false; draftReturn = nil; draftError = nil
        range = 0...source.duration; draftRange = range
        prepareOriginal(position: position, resume: resume)
        status = "已恢复整首原曲，下次分离使用整首"
        saveListening()
    }
    func start(force: Bool = false) {
        guard readyToRun, let source, let project = currentProject else { return }
        if !force, let match = matchingResult { switchResult(match.id); return }
        // Historical two-track results stay readable; running them again uses the upgraded mode.
        if ["leadback", "lead", "backing"].contains(mode) { mode = "lead3" }
        saveListening(); error = nil; processing = true; cancelling = false; progress = nil; elapsed = 0
        status = "准备分离"; jobStatus = status; projectErrors[errorKey(project.id, mode)] = nil
        let id = UUID(); jobID = id; jobProjectID = project.id; jobResultID = nil; jobMode = mode
        do {
            let root = try library.temporaryResultURL(projectID: project.id, taskID: id)
            // The worker publishes its directory atomically and requires an absent destination.
            try FileManager.default.removeItem(at: root)
            jobRoot = root; let output = root; jobDestination = output
            launch(["separate", source.url.path, output.path, "--start", String(range.lowerBound), "--end", String(range.upperBound), "--mode", mode, "--device", ProcessInfo.processInfo.environment["XIANWAIWU_DEVICE"] ?? "auto", "--quality", "standard", "--source-sha256", project.source.sha256], token: id)
        } catch { processing = false; self.error = error.localizedDescription }
    }
    func chooseExportDirectory() {
        let panel = NSOpenPanel(); panel.title = "选择保存位置"; panel.prompt = "保存到这里"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.directoryURL = exportDirectory
        if panel.runModal() == .OK, let url = panel.url {
            exportDirectory = url; UserDefaults.standard.set(url, forKey: "xwExportDirectory")
        }
    }
    func export(selected: Set<String>) {
        guard !busy, let project = currentProject, let rid = selectedResultID,
              let result = project.results.first(where: { $0.id == rid }), !selected.isEmpty,
              SeparationModeIdentity.board(result.mode) == SeparationModeIdentity.board(mode),
              selected.isSubset(of: Set(result.tracks.map(\.id))) else { return }
        if exportDirectory == nil { chooseExportDirectory() }
        guard let directory = exportDirectory else { return }
        let own = Project.data.resolvingSymlinksInPath().path
        let path = directory.resolvingSymlinksInPath().path
        guard path != own, !path.hasPrefix(own+"/") else { error = "请选择项目资料之外的保存位置"; return }
        saveListening(); error = nil; lastExport = nil; exporting = true; cancelling = false; elapsed = 0; progress = nil
        status = "准备导出"; let id = UUID(); jobID = id; jobProjectID = project.id; jobResultID = rid
        jobMode = result.mode
        jobDestination = nil; jobRoot = nil; exportingIDs = selected; exportingFormat = format
        launch(["export", library.resultURL(projectID: project.id, resultID: rid).path, directory.path, "--format", format, "--tracks"] + result.tracks.map(\.id).filter(selected.contains), token: id)
    }
    func revealExport() { if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) } }
    func cancel() {
        if scoreTask.running { scoreTask.cancel(); return }
        guard let process, process.isRunning, !cancelling else { return }
        cancelling = true; status = "正在取消并清理临时文件"; process.terminate()
    }
    func quit() { saveListening(); player.stop(); cancel() }
    var hasRunningProcess: Bool { (process?.isRunning ?? false) || scoreTask.running }
    func relocateSource() {
        guard !busy, sourceRelocationToken == nil, currentProject != nil else { return }
        let panel = NSOpenPanel(); panel.title = "重新定位原音频"; panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            relocateSource(to: url)
        }
    }
    func relocateSource(to url: URL) {
        guard !busy, !rangeEditing, sourceRelocationToken == nil, let project = currentProject else { return }
        saveListening()
        let id = project.id, token = UUID(), original = project.source
        if !listeningToResult { player.stop() }
        sourceRelocationToken = token; sourceRelocationProjectID = id
        sourceChecking = true; sourceIssue = "正在核对你选择的原音频…"
        // Reject the earlier source check and waveform callbacks if they finish during relocation.
        waveToken = UUID()
        let inspect = sourceRelocationInspector
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result<SourceRecord, Error> {
                let verified: SourceRecord
                if let inspect { verified = try inspect(url, original) }
                else { verified = try LibraryStore.makeSource(url: url, duration: original.duration, sampleRate: original.sampleRate, channels: original.channels) }
                guard verified.sha256 == original.sha256, verified.bytes == original.bytes else {
                    throw LibraryFailure("这份文件与原音频内容不同，请选择原来的音频。已有分轨仍可继续使用。")
                }
                return verified
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sourceRelocationToken == token else { return }
                self.sourceRelocationToken = nil; self.sourceRelocationProjectID = nil
                self.flushListeningWrites()
                do {
                    let verified = try result.get()
                    let saved = try self.library.relocateSource(projectID: id, verifiedSource: verified)
                    if self.currentProject?.id == id { self.restoreVerifiedSource(saved) }
                } catch {
                    let message = error.localizedDescription
                    if self.currentProject?.id == id {
                        self.sourceChecking = false; self.sourceIssue = message
                        self.error = message
                    }
                }
            }
        }
    }
    private func restoreVerifiedSource(_ saved: ProjectRecord) {
        guard currentProject?.id == saved.id else { return }
        // Keep the currently visible board and its source audition; source validation cannot navigate it.
        let sourceListening = currentProject?.sourceListening ?? saved.sourceListening
        let position = hasPreparedPlayback && !listeningToResult ? absoluteTime : sourceListening.absoluteTime
        var active = saved
        active.sourceListening = sourceListening
        currentProject = active
        sourceChecking = false
        do {
            source = try Self.readSource(saved.source.url)
            sourceIssue = nil
            loadWave(projectID: saved.id, resultID: nil, trackID: "original", url: saved.source.url, token: waveToken)
            if !listeningToResult { prepareOriginal(position: position, resume: false) }
            else if let resultID = selectedResultID {
                for track in player.tracks { loadWave(projectID: saved.id, resultID: resultID, trackID: track.id, url: track.url, token: waveToken) }
            }
        } catch { sourceIssue = "原音频暂时无法读取：\(error.localizedDescription)" }
    }
    private func launch(_ args: [String], token: UUID) {
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); proc.arguments = [Project.source.path] + args
        var env = ProcessInfo.processInfo.environment; env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"; env["PYTHONUNBUFFERED"] = "1"; env["SHISHENG_FFMPEG"] = Project.ffmpeg; proc.environment = env
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        do { try proc.run() } catch { processing = false; exporting = false; self.error = "无法启动音频引擎：\(error.localizedDescription)"; cleanupTask(); return }
        process = proc; started = ProcessInfo.processInfo.systemUptime
        meter = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.jobID == token else { return }; self.elapsed = ProcessInfo.processInfo.systemUptime-self.started
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var partial = Data(); var terminal = false
            while true {
                let data = pipe.fileHandleForReading.availableData; if data.isEmpty { break }; partial.append(data)
                while let i = partial.firstIndex(of: 10) {
                    let line = Data(partial.prefix(upTo: i)); partial.removeSubrange(...i)
                    guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    if ["done", "error", "cancelled"].contains(msg["event"] as? String ?? "") { terminal = true }
                    DispatchQueue.main.async { [weak self] in guard self?.jobID == token else { return }; self?.receive(msg) }
                }
            }
            proc.waitUntilExit(); let sawTerminal = terminal
            DispatchQueue.main.async { [weak self] in
                guard let self, self.jobID == token else { return }
                if !sawTerminal { self.taskError("音频引擎提前退出（\(proc.terminationStatus)），请重试。") }
                self.processing = false; self.exporting = false; self.cancelling = false; self.progress = nil; self.process = nil
                self.meter?.invalidate(); self.meter = nil; self.cleanupTask(); self.jobID = nil
            }
        }
    }
    private func receive(_ msg: [String: Any]) {
        let belongs = taskBelongsToCurrentBoard
        switch msg["event"] as? String {
        case "status", "progress":
            guard !cancelling else { return }
            jobStatus = msg["phase"] as? String ?? jobStatus
            if belongs { status = jobStatus }
            if let p = msg["progress"] as? Double, p.isFinite { progress = min(1, max(0, p/100)) } else { progress = nil }
        case "done":
            guard let pid = jobProjectID else { return }
            if let destination = jobDestination {
                do {
                    let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: destination.appendingPathComponent("拾声分轨.json")))
                    let record = ResultRecord(mode: m.mode, range: AudioRange(start: m.start, end: m.end), tracks: m.tracks.map { ResultTrackRecord(id: $0.id, label: $0.label, filename: $0.filename, peakDB: $0.peakDB) }, elapsed: m.elapsed, device: m.device, backend: m.backend, engineGainDB: m.engineGainDB)
                    if currentProject?.id == pid { saveListening() }
                    let result = try library.commitResult(projectID: pid, temporaryURL: destination, record: record, activate: belongs)
                    if currentProject?.id == pid {
                        let resume = player.playing, position = absoluteTime
                        currentProject = library.projects.first { $0.id == pid }
                        versions = currentProject?.results.sorted { $0.createdAt > $1.createdAt }.map { version($0, projectID: pid) } ?? []
                        if belongs { loadResult(result, position: position, resume: resume) }
                        saveListening()
                    }
                    if belongs { status = (m.engineGainDB ?? 0) < -0.05 ? String(format: "分离完成 · 共同降低 %.1f dB 防止过载", -(m.engineGainDB ?? 0)) : "分离完成，可以试听和导出" }
                } catch { taskError("结果未能保存：\(error.localizedDescription)") }
            } else if let path = msg["result"] as? String, let rid = jobResultID {
                let receipt = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else { taskError("保存程序未交回有效文件"); return }
                do {
                    flushListeningWrites()
                    guard var project = library.projects.first(where: { $0.id == pid }), let idx = project.results.firstIndex(where: { $0.id == rid }) else { return }
                    project.results[idx].exports.append(ExportRecord(format: exportingFormat, trackIDs: exportingIDs.sorted(), path: path, gainDB: msg["gainDB"] as? Double ?? 0))
                    let saved = try library.saveProject(project)
                    let gain = msg["gainDB"] as? Double ?? 0
                    if currentProject?.id == pid { currentProject = saved; if selectedResultID == rid { lastExportGainDB = gain; lastExport = receipt } }
                    if belongs { status = gain < -0.05 ? String(format: "已保存 · 整组共同降低 %.1f dB 防止过载", -gain) : "已保存所选音轨" }
                } catch { taskError("文件已保存，导出记录未能写入：\(error.localizedDescription)") }
            }
        case "cancelled": if belongs { status = "已取消，项目和旧结果均已保留" }
        case "error":
            let code = msg["code"] as? String ?? ""
            let detail = msg["message"] as? String ?? "音频处理未能完成"
            let advice: String
            switch code {
            case "source_changed", "source_missing":
                advice = "请重新定位原音频，或把新文件导入为新项目。"
                if currentProject?.id == jobProjectID { sourceIssue = detail }
            case "disk_full": advice = "请腾出磁盘空间后重试。"
            case "permission": advice = "请换一个有写入权限的保存位置。"
            case "model_missing", "model_invalid": advice = "请检查项目引擎目录中的模型和准备脚本。"
            default: advice = exporting ? "可以更换保存位置后重试。" : "可以缩短选段后重试，原曲和旧结果仍保留。"
            }
            taskError("\(detail)\n\(advice)")
        default: break
        }
    }
    private func taskError(_ message: String) {
        if let id = jobProjectID, let jobMode { projectErrors[errorKey(id, jobMode)] = message }
        if taskBelongsToCurrentBoard { error = message; status = "本次没有完成" }
    }
    private func cleanupTask() {
        if let jobRoot, let id = jobProjectID { try? library.discardTemporaryResult(jobRoot, projectID: id) }
        jobRoot = nil; jobDestination = nil
    }
    private func loadWave(projectID: UUID, resultID: UUID?, trackID: String, url: URL, token: UUID) {
        if let cached = library.loadWaveform(projectID: projectID, resultID: resultID, trackID: trackID) {
            if resultID == nil { wave = cached } else { trackWaves[trackID] = cached }; return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let peaks = Self.measureWave(url)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentProject?.id == projectID, self.waveToken == token else { return }
                try? self.library.saveWaveform(peaks, projectID: projectID, resultID: resultID, trackID: trackID)
                if resultID == nil { self.wave = peaks }
                else if self.selectedResultID == resultID { self.trackWaves[trackID] = peaks }
            }
        }
    }
    /// Scan every sample in bounded chunks; no synthetic or sparse substitute waveforms.
    static func measureWave(_ url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768) else { return [] }
        let bins = 1600; var peaks = [Float](repeating: 0, count: bins); var offset: Int64 = 0
        while offset < file.length {
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(32768, file.length-offset))) } catch { return [] }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                let idx = min(bins-1, Int((offset+Int64(frame))*Int64(bins)/file.length))
                for channel in 0..<Int(buffer.format.channelCount) { peaks[idx] = max(peaks[idx], abs(data[channel][frame])) }
            }
            offset += Int64(buffer.frameLength)
        }
        let high = max(0.01, peaks.max() ?? 1); return peaks.map { pow(min(1, $0/high), 0.7) }
    }
}
