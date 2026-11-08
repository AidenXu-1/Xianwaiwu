import AppKit
import CoreFoundation
import Foundation

struct LyricsFailure: LocalizedError {
    enum Kind: String { case unreadable, noTiming, incompleteTiming, invalidTiming, outOfOrder, outOfBounds, tooLarge, changed }
    let kind: Kind
    let message: String
    var errorDescription: String? { message }
    init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
}

struct LyricCue: Codable, Equatable, Identifiable {
    var startMilliseconds: Int
    var text: String
    var id: Int { startMilliseconds }
}

/// One small attachment per song, shared by all separation boards and results.
struct LyricsDocument: Codable, Equatable {
    var sourceName: String
    var cues: [LyricCue]
    // LRC convention: a positive offset makes lyrics appear earlier.
    var offsetMilliseconds: Int = 0

    func activeIndex(at seconds: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0, seconds < 86_400 else { return nil }
        // Keep imported times as integers. The tiny tolerance only absorbs Double boundary noise.
        let time = Int(floor(seconds * 1000 + 0.000001)) + offsetMilliseconds
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].startMilliseconds <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    func audioTime(for cue: LyricCue) -> Double {
        Double(cue.startMilliseconds - offsetMilliseconds) / 1000
    }

    func validate(duration: Double) throws {
        guard duration.isFinite, duration >= 0.2, duration <= 14_400,
              !cues.isEmpty, cues.count <= LyricsImport.maximumCues,
              cues.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              sourceName.utf8.count <= 1024,
              cues.reduce(0, { $0 + $1.text.utf8.count }) <= LyricsImport.maximumBytes else {
            throw LyricsFailure(.tooLarge, "歌词内容为空或过大，请使用不超过 2 MB 的歌词文件。")
        }
        let end = Int(ceil(duration * 1000))
        guard (-end...end).contains(offsetMilliseconds) else {
            throw LyricsFailure(.invalidTiming, "歌词的整体时间偏移超过了歌曲时长，请检查时间设置。")
        }
        for (index, cue) in cues.enumerated() {
            guard cue.startMilliseconds >= 0, cue.startMilliseconds < end else {
                throw LyricsFailure(.outOfBounds, "第 \(index + 1) 条歌词的时间超出了这首歌，请确认歌词与音频匹配。")
            }
            if index > 0 && cues[index - 1].startMilliseconds >= cue.startMilliseconds {
                throw LyricsFailure(.outOfOrder, "歌词时间顺序有误，请检查重复或倒序的时间。")
            }
        }
    }

    var lrcText: String {
        let offset = offsetMilliseconds == 0 ? [] : ["[offset:\(offsetMilliseconds)]"]
        return (offset + cues.flatMap { cue in
            cue.text.components(separatedBy: "\n").map { "[\(Self.timestamp(cue.startMilliseconds))]\($0)" }
        }).joined(separator: "\n") + "\n"
    }

