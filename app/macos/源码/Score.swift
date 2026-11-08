import AppKit
import Foundation
import PDFKit

struct ScoreChord: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var label: String
    var originalLabel: String
    var originalStart: Double
    var edited: Bool { label != originalLabel || abs(start - originalStart) > 0.00001 }
    func progress(at time: Double) -> Double {
        guard time.isFinite, end > start else { return 0 }
        return min(1, max(0, (time - start) / (end - start)))
    }
    func remaining(at time: Double) -> Double { (1 - progress(at: time)) * (end - start) }
    func progress(at time: Double, within row: ClosedRange<Double>) -> Double {
        let first = max(start, row.lowerBound), last = min(end, row.upperBound)
        guard time.isFinite, last > first else { return 0 }
        return min(1, max(0, (time - first) / (last - first)))
    }
    func remaining(at time: Double, within row: ClosedRange<Double>) -> Double {
        (1 - progress(at: time, within: row)) * max(0, min(end, row.upperBound) - max(start, row.lowerBound))
    }
}

struct ScoreBeatState {
    var index: Int?
    var previous: Double?
    var next: Double?
}

struct ScoreDocument: Codable, Equatable {
    var schemaVersion = 1
    var sourceSHA256: String
    var range: AudioRange
    var model: String
    var elapsed: Double
    // Library snapshots encode ISO-8601 seconds; keep attachment equality stable after reopening.
    var createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    var chords: [ScoreChord]
    var beats: [Double]
    var capo = 0

    func validate(source: SourceRecord) throws {
        guard schemaVersion == 1, sourceSHA256 == source.sha256,
              range.start.isFinite, range.end.isFinite, range.start >= 0,
              range.end <= source.duration + 0.001, range.end - range.start >= 0.199,
              elapsed.isFinite, elapsed >= 0, (0...11).contains(capo),
              !chords.isEmpty, chords.count <= 20_000, beats.count <= 100_000,
              Set(chords.map(\.id)).count == chords.count, model.utf8.count <= 200 else {
            throw LibraryFailure("乐谱数据与当前歌曲不匹配，已有乐谱已保留。")
        }
        for (i, c) in chords.enumerated() {
            guard c.start.isFinite, c.end.isFinite, c.originalStart.isFinite,
                  c.start >= range.start - 0.001, c.end <= range.end + 0.001,
                  c.end > c.start, GuitarChord(c.label) != nil, GuitarChord(c.originalLabel) != nil,
                  i == 0 || abs(chords[i-1].end - c.start) < 0.002 else {
                throw LibraryFailure("乐谱的和弦或时间有误，请检查后再保存。")
            }
        }
        guard abs(chords[0].start - range.start) < 0.002,
              abs(chords[chords.count-1].end - range.end) < 0.002 else {
            throw LibraryFailure("乐谱的起止范围不完整。")
        }
        for (i, t) in beats.enumerated() {
            guard t.isFinite, t >= range.start, t <= range.end,
                  i == 0 || t > beats[i-1] else { throw LibraryFailure("节拍时间无效。") }
        }
    }

