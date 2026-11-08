import AppKit
import CryptoKit
import Foundation

@main
enum LyricsRegression {
    struct Failure: Error { let message: String }
    static var checks: [String] = []
    static func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw Failure(message: name) }
        checks.append(name)
    }
    static func rejects(_ kind: LyricsFailure.Kind, _ name: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch let error as LyricsFailure { try check(error.kind == kind, name + "：错误分类"); return }
        throw Failure(message: name + "：没有拒绝")
    }
    static func parse(_ text: String, duration: Double = 370) throws -> LyricsDocument {
        try LyricsImport.parse(text, name: "测试歌词", duration: duration)
    }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Xianwaiwu-Lyrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let timed = "[00:16.430]第一句\n[00:20.050]第二句\n[00:30.000]\n[00:40.000]副歌\n"
        let document = try parse(timed)
        try check(document.cues.count == 4 && document.cues[1].startMilliseconds == 20050, "时间保留整数毫秒")
        try check(document.activeIndex(at: 16.429) == nil && document.activeIndex(at: 16.43) == 0, "首句前一毫秒和准确边界")
        try check(document.activeIndex(at: 20.05) == 1 && document.activeIndex(at: 17) == 0, "向前和向后跳转")
        try check(document.activeIndex(at: .nan) == nil && document.activeIndex(at: .infinity) == nil, "非法播放时间不会崩溃")
        try check(document.cues[document.activeIndex(at: 35)!].text.isEmpty, "空白时间项保留间奏")
        try check(try parse(document.lrcText) == document, "编辑和导出的 LRC 可以完整重读")
        let positive = try parse("[offset:500]\n" + timed)
        let negative = try parse("[offset:-500]\n" + timed)
        try check(positive.activeIndex(at: 15.93) == 0 && positive.audioTime(for: positive.cues[0]) == 15.93, "LRC 正偏移提前显示和定位")
        try check(negative.activeIndex(at: 16.929) == nil && negative.activeIndex(at: 16.93) == 0, "LRC 负偏移延后显示")
        try check(try parse(positive.lrcText) == positive, "整体时间偏移往返不重复叠加")
        try rejects(.invalidTiming, "冲突的偏移") { _ = try parse("[offset:100]\n[offset:200]\n" + timed) }
        let repeated = try parse("[00:10][00:20]副歌\n[00:15]间句")
        try check(repeated.cues.map(\.startMilliseconds) == [10000, 15000, 20000], "多时间标签保留重复副歌并正确排序")
        let shared = try parse("[00:10]中文\n[00:10]English")
        try check(shared.cues.count == 1 && shared.cues[0].text == "中文\nEnglish", "同一时刻多行合并显示")
        try check(try parse(shared.lrcText) == shared, "同一时刻多行导出后不丢失")
        try check(try parse("00:16.430 第一句").cues[0].startMilliseconds == 16430, "普通文本开始时间")
        try check(try parse("01:00:01.9 第一行", duration: 7200).cues[0].startMilliseconds == 3601900, "小时格式时间")
        try check(try parse("# 歌名\n| 时间 | 歌词 |\n| --- | --- |\n| 00:16.430 | 第一句 |\n| 00:20.050 | 第二句 |").cues.count == 2, "Markdown 表格按实际时间识别")
        try check(try parse("```lrc\n- [00:16.43]第一句\n```\n").cues.count == 1, "Markdown 代码块和列表")
        try check(try parse("[ar:作者]\n[ti:歌名]\n[00:16.43]<00:16.43>第<00:16.80>一句").cues[0].text == "第一句", "元信息和逐字标签不混入歌词文字")
        try rejects(.noTiming, "纯文字不会按扩展名伪造时间") { _ = try parse("没有时间的歌词") }
        try rejects(.noTiming, "正文中的钟点不是歌词起点") { _ = try parse("我在12:00等你\n这段时长是 00:30") }
        try rejects(.noTiming, "紧连正文的钟点不误识别") { _ = try parse("12:00等你回来") }
        try rejects(.incompleteTiming, "部分行没有时间不能静默丢弃") { _ = try parse("[00:16]第一句\n第二句") }
        try rejects(.invalidTiming, "秒数无效") { _ = try parse("[00:77]第一句") }
        try rejects(.invalidTiming, "过长小数不偷偷截断") { _ = try parse("[00:16.1234]第一句") }
        try rejects(.outOfOrder, "时间倒序") { _ = try parse("[00:20]第一句\n[00:10]第二句") }
        try rejects(.outOfBounds, "歌词超出歌曲长度") { _ = try parse("[06:20]第一句") }
        try rejects(.invalidTiming, "不猜测未支持的时间范围") { _ = try parse("00:16.430 --> 00:20.000\n第一句") }
        var invalid = document; invalid.offsetMilliseconds = Int.min
        try rejects(.invalidTiming, "异常极值偏移不会溢出崩溃") { try invalid.validate(duration: 370) }

        for ext in ["lrc", "txt", "md", "markdown"] {
            let url = folder.appendingPathComponent("带时间.\(ext)")
            try timed.write(to: url, atomically: true, encoding: .utf8)
            let loaded = try LyricsImport.read(url, duration: 370)
            try check(loaded.cues == document.cues, "\(ext) 根据内容读出相同时间")
            try "纯文字歌词".write(to: url, atomically: true, encoding: .utf8)
            try rejects(.noTiming, "\(ext) 无时间时明确提示") { _ = try LyricsImport.read(url, duration: 370) }
        }
        let utf16 = folder.appendingPathComponent("UTF16.txt")
        try timed.data(using: .utf16)!.write(to: utf16)
        try check(try LyricsImport.read(utf16, duration: 370).cues == document.cues, "UTF-16 文本")
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbURL = folder.appendingPathComponent("GB18030.lrc")
        try timed.data(using: gb)!.write(to: gbURL)
        try check(try LyricsImport.read(gbURL, duration: 370).cues == document.cues, "常见中文编码")
        let damaged = folder.appendingPathComponent("损坏.docx")
        try Data([0, 1, 2, 3]).write(to: damaged)
        try rejects(.unreadable, "读取失败与没有时间分开") { _ = try LyricsImport.read(damaged, duration: 370) }
        let large = folder.appendingPathComponent("过大.txt")
        try Data(repeating: 65, count: LyricsImport.maximumBytes + 1).write(to: large)
        try rejects(.tooLarge, "过大文件提前拦截") { _ = try LyricsImport.read(large, duration: 370) }
        for (ext, type) in [("docx", NSAttributedString.DocumentType.officeOpenXML), ("doc", .docFormat)] {
            let url = folder.appendingPathComponent("真实Word.\(ext)")
            let attributed = NSMutableAttributedString(string: timed)
            attributed.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 2, length: 5))
            try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: type]).write(to: url)
            try check(try LyricsImport.read(url, duration: 370).cues == document.cues, "真实 \(ext) 文件和拆分文字样式")
            let plain = NSAttributedString(string: "没有时间的 Word 歌词")
            try plain.data(from: NSRange(location: 0, length: plain.length), documentAttributes: [.documentType: type]).write(to: url)
            try rejects(.noTiming, "真实 \(ext) 无时间分类") { _ = try LyricsImport.read(url, duration: 370) }
        }
        let table = NSTextTable(); table.numberOfColumns = 2
        let cells = [["时间", "歌词"], ["00:16.430", "第一句"], ["00:20.050", "第二句"]]
        let tableText = NSMutableAttributedString(string: "")
        for (row, values) in cells.enumerated() {
            for (column, value) in values.enumerated() {
                let style = NSMutableParagraphStyle()
                style.textBlocks = [NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)]
                tableText.append(NSAttributedString(string: value + "\n", attributes: [.paragraphStyle: style]))
            }
        }
        let tableURL = folder.appendingPathComponent("真实Word表格.docx")
        try tableText.data(from: NSRange(location: 0, length: tableText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: tableURL)
        // Apple's writer drops NSTextTable structure. Build actual OOXML table rows in the test package.
        let package = folder.appendingPathComponent("word-table-package")
        func ditto(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = arguments
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure(message: "Word table fixture packaging failed") }
        }
        try ditto(["-x", "-k", tableURL.path, package.path])
        let rows = cells.map { values in
            "<w:tr>" + values.map { "<w:tc><w:p><w:r><w:t>\($0)</w:t></w:r></w:p></w:tc>" }.joined() + "</w:tr>"
        }.joined()
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w=\"2400\"/><w:gridCol w:w=\"8000\"/></w:tblGrid>\(rows)</w:tbl><w:p/></w:body></w:document>"
        try xml.write(to: package.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: tableURL)
        try ditto(["-c", "-k", package.path, tableURL.path])
        try check(try LyricsImport.read(tableURL, duration: 370).cues.map(\.startMilliseconds) == [16430, 20050], "真实 Word 时间与歌词两列表格")

        let reference = ProcessInfo.processInfo.environment["XIANWAIWU_TEST_LYRICS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/入海歌词.lrc")
        let skipReference = ProcessInfo.processInfo.environment["XIANWAIWU_SKIP_REFERENCE_LYRICS"] == "1"
        if !skipReference && (ProcessInfo.processInfo.environment["XIANWAIWU_TEST_LYRICS"] != nil || FileManager.default.fileExists(atPath: reference.path)) {
            let original = try Data(contentsOf: reference)
            let real = try LyricsImport.read(reference, duration: 369.49425)
            try check(real.cues.count == 84 && real.cues[4].startMilliseconds == 16430 && real.cues.last?.startMilliseconds == 368240,
                      "用户入海 LRC 的 84 个时间项及起止时间")
            try check(try Data(contentsOf: reference) == original, "用户原始歌词文件未改写")
        } else {
            print("SKIP 可选参考 LRC 未提供；继续执行自建歌词和真实 Word 检查。")
        }

        let sourceURL = folder.appendingPathComponent("原始音频样本.wav")
        let sourceData = Data("store-metadata-fixture".utf8)
        try sourceData.write(to: sourceURL)
        let source = SourceRecord(path: sourceURL.path, duration: 370, sampleRate: 44100, channels: 1,
                                  bytes: Int64(sourceData.count), modificationDate: Date(),
                                  sha256: SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined(), bookmarkData: nil)
        let root = folder.appendingPathComponent("library")
        let store = try LibraryStore(rootURL: root)
        let project = try store.createProject(source: source, name: "持久化检查")
        let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        var withoutLyrics = oldJSON; withoutLyrics.removeValue(forKey: "lyrics")
        let legacy = try JSONDecoder().decode(ProjectRecord.self, from: JSONSerialization.data(withJSONObject: withoutLyrics))
        try check(legacy.lyrics == nil, "旧项目缺少歌词字段仍可读取")
        _ = try store.setLyrics(document, projectID: project.id, replacing: nil)
        let other = try LibraryStore(rootURL: root)
        var renamed = other.projects[0]; renamed.title = "另一次操作的改名"
        _ = try other.saveProject(renamed)
        let saved = try store.setLyrics(positive, projectID: project.id, replacing: document)
        try check(saved.title == renamed.title && saved.lyrics == positive, "歌词保存不覆盖并行项目改名")
        let update = ListeningUpdate(projectID: project.id, mode: "pair", range: nil, selectedResultID: nil,
                                     listeningToResult: false, listening: ListeningRecord(absoluteTime: 17, enabled: ["original"]),
                                     sourceListening: ListeningRecord(absoluteTime: 17, enabled: ["original"]))
        _ = try other.persistListening(update)
        let reopened = try LibraryStore(rootURL: root)
        try check(reopened.projects[0].lyrics == positive && reopened.projects[0].sourceListening.absoluteTime == 17,
                  "自动试听保存和重新打开保留歌词")
        try rejects(.changed, "过期歌词编辑不覆盖新内容") { _ = try other.setLyrics(negative, projectID: project.id, replacing: document) }
        let beforeRejected = try Data(contentsOf: root.appendingPathComponent("library.json"))
        try rejects(.invalidTiming, "错误歌词不写入资料库") { _ = try store.setLyrics(invalid, projectID: project.id, replacing: positive) }
        try check(try Data(contentsOf: root.appendingPathComponent("library.json")) == beforeRejected, "失败保存保留已有资料库")
        _ = try store.setLyrics(nil, projectID: project.id, replacing: positive)
        try check(try LibraryStore(rootURL: root).projects[0].lyrics == nil && FileManager.default.fileExists(atPath: sourceURL.path), "移除附件保留歌曲")
        print("PASS \(checks.count) 歌词解析与持久化检查；真实 Word 与自建 LRC，可选参考输入按检查项区分；其他音频仅元信息夹具，无云端调用。")
        if CommandLine.arguments.count > 1 {
            let report: [String: Any] = ["passedChecks": checks.count, "checks": checks, "boundary": "本机解析、真实Word文档及隔离资料库；不含听音准确度或云端识别"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
    }
}