    static func timestamp(_ milliseconds: Int) -> String {
        String(format: "%02d:%02d.%03d", milliseconds / 60000, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}

enum LyricsImport {
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumCues = 10_000
    static let extensions = ["lrc", "txt", "md", "markdown", "docx", "doc"]
    private static let timePattern = #"[0-9]{1,3}:[0-9]{2}(?::[0-9]{2})?(?:[.,][0-9]{1,3})?"#

    static func read(_ url: URL, duration: Double) throws -> LyricsDocument {
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else {
            throw LyricsFailure(.unreadable, "请选择 LRC、TXT、Markdown 或 Word 歌词文件。")
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw LyricsFailure(.unreadable, "请选择一份歌词文件。") }
            guard (values.fileSize ?? maximumBytes + 1) <= maximumBytes else {
                throw LyricsFailure(.tooLarge, "歌词文件超过 2 MB，请精简文档中的图片等内容后再导入。")
            }
            data = try Data(contentsOf: url)
        } catch let failure as LyricsFailure { throw failure }
        catch { throw LyricsFailure(.unreadable, "无法读取这份歌词，请检查文件是否完整、是否有读取权限。") }
        guard data.count <= maximumBytes else { throw LyricsFailure(.tooLarge, "歌词文件超过 2 MB。") }
        let text: String
        if ["doc", "docx"].contains(url.pathExtension.lowercased()) {
            do {
                let format: NSAttributedString.DocumentType = url.pathExtension.lowercased() == "docx" ? .officeOpenXML : .docFormat
                let document = try NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil)
                text = wordText(document)
            } catch { throw LyricsFailure(.unreadable, "这份 Word 文档无法读取。请检查文件是否损坏、加密，或另存为 TXT 后再试。") }
        } else {
            let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let decoded = String(data: data, encoding: .utf16) {
                text = decoded
            } else if let decoded = String(data: data, encoding: .utf8) {
                text = decoded
            } else if let decoded = String(data: data, encoding: gb) {
                text = decoded
            } else { throw LyricsFailure(.unreadable, "无法读取歌词文字，请将文件另存为 UTF-8 编码后再试。") }
        }
        guard !text.contains("\0") else { throw LyricsFailure(.unreadable, "这份文件没有读到有效的歌词文字。") }
        return try parse(text, name: url.lastPathComponent, duration: duration)
    }

