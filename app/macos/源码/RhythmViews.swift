import SwiftUI

struct XWScoreRhythm: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var player: PracticePlayer
    @ObservedObject var clock: PlaybackClock
    var score: ScoreDocument
    var bpm: Double?
    @State private var scrubbing = false
    @State private var scrubTime = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var time: Double { clock.time + (workspace.listeningToResult ? workspace.manifest?.start ?? 0 : 0) }
    private var shownTime: Double { min(score.range.end, max(score.range.start, scrubbing ? scrubTime : time)) }
    private var playbackBPM: Double? { bpm.map { $0 * player.speed } }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 10) {
                Label("节拍", systemImage: "metronome").font(.system(size: 11)).fixedSize()
                    .foregroundStyle(XWTheme.muted)
                Canvas { context, size in
                    guard !score.beats.isEmpty else {
                        context.draw(Text("暂无节拍").font(.system(size: 10)).foregroundColor(XWTheme.dim), at: CGPoint(x: size.width / 2, y: size.height / 2))
                        return
                    }
                    let middle = size.width / 2, y = size.height / 2
                    var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(XWTheme.line.opacity(0.7)), lineWidth: 1)
                    let state = score.beatState(at: shownTime)
                    let index = state.index ?? 0
                    for i in max(0, index - 4)..<min(score.beats.count, index + 6) where !reduceMotion {
                        let x = middle + (score.beats[i] - shownTime) * 54
                        guard x >= 3 && x <= size.width - 3 else { continue }
                        context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)),
                                     with: .color(XWTheme.accent.opacity(score.beats[i] >= shownTime ? 0.65 : 0.22)))
                    }
                    let pulse = state.previous.map { max(0, 1 - (shownTime - $0) / 0.16) } ?? 0
                    let radius = reduceMotion ? 5 : 5 + pulse * 3
                    context.fill(Path(ellipseIn: CGRect(x: middle - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                                 with: .color(XWTheme.accent.opacity(0.22 + pulse * 0.65)))
                }
                .frame(width: min(150, geometry.size.width * 0.22), height: 30)
                .accessibilityElement(children: .ignore).accessibilityLabel("节拍参考")
                .accessibilityValue(playbackBPM.map { "约 \(Int($0.rounded())) 拍每分钟" } ?? "暂无节拍参考")
                .accessibilityIdentifier("xw.score.rhythm")
                .help("根据音乐估计的节拍参考，亮点随音乐跳动")
                if geometry.size.width >= 700, let bpm = playbackBPM {
                    Text("≈\(Int(bpm.rounded())) 拍/分").font(.system(size: 9)).foregroundStyle(XWTheme.dim).fixedSize()
                        .accessibilityIdentifier("xw.score.bpm")
                }
                Toggle("鼓点声", isOn: $player.beatGuideEnabled).toggleStyle(.checkbox)
                    .font(.system(size: 11)).fixedSize().disabled(score.beats.isEmpty)
                    .accessibilityIdentifier("xw.score.drum")
                    .help("轻鼓点跟随节拍参考，可随时关闭；暂停和返回音轨会停止")
                Slider(value: Binding(get: { shownTime }, set: { value in
                    if scrubbing { scrubTime = value } else { workspace.scoreSeek(value) }
                }), in: score.range.start...score.range.end, onEditingChanged: { editing in
                    if editing { scrubTime = shownTime; scrubbing = true }
                    else { scrubbing = false; workspace.scoreSeek(scrubTime) }
                })
                .controlSize(.small).accessibilityLabel("乐谱播放位置")
                .help("整段进度；拖动松开后跳到对应位置")
                Text("\(xwTime(shownTime, precise: true)) / \(xwTime(score.range.end, precise: true))")
                    .font(.system(size: 9, design: .monospaced)).monospacedDigit().foregroundStyle(XWTheme.muted).fixedSize()
            }.frame(height: geometry.size.height)
        }.frame(height: 34)
    }
}

struct XWScoreChordCard: View {
    var clock: PlaybackClock
    var offset: Double
    var chord: ScoreChord
    var rowStart: Double
    var rowEnd: Double
    var symbol: String
    var seek: () -> Void
    var edit: () -> Void
    @State private var time = -Double.infinity
    private func isActive(at value: Double) -> Bool { value >= max(rowStart, chord.start) && value < min(rowEnd, chord.end) }
    private func fill(at value: Double) -> Double { chord.progress(at: value, within: rowStart...rowEnd) }
    private var carriesIn: Bool { chord.start < rowStart - 0.001 }
    private var carriesOut: Bool { chord.end > rowEnd + 0.001 }
    private var timeCaption: String {
        if active {
            let seconds = String(format: "%.1f", chord.remaining(at: time, within: rowStart...rowEnd))
            return carriesOut ? "本句余 \(seconds) 秒" : "\(carriesIn ? "续 · " : "")剩 \(seconds) 秒"
        }
        return "\(carriesIn ? "续 · " : "")\(xwTime(max(rowStart, chord.start), precise: true))"
    }
    private var active: Bool { isActive(at: time) }
    private var progress: Double { fill(at: time) }
    private var key: String { "\(chord.id.uuidString).\(Int((rowStart * 1000).rounded()))" }
    private var status: String {
        if active { return "\(carriesIn ? "继续按同一和弦，" : "")进行中 \(Int(progress * 100))%，\(timeCaption)\(carriesOut ? "，下一句继续同一和弦" : "")" }
        if progress >= 1 && carriesOut { return "100%，本句已完成，下一句继续同一和弦" }
        return progress >= 1 ? "已播放" : "未播放"
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: seek) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(symbol).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        if carriesIn || carriesOut {
                            Text("续").font(.system(size: 8)).foregroundStyle(XWTheme.dim)
                                .help(carriesIn ? "继续上一句的同一和弦，无需换指法" : "下一句继续这个和弦")
                        }
                    }
                    Text(timeCaption)
                        .font(.system(size: 9, design: .monospaced)).monospacedDigit().lineLimit(1)
                        .foregroundStyle(active ? XWTheme.accent : XWTheme.dim)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(symbol)，\(status)，\(xwTime(max(rowStart, chord.start), precise: true))")
            .accessibilityValue(status)
            .accessibilityIdentifier("xw.score.chord.\(key)")
            Button(action: edit) {
                Image(systemName: chord.edited ? "pencil.circle.fill" : "pencil").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(XWTheme.muted).help("修改原调和弦与切换时间")
                .accessibilityLabel("修改 \(chord.label)")
        }
        .foregroundStyle(active ? XWTheme.accent : time >= rowEnd || progress >= 1 ? XWTheme.muted : XWTheme.text)
        .padding(9)
        .background {
            GeometryReader { geometry in
                Canvas { context, size in
                    let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7)
                    context.fill(shape, with: .color(XWTheme.background.opacity(0.55)))
                    context.clip(to: shape)
                    context.fill(Path(CGRect(x: 0, y: 0, width: size.width * progress, height: size.height)),
                                 with: .color(XWTheme.accent.opacity(active ? 0.23 : 0.07)))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(active ? XWTheme.accent.opacity(0.55) : .clear))
        .accessibilityElement(children: .contain)
        .onReceive(clock.$time) { value in
            let next = value + offset
            if fill(at: next) != progress || isActive(at: next) != active { time = next }
        }
    }
}
