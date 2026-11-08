import AppKit
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import PDFKit
import QuartzCore

/// Explicit, isolated verification entry, never used by an ordinary app launch.
enum ScoreAcceptance {
    @MainActor static func run(work: Workspace, window: NSWindow, destination: URL, reopen: Bool) {
        Task { @MainActor in
            let runner = Runner(work: work, window: window, destination: destination)
            do {
                try await runner.execute(reopen: reopen)
                try runner.finish(true)
                if (CommandLine.arguments.contains("--score-motion") || CommandLine.arguments.contains("--score-rhythm")), ProcessInfo.processInfo.environment["XIANWAIWU_SCORE_PREVIEW"] == "1" {
                    window.setContentSize(NSSize(width: 1120, height: 740))
                    return
                }
                work.quit(); Darwin.exit(0)
            } catch {
                try? await runner.screenshot("99-failure")
                try? runner.record("FAIL \(error.localizedDescription)")
                try? runner.finish(false)
                work.quit()
                for _ in 0..<50 where work.hasRunningProcess { try? await Task.sleep(nanoseconds: 100_000_000) }
                Darwin.exit(1)
            }
        }
    }

    private struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private final class AudioProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        private var peak: Float = 0
        func receive(_ buffer: AVAudioPCMBuffer) {
            guard let data = buffer.floatChannelData?[0] else { return }
            var maximum: Float = 0
            for i in 0..<Int(buffer.frameLength) { maximum = max(maximum, abs(data[i])) }
            lock.lock(); frames += Int(buffer.frameLength); peak = max(peak, maximum); lock.unlock()
        }
        func snapshot() -> (Int, Float) {
            lock.lock(); defer { lock.unlock() }; return (frames, peak)
        }
    }

    @MainActor private final class Runner {
        let work: Workspace
        let window: NSWindow
        let destination: URL
        var checks: [String] = []
        var originalFingerprint = ""
        var priorJobs = Set<String>()
        init(work: Workspace, window: NSWindow, destination: URL) {
            self.work = work; self.window = window; self.destination = destination
        }
        func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func record(_ message: String) throws {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            print(message); fflush(stdout)
            let path = destination.appendingPathComponent("score-check.log")
            let current = (try? String(contentsOf: path)) ?? ""
            try (current + message + "\n").write(to: path, atomically: true, encoding: .utf8)
        }
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw Failure(message: message) }
            checks.append(message); try record("PASS \(checks.count) \(message)")
        }
        func wait(_ name: String, seconds: Double = 90, until condition: () -> Bool) async throws {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while !condition() {
                if ProcessInfo.processInfo.systemUptime >= end { throw Failure(message: "等待超时：\(name)；\(work.scoreTask.error ?? "")") }
                try await pause(0.05)
            }
        }
        func screenshot(_ name: String, width: Double = 1120, height: Double = 740) async throws {
            window.setContentSize(NSSize(width: width, height: height))
            try await pause(0.3)
            guard let view = window.contentView else { throw Failure(message: "原生窗口无内容") }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "无法截图") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "无法编码截图") }
            try data.write(to: destination.appendingPathComponent(name + ".png"))
            try record("SCREEN \(name) \(width)×\(height)")
        }
        func accessibilityItem(_ identifier: String) -> AnyObject? {
            var visited = Set<ObjectIdentifier>()
            func visit(_ object: AnyObject) -> AnyObject? {
                if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return nil }
                if let host = object as? XWRetainedContainer, !host.interactive { return nil }
                guard visited.count < 10000, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
                if let item = object as? NSAccessibilityProtocol {
                    if item.accessibilityIdentifier() == identifier { return object }
                    for child in item.accessibilityChildren() ?? [] {
                        if let frame = visit(child as AnyObject) { return frame }
                    }
                } else if let item = object as? NSAccessibilityElementProtocol,
                          item.accessibilityIdentifier?() == identifier {
                    return object
                }
                if !(object is NSAccessibilityProtocol), let item = object as? NSObject {
                    for name in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder"] {
                        let selector = NSSelectorFromString(name)
                        if item.responds(to: selector), let children = item.perform(selector)?.takeUnretainedValue() as? [Any] {
                            for child in children { if let frame = visit(child as AnyObject) { return frame } }
                        }
                    }
                }
                if let view = object as? NSView {
                    for child in view.subviews { if let frame = visit(child) { return frame } }
                }
                return nil
            }
            return window.contentView.flatMap { visit($0) }
        }
        func accessibilityFrame(_ identifier: String) -> NSRect? {
            let object = accessibilityItem(identifier)
            if let item = object as? NSAccessibilityProtocol { return item.accessibilityFrame() }
            return (object as? NSAccessibilityElementProtocol)?.accessibilityFrame()
        }
        func accessibilityString(_ identifier: String) -> String {
            let object = accessibilityItem(identifier)
            if let item = object as? NSAccessibilityProtocol {
                if let value = item.accessibilityValue() as? String { return value }
                if let label = item.accessibilityLabel(), !label.isEmpty { return label }
            }
            if let item = object as? NSObject {
                for key in ["accessibilityValue", "accessibilityLabel"] {
                    let selector = NSSelectorFromString(key)
                    if item.responds(to: selector), let value = item.perform(selector)?.takeUnretainedValue() as? String, !value.isEmpty { return value }
                }
            }
            return ""
        }
        func followedRowVisible() throws {
            guard let score = work.currentScore,
                  let row = score.rows(lyrics: work.currentProject?.lyrics).first(where: { work.absoluteTime >= $0.start && work.absoluteTime < $0.end }) else {
                throw Failure(message: "没有活动乐谱行")
            }
            let identifier = "xw.score.row.\(Int((row.start * 1000).rounded()))"
            guard let frame = accessibilityFrame(identifier) else { throw Failure(message: "未找到活动行几何：\(identifier)") }
            if !window.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) {
                let viewport = accessibilityFrame("xw.score.sheet")
                try record("GEOMETRY row=\(frame), window=\(window.frame), viewport=\(String(describing: viewport))")
            }
            try check(window.frame.contains(NSPoint(x: frame.midX, y: frame.midY)), "跟随的活动行实际位于可见窗口内")
        }
        func followedLyricVisible() throws {
            guard let score = work.currentScore,
                  let row = score.rows(lyrics: work.currentProject?.lyrics).first(where: { work.absoluteTime >= $0.start && work.absoluteTime < $0.end }),
                  let lyric = accessibilityFrame("xw.score.lyric.\(Int((row.start * 1000).rounded()))"),
                  let viewport = accessibilityFrame("xw.score.sheet") else { throw Failure(message: "未找到当前歌词与谱面视口") }
            try check(viewport.intersection(lyric).height >= lyric.height - 1, "当前歌词在谱面视口内完整显示")
        }
        func fingerprint(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        func sourceReady() async throws {
            try await wait("核对来源") { !work.importing && !work.sourceChecking && work.sourceIssue == nil && !work.player.tracks.isEmpty }
        }
        func generated() async throws {
            try await wait("生成结束") { !work.scoreTask.running }
            try check(work.scoreTask.error == nil, "真实模型任务成功结束：\(work.scoreTask.error ?? "无错误")")
        }

        func importReferenceScore(openPractice: Bool = true) async throws -> ScoreDocument {
            guard let fixturePath = ProcessInfo.processInfo.environment["XIANWAIWU_SCORE_FIXTURE"] else {
                throw Failure(message: "动效检查需要独立乐谱副本")
            }
            try check(work.library.projects.isEmpty, "乐谱专项从空隔离库开始")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let input = destination.appendingPathComponent("入海.mp3")
            try FileManager.default.copyItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/入海.mp3"), to: input)
            work.player.volume = 0
            work.importFile(input)
            try await sourceReady()
            work.importLyrics(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/入海歌词.lrc"))
            try await wait("歌词导入") { !work.importingLyrics && work.currentProject?.lyrics != nil }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let score = try decoder.decode(ScoreDocument.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
            guard let id = work.currentProject?.id else { throw Failure(message: "动效项目未导入") }
            _ = try work.library.setScore(score, projectID: id, replacing: nil)
            work.openProject(id); try await sourceReady()
            if openPractice { work.openScore() }
            return score
        }

        func switchPerformanceCheck() async throws {
            _ = try await importReferenceScore(openPractice: false)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            work.seekAbsolute(221.4)
            try await pause(0.5)
            try await pause(ProcessInfo.processInfo.environment["XIANWAIWU_PROFILE_DELAY"].flatMap(Double.init) ?? 0)
            var reports: [[String: Any]] = []
            for iteration in 0..<4 {
                for identifier in ["xw.lyrics.toggle", "xw.lyrics.toggle", "xw.score.open", "xw.score.back"] {
                    let object = accessibilityItem(identifier)
                    let probe = SwitchFrameProbe(view: window.contentView!)
                    probe.start()
                    let began = ProcessInfo.processInfo.systemUptime
                    try pressPanelControl(identifier, using: object)
                    let action = ProcessInfo.processInfo.systemUptime - began
                    try await pause(0.45)
                    let metrics = probe.finish()
                    reports.append(["iteration": iteration, "control": identifier, "actionMs": action * 1000,
                                    "frameGapsMs": metrics])
                }
            }
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("switch-performance.json"))
            try check(reports.count == 16, "两种切换实际屏幕刷新间隔已采样")
        }

        func scoreLayoutCheck() async throws {
            let score = try await importReferenceScore(openPractice: false)
            guard let original = work.currentProject else { throw Failure(message: "没有版式检查项目") }
            let long = try work.library.createProject(source: original.source,
                name: "这是一首用来核对长歌名与小窗口排版的歌曲，返回音轨和重新识别按钮都应完整可用")
            _ = try work.library.setScore(score, projectID: long.id, replacing: nil)
            var geometry: [[String: Any]] = []
            for project in [original, long] {
                work.openProject(project.id); try await sourceReady()
                for width in [1120.0, 880.0] {
                    window.setContentSize(NSSize(width: width, height: width == 880 ? 620 : 740))
                    try await pause(0.3)
                    guard let entry = accessibilityFrame("xw.score.open") else { throw Failure(message: "未找到乐谱入口") }
                    try pressPanelControl("xw.score.open"); try await pause(0.35)
                    guard let back = accessibilityFrame("xw.score.back"),
                          let regenerate = accessibilityFrame("xw.score.regenerate"),
                          let export = accessibilityFrame("xw.score.export"),
                          let sheet = accessibilityFrame("xw.score.sheet"), let content = window.contentView else {
                        throw Failure(message: "缺少乐谱页实际布局")
                    }
                    let visible = window.convertToScreen(content.convert(content.bounds, to: nil))
                    try check([back, regenerate, export].allSatisfy { visible.insetBy(dx: -1, dy: -1).contains($0) },
                              "\(Int(width)) 窗宽、\(project.id == original.id ? "普通" : "长")歌名的三个操作完整可见")
                    try check(regenerate.maxX < visible.midX && back.minX > visible.midX && back.maxX <= export.minX,
                              "重新识别在左上，返回音轨位于右侧导出之前")
                    try check(accessibilityFrame("xw.player.primary") == nil, "练习页去掉底部重复操作，只保留顶部导出乐谱")
                    try check(abs(back.midX - entry.midX) < 110 && abs(back.midY - entry.midY) < 24,
                              "返回按钮靠近进入乐谱时的鼠标位置")
                    let gap = sheet.minY - visible.minY
                    try check(gap < 110, "去掉备注后谱面直接延伸至底部播放器上方")
                    geometry.append(["width": width, "longTitle": project.id != original.id,
                                     "entryX": entry.midX, "backX": back.midX, "sheetBottomGap": gap])
                    try await screenshot("layout-\(project.id == original.id ? "normal" : "long")-\(Int(width))", width: width, height: width == 880 ? 620 : 740)
                    try pressPanelControl("xw.score.back"); try await pause(0.3)
                    try check(!work.showingScore && work.currentScore == score, "返回原音轨且不修改已有乐谱")
                    try check(accessibilityFrame("xw.player.primary") != nil, "返回音轨后原有分离或导出操作恢复")
                }
            }
            work.openProject(original.id); try await sourceReady(); work.openScore()
            work.scoreSeek(221.4)
            try await screenshot("layout-delivery")
            try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("score-layout-geometry.json"))
        }
        func pressPanelControl(_ identifier: String, using cached: AnyObject? = nil) throws {
            guard let object = cached ?? accessibilityItem(identifier) else {
                throw Failure(message: "未找到面板实际按钮：\(identifier)")
            }
            let pressed: Bool
            if let item = object as? NSAccessibilityProtocol { pressed = item.accessibilityPerformPress() }
            else if let item = object as? NSObject, item.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                let selector = NSSelectorFromString("accessibilityPerformPress")
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                pressed = unsafeBitCast(item.method(for: selector), to: Press.self)(item, selector)
            } else { pressed = false }
            try check(pressed, "实际开关动作 \(identifier)")
        }

        func waveformIdentities() -> Set<ObjectIdentifier> {
            var ids = Set<ObjectIdentifier>()
            func visit(_ view: NSView) {
                if view is XWWaveformCanvas { ids.insert(ObjectIdentifier(view)) }
                for child in view.subviews { visit(child) }
            }
            if let view = window.contentView { visit(view) }
            return ids
        }

        func waveformFrame() throws -> NSRect {
            var result: NSRect?
            func visit(_ view: NSView) {
                if view is XWWaveformCanvas { result = view.convert(view.bounds, to: nil) }
                for child in view.subviews { visit(child) }
            }
            if let view = window.contentView { visit(view) }
            guard let result else { throw Failure(message: "没有实际波形几何") }
            return result
        }

        func renderedLyricsFrame() -> NSRect? {
            func find(_ view: NSView) -> XWRetainedContainer? {
                if view.identifier?.rawValue == "xw.lyrics.host" { return view as? XWRetainedContainer }
                return view.subviews.lazy.compactMap(find).first
            }
            guard let root = window.contentView, let host = find(root) else { return nil }
            var frame = window.convertToScreen(host.convert(host.bounds, to: nil))
            frame.origin.x += host.layer?.presentation()?.sublayerTransform.m41 ?? host.layer?.sublayerTransform.m41 ?? 0
            return frame
        }

        func sidebarGeometryCheck() async throws {
            window.setContentSize(NSSize(width: 1120, height: 740))
            try await pause(0.4)
            let open = try waveformFrame()
            try pressPanelControl("xw.lyrics.close")
            try await pause(0.35)
            let closed = try waveformFrame()
            try check(abs(closed.width - open.width - 304) < 1, "收起歌词后波形获得完整侧栏空间")
            var samples: [[String: Double]] = []
            for opening in [true, false] {
                try pressPanelControl("xw.lyrics.toggle")
                let start = ProcessInfo.processInfo.systemUptime
                var intermediate = Set<Int>()
                for _ in 0..<24 {
                    try await pause(0.012)
                    let frame = try waveformFrame()
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    if frame.width > open.width + 2 && frame.width < closed.width - 2 {
                        intermediate.insert(Int(frame.width.rounded()))
                    }
                    samples.append(["opening": opening ? 1 : 0, "seconds": elapsed,
                                    "waveWidth": frame.width, "waveX": frame.minX,
                                    "lyricsX": renderedLyricsFrame()?.minX ?? -1,
                                    "lyricsWidth": renderedLyricsFrame()?.width ?? 0])
                }
                let data = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: destination.appendingPathComponent("sidebar-geometry.json"))
                try check(intermediate.count >= 3, "\(opening ? "展开" : "收起")实际波形经过多个中间宽度")
                if opening {
                    let visible = samples.filter { $0["opening"] == 1 && ($0["lyricsWidth"] ?? 0) > 0 }
                    try check(visible.allSatisfy { abs(($0["lyricsWidth"] ?? 0) - 290) < 1 }, "滑出期间歌词保持完整宽度，不挤压文字")
                    try check((visible.map { $0["lyricsX"]! }.max() ?? 0) - (visible.map { $0["lyricsX"]! }.min() ?? 0) > 100,
                              "歌词面板实际从右侧移入，与波形缩窄同时进行")
                }
                let target = opening ? open : closed
                try check(abs(try waveformFrame().width - target.width) < 1, "侧栏动效准确停在目标宽度")
            }
            let data = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination.appendingPathComponent("sidebar-geometry.json"))
            try pressPanelControl("xw.lyrics.toggle")
            try await pause(0.35)
            // Capture the actual native view without resizing or forcing a target layout.
            func frame(_ name: String) throws {
                guard let view = window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "无法截取动效画面") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "动效画面编码失败") }
                try data.write(to: destination.appendingPathComponent(name + ".png"))
            }
            try frame("sidebar-open")
            try pressPanelControl("xw.lyrics.close")
            try await pause(0.07); try frame("sidebar-closing")
            try await pause(0.3); try frame("sidebar-closed")
            try pressPanelControl("xw.lyrics.toggle")
            try await pause(0.07); try frame("sidebar-opening")
            try await pause(0.3)
        }

        func panelMotionCheck() async throws {
            let score = try await importReferenceScore()
            work.closeScore()
            try await pause(0.4)
            let lyrics = work.currentProject?.lyrics
            let versions = work.versions.count
            try await sidebarGeometryCheck()
            work.seekAbsolute(100)
            work.togglePlayback()
            let waveform = waveformIdentities()
            try check(!waveform.isEmpty, "已挂载真实波形视图")
            for width in [1120.0, 880.0, 1120.0] {
                window.setContentSize(NSSize(width: width, height: width == 880 ? 620 : 740))
                try await pause(0.35)
                try check(waveformIdentities() == waveform, "跨左右与上下布局保留同一波形实例")
                if let document = work.currentProject?.lyrics, let active = document.activeIndex(at: work.absoluteTime),
                   document.cues.indices.contains(active) {
                    guard let viewport = accessibilityFrame("xw.lyrics.viewport"),
                          let row = accessibilityFrame("xw.lyrics.cue.\(document.cues[active].id)") else {
                        throw Failure(message: "未找到实际歌词视口或当前句")
                    }
                    try check(viewport.contains(NSPoint(x: row.midX, y: row.midY)), "宽窄布局变化后当前歌词仍可见")
                }
                let before = work.absoluteTime
                let buttonBefore = accessibilityFrame("xw.lyrics.toggle")
                try check(accessibilityString("xw.lyrics.toggle") == "已展开", "宽窄布局歌词起始展开")
                for _ in 0..<6 {
                    try pressPanelControl("xw.lyrics.toggle")
                    try await pause(0.045)
                }
                try await pause(0.35)
                try check(accessibilityString("xw.lyrics.toggle") == "已展开", "连续反向点击没有丢失最终开关状态")
                try check(accessibilityFrame("xw.lyrics.close") != nil, "展开后实际关闭按钮仍可操作")
                try check(waveformIdentities() == waveform, "连续开合未拆掉并重建波形")
                try check(work.player.playing && work.absoluteTime > before + 0.2, "开合过程中真实播放持续前进")
                try pressPanelControl("xw.lyrics.close")
                try await pause(0.35)
                try check(accessibilityString("xw.lyrics.toggle") == "已收起" && accessibilityFrame("xw.lyrics.close") == nil,
                          "面板关闭出口同步开关，收起内容不留可操作残影")
                if let before = buttonBefore, let after = accessibilityFrame("xw.lyrics.toggle") {
                    try check(abs(before.width - after.width) < 0.5 && abs(before.minX - after.minX) < 0.5,
                              "歌词选中前后入口宽度与位置稳定")
                }
                try pressPanelControl("xw.lyrics.toggle")
                try await pause(0.35)
            }
            let time = work.absoluteTime
            for _ in 0..<3 {
                try pressPanelControl("xw.score.open")
                try await pause(0.09)
                try check(work.showingScore && accessibilityFrame("xw.score.back") != nil, "乐谱进入立即响应")
                try check(accessibilityFrame("xw.lyrics.toggle") == nil, "乐谱进入时旧音轨控件立即退出辅助阅读")
                try pressPanelControl("xw.score.back")
                try await pause(0.10)
                try check(!work.showingScore && accessibilityFrame("xw.lyrics.toggle") != nil, "过渡未结束即可返回音轨")
                try check(accessibilityFrame("xw.score.back") == nil, "返回音轨时旧乐谱控件立即退出辅助阅读")
            }
            try await pause(0.4)
            try check(work.player.playing && work.absoluteTime > time + 0.3, "乐谱快速往返不打断底部播放")
            try pressPanelControl("xw.score.open")
            try await pause(0.08)
            try pressPanelControl("xw.score.back")
            try await pause(0.07)
            try pressPanelControl("xw.score.open")
            try await pause(0.05)
            let beats = work.player.beatGuideTimes
            try check(!beats.isEmpty, "重入乐谱已准备节拍")
            work.player.beatGuideEnabled = true
            try await pause(0.4)
            try check(work.player.beatGuideEnabled && work.player.beatGuideTimes == beats,
                      "旧页面退场不清除新页面节拍和鼓点开关")
            work.closeScore()
            try await pause(0.3)
            work.player.stop()
            try check(work.currentScore == score && work.currentProject?.lyrics == lyrics && work.versions.count == versions,
                      "开关与导航不修改谱、歌词或分离结果")
            try check(try fingerprint(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/入海.mp3")) == originalFingerprint,
                      "面板检查未改写原始音频")
            try await screenshot("14-开关宽屏")
            try await screenshot("15-开关窄屏", width: 880, height: 620)
        }

        func motionCheck() async throws {
            let score = try await importReferenceScore()
            window.setContentSize(NSSize(width: 1120, height: 740))
            let rows = score.rows(lyrics: work.currentProject?.lyrics)
            guard let row = rows.first(where: { $0.start > score.range.start + 20 && $0.end - $0.start > 3 && $0.end - $0.start < 8 }) else {
                throw Failure(message: "没有适合测量的真实歌词行")
            }
            work.scoreSeek(row.start + 0.35)
            try await pause(0.5)
            let identifier = "xw.score.row.\(Int((row.start * 1000).rounded()))"
            work.togglePlayback()
            try await pause(0.15)
            var samples: [[String: Double]] = []
            for _ in 0..<32 {
                guard let frame = accessibilityFrame(identifier) else { throw Failure(message: "播放中活动行丢失") }
                samples.append(["time": work.absoluteTime, "y": frame.minY, "height": frame.height])
                try await pause(0.05)
            }
            work.player.stop()
            let data = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination.appendingPathComponent("motion-samples.json"))
            let ys = samples.compactMap { $0["y"] }
            let distinct = Set(ys.map { Int(($0 * 10).rounded()) }).count
            let movement = (ys.max() ?? 0) - (ys.min() ?? 0)
            let steps = zip(ys, ys.dropFirst()).map { abs($1 - $0) }
            try record("MOTION samples=\(samples.count), positions=\(distinct), travel=\(movement), maxStep=\(steps.max() ?? 0)")
            try check(movement < 1, "同一段播放时谱面保持静止，不持续追赶进度")
            try check((steps.max() ?? 0) < 1, "段内没有突然位移")
            guard let nextRow = rows.first(where: { $0.start >= row.end - 0.001 }) else {
                throw Failure(message: "没有下一段用于检查换幕")
            }
            work.scoreSeek(row.end - 0.05); try await pause(0.35)
            let nextID = "xw.score.row.\(Int((nextRow.start * 1000).rounded()))"
            work.scoreSeek(nextRow.start + 0.05)
            var pageSamples: [Double] = []
            for _ in 0..<24 {
                guard let frame = accessibilityFrame(nextID) else { throw Failure(message: "下一段画面丢失") }
                pageSamples.append(frame.minY)
                try await pause(0.016)
            }
            try JSONSerialization.data(withJSONObject: pageSamples, options: [.prettyPrinted])
                .write(to: destination.appendingPathComponent("page-transition-samples.json"))
            try check(Set(pageSamples.map { Int(($0 * 10).rounded()) }).count >= 6,
                      "进入下一段时经过多个中间位置，平滑换幕")
            let pageStill = accessibilityFrame(nextID)!.minY
            try await pause(0.25)
            try check(abs((accessibilityFrame(nextID)?.minY ?? 0) - pageStill) < 1,
                      "换幕结束后停稳，下一段内部不继续滚动")
            try check((accessibilityFrame("xw.score.rhythm")?.height ?? 0) >= 28, "紧凑节拍参考有清楚的显示高度")
            try check(accessibilityFrame("xw.score.timeline") == nil, "重复的上方和弦时间带已经移除")
            let still = accessibilityFrame(nextID)!.minY
            try await pause(0.25)
            try check(abs((accessibilityFrame(nextID)?.minY ?? 0) - still) < 1, "暂停后谱面停稳")
            work.scoreLoop(row)
            work.scoreSeek(row.end - 0.18)
            work.togglePlayback(); try await pause(0.75)
            work.player.stop(); try await pause(0.25)
            try check(work.absoluteTime >= row.start && work.absoluteTime < row.start + 1.2, "真实 A/B 循环已回到句首附近")
            try followedLyricVisible()
            work.player.clearLoop()
            work.scoreSeek(score.range.end - 15)
            try await pause(0.35); try followedRowVisible()
            work.scoreSeek(score.range.start + 2)
            work.scoreSeek(score.range.start + 40)
            work.scoreSeek(row.start + 0.5)
            try await pause(0.35); try followedRowVisible()
            try await screenshot("08-按段跟随")
            try followedLyricVisible()
            try await screenshot("09-最小窗口", width: 880, height: 620)
            try await pause(0.2); try followedRowVisible()
            try followedLyricVisible()
            try check(try fingerprint(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/入海.mp3")) == originalFingerprint, "动效检查未改写原始音频")
        }

        func rhythmCheck() async throws {
            let score = try await importReferenceScore()
            guard let projectID = work.currentProject?.id else { throw Failure(message: "没有节拍项目") }
            try check(!work.player.beatGuideEnabled && !work.player.beatGuide.node.isPlaying, "鼓点声默认关闭")
            try check(work.player.beatGuideTimes == score.beats, "原曲节拍使用现有绝对时间，无需重新识别")
            let rows = score.rows(lyrics: work.currentProject?.lyrics)
            guard let chord = score.chords.first(where: { c in
                c.label != "N.C." && c.start > score.range.start + 20 && c.end - c.start > 1.2 &&
                rows.contains { $0.start <= c.start && $0.end >= c.end }
            }), let row = rows.first(where: { $0.start <= chord.start && $0.end >= chord.end }) else {
                throw Failure(message: "没有完整可测的和弦格")
            }
            let key = "xw.score.chord.\(chord.id.uuidString).\(Int((row.start * 1000).rounded()))"
            func percent(_ value: String) -> Int? {
                guard let range = value.range(of: "[0-9]+(?=%)", options: .regularExpression) else { return nil }
                return Int(value[range])
            }
            work.scoreSeek(chord.start + (chord.end - chord.start) * 0.25)
            try await pause(0.3)
            let first = accessibilityString(key)
            try record("CARD \(key) class=\(String(describing: accessibilityItem(key).map { type(of: $0) })) value=\(first)")
            try check((20...30).contains(percent(first) ?? -1) && first.contains("剩"), "当前和弦格显示四分之一进度与剩余秒数")
            try await screenshot("10-和弦四分之一")
            work.scoreSeek(chord.start + (chord.end - chord.start) * 0.75)
            try await pause(0.25)
            try check((70...80).contains(percent(accessibilityString(key)) ?? -1), "同一格进度随真实音频位置推进到四分之三")
            let lyricID = "xw.score.lyric.\(Int((row.start * 1000).rounded()))"
            let rowID = "xw.score.row.\(Int((row.start * 1000).rounded()))"
            if let lyricFrame = accessibilityFrame(lyricID), let rowFrame = accessibilityFrame(rowID) {
                try check(abs(lyricFrame.midX - rowFrame.midX) < 1, "当前歌词在句子区域水平居中")
            } else { throw Failure(message: "没有当前歌词几何") }
            try await screenshot("11-和弦四分之三")
            try await screenshot("12-节拍最小窗口", width: 880, height: 620)
            try followedLyricVisible()
            window.setContentSize(NSSize(width: 1120, height: 740))

            // Four cards fill the narrow layout: this also exercises the cue wrapping after the last card.
            if let priorRow = rows.first(where: { row in
                guard row.chordIDs.count == 4, let last = score.chords.first(where: { $0.id == row.chordIDs.last }) else { return false }
                return last.label != "N.C." && row.end > last.start + 0.2 && row.end < last.end - 0.2
            }), let crossing = score.chords.first(where: { $0.id == priorRow.chordIDs.last }),
               let nextRow = rows.first(where: { $0.start == priorRow.end }) {
                let priorKey = "xw.score.chord.\(crossing.id.uuidString).\(Int((priorRow.start * 1000).rounded()))"
                let nextKey = "xw.score.chord.\(crossing.id.uuidString).\(Int((nextRow.start * 1000).rounded()))"
                let cueID = "xw.score.continuation.\(Int((priorRow.start * 1000).rounded()))"
                work.scoreSeek(nextRow.start - 0.05); try await pause(0.25)
                let before = percent(accessibilityString(priorKey)) ?? -1
                try check(before >= 70 && !accessibilityString(nextKey).contains("进行中"), "跨句和弦的上一格接近走满，下一句不提前亮格")
                try check(accessibilityString(cueID).contains("继续按同一和弦"), "换句前已经显示保持同一和弦的提示")
                for width in [1120.0, 880.0] {
                    window.setContentSize(NSSize(width: width, height: width == 880 ? 620 : 740)); try await pause(0.35)
                    guard let cue = accessibilityFrame(cueID), let card = accessibilityFrame(priorKey),
                          let sheet = accessibilityFrame("xw.score.sheet") else { throw Failure(message: "没有末尾延续提示几何") }
                    let afterCard = cue.minX >= card.maxX - 1 && abs(cue.midY - card.midY) < 18
                    let wrappedAfter = cue.maxY <= card.minY + 1
                    try check(afterCard || wrappedAfter, "\(Int(width)) 窗宽的提示紧接最后一个和弦格，空间不足顺序换行")
                    try check(sheet.intersection(cue).height >= cue.height - 1 && sheet.intersection(cue).width >= cue.width - 1,
                              "\(Int(width)) 窗宽在换句前完整看见延续提示")
                    try await screenshot("14-末尾提前提示-\(Int(width))", width: width, height: width == 880 ? 620 : 740)
                }
                window.setContentSize(NSSize(width: 1120, height: 740))
                work.scoreSeek(nextRow.start + 0.05); try await pause(0.25)
                let after = percent(accessibilityString(nextKey)) ?? -1
                try check(percent(accessibilityString(priorKey)) == 100 && !accessibilityString(priorKey).contains("进行中"),
                          "换句后上一格完整走满，不再冻结在半格")
                try check(after >= 0 && after <= 30 && accessibilityString(nextKey).contains("继续按同一和弦"),
                          "新句的格子重新计本段进度，并明确表示延续同一和弦")
                try check(accessibilityString(cueID).contains("继续按同一和弦"), "换句后上一段的末尾提示保持在原处，不移动到新句标题")
            } else { throw Failure(message: "没有跨歌词行的真实和弦") }

            let probe = AudioProbe()
            let guide = work.player.beatGuide
            guide.node.installTap(onBus: 0, bufferSize: 1024, format: guide.format) { buffer, _ in probe.receive(buffer) }
            defer { guide.node.removeTap(onBus: 0) }
            func aligned(_ name: String) throws {
                let error = work.player.beatGuideAlignmentError ?? 100
                try record("ALIGN \(name) \(error) seconds")
                try check(error < 0.04, "\(name)鼓点与音乐源帧相位一致")
            }
            work.player.beatGuideEnabled = true
            try check(!guide.node.isPlaying, "暂停时打开鼓点开关不会自行出声")
            work.togglePlayback(); try await pause(0.8)
            try check(work.player.playing && guide.node.isPlaying && guide.renderedBuffers > 0 && guide.nonzeroScheduledFrames > 0,
                      "系统音频引擎真实渲染鼓点缓冲区")
            try aligned("正常播放")
            let captured = probe.snapshot()
            try check(captured.0 > 0 && captured.1 > 0.001, "独立鼓点音轨的实际输出采样非静音")
            work.scoreSeek(chord.start + 0.15); try await pause(0.3)
            try check(work.player.playing, "鼓点开启时跳转保持音乐播放")
            try aligned("播放中跳转")
            work.player.speed = 0.5; try await pause(0.6); try aligned("半速")
            let halfBPM = Int(((score.estimatedBPM ?? 0) * 0.5).rounded())
            try check(accessibilityString("xw.score.bpm").contains("\(halfBPM)"), "半速时显示与实际播放相符的节拍速度")
            work.player.pitch = 2; try await pause(0.3); try aligned("升降调")
            work.player.stop(); try await pause(0.1)
            try check(!guide.node.isPlaying, "暂停同步停止鼓点，不遗留队列音频")
            work.player.speed = 1; work.player.pitch = 0
            work.scoreLoop(row); work.scoreSeek(row.end - 0.18)
            work.togglePlayback(); try await pause(0.85)
            try check(work.absoluteTime >= row.start && work.absoluteTime < row.start + 1.3, "鼓点开启时真实 A/B 循环已回跳")
            try aligned("循环回跳后")
            work.player.beatGuideEnabled = false
            try check(work.player.playing && !guide.node.isPlaying, "关闭鼓点保留音乐播放")
            work.player.beatGuideEnabled = true; try await pause(0.4)
            try aligned("播放中重新开启")
            work.closeScore()
            try check(work.player.playing && !work.player.beatGuideEnabled && !guide.node.isPlaying, "返回音轨即关闭鼓点，音乐继续播放")
            work.player.stop(); work.player.clearLoop(); work.openScore()
            let other = try work.library.createProject(source: work.currentProject!.source, name: "节拍隔离检查")
            work.openProject(other.id); try await sourceReady()
            try check(!work.player.beatGuideEnabled && work.player.beatGuideTimes.isEmpty, "切项目清除旧节拍与开关")
            work.openProject(projectID); try await sourceReady(); work.openScore()
            var silent = score; silent.beats = []
            try work.saveScore(silent, replacing: score); work.prepareScorePlayback()
            try check(work.player.beatGuideTimes.isEmpty && !work.player.beatGuideEnabled, "无节拍谱不制造鼓点")
            try work.saveScore(score, replacing: silent); work.prepareScorePlayback()
            work.scoreSeek(chord.start + (chord.end - chord.start) * 0.5)
            try await pause(0.3)
            try await screenshot("13-节拍交付预览")
            try check(work.currentScore == score, "节拍与格内进度不改变已有乐谱数据")
            try check(try fingerprint(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/入海.mp3")) == originalFingerprint, "节拍检查未改写原音频")
            try record("AUDIO renderedFrames=\(captured.0), peak=\(captured.1)")
        }

        func execute(reopen: Bool) async throws {
            guard ProcessInfo.processInfo.environment["XIANWAIWU_DATA"] != nil,
                  work.library.rootURL.path.contains("/scratch/score/native/"),
                  !work.library.rootURL.path.contains("lyrics-verification") else {
                throw Failure(message: "乐谱专项仅允许独立的 scratch/score/native 资料库")
            }
            priorJobs = Set(((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("xianwaiwu-score-job-") })
            let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/入海.mp3")
            originalFingerprint = try fingerprint(source)
            if CommandLine.arguments.contains("--score-layout") {
                try await scoreLayoutCheck()
                return
            }
            if CommandLine.arguments.contains("--switch-performance") {
                try await switchPerformanceCheck()
                return
            }
            if CommandLine.arguments.contains("--panel-motion") {
                try await panelMotionCheck()
                return
            }
            if CommandLine.arguments.contains("--score-rhythm") {
                try await rhythmCheck()
                return
            }
            if CommandLine.arguments.contains("--score-motion") {
                try await motionCheck()
                return
            }
            if reopen {
                guard let project = work.library.projects.first(where: { $0.score != nil }) else { throw Failure(message: "没有待恢复乐谱") }
                let expected = project.score
                work.openProject(project.id); try await sourceReady(); work.openScore()
                try check(work.currentScore == expected && work.currentProject?.lyrics != nil, "新进程恢复真实乐谱、修改与歌词")
                try check(work.currentScore?.capo == 2 && work.currentScore?.chords.contains(where: \.edited) == true, "新进程保留变调夹与人工修改")
                work.scoreSeek(42)
                try check(abs(work.absoluteTime - 42) < 0.02, "恢复后和弦时间仍对应歌曲绝对时间")
                try await pause(0.3); try followedRowVisible()
                work.scoreSeek(130); work.togglePlayback(); try await pause(0.15)
                work.scoreSeek(140); work.player.stop()
                work.scoreSeek(16.5)
                if let original = work.currentScore { try work.saveScore(original, replacing: original) }
                try await pause(0.4); try followedRowVisible()
                try await screenshot("07-快速跳转跟随")
                work.scoreSeek(42); try await pause(0.2)
                try await screenshot("06-重新打开")
                return
            }
            try check(work.library.projects.isEmpty, "首轮从空隔离资料库开始")
            let input = destination.appendingPathComponent("入海.mp3")
            try FileManager.default.copyItem(at: source, to: input)
            work.player.volume = 0
            work.importFile(input)
            try await sourceReady()
            guard let id = work.currentProject?.id else { throw Failure(message: "项目未导入") }
            work.importLyrics(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/入海歌词.lrc"))
            try await wait("歌词导入") { !work.importingLyrics && work.currentProject?.lyrics != nil }
            try check(work.currentProject?.lyrics?.cues.count == 84, "真实歌词复用且无需歌词模型")
            work.openScore()
            try check(work.showingScore && work.currentScore == nil, "乐谱入口打开独立练习页")
            try await screenshot("01-生成前")
            work.generateScore()
            try check(work.scoreTask.running && work.busy, "真实生成期间统一任务忙状态")
            try await wait("识别进度") { work.scoreTask.progress >= 0.12 || !work.scoreTask.running }
            try await screenshot("02-生成中")
            try await generated()
            guard let original = work.currentScore else { throw Failure(message: "没有真实乐谱") }
            try original.validate(source: work.currentProject!.source)
            try check(original.chords.count > 30 && original.beats.count > 0, "真实《入海》产生和弦与节拍")
            try check(original.sourceSHA256 == originalFingerprint && abs(original.range.end - 369.49425) < 0.001, "乐谱范围和音频指纹一致")
            let payload = try JSONEncoder().encode(original)
            try check(payload.count < 262144, "本曲乐谱数据为 \(payload.count) 字节")
            try check(GuitarShapes.all["C"]?.first?.frets == [-1, 3, 2, 0, 1, 0], "加载真实授权指法数据")
            work.scoreSeek(130)
            try check(abs(work.absoluteTime - 130) < 0.02, "暂停时点击和弦准确定位")
            work.togglePlayback(); try await pause(0.15)
            try check(work.player.playing, "真实播放器开始试听")
            work.scoreSeek(140)
            try check(work.player.playing, "播放中点击和弦继续播放")
            work.player.stop()
            let row = original.rows(lyrics: work.currentProject?.lyrics).first(where: { $0.start > 16 && $0.end - $0.start > 1 })!
            work.scoreLoop(row)
            try check(work.player.loop && abs(work.player.a - row.start) < 0.01 && abs(work.player.b - row.end) < 0.01, "歌词句设置真实 A/B 循环")
            work.player.clearLoop(); work.player.speed = 0.75; work.player.pitch = 2
            try check(work.player.speed == 0.75 && work.player.pitch == 2, "慢速练习和升降调沿用真实播放器")
            work.player.speed = 1; work.player.pitch = 0
            var edited = original
            let editIndex = edited.chords.firstIndex(where: { $0.label != "N.C." })!
            edited.chords[editIndex].label = "Dm7"; edited.capo = 2
            let boundary = edited.chords[editIndex + 1]
            try edited.moveBoundary(id: boundary.id, to: boundary.start + 0.05)
            try work.saveScore(edited, replacing: original)
            try check(work.currentScore == edited, "原调和弦、时间微调及变调夹保存")
            try await pause(0.4); try followedRowVisible()
            try await screenshot("03-弹唱谱")
            try await screenshot("04-最小窗口", width: 880, height: 620)
            let pdf = destination.appendingPathComponent("入海-真实弹唱谱.pdf")
            try ScoreExport.pdf(edited, title: "入海", lyrics: work.currentProject?.lyrics, pitch: 0, to: pdf)
            let doc = PDFDocument(url: pdf)
            try check((doc?.pageCount ?? 0) >= 2 && doc?.string?.contains("还有说不完的话") == true, "真实 PDF 多页、可搜索中文歌词")
            let cho = edited.chordPro(title: "入海", lyrics: work.currentProject?.lyrics)
            try cho.write(to: destination.appendingPathComponent("入海-真实弹唱谱.cho"), atomically: true, encoding: .utf8)
            try check(cho.contains("{capo: 2}") && cho.contains("[Cm7]"), "导出指法按变调夹换算")
            if let image = doc?.page(at: 0)?.thumbnail(of: NSSize(width: 595, height: 842), for: .mediaBox),
               let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: destination.appendingPathComponent("05-PDF第一页.png"))
            }
            work.generateScore(); try check(work.scoreTask.running, "重新识别启动")
            work.cancel()
            try await wait("取消", seconds: 8) { !work.scoreTask.running }
            try check(work.currentScore == edited && !work.hasRunningProcess, "取消真实任务保留修改并释放进程")
            work.currentProject!.source.sha256 = String(repeating: "0", count: 64)
            work.generateScore()
            try await wait("故意失败") { !work.scoreTask.running }
            try check(work.scoreTask.error != nil, "来源校验失败明确提示")
            try work.library.reload()
            try check(work.library.projects.first { $0.id == id }?.score == edited, "生成失败保留已有乐谱")
            work.openProject(id); try await sourceReady(); work.openScore()
            work.range = 15...35
            let other = try work.library.createProject(source: work.currentProject!.source, name: "隔离切换检查")
            work.generateScore()
            work.closeScore()
            try check(work.mainActionLabel == "正在生成乐谱", "返回音轨仍正确显示本曲乐谱任务")
            work.openProject(other.id)
            try check(work.mainActionLabel == "其他项目正在生成乐谱", "切项目后明确说明后台乐谱任务")
            try await generated()
            try work.library.reload()
            let owned = work.library.projects.first { $0.id == id }!
            try check(owned.score?.range == AudioRange(start: 15, end: 35) && work.currentProject?.id == other.id &&
                      work.library.projects.first { $0.id == other.id }?.score == nil, "处理中切项目只保存原项目")
            _ = try work.library.setScore(edited, projectID: id, replacing: owned.score)
            work.openProject(id); try await sourceReady(); work.openScore()
            work.scoreSeek(42)
            work.closeScore()
            try check(!work.showingScore && work.range == 15...35, "返回音轨保留原曲处理范围")
            work.openScore()
            try check(work.player.limit == edited.range.closedRange, "旧全曲乐谱独立于后续处理范围试听")
            work.player.stop(); work.saveListening()
            try check(try fingerprint(source) == originalFingerprint, "个人原始《入海》未改动")
        }
        func finish(_ success: Bool) throws {
            let remaining = Set(((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("xianwaiwu-score-job-") })
            if success { try check(remaining.subtracting(priorJobs).isEmpty, "真实任务结束后临时音频目录已清理") }
            let summary: [String: Any] = ["success": success, "checks": checks, "count": checks.count,
                                          "projectID": work.currentProject?.id.uuidString ?? "",
                                          "scoreBytes": work.currentScore.flatMap { try? JSONEncoder().encode($0).count } ?? 0]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try data.write(to: destination.appendingPathComponent("report.json"))
        }
    }
}

/// Records main-thread display callbacks only during an explicit isolated acceptance run.
@MainActor final class SwitchFrameProbe: NSObject {
    private var link: CADisplayLink?
    private var times: [Double] = []
    private let view: NSView
    init(view: NSView) { self.view = view }
    func start() {
        times = [ProcessInfo.processInfo.systemUptime]
        let display = view.displayLink(target: self, selector: #selector(tick))
        display.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link = display
        display.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ display: CADisplayLink) { times.append(ProcessInfo.processInfo.systemUptime) }
    func finish() -> [Double] {
        link?.invalidate(); link = nil
        return zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
    }
}