    /// Content determines whether times exist; extensions only select a document reader.
    static func parse(_ text: String, name: String, duration: Double) throws -> LyricsDocument {
        guard text.utf8.count <= maximumBytes else { throw LyricsFailure(.tooLarge, "歌词文字超过 2 MB，请精简后再试。") }
        let normalized = text.replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.count <= 20_000 else { throw LyricsFailure(.tooLarge, "歌词超过 20,000 行，请精简后再导入。") }
        var cues: [LyricCue] = [], missing: [Int] = [], previous = -1
        var offset: Int?
        for (number, original) in lines.enumerated() {
            let lineNumber = number + 1
            var line = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            if let match = groups(#"^\[offset:([+-]?\d+)\]$"#, line, insensitive: true) {
                guard let value = Int(match[1]), value > -86_400_000, value < 86_400_000,
                      offset == nil || offset == value else {
                    throw LyricsFailure(.invalidTiming, "第 \(lineNumber) 行的整体时间偏移无效或重复冲突。")
                }
                offset = value; continue
            }
            if groups(#"^\[(?:ar|ti|al|au|by|length|re|ve):.*\]$"#, line, insensitive: true) != nil { continue }
            if line.hasPrefix("[offset:") { throw LyricsFailure(.invalidTiming, "第 \(lineNumber) 行的整体时间偏移无法识别。") }
            if line.hasPrefix("|") {
                let columns = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                }
                if columns.allSatisfy({ groups(#"^[:\-\s]+$"#, $0) != nil }) { continue }
                if columns.count == 2, ["时间", "时间标记", "time", "timestamp"].contains(columns[0].lowercased()),
                   ["歌词", "歌词内容", "lyrics", "text"].contains(columns[1].lowercased()) { continue }
                if columns.count == 2 { line = columns[0] + " " + columns[1] }
            }
            let tabColumns = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if tabColumns.count == 2, ["时间", "时间标记", "time", "timestamp"].contains(tabColumns[0].lowercased()),
               ["歌词", "歌词内容", "lyrics", "text"].contains(tabColumns[1].lowercased()) { continue }
            if let match = groups(#"^(?:[-*•]\s+|#{1,6}\s+)(.*)$"#, line),
               groups("^(?:\\[)?" + timePattern, match[1]) != nil { line = match[1] }
            else if cues.isEmpty && groups(#"^#{1,6}\s+"#, line) != nil { continue }
            var times: [Int] = [], rest = line
            while groups(#"^\[[+-]?\d"#, rest) != nil {
                guard let close = rest.firstIndex(of: "]"),
                      let value = milliseconds(String(rest[rest.index(after: rest.startIndex)..<close])) else {
                    throw LyricsFailure(.invalidTiming, "第 \(lineNumber) 行的时间无效，请使用 [00:16.430] 这样的时间标记。")
                }
                times.append(value)
                rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            if times.isEmpty, let match = groups("^(`?(" + timePattern + ")`?)(?:\\s+|$)(.*)$", line),
               let value = milliseconds(match[2]) {
                times = [value]; rest = match[3]
            }
            guard let first = times.first else { missing.append(lineNumber); continue }
            guard !rest.hasPrefix("-->"), !rest.hasPrefix("→") else {
                throw LyricsFailure(.invalidTiming, "第 \(lineNumber) 行包含起止时间范围，请改成每句一个开始时间后再导入。")
            }
            guard first >= previous, times == times.sorted() else {
                throw LyricsFailure(.outOfOrder, "第 \(lineNumber) 行的时间早于前一行，请检查歌词时间顺序。")
            }
            previous = first
            // Enhanced LRC can carry word tags. This feature follows sentences and keeps their words.
            rest = rest.replacingOccurrences(of: "<" + timePattern + ">", with: "", options: .regularExpression)
            cues.append(contentsOf: times.map { LyricCue(startMilliseconds: $0, text: rest) })
            guard cues.count <= maximumCues else { throw LyricsFailure(.tooLarge, "歌词超过 10,000 个时间标记，请精简后再导入。") }
        }
        guard !cues.isEmpty else { throw LyricsFailure(.noTiming, "这份歌词没有找到可用时间，当前请导入带时间标记的歌词文件。") }
        guard missing.isEmpty else {
            let locations = missing.prefix(4).map(String.init).joined(separator: "、")
            throw LyricsFailure(.incompleteTiming, "第 \(locations) 行缺少时间。请补齐时间，或移除不需要显示的文字后再导入；原有歌词已保留。")
        }
        // Repeated chorus tags may interleave with later rows; duplicate times form one display group.
        var merged: [LyricCue] = []
        for cue in cues.enumerated().sorted(by: {
            $0.element.startMilliseconds == $1.element.startMilliseconds ? $0.offset < $1.offset : $0.element.startMilliseconds < $1.element.startMilliseconds
        }).map(\.element) {
            if merged.last?.startMilliseconds == cue.startMilliseconds {
                if !cue.text.isEmpty {
                    let index = merged.count - 1
                    merged[index].text += (merged[index].text.isEmpty ? "" : "\n") + cue.text
                }
            } else { merged.append(cue) }
        }
        let document = LyricsDocument(sourceName: name, cues: merged, offsetMilliseconds: offset ?? 0)
        try document.validate(duration: duration)
        return document
    }

    private static func milliseconds(_ raw: String) -> Int? {
        guard groups("^" + timePattern + "$", raw) != nil else { return nil }
        let parts = raw.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        let final = parts.last!.components(separatedBy: ".")
        guard let seconds = Int(final[0]), seconds < 60 else { return nil }
        let fraction = final.count == 2 ? Int(final[1].padding(toLength: 3, withPad: "0", startingAt: 0))! : 0
        guard let minutes = Int(parts[parts.count - 2]), parts.count == 2 || minutes < 60 else { return nil }
        let hours = parts.count == 3 ? Int(parts[0])! : 0
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + fraction
    }

    /// Native Word extraction puts table cells in separate paragraphs. Preserve each row's pairing.
    private static func wordText(_ document: NSAttributedString) -> String {
        var output = "", table: ObjectIdentifier?, row: Int?, cells: [Int: String] = [:]
        func flush() {
            guard !cells.isEmpty else { return }
            output += cells.keys.sorted().map { key in
                cells[key]!.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
            }.joined(separator: "\t") + "\n"
            cells.removeAll(); table = nil; row = nil
        }
        document.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: document.length)) { value, range, _ in
            let text = document.attributedSubstring(from: range).string
            if let block = (value as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock {
                let identity = ObjectIdentifier(block.table)
                if table != identity || row != block.startingRow { flush(); table = identity; row = block.startingRow }
                cells[block.startingColumn, default: ""] += text
            } else { flush(); output += text }
        }
        flush()
        return output
    }

    private static func groups(_ pattern: String, _ text: String, insensitive: Bool = false) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: insensitive ? [.caseInsensitive] : []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
