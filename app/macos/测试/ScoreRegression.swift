import AppKit
import Foundation
import PDFKit

@main enum ScoreRegression {
    struct Failure: Error { var message: String }
    static var passed = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw Failure(message: name) }
        passed += 1; print("PASS \(passed) \(name)"); fflush(stdout)
    }
    static func rejects(_ name: String, _ block: () throws -> Void) throws {
        do { try block() } catch { passed += 1; print("PASS \(passed) \(name)"); fflush(stdout); return }
        throw Failure(message: name)
    }
    static func main() {
        do { try execute() } catch { fputs("FAIL \(error)\\n", stderr); exit(1) }
    }
    static func execute() throws {
        _ = NSApplication.shared
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("XWScoreRegression-\(UUID())")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let metadataSource = temp.appendingPathComponent("score-metadata-fixture.wav")
        try Data("score-metadata-fixture".utf8).write(to: metadataSource)
        let source = try LibraryStore.makeSource(url: metadataSource,
                                                duration: 369.49425, sampleRate: 48000, channels: 2)
        let store = try LibraryStore(rootURL: temp.appendingPathComponent("library"))
        let project = try store.createProject(source: source)
        var score = ScoreDocument(sourceSHA256: source.sha256, range: AudioRange(start: 10, end: 30), model: "controlled fixture", elapsed: 0.1,
                                  chords: [ScoreChord(start: 10, end: 20, label: "C/E", originalLabel: "C/E", originalStart: 10),
                                           ScoreChord(start: 20, end: 30, label: "Am7", originalLabel: "Am7", originalStart: 20)],
                                  beats: [10, 15, 20, 25])
        try score.validate(source: source)
        try check(GuitarChord("D/F#")?.transposed(-2) == "C/E", "转调同时换算和弦与低音")
        try check(GuitarChord("B♭m7")?.transposed(2) == "Cm7", "降号与负向换算")
        try check(GuitarChord("Cmaj9")?.transposed(0) == "Cmaj9", "扩展和弦不丢失")
        try check(GuitarChord("Cmaj7<script>") == nil && GuitarChord("garbage") == nil, "拒绝无效和弦")
        try check(score.activeIndex(at: 9.99) == nil && score.activeIndex(at: 10) == 0 &&
                  score.activeIndex(at: 20) == 1 && score.activeIndex(at: 30) == nil, "边界与跳转定位")
        let lyric = LyricsDocument(sourceName: "timed", cues: [LyricCue(startMilliseconds: 12000, text: "第一句"),
                                                              LyricCue(startMilliseconds: 22000, text: "第二句")], offsetMilliseconds: 1000)
        let rows = score.rows(lyrics: lyric)
        try check(rows.map(\.start) == [10, 11, 21] && rows[1].text == "第一句", "逐句时间偏移及选段前奏保留")
        try check(score.rows(lyrics: nil).count == 1, "没有歌词仍可生成和弦谱")
        let held = score.chords[1]
        try check(held.progress(at: 19) == 0 && held.progress(at: 25) == 0.5 && held.progress(at: 31) == 1,
                  "和弦格在开始前、进行中、结束后保持正确进度")
        try check(abs(held.progress(at: 21) - 0.1) < 0.00001 && held.remaining(at: 21) == 9,
                  "和弦本体保持真实区间，歌词换句不改变实际切换点")
        try check(held.progress(at: 20) == 0 && held.progress(at: .nan) == 0,
                  "回跳复位且异常时刻不会产生无效绘图宽度")
        try check(held.progress(at: 22, within: 10...25) == 0.4 && held.progress(at: 25, within: 10...25) == 1,
                  "跨句和弦的前一格按本句区间走满，不停在半格")
        try check(held.progress(at: 25, within: 25...35) == 0 && held.progress(at: 27.5, within: 25...35) == 0.5 &&
                  held.progress(at: 30, within: 25...35) == 1, "下一句延续格有独立完整进度，和弦真实边界不变")
        try check(abs(held.remaining(at: 24, within: 10...25) - 1) < 0.000001 &&
                  abs(held.remaining(at: 26, within: 25...35) - 4) < 0.000001,
                  "本句与下一句的剩余秒数分别对应可见格的实际区间")
        try check(score.beatState(at: 9).previous == nil && score.beatState(at: 9).next == 10,
                  "第一拍之前不伪造鼓点")
        try check(score.beatState(at: 15).index == 1 && score.beatState(at: 16).previous == 15 && score.beatState(at: 16).next == 20,
                  "真实节拍边界与邻近拍定位")
        try check(score.beatState(at: 29).previous == 25 && score.beatState(at: 29).next == nil,
                  "最后一拍之后不外推不存在的节拍")
        var noBeats = score; noBeats.beats = []
        try check(noBeats.beatState(at: 15).index == nil && noBeats.estimatedBPM == nil,
                  "没有节拍数据时明确留空")
        let saved = try store.setScore(score, projectID: project.id, replacing: nil)
        let parallel = try LibraryStore(rootURL: store.rootURL)
        _ = try parallel.setLyrics(lyric, projectID: project.id, replacing: nil)
        score.capo = 2
        _ = try store.setScore(score, projectID: project.id, replacing: saved.score)
        let reopened = try LibraryStore(rootURL: store.rootURL)
        try check(reopened.projects[0].score == score && reopened.projects[0].lyrics == lyric, "乐谱更新保留并行歌词修改并跨实例恢复")
        try rejects("旧乐谱版本不能覆盖较新修改") { _ = try store.setScore(saved.score!, projectID: project.id, replacing: nil) }
        var invalid = score; invalid.chords[0].label = "bogus"
        try rejects("非法和弦不能写入资料库") { _ = try store.setScore(invalid, projectID: project.id, replacing: score) }
        invalid = score; invalid.sourceSHA256 = String(repeating: "0", count: 64)
        try rejects("其他音频的识别结果不能覆盖此歌") { try invalid.validate(source: source) }
        invalid = score; invalid.chords[1].start = 19
        try rejects("重叠和弦时间拒绝保存") { try invalid.validate(source: source) }
        invalid = score; invalid.chords[1].start = .nan
        try rejects("非有限时间不能写入") { try invalid.validate(source: source) }
        try score.moveBoundary(id: score.chords[1].id, to: 20.1)
        try check(score.chords[0].end == 20.1 && score.chords[1].start == 20.1 && score.chords[1].edited, "换和弦微调同时更新相邻时间")
        try rejects("微调不允许吞掉相邻和弦") { try score.moveBoundary(id: score.chords[1].id, to: 30) }
        let bytes = try JSONEncoder().encode(project)
        let legacy = try JSONDecoder().decode(ProjectRecord.self, from: bytes)
        try check(legacy.score == nil && legacy.results.isEmpty, "旧项目无需迁移即可读取")
        let text = score.chordPro(title: "入海", lyrics: lyric)
        try check(text.contains("{capo: 2}") && text.contains("[Bb/D]") && text.contains("第一句"), "ChordPro包含变调夹、换算和弦与中文歌词")
        let pdf = temp.appendingPathComponent("score.pdf")
        try ScoreExport.pdf(score, title: "入海", lyrics: lyric, pitch: 0, to: pdf)
        let document = PDFDocument(url: pdf)
        try check(document?.pageCount == 1 && document?.string?.contains("第一句") == true, "PDF可打开且包含可搜索中文")
        let longLyrics = LyricsDocument(sourceName: "long", cues: [LyricCue(startMilliseconds: 10000, text: String(repeating: "中文长行分页测试", count: 600) + "最后一行")])
        try ScoreExport.pdf(score, title: "长行", lyrics: longLyrics, pitch: 0, to: pdf)
        try check((PDFDocument(url: pdf)?.pageCount ?? 0) >= 4, "超长歌词跨页完整排版")
        print("Completed \(passed) score checks")
    }
}
