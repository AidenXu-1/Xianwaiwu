import AppKit
import SwiftUI
import Combine

struct GuitarShape: Decodable {
    var frets: [Int]
    var fingers: [Int]
    var baseFret: Int
    var barres: [Int]?
}

enum GuitarShapes {
    private struct Database: Decodable {
        struct Entry: Decodable { var key: String; var suffix: String; var positions: [GuitarShape] }
        var chords: [String: [Entry]]
    }
    static let all: [String: [GuitarShape]] = {
        let path = Project.root.appendingPathComponent("app/audio/乐谱/guitar.json")
        guard let bytes = try? Data(contentsOf: path), let db = try? JSONDecoder().decode(Database.self, from: bytes) else { return [:] }
        var result: [String: [GuitarShape]] = [:]
        for entry in db.chords.values.flatMap({ $0 }) {
            let suffix = entry.suffix == "major" ? "" : entry.suffix == "minor" ? "m" : entry.suffix
            guard let chord = GuitarChord(entry.key + suffix) else { continue }
            result[chord.transposed(0)] = entry.positions.filter { $0.frets.count == 6 && $0.fingers.count == 6 && $0.baseFret >= 1 }
        }
        return result
    }()
}

struct XWGuitarDiagram: View {
    var shape: GuitarShape
    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 26, top: CGFloat = 24
            let dx = (size.width - left - 16) / 5, dy = (size.height - top - 14) / 5
            for i in 0..<6 {
                var line = Path(); line.move(to: CGPoint(x: left + CGFloat(i) * dx, y: top))
                line.addLine(to: CGPoint(x: left + CGFloat(i) * dx, y: top + dy * 5))
                context.stroke(line, with: .color(XWTheme.muted.opacity(0.65)), lineWidth: 0.8)
            }
            for i in 0..<6 {
                var line = Path(); line.move(to: CGPoint(x: left, y: top + CGFloat(i) * dy))
                line.addLine(to: CGPoint(x: left + dx * 5, y: top + CGFloat(i) * dy))
                context.stroke(line, with: .color(i == 0 && shape.baseFret == 1 ? XWTheme.text : XWTheme.muted.opacity(0.65)),
                               lineWidth: i == 0 && shape.baseFret == 1 ? 3 : 0.8)
            }
            if shape.baseFret > 1 {
                context.draw(Text("\(shape.baseFret)").font(.system(size: 11)).foregroundColor(XWTheme.muted),
                             at: CGPoint(x: 10, y: top + dy / 2))
            }
            for (i, fret) in shape.frets.enumerated() {
                let x = left + CGFloat(i) * dx
                if fret <= 0 {
                    context.draw(Text(fret < 0 ? "×" : "○").font(.system(size: 12)).foregroundColor(XWTheme.muted),
                                 at: CGPoint(x: x, y: top - 12))
                } else {
                    let y = top + (CGFloat(fret) - 0.5) * dy
                    context.fill(Path(ellipseIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14)), with: .color(XWTheme.accent))
                    let finger = shape.fingers[i]
                    if finger > 0 {
                        context.draw(Text("\(finger)").font(.system(size: 9, weight: .bold)).foregroundColor(XWTheme.accentInk),
                                     at: CGPoint(x: x, y: y))
                    }
                }
            }
        }
        .frame(width: 156, height: 155)
        .accessibilityLabel("吉他指法，从六弦到一弦：\(shape.frets.map { $0 < 0 ? "不弹" : $0 == 0 ? "空弦" : "\($0 + shape.baseFret - 1)品" }.joined(separator: "、"))")
    }
}

private struct ScoreEditContext: Identifiable {
    var id: UUID { chordID }
    var projectID: UUID
    var document: ScoreDocument
    var chordID: UUID
}

