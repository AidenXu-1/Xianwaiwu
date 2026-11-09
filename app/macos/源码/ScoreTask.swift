import AppKit
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers

struct ScorePayload: Decodable {
    struct Segment: Decodable { var start: Double; var end: Double; var label: String }
    var sourceSHA256: String
    var start: Double
    var end: Double
    var model: String
    var elapsed: Double
    var segments: [Segment]
    var beats: [Double]

    func document() -> ScoreDocument {
        ScoreDocument(sourceSHA256: sourceSHA256, range: AudioRange(start: start, end: end),
                      model: model, elapsed: elapsed, chords: segments.map {
            ScoreChord(start: $0.start, end: $0.end, label: $0.label, originalLabel: $0.label, originalStart: $0.start)
        }, beats: beats)
    }
}

/// A bounded, cancellable worker. Model state lives only in the child process.
final class ScoreTask: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var cancelling = false
    @Published private(set) var projectID: UUID?
    @Published private(set) var message = ""
    @Published private(set) var progress = 0.0
    @Published var error: String?
    @Published private(set) var errorProjectID: UUID?
    private var process: Process?
    private var token = UUID()

    func start(project: ProjectRecord, input: URL, range: ClosedRange<Double>, preferCPU: Bool = false,
               completion: @escaping (Result<ScoreDocument, Error>) -> Void) {
        guard !running else { return }
        error = nil; errorProjectID = project.id; projectID = project.id
        let proc = Process(), pipe = Pipe(), id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xianwaiwu-score-job-\(id.uuidString)")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        catch { report("无法准备临时空间，请检查磁盘后重试。", projectID: project.id); return }
        token = id
        proc.executableURL = Project.python
        proc.arguments = [Project.root.appendingPathComponent("app/audio/乐谱/score_job.py").path,
                          "--device", preferCPU ? "cpu" : "auto", "--work-directory", directory.path,
                          "--input", input.path, "--start", String(range.lowerBound),
                          "--end", String(range.upperBound), "--source-sha256", project.source.sha256]
        var env = Project.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"; env["OMP_NUM_THREADS"] = "2"
        env["NUMBA_CACHE_DIR"] = NSTemporaryDirectory() + "xianwaiwu-score-numba"
        env["SHISHENG_FFMPEG"] = Project.ffmpeg
        proc.environment = env
        proc.standardOutput = pipe; proc.standardError = pipe; proc.standardInput = FileHandle.nullDevice
        do { try proc.run() }
        catch {
            try? FileManager.default.removeItem(at: directory)
            self.error = "乐谱工具暂时无法启动，请检查本机音频环境。\n\(error.localizedDescription)"; return
        }
        process = proc; running = true; cancelling = false; progress = 0; message = "正在准备乐谱"
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self, weak proc] in
            guard let self, self.token == id, self.running, proc?.isRunning == true else { return }
            self.report("本次生成用时过长，已停止。可以在原曲页选一小段再试。", projectID: project.id); self.cancel()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data(), total = 0
            var payload: ScorePayload?
            var failure: String?
            while true {
                let part = pipe.fileHandleForReading.availableData
                if part.isEmpty { break }
                total += part.count
                if total > 8 * 1024 * 1024 { failure = "乐谱返回内容过大，已停止。"; proc.terminate(); break }
                buffer.append(part)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let type = event["type"] as? String else { continue }
                    if type == "progress" {
                        let message = event["message"] as? String ?? "正在识别和弦"
                        let progress = event["fraction"] as? Double ?? 0
                        DispatchQueue.main.async {
                            guard let self, self.token == id, !self.cancelling else { return }
                            self.message = message
                            self.progress = progress.isFinite ? min(1, max(0, progress)) : 0
                        }
                    } else if type == "done", let object = event["result"],
                              let bytes = try? JSONSerialization.data(withJSONObject: object) {
                        payload = try? JSONDecoder().decode(ScorePayload.self, from: bytes)
                    } else if type == "error" { failure = event["message"] as? String ?? "这次没有生成成功，请重试。" }
                }
            }
            try? pipe.fileHandleForReading.close()
            proc.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
            let value = payload
            let reason = failure
            DispatchQueue.main.async {
                guard let self, self.token == id else { return }
                let cancelled = self.cancelling
                self.running = false; self.cancelling = false; self.process = nil
                if cancelled {
                    self.message = "已取消，原有乐谱已保留"
                    return
                }
                if proc.terminationStatus == 75 && !preferCPU {
                    self.start(project: project, input: input, range: range, preferCPU: true, completion: completion)
                    return
                }
                do {
                    guard proc.terminationStatus == 0, let value else {
                        throw LibraryFailure(reason ?? "这次没有生成成功，已有乐谱已保留。可以重试或先选一小段。")
                    }
                    guard abs(value.start - range.lowerBound) < 0.002, abs(value.end - range.upperBound) < 0.002 else {
                        throw LibraryFailure("返回的乐谱范围与本次选段不一致，已有乐谱已保留。")
                    }
                    let doc = value.document()
                    try doc.validate(source: project.source)
                    self.progress = 1; self.message = "弹唱参考谱已生成"
                    completion(.success(doc))
                } catch {
                    self.report(error.localizedDescription, projectID: project.id)
                    completion(.failure(error))
                }
            }
        }
    }

    func report(_ message: String, projectID: UUID?) {
        errorProjectID = projectID; error = message
    }

    func cancel() {
        guard running, !cancelling else { return }
        cancelling = true; message = "正在取消"
        guard let process else { return }
        if process.isRunning { process.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak process] in
            guard let self, self.process === process, let process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

extension Workspace {
    var currentScore: ScoreDocument? { currentProject?.score }

    func openScore() {
        guard !showingHome, currentProject != nil, !rangeEditing else { return }
        showingScore = true
        prepareScorePlayback()
    }

    func closeScore() {
        player.configureBeatGuide([])
        showingScore = false
        let target = listeningToResult ? 0...((manifest?.end ?? 0) - (manifest?.start ?? 0)) : range
        setScorePlayerRange(target)
    }

    func prepareScorePlayback() {
        guard let score = currentScore else { return }
        if score.range.start < timeBounds.lowerBound || score.range.end > timeBounds.upperBound {
            guard sourceIssue == nil, source != nil else { return }
            original()
        }
        guard listeningToResult || sourceIssue == nil else { return }
        let offset = listeningToResult ? manifest?.start ?? 0 : 0
        setScorePlayerRange((score.range.start - offset)...(score.range.end - offset))
        player.configureBeatGuide(score.beats.map { $0 - offset })
    }

    private func setScorePlayerRange(_ target: ClosedRange<Double>) {
        guard player.limit != target else { return }
        let state = player.listeningState(), resume = player.playing
        player.useRange(target)
        player.restoreListening(state, at: state.time, resume: resume)
    }

    func generateScore() {
        guard readyToRun, let project = currentProject, let source else { return }
        guard range.upperBound - range.lowerBound <= 1800 else {
            scoreTask.report("单次生成支持 30 分钟以内，请先在原曲页选取练习范围。", projectID: project.id)
            return
        }
        saveListening()
        let expected = project.score
        scoreTask.start(project: project, input: source.url, range: range) { [weak self] result in
            guard let self else { return }
            if case .success(let score) = result {
                do {
                    let saved = try self.library.setScore(score, projectID: project.id, replacing: expected)
                    if self.currentProject?.id == project.id {
                        self.currentProject = saved
                        if self.showingScore { self.prepareScorePlayback() }
                    }
                } catch { self.scoreTask.report(error.localizedDescription, projectID: project.id) }
            }
        }
    }

    func saveScore(_ score: ScoreDocument, replacing expected: ScoreDocument) throws {
        guard let project = currentProject else { throw LibraryFailure("请回到原项目后再修改乐谱。") }
        saveListening()
        currentProject = try library.setScore(score, projectID: project.id, replacing: expected)
    }

    func scoreSeek(_ absolute: Double) {
        guard absolute.isFinite, sourceIssue == nil || listeningToResult && timeBounds.contains(absolute) else {
            scoreTask.report("这句暂时无法试听，请返回音轨页重新定位原音频。", projectID: currentProject?.id)
            return
        }
        if absolute < timeBounds.lowerBound || absolute >= timeBounds.upperBound { original() }
        prepareScorePlayback()
        seekAbsolute(absolute)
    }

    func scoreLoop(_ row: ScoreRow) {
        guard !sourceChecking, sourceIssue == nil || listeningToResult && row.start >= timeBounds.lowerBound && row.end <= timeBounds.upperBound else {
            scoreTask.report("这句超出可试听音轨的范围，请返回音轨页重新定位原音频。", projectID: currentProject?.id)
            return
        }
        if row.start < timeBounds.lowerBound || row.end > timeBounds.upperBound { original() }
        prepareScorePlayback()
        let offset = listeningToResult ? manifest?.start ?? 0 : 0
        player.setA(row.start - offset); player.setB(row.end - offset)
        player.updateLoop(true); seekAbsolute(row.start)
    }

    func exportScore(pdf: Bool) {
        guard let project = currentProject, let score = project.score, NSApp.mainWindow?.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pdf ? .pdf : UTType(filenameExtension: "cho") ?? .plainText]
        panel.nameFieldStringValue = project.title + " · 弹唱谱." + (pdf ? "pdf" : "cho")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if pdf { try ScoreExport.pdf(score, title: project.title, lyrics: project.lyrics, pitch: player.pitch, to: url) }
            else { try score.chordPro(title: project.title, lyrics: project.lyrics, pitch: player.pitch).write(to: url, atomically: true, encoding: .utf8) }
            scoreExportURL = url
        } catch { scoreTask.report("乐谱未能导出：\(error.localizedDescription)", projectID: project.id) }
    }
}