    func activeIndex(at time: Double) -> Int? {
        guard time.isFinite, time >= range.start, time < range.end else { return nil }
        var low = 0, high = chords.count
        while low < high {
            let mid = (low + high) / 2
            if chords[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    func beatState(at time: Double) -> ScoreBeatState {
        guard time.isFinite else { return ScoreBeatState() }
        var low = 0, high = beats.count
        while low < high {
            let mid = (low + high) / 2
            if beats[mid] <= time { low = mid + 1 } else { high = mid }
        }
        return ScoreBeatState(index: low > 0 ? low - 1 : nil,
                              previous: low > 0 ? beats[low - 1] : nil,
                              next: low < beats.count ? beats[low] : nil)
    }

    var estimatedBPM: Double? {
        let intervals = zip(beats, beats.dropFirst()).map { $1 - $0 }.filter { $0 >= 0.2 && $0 <= 2 }.sorted()
        guard !intervals.isEmpty else { return nil }
        let middle = intervals.count / 2
        let interval = intervals.count.isMultiple(of: 2) ? (intervals[middle-1] + intervals[middle]) / 2 : intervals[middle]
        return 60 / interval
    }

    mutating func moveBoundary(id: UUID, to time: Double) throws {
        guard time.isFinite, let i = chords.firstIndex(where: { $0.id == id }), i > 0,
              time >= chords[i-1].start + 0.05, time <= chords[i].end - 0.05 else {
            throw LibraryFailure("请让换和弦的位置留在前后两段之间，至少相隔 0.05 秒。")
        }
        chords[i-1].end = time
        chords[i].start = time
    }

    func rows(lyrics: LyricsDocument?) -> [ScoreRow] {
        let cues = lyrics?.cues ?? []
        if !cues.isEmpty, let lyrics {
            let starts = cues.map { lyrics.audioTime(for: $0) }
            var boundaries = [range.start]
            boundaries += starts.filter { $0 > range.start + 0.001 && $0 < range.end - 0.001 }
            boundaries.append(range.end)
            return zip(boundaries, boundaries.dropFirst()).map { a, b in
                let index = starts.lastIndex(where: { $0 <= a + 0.001 })
                let text = index.map { cues[$0].text } ?? ""
                return ScoreRow(start: a, end: b, text: text,
                                chordIDs: chords.filter { $0.end > a && $0.start < b }.map(\.id))
            }
        }
        // Four actual chord regions per row, without inventing a meter or bar line.
        return stride(from: 0, to: chords.count, by: 4).map { i in
            let group = Array(chords[i..<min(i + 4, chords.count)])
            return ScoreRow(start: group[0].start, end: group.last!.end, text: "", chordIDs: group.map(\.id))
        }
    }

    func chordPro(title: String, lyrics: LyricsDocument?, pitch: Int = 0) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
        }
        var lines = ["{title: \(escape(title.replacingOccurrences(of: "\n", with: " ")))}",
                     "{capo: \(capo)}", "{comment: 自动识别参考谱；和弦按时间顺序列出，逐字位置未校对。}",
                     "{comment: 范围 \(xwRange(range.closedRange))；试听升降调 \(pitch) 半音。}"]
        for row in rows(lyrics: lyrics) {
            lines.append("{comment: \(xwTime(row.start, precise: true))}")
            let values = row.chordIDs.compactMap { id in chords.first { $0.id == id } }
            lines.append(values.map { "[\(GuitarChord($0.label)?.transposed(pitch - capo) ?? "N.C.")]" }.joined(separator: " "))
            if !row.text.isEmpty { lines.append(escape(row.text)) }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct ScoreRow: Identifiable {
    var start: Double
    var end: Double
    var text: String
    var chordIDs: [UUID]
    var id: Double { start }
}

struct GuitarChord {
    static let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    let root: Int?
    let quality: String
    let bass: Int?

    init?(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        if ["N", "N.C.", "NC"].contains(text) { root = nil; quality = ""; bass = nil; return }
        let pattern = #"^([A-G])([#b]?)(maj13|maj11|maj9|maj7|mmaj7|m11|m9|m7b5|m7|dim7|dim|aug|sus2|sus4|7sus4|7|m|6|m6|madd9|add9|9|11|13)?(?:/([A-G][#b]?))?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ n: Int) -> String {
            Range(match.range(at: n), in: text).map { String(text[$0]) } ?? ""
        }
        root = Self.note(group(1) + group(2))
        quality = group(3)
        bass = Self.note(group(4))
    }

    static func note(_ name: String) -> Int? {
        guard let first = name.first, let value = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(first)] else { return nil }
        return (value + (name.hasSuffix("#") ? 1 : name.hasSuffix("b") ? -1 : 0) + 12) % 12
    }

    func transposed(_ amount: Int) -> String {
        guard let root else { return "N.C." }
        let n = (root + amount % 12 + 12) % 12
        return Self.names[n] + quality + (bass.map { "/" + Self.names[($0 + amount % 12 + 12) % 12] } ?? "")
    }
}

enum ScoreExport {
    /// Native text PDF: searchable Chinese lyrics, honest time rows and no bitmap score dependency.
    static func pdf(_ score: ScoreDocument, title: String, lyrics: LyricsDocument?, pitch: Int, to url: URL) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw LibraryFailure("无法准备乐谱导出。") }
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw LibraryFailure("无法创建乐谱 PDF。") }
        var y: CGFloat = 0
        func text(_ value: String, at x: CGFloat = 42, size: CGFloat = 12, color: NSColor = .black, width: CGFloat = 511) -> CGFloat {
            let font = NSFont.systemFont(ofSize: size)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let string = NSAttributedString(string: value, attributes: attrs)
            let rect = string.boundingRect(with: NSSize(width: width, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            string.draw(with: CGRect(x: x, y: 842 - y - rect.height, width: width, height: rect.height + 2),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
            return ceil(rect.height)
        }
        func page() {
            pdf.beginPDFPage(nil); y = 38
            y += text(title, size: 22) + 8
            y += text("弹唱参考谱 · 变调夹 \(score.capo) 品 · 试听升降调 \(pitch) 半音 · \(xwRange(score.range.closedRange))", size: 10, color: .darkGray) + 6
            y += text("自动识别，可按听感校正。和弦按时间顺序排列，逐字位置未校对。", size: 9, color: .gray) + 22
        }
        page()
        func write(_ value: String, size: CGFloat = 12, color: NSColor = .black) {
            let font = NSFont.systemFont(ofSize: size)
            let string = NSAttributedString(string: value, attributes: [.font: font])
            let height = ceil(string.boundingRect(with: NSSize(width: 511, height: 2000),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            if y + height + 5 > 794 { pdf.endPDFPage(); page() }
            y += text(value, size: size, color: color) + 5
        }
        for row in score.rows(lyrics: lyrics) {
            if y + 55 > 794 { pdf.endPDFPage(); page() }
            write(xwTime(row.start, precise: true), size: 9, color: .gray)
            let symbols = row.chordIDs.compactMap { id in score.chords.first { $0.id == id } }.map {
                "\(GuitarChord($0.label)?.transposed(pitch - score.capo) ?? $0.label)  (\(xwTime(max($0.start, row.start), precise: true)))"
            }
            for i in stride(from: 0, to: symbols.count, by: 4) {
                write(symbols[i..<min(i + 4, symbols.count)].joined(separator: "    "), size: 12,
                      color: NSColor(srgbRed: 0.48, green: 0.25, blue: 0.10, alpha: 1))
            }
            for paragraph in row.text.components(separatedBy: .newlines) where !paragraph.isEmpty {
                let characters = Array(paragraph)
                for i in stride(from: 0, to: characters.count, by: 31) {
                    write(String(characters[i..<min(i + 31, characters.count)]), size: 14)
                }
            }
            y += 14
        }
        pdf.endPDFPage(); pdf.closePDF()
        guard PDFDocument(data: data as Data)?.pageCount ?? 0 > 0 else { throw LibraryFailure("PDF 生成未完成，请重试。") }
        try (data as Data).write(to: url, options: .atomic)
    }
}