struct XWScoreView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var task: ScoreTask
    @ObservedObject var player: PracticePlayer
    @StateObject private var displayClock = PlaybackClock()
    @State private var follow = true
    @State private var showLyrics = true
    @State private var showFingers = true
    @State private var fontSize = 18.0
    @State private var editing: ScoreEditContext?
    @State private var confirmRegenerate = false
    private var runningHere: Bool { task.running && task.projectID == workspace.currentProject?.id }

    var body: some View {
        VStack(spacing: 14) {
            header
            if let error = task.error, task.errorProjectID == workspace.currentProject?.id {
                XWIssueBanner(message: error) { task.error = nil }
            }
            if runningHere { generationProgress }
            if let score = workspace.currentScore {
                toolbar(score)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        XWScoreRhythm(workspace: workspace, player: player, clock: displayClock, score: score, bpm: score.estimatedBPM)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                        Divider().overlay(XWTheme.line)
                        XWScoreRows(workspace: workspace, clock: displayClock, score: score,
                                    rows: score.rows(lyrics: showLyrics ? workspace.currentProject?.lyrics : nil),
                                    follow: $follow, fontSize: fontSize, pitch: player.pitch, edit: edit)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(XWTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(XWTheme.line))
                    if showFingers {
                        XWScoreNow(clock: displayClock, offset: workspace.listeningToResult ? workspace.manifest?.start ?? 0 : 0,
                                   score: score, pitch: player.pitch)
                            .frame(width: 190, alignment: .top)
                    }
                }
            } else {
                emptyState
            }
        }
        .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 15)
        .onReceive(player.clock.$time) { value in
            if workspace.showingScore { displayClock.synchronize(value) }
        }
        .onReceive(player.clock.$time.debounce(for: .milliseconds(120), scheduler: RunLoop.main)) { value in
            // Prepare a parked page after a paused seek, without replaying intermediate range resets.
            if !workspace.showingScore { displayClock.synchronize(value) }
        }
        .onChange(of: workspace.showingScore) { _, visible in
            if visible { displayClock.synchronize(player.clock.time) }
        }
        // An interrupted exit can finish after a new score page has opened.
        .onDisappear { if !workspace.showingScore { player.configureBeatGuide([]) } }
        .sheet(item: $editing) { context in
            XWScoreEdit(workspace: workspace, context: context, done: { editing = nil })
                .preferredColorScheme(.dark)
        }
        .alert("重新识别这段音乐？", isPresented: $confirmRegenerate) {
            Button("保留当前乐谱", role: .cancel) { }
            Button("重新识别") { workspace.generateScore() }
        } message: {
            Text("新结果生成成功后，会替换这首歌当前的和弦和修改。失败或取消时保留当前乐谱。可先导出保存。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if workspace.currentScore != nil {
                Button { confirmRegenerate = true } label: {
                    Label { Text("重新识别") } icon: { Image(systemName: "arrow.clockwise").foregroundStyle(XWTheme.accent) }
                }
                    .buttonStyle(XWButtonStyle(kind: .secondary)).fixedSize()
                    .disabled(!workspace.readyToRun).help("使用原曲页当前已完成的选段")
                    .accessibilityIdentifier("xw.score.regenerate")
                Rectangle().fill(XWTheme.line).frame(width: 1, height: 24)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.currentTitle).font(.system(size: 19, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail).help(workspace.currentTitle)
                Text("弹唱谱 · 专注练习").font(.system(size: 11)).foregroundStyle(XWTheme.muted)
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Button { workspace.closeScore() } label: {
                Label { Text("返回音轨") } icon: { Image(systemName: "chevron.left").foregroundStyle(XWTheme.accent) }
            }
                .buttonStyle(XWButtonStyle(kind: .secondary)).fixedSize()
                .help("返回音轨，继续试听和分离")
                .accessibilityIdentifier("xw.score.back")
            if workspace.currentScore != nil {
                Menu {
                    Button("导出 PDF…") { workspace.exportScore(pdf: true) }
                    Button("导出 ChordPro…") { workspace.exportScore(pdf: false) }
                    Button("复制带时间的和弦与歌词") {
                        guard let project = workspace.currentProject, let score = project.score else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(score.chordPro(title: project.title, lyrics: project.lyrics, pitch: player.pitch), forType: .string)
                    }
                    if let url = workspace.scoreExportURL {
                        Button("显示刚才导出的乐谱") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                } label: { Label("导出乐谱", systemImage: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize().padding(10)
                .background(XWTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("xw.score.export")
            }
        }.frame(minHeight: 45)
    }

    private var generationProgress: some View {
        HStack(spacing: 12) {
            ProgressView(value: task.progress).frame(maxWidth: 180)
            Text(task.message).font(.system(size: 11)).foregroundStyle(XWTheme.accent)
            Spacer()
            Text("\(Int(task.progress * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(XWTheme.muted)
            Button(task.cancelling ? "正在取消" : "取消", action: task.cancel)
                .buttonStyle(XWButtonStyle(compact: true)).disabled(task.cancelling)
        }.padding(12).background(XWTheme.raised, in: RoundedRectangle(cornerRadius: 9))
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            Image(systemName: "guitars").font(.system(size: 38, weight: .light)).foregroundStyle(XWTheme.accent)
            Text(runningHere ? "正在从音乐里整理和弦" : "把这首歌，变成可跟弹的谱")
                .font(.system(size: 22, weight: .semibold))
            Text("识别和弦与切换时间，配上指法图和已有歌词。\n生成后可以校正和弦、慢速播放、循环练习和导出。")
                .font(.system(size: 13)).foregroundStyle(XWTheme.muted).multilineTextAlignment(.center).lineSpacing(7)
            Label("原曲 · \(xwRange(workspace.range, duration: workspace.currentProject?.source.duration))", systemImage: "waveform")
                .font(.system(size: 12)).padding(12).background(XWTheme.raised, in: RoundedRectangle(cornerRadius: 8))
            if workspace.sourceIssue != nil {
                Text(workspace.sourceChecking ? "正在核对原音频…" : "请返回音轨页重新定位原音频后生成。")
                    .font(.system(size: 12)).foregroundStyle(XWTheme.accent)
            }
            if !runningHere {
                Button(action: workspace.generateScore) { Label("生成弹唱谱", systemImage: "sparkles").frame(minWidth: 140) }
                    .buttonStyle(XWButtonStyle(kind: .primary)).disabled(!workspace.readyToRun)
                    .accessibilityIdentifier("xw.score.generate")
            }
            Text("本机生成 · 无按首费用 · 范围沿用原曲页")
                .font(.system(size: 10)).foregroundStyle(XWTheme.dim)
            Spacer(minLength: 30)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(XWTheme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(XWTheme.line))
    }

    private func toolbar(_ score: ScoreDocument) -> some View {
        HStack(spacing: 12) {
            Toggle("跟随", isOn: $follow)
                .help("连续跟随播放；手动滚动会暂停跟随，重新勾选即可回到当前")
                .accessibilityIdentifier("xw.score.follow")
            Toggle("歌词", isOn: $showLyrics).disabled(workspace.currentProject?.lyrics == nil)
            Toggle("指法", isOn: $showFingers)
            Spacer(minLength: 5)
            Text("变调夹").foregroundStyle(XWTheme.muted)
            Picker("变调夹", selection: Binding(get: { score.capo }, set: { value in
                var updated = score; updated.capo = value
                do { try workspace.saveScore(updated, replacing: score) } catch { task.report(error.localizedDescription, projectID: workspace.currentProject?.id) }
            })) {
                ForEach(0..<12) { Text($0 == 0 ? "不用" : "\($0) 品").tag($0) }
            }.labelsHidden().frame(width: 72).disabled(runningHere).accessibilityIdentifier("xw.score.capo")
            Text("速度").foregroundStyle(XWTheme.muted)
            Picker("练习速度", selection: $player.speed) {
                ForEach([0.5, 0.75, 0.9, 1.0], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
            }.labelsHidden().frame(width: 72)
            Picker("升降调", selection: $player.pitch) {
                ForEach(-6...6, id: \.self) { Text($0 == 0 ? "原调" : "\($0 > 0 ? "+" : "")\($0) 半音").tag($0) }
            }.frame(width: 114)
            Stepper("字号", value: $fontSize, in: 16...24, step: 2).fixedSize()
            if player.loop {
                Button("结束循环") { player.clearLoop() }.buttonStyle(XWButtonStyle(kind: .selected, compact: true))
            }
        }
        .toggleStyle(.checkbox).font(.system(size: 11)).controlSize(.small)
        .padding(.vertical, 4)
    }

    private func edit(_ id: UUID) {
        guard !runningHere, let project = workspace.currentProject, let score = project.score else { return }
        editing = ScoreEditContext(projectID: project.id, document: score, chordID: id)
    }
}

private struct XWScoreRows: View {
    @ObservedObject var workspace: Workspace
    var clock: PlaybackClock
    var score: ScoreDocument
    var rows: [ScoreRow]
    @Binding var follow: Bool
    var fontSize: Double
    var pitch: Int
    var edit: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var time = 0.0
    @State private var frames: [Double: CGRect] = [:]
    private var offset: Double { workspace.listeningToResult ? workspace.manifest?.start ?? 0 : 0 }
    private var active: Double? { rows.first { time >= $0.start && time < $0.end }?.start }
    var body: some View {
        let lookup = Dictionary(uniqueKeysWithValues: score.chords.map { ($0.id, $0) })
        Group {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button { workspace.scoreSeek(row.start) } label: {
                                    Text(xwTime(row.start, precise: true)).font(.system(size: 10, design: .monospaced))
                                }.buttonStyle(.plain).foregroundStyle(XWTheme.muted)
                                Text("\(row.chordIDs.compactMap { lookup[$0] }.filter { $0.label != "N.C." }.count) 个和弦")
                                    .font(.system(size: 9)).foregroundStyle(XWTheme.dim)
                                Spacer()
                                Button { workspace.scoreLoop(row) } label: { Label("循环这句", systemImage: "repeat") }
                                    .buttonStyle(XWButtonStyle(kind: .quiet, compact: true))
                                    .help("设置这句的 A/B 循环，再按播放")
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], alignment: .leading, spacing: 8) {
                                ForEach(row.chordIDs, id: \.self) { id in
                                    if let chord = lookup[id] {
                                        XWScoreChordCard(clock: clock, offset: offset, chord: chord, rowStart: row.start, rowEnd: row.end,
                                                         symbol: GuitarChord(chord.label)?.transposed(pitch - score.capo) ?? chord.label,
                                                         seek: { workspace.scoreSeek(max(row.start, chord.start)) }, edit: { edit(id) })
                                    }
                                }
                                // Reserve the cue after the last chord, before the phrase ends; playback never inserts a new cell.
                                if let last = row.chordIDs.last.flatMap({ lookup[$0] }),
                                   last.label != "N.C.", last.end > row.end + 0.001 {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.right")
                                        Text("继续按同一和弦").fixedSize(horizontal: false, vertical: true)
                                    }
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(XWTheme.accent)
                                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("继续按同一和弦，下一句保持手指位置继续弹")
                                    .accessibilityIdentifier("xw.score.continuation.\(Int((row.start * 1000).rounded()))")
                                    .help("下一句延续这个和弦，保持手指位置继续弹")
                                }
                            }
                            if !row.text.isEmpty {
                                Text(row.text).font(.system(size: fontSize, weight: .medium))
                                    .lineSpacing(7).fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .foregroundStyle(active == row.id ? XWTheme.text : XWTheme.muted)
                                    .accessibilityIdentifier("xw.score.lyric.\(Int((row.start * 1000).rounded()))")
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(active == row.id ? XWTheme.accent.opacity(0.07) : XWTheme.raised.opacity(0.35))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: active == row.id))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active == row.id ? XWTheme.accent.opacity(0.32) : .clear)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: active == row.id))
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ScoreRowFrames.self, value: [row.id: geometry.frame(in: .named("score-rows"))])
                        })
                        .id(row.id)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("xw.score.row.\(Int((row.start * 1000).rounded()))")
                    }
                }.padding(14)
                    .coordinateSpace(name: "score-rows")
                    .background(XWScoreFollowBridge(clock: clock, offset: offset, rows: rows, frames: frames,
                                                   follow: follow && workspace.showingScore, reduceMotion: reduceMotion, onManualScroll: { follow = false }))
                    .onPreferenceChange(ScoreRowFrames.self) { frames = $0 }
            }
            .onReceive(clock.$time) { value in
                let next = value + offset
                let row = rows.first { next >= $0.start && next < $0.end }?.id
                if row != active || score.activeIndex(at: next) != score.activeIndex(at: time) { time = next }
            }
        }.accessibilityIdentifier("xw.score.sheet")
    }
}

private struct XWScoreNow: View {
    var clock: PlaybackClock
    var offset: Double
    var score: ScoreDocument
    var pitch: Int
    @State private var position = 0
    @State private var shownTime = 0.0
    private var index: Int? { score.activeIndex(at: shownTime + offset) }
    private var symbol: String { index.flatMap { GuitarChord(score.chords[$0].label)?.transposed(pitch - score.capo) } ?? "N.C." }
    private var shapes: [GuitarShape] { GuitarShapes.all[symbol] ?? [] }
    var body: some View {
        ScrollView {
        VStack(spacing: 14) {
            Text("当前指法").font(.system(size: 11)).foregroundStyle(XWTheme.muted)
            Text(symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(XWTheme.accent)
                .lineLimit(1).minimumScaleFactor(0.5).accessibilityIdentifier("xw.score.currentChord")
            if !shapes.isEmpty {
                XWGuitarDiagram(shape: shapes[min(position, shapes.count - 1)])
                if shapes.count > 1 {
                    Button("换个把位 \(min(position + 1, shapes.count))/\(shapes.count)") { position = (position + 1) % shapes.count }
                        .buttonStyle(XWButtonStyle(kind: .quiet, compact: true))
                }
                Text("数字为手指，○ 空弦，× 不弹\n左侧为六弦，右侧为一弦")
                    .font(.system(size: 10)).foregroundStyle(XWTheme.dim).multilineTextAlignment(.center).lineSpacing(4)
            } else {
                Text(symbol == "N.C." ? "这一段暂无和弦" : "暂无此和弦的指法图\n可听音后修改和弦")
                    .font(.system(size: 12)).foregroundStyle(XWTheme.muted).multilineTextAlignment(.center).frame(height: 150)
            }
            Divider().overlay(XWTheme.line)
            Text(score.capo == 0 ? "原调指法" : "变调夹夹 \(score.capo) 品\n指法已换算")
                .font(.system(size: 11)).foregroundStyle(XWTheme.muted).multilineTextAlignment(.center)
            if let index, index + 1 < score.chords.count {
                Text("接下来  \(GuitarChord(score.chords[index+1].label)?.transposed(pitch-score.capo) ?? "")")
                    .font(.system(size: 12)).foregroundStyle(XWTheme.text)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        }.frame(maxHeight: .infinity)
        .background(XWTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(XWTheme.line))
        .onChange(of: symbol) { _, _ in position = 0 }
        .onReceive(clock.$time) { value in
            if score.activeIndex(at: value + offset) != index { shownTime = value }
        }
    }
}

private struct XWScoreEdit: View {
    @ObservedObject var workspace: Workspace
    var context: ScoreEditContext
    var done: () -> Void
    @State private var label = ""
    @State private var start = ""
    @State private var issue: String?
    private var chord: ScoreChord { context.document.chords.first { $0.id == context.chordID }! }
    private var first: Bool { context.document.chords.first?.id == context.chordID }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("修改和弦").font(.system(size: 19, weight: .semibold))
            Text("填写原调和弦，例如 C、Am、G7 或 D/F#。\n变调夹会自动换算页面上的指法。")
                .font(.system(size: 12)).foregroundStyle(XWTheme.muted).lineSpacing(5)
            HStack {
                Text("原调和弦").frame(width: 75, alignment: .leading)
                TextField("如 Am7", text: $label).textFieldStyle(.roundedBorder).accessibilityIdentifier("xw.score.edit.label")
            }
            HStack {
                Text("开始秒数").frame(width: 75, alignment: .leading)
                TextField("秒", text: $start).textFieldStyle(.roundedBorder).disabled(first)
                Stepper("微调", onIncrement: { shift(0.1) }, onDecrement: { shift(-0.1) }).labelsHidden().disabled(first)
            }
            Text("识别值：\(chord.originalLabel) · \(xwTime(chord.originalStart, precise: true))")
                .font(.system(size: 11)).foregroundStyle(XWTheme.dim)
            if let issue { Text(issue).font(.system(size: 11)).foregroundStyle(XWTheme.danger) }
            HStack {
                Button("恢复识别值") { label = chord.originalLabel; start = String(format: "%.3f", chord.originalStart) }
                    .buttonStyle(XWButtonStyle(kind: .quiet, compact: true))
                Spacer()
                Button("取消", action: done).buttonStyle(XWButtonStyle(compact: true)).keyboardShortcut(.cancelAction)
                Button("保存", action: save).buttonStyle(XWButtonStyle(kind: .primary, compact: true)).keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 12)).padding(24).frame(width: 420)
            .background(XWTheme.panel).foregroundStyle(XWTheme.text)
            .onAppear { label = chord.label; start = String(format: "%.3f", chord.start) }
    }
    private func shift(_ delta: Double) {
        if let value = Double(start) { start = String(format: "%.3f", value + delta) }
    }
    private func save() {
        guard workspace.currentProject?.id == context.projectID else { issue = "项目已切换，请回到原项目后修改。"; return }
        guard let parsed = GuitarChord(label), let time = Double(start), time.isFinite else {
            issue = "请填写有效和弦和秒数，例如 Am7、16.5。"; return
        }
        var doc = context.document
        guard let i = doc.chords.firstIndex(where: { $0.id == context.chordID }) else { return }
        do {
            doc.chords[i].label = parsed.transposed(0)
            if !first { try doc.moveBoundary(id: context.chordID, to: time) }
            try workspace.saveScore(doc, replacing: context.document)
            done()
        } catch { issue = error.localizedDescription }
    }
}
