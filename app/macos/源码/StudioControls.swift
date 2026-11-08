import AppKit
import SwiftUI

struct XWRangeEditor: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var input = XWRangeInputState()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 8) {
                Button(action: workspace.beginRange) { Label("选段", systemImage: "viewfinder") }
                    .buttonStyle(XWButtonStyle(kind: workspace.rangeEditing ? .selected : .quiet, compact: true))
                    .disabled(!workspace.canEditRange || workspace.rangeEditing)
                    .accessibilityIdentifier("xw.range.begin")
                XWSecondsField(label: "开始", text: $input.startText) { _ = commitPair() }
                    .disabled(!workspace.rangeEditing)
                XWSecondsField(label: "结束", text: $input.endText) { _ = commitPair() }
                    .disabled(!workspace.rangeEditing)
                if geometry.size.width >= 700 {
                    Text(durationText)
                        .font(.system(size: 10)).foregroundStyle(XWTheme.color(0xa69b8c)).lineLimit(1)
                        .frame(width: 75, alignment: .leading)
                }
                Spacer(minLength: 4)
                Button("恢复整首", action: workspace.clearRange)
                    .buttonStyle(XWButtonStyle(kind: .quiet, compact: true))
                    .disabled(!workspace.canEditRange || !workspace.rangeEditing && !workspace.hasCustomRange)
                    .accessibilityIdentifier(workspace.rangeEditing ? "xw.range.reset.editor" : "xw.range.reset")
                Button("试听") { commitAndPerform(workspace.previewDraft) }
                    .buttonStyle(XWButtonStyle(compact: true))
                    .disabled(!workspace.rangeEditing)
                    .accessibilityIdentifier("xw.range.preview")
                Button("取消", action: workspace.cancelRange)
                    .buttonStyle(XWButtonStyle(compact: true))
                    .disabled(!workspace.rangeEditing)
                    .accessibilityIdentifier("xw.range.cancel")
                Button("完成") { commitAndPerform(workspace.applyRange) }
                    .buttonStyle(XWButtonStyle(kind: .primary, compact: true))
                    .disabled(!workspace.rangeEditing)
                    .accessibilityIdentifier("xw.range.apply")
            }
            .padding(.horizontal, 9).frame(height: 43)
        }
        .frame(height: 43)
        .help("完成后，下一次分离只处理这段声音。支持秒数或分:秒。")
        .background(XWTheme.color(0x242019), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(XWTheme.color(0x4a3e31)))
        .overlay(alignment: .bottomLeading) {
            if workspace.rangeEditing, let error = workspace.draftError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(XWTheme.danger)
                    .padding(6).background(XWTheme.raised, in: RoundedRectangle(cornerRadius: 5))
                    .offset(y: 27).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("xw.range.editor")
        .onReceive(workspace.$draftRange) { range in
            if workspace.rangeEditing { synchronize(range) }
        }
        .onReceive(workspace.$range) { range in if !workspace.rangeEditing { synchronize(range) } }
        .onChange(of: workspace.rangeEditing) { _, editing in synchronize(editing ? workspace.draftRange : workspace.range, force: true) }
        .onChange(of: workspace.currentProject?.id) { _, _ in synchronize(workspace.range, force: true) }
    }

    private func synchronize(_ range: ClosedRange<Double>, force: Bool = false) {
        input.synchronize(range, maximum: workspace.source?.duration ?? workspace.currentProject?.source.duration, force: force)
    }

    private var durationText: String {
        guard let pair = input.parsedPair, pair.end > pair.start else { return "范围待修正" }
        return "共 \(xwTime(pair.end - pair.start, precise: true))"
    }

    @discardableResult
    private func commitPair() -> Bool {
        guard workspace.rangeEditing else { return false }
        input.committing = true
        defer { input.committing = false }
        guard let pair = input.parsedPair else {
            workspace.updateDraft(.nan, .nan)
            return false
        }
        workspace.updateDraft(pair.start, pair.end)
        guard workspace.rangeValid && workspace.draftRange.lowerBound == pair.start && workspace.draftRange.upperBound == pair.end else { return false }
        input.acknowledge(workspace.draftRange)
        return true
    }

    private func commitAndPerform(_ action: @escaping () -> Void) {
        let window = NSApp.keyWindow
        window?.makeFirstResponder(nil)
        window?.endEditing(for: nil)
        DispatchQueue.main.async {
            guard commitPair() else { return }
            action()
        }
    }
}

private final class XWRangeInputState: ObservableObject {
    @Published var startText = ""
    @Published var endText = ""
    var committing = false
    private var lastObservedRange: ClosedRange<Double>?

    var parsedPair: (start: Double, end: Double)? {
        guard let start = Self.seconds(startText), let end = Self.seconds(endText) else { return nil }
        return (start, end)
    }

    func synchronize(_ range: ClosedRange<Double>, maximum: Double?, force: Bool = false) {
        guard force || lastObservedRange != range else { return }
        lastObservedRange = range
        guard !committing else { return }
        startText = Self.format(range.lowerBound)
        endText = Self.format(range.upperBound, maximum: maximum)
    }

    func acknowledge(_ range: ClosedRange<Double>) {
        lastObservedRange = range
    }

    private static func format(_ seconds: Double, maximum: Double? = nil) -> String {
        var text = String(format: "%.6f", seconds)
        if let maximum, let rounded = Double(text), rounded > maximum { text = String(seconds) }
        while let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 3, text.last == "0" {
            text.removeLast()
        }
        return text
    }

    private static func seconds(_ text: String) -> Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        let parsed: Double?
        if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]),
           minutes.isFinite, minutes >= 0, minutes.rounded(.towardZero) == minutes,
           seconds.isFinite, seconds >= 0, seconds < 60 {
            parsed = minutes * 60 + seconds
        } else if parts.count == 1 { parsed = Double(input) }
        else { parsed = nil }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }
}

private struct XWSecondsField: View {
    let label: String
    @Binding var text: String
    let commitValue: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundStyle(XWTheme.color(0x8e867a))
            TextField(label, text: $text)
                .font(.system(size: 11, design: .monospaced)).textFieldStyle(.plain)
                .padding(.horizontal, 7).frame(width: 76, height: 29)
                .background(XWTheme.color(0x1b1b17), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? XWTheme.accent : XWTheme.color(0x4a443a), lineWidth: focused ? 1.5 : 1))
                .focused($focused)
                .accessibilityLabel("\(label)秒数")
                .accessibilityIdentifier(label == "开始" ? "xw.range.start" : "xw.range.end")
                .onSubmit(commitValue)
                .onChange(of: focused) { _, active in if !active { commitValue() } }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct XWProcessingView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().stroke(XWTheme.color(0x4a4035), lineWidth: 1).frame(width: 50, height: 50)
                if !reduceMotion { ProgressView().controlSize(.large).tint(XWTheme.accent) }
                else { Image(systemName: "square.stack.3d.up").font(.system(size: 21)).foregroundStyle(XWTheme.accent) }
            }.padding(.bottom, 15)
            Text(workspace.status).font(.system(size: 14, weight: .semibold))
                .lineLimit(2).multilineTextAlignment(.center)
            Text("原曲和这项分离已有的结果可以继续试听")
                .font(.system(size: 11)).foregroundStyle(XWTheme.dim).padding(.top, 7).padding(.bottom, 15)
            if let progress = workspace.progress {
                ProgressView(value: progress).progressViewStyle(.linear).tint(XWTheme.accent).frame(width: 240)
            }
            HStack {
                Text(XWMode.resolve(workspace.mode).title)
                Spacer()
                if let progress = workspace.progress { Text("\(Int(progress * 100))%") }
                else { Text("已用 \(xwTime(workspace.elapsed))") }
            }
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(XWTheme.dim)
            .frame(width: 240).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .accessibilityElement(children: .combine)
    }
}

struct XWPlayerBar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var player: PracticePlayer
    let openExport: () -> Void

    var body: some View {
        HStack(spacing: 15) {
            status.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button(action: workspace.togglePlayback) {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold)).frame(width: 42, height: 42)
                }
                .buttonStyle(XWButtonStyle(kind: .play))
                .disabled(player.tracks.isEmpty || workspace.sourceIssue != nil && !workspace.listeningToResult)
                .help("播放或暂停（空格）")
                .accessibilityLabel(player.playing ? "暂停" : "播放")
                XWClockReadout(clock: player.clock, offset: workspace.listeningToResult ? workspace.manifest?.start ?? 0 : 0,
                               end: workspace.showingScore ? workspace.currentScore?.range.end ?? workspace.range.upperBound : workspace.rangeEditing ? workspace.draftRange.upperBound :
                                workspace.listeningToResult ? workspace.manifest?.end ?? 0 : workspace.range.upperBound)
                HStack(spacing: 6) {
                    Image(systemName: player.volume == 0 ? "speaker.slash" : "speaker.wave.1")
                        .font(.system(size: 12)).foregroundStyle(XWTheme.dim)
                    Slider(value: $player.volume, in: 0...1)
                        .controlSize(.mini).frame(width: 62).tint(XWTheme.accent).accessibilityLabel("试听音量")
                }
            }.fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 8) {
                if workspace.busy {
                    Button(workspace.cancelling || workspace.scoreTask.cancelling ? "正在取消" : "取消", action: workspace.cancel)
                        .buttonStyle(XWButtonStyle()).disabled(workspace.cancelling || workspace.scoreTask.cancelling)
                }
                if !workspace.showingScore {
                    Button {
                        if workspace.canExportCurrentSelection { openExport() }
                        else { workspace.start() }
                    } label: {
                        Label(workspace.rangeEditing ? "先完成选段" : workspace.mainActionLabel,
                              systemImage: workspace.canExportCurrentSelection ? "square.and.arrow.up" : "sparkles")
                            .frame(minWidth: 105)
                    }
                    .buttonStyle(XWButtonStyle(kind: .primary))
                    .disabled(workspace.busy || workspace.rangeEditing || workspace.importing ||
                              !workspace.readyToRun && !workspace.canExportCurrentSelection)
                    .accessibilityIdentifier("xw.player.primary")
                }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 28).frame(height: 79)
        .background(XWTheme.bar)
        .overlay(alignment: .top) { Rectangle().fill(XWTheme.line.opacity(0.75)).frame(height: 1) }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle().fill(workspace.error != nil ? XWTheme.danger : workspace.canExportCurrentSelection ? XWTheme.green : XWTheme.dim).frame(width: 6, height: 6)
                Text(statusTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            HStack(spacing: 6) {
                if workspace.scoreTask.running {
                    Text("\(Int(workspace.scoreTask.progress * 100))% · 本机生成")
                } else if workspace.busy {
                    if let progress = workspace.progress { Text("\(Int(progress * 100))% ·") }
                    Text("已用 \(xwTime(workspace.elapsed))")
                } else if !workspace.showingScore && workspace.lastExport != nil && workspace.canExportCurrentSelection && !workspace.rangeEditing {
                    Button("在 Finder 中显示", action: workspace.revealExport)
                        .buttonStyle(.plain).foregroundStyle(XWTheme.accent).help(workspace.lastExport?.path ?? "")
                } else {
                    Text(statusDetail).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.system(size: 10)).foregroundStyle(XWTheme.dim)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        if workspace.scoreTask.running && workspace.scoreTask.projectID != workspace.currentProject?.id {
            return "另一首歌正在生成弹唱谱"
        }
        if workspace.scoreTask.running { return workspace.scoreTask.message }
        if workspace.showingScore {
            if workspace.scoreTask.running { return workspace.scoreTask.message }
            return workspace.currentScore == nil ? "准备生成弹唱谱" : "弹唱参考谱 · 可以边听边校正"
        }
        if workspace.busy { return workspace.status }
        if workspace.rangeEditing { return "正在选择处理范围" }
        if workspace.lastExport != nil && workspace.canExportCurrentSelection { return "所选音轨已保存" }
        if workspace.status.contains("取消") { return workspace.status }
        if workspace.canExportCurrentSelection { return "分离完成，挑想保存的音轨" }
        if workspace.error != nil { return "这次没有完成，可以重试" }
        return "项目已创建，可以先听原曲"
    }

    private var statusDetail: String {
        if workspace.showingScore {
            if let score = workspace.currentScore { return "\(xwRange(score.range.closedRange)) · 本机生成 · \(String(format: "%.1f", score.elapsed)) 秒" }
            return "使用原曲页的已完成选段 · 本机处理"
        }
        if workspace.rangeEditing { return "选段 \(xwRange(workspace.draftRange)) · 完成后用于分离" }
        if workspace.status.hasPrefix("已移到") { return workspace.status }
        if workspace.canExportCurrentSelection, let manifest = workspace.manifest {
            return "\(manifest.tracks.count) 条音轨 · \(xwRange(manifest.start...manifest.end, duration: workspace.currentProject?.source.duration)) · 可同时独奏多轨"
        }
        return "\(xwRange(workspace.range, duration: workspace.currentProject?.source.duration)) · \(XWMode.resolve(workspace.mode).detail)"
    }
}

private struct XWClockReadout: View {
    @ObservedObject var clock: PlaybackClock
    let offset: Double
    let end: Double
    var body: some View {
        HStack(spacing: 5) {
            Text(xwTime(clock.time + offset, precise: true)).foregroundStyle(XWTheme.text)
            Text("/ \(xwTime(end, precise: true))").foregroundStyle(XWTheme.muted)
        }
        .font(.system(size: 11, design: .monospaced)).monospacedDigit()
        .frame(minWidth: 119, alignment: .leading)
        .accessibilityLabel("播放到 \(xwTime(clock.time + offset, precise: true))，结束 \(xwTime(end, precise: true))")
    }
}

struct XWExportSheet: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: StudioViewState
    private var tracks: [Manifest.Row] { workspace.manifest?.tracks ?? [] }
    private var allSelected: Bool { !tracks.isEmpty && state.exportTracks == Set(tracks.map(\.id)) }
    private var bodyHeight: CGFloat {
        let content = CGFloat(tracks.count) * 44 + 166 + (workspace.error == nil ? 0 : 80) + (workspace.exporting ? 60 : 0)
        let available = max(220, min(440, (NSApp.mainWindow?.frame.height ?? 740) - 250))
        return min(content, available)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let url = state.exportSuccess { success(url) }
            else {
                header
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 15) {
                        if let error = workspace.error {
                            XWIssueBanner(message: error) { workspace.error = nil }
                        }
                        HStack {
                            Text("选择音轨").font(.system(size: 11)).foregroundStyle(XWTheme.muted)
                            Spacer()
                            Button(allSelected ? "取消全选" : "全选") {
                                state.exportTracks = allSelected ? [] : Set(tracks.map(\.id))
                            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(XWTheme.accent)
                                .disabled(workspace.exporting)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                Toggle(isOn: Binding(get: { state.exportTracks.contains(track.id) }, set: { selected in
                                    if selected { state.exportTracks.insert(track.id) }
                                    else { state.exportTracks.remove(track.id) }
                                })) {
                                    HStack(spacing: 9) {
                                        Circle().fill(XWTheme.trackColor(track.id)).frame(width: 6, height: 6)
                                        Text(track.label).font(.system(size: 12)).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(XWTheme.trackDetail(track.id)).font(.system(size: 10)).foregroundStyle(XWTheme.dim).lineLimit(1)
                                    }.padding(.leading, 6)
                                }
                                .toggleStyle(.checkbox).tint(XWTheme.accent)
                                .accessibilityLabel(track.label)
                                .padding(.horizontal, 12).frame(height: 43)
                                .disabled(workspace.exporting)
                                if index < tracks.count - 1 { Rectangle().fill(XWTheme.line.opacity(0.65)).frame(height: 1) }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(XWTheme.line))
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("音频格式").font(.system(size: 10)).foregroundStyle(XWTheme.dim)
                                Picker("音频格式", selection: $workspace.format) {
                                    Text("WAV · 24 位").tag("wav24")
                                    Text("WAV · 16 位").tag("wav16")
                                    Text("FLAC · 24 位无损").tag("flac")
                                    Text("MP3 · 320 kbps").tag("mp3")
                                }.labelsHidden().pickerStyle(.menu).controlSize(.regular).frame(maxWidth: .infinity)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 7) {
                                Text("保存位置").font(.system(size: 10)).foregroundStyle(XWTheme.dim)
                                Button(action: workspace.chooseExportDirectory) {
                                    Label(workspace.exportDirectory?.lastPathComponent ?? "选择文件夹…", systemImage: "folder")
                                        .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(XWButtonStyle(compact: true))
                                    .help(workspace.exportDirectory?.path ?? "导出时选择 Finder 保存位置")
                                    .accessibilityLabel("保存位置，\(workspace.exportDirectory?.path ?? "尚未选择")")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.disabled(workspace.exporting)
                        Text("导出保持原速、原调。试听时的静音与独奏不会影响文件。")
                            .font(.system(size: 10)).foregroundStyle(XWTheme.dim)
                            .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                        if let gain = workspace.manifest?.engineGainDB, gain < -0.05 {
                            Label(String(format: "整组音轨共同降低 %.1f dB，保留相对音量", -gain), systemImage: "info.circle")
                                .font(.system(size: 10)).foregroundStyle(XWTheme.muted)
                        }
                        if workspace.exporting {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(workspace.status).font(.system(size: 11))
                                if let progress = workspace.progress { ProgressView(value: progress).tint(XWTheme.accent) }
                                else { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: bodyHeight)
                .scrollIndicators(.automatic, axes: .vertical)
                footer
            }
        }
        .frame(width: 480)
        .foregroundStyle(XWTheme.text).background(XWTheme.color(0x1e1e1b))
        .onChange(of: workspace.lastExport) { _, url in
            if state.exportStarted, let url { state.exportSuccess = url; state.exportStarted = false }
        }
        .onChange(of: workspace.exporting) { _, active in
            if !active { state.exportStarted = false }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("保存想要的声音").font(.system(size: 20, weight: .semibold))
                Text(summary).font(.system(size: 11)).foregroundStyle(XWTheme.dim)
                    .lineLimit(1).truncationMode(.tail).help(summary).accessibilityLabel(summary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { state.exportPresented = false } label: { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 13) }
                .buttonStyle(XWButtonStyle(kind: .quiet, compact: true)).disabled(workspace.exporting)
                .accessibilityLabel("关闭导出")
        }
        .padding(.horizontal, 24).padding(.top, 23).padding(.bottom, 17)
        .overlay(alignment: .bottom) { Rectangle().fill(XWTheme.line).frame(height: 1) }
    }

    private var summary: String {
        guard let manifest = workspace.manifest else { return workspace.currentTitle }
        return "\(workspace.currentTitle) · \(XWMode.resolve(manifest.mode).title) · \(xwRange(manifest.start...manifest.end, duration: workspace.currentProject?.source.duration))"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(workspace.exporting ? "正在保存…" : "已选择 \(state.exportTracks.count) 条")
                .font(.system(size: 10)).foregroundStyle(XWTheme.dim)
            Spacer(minLength: 4)
            Button(workspace.exporting ? "取消导出" : "取消") {
                if workspace.exporting { workspace.cancel() }
                else { state.exportPresented = false }
            }.buttonStyle(XWButtonStyle()).keyboardShortcut(.cancelAction).disabled(workspace.cancelling)
            Button {
                state.exportStarted = true
                workspace.export(selected: state.exportTracks)
                if !workspace.exporting { state.exportStarted = false }
            } label: { Label("导出所选音轨", systemImage: "square.and.arrow.up") }
                .buttonStyle(XWButtonStyle(kind: .primary))
                .disabled(state.exportTracks.isEmpty || workspace.busy)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .overlay(alignment: .top) { Rectangle().fill(XWTheme.line).frame(height: 1) }
    }

    private func success(_ url: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark").font(.system(size: 25, weight: .medium)).foregroundStyle(XWTheme.green)
                .frame(width: 58, height: 58).background(XWTheme.green.opacity(0.08), in: Circle())
            Text("想要的声音，已保存").font(.system(size: 20, weight: .semibold))
            Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(url.path)
            Text(url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(XWTheme.dim)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if workspace.lastExportGainDB < -0.05 {
                Text(String(format: "导出时整组共同降低 %.1f dB，防止过载", -workspace.lastExportGainDB))
                    .font(.system(size: 10)).foregroundStyle(XWTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(XWButtonStyle())
                Button("完成") { state.exportPresented = false }
                    .buttonStyle(XWButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }.padding(.top, 8)
        }
        .padding(30).frame(maxWidth: .infinity)
    }
}

struct XWDeleteSheet: View {
    @ObservedObject var workspace: Workspace
    let deletion: XWDeletion
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "trash").font(.system(size: 19)).foregroundStyle(XWTheme.color(0xdf9483))
                .frame(width: 40, height: 40).background(XWTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                .padding(.bottom, 16)
            Text(deletion.kind == .project ? "删除这个项目？" : "删除这个文件夹？")
                .font(.system(size: 18, weight: .semibold)).padding(.bottom, 9)
            Text("「\(deletion.title)」" + (deletion.kind == .project ?
                 "将从弦外屋中移除。原始音频和已导出的文件不会受影响。" :
                 "文件夹将被移除，里面的项目会保留在「全部项目」中。"))
                .font(.system(size: 11)).foregroundStyle(XWTheme.muted).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: dismiss).buttonStyle(XWButtonStyle()).keyboardShortcut(.cancelAction)
                Button(deletion.kind == .project ? "删除项目" : "删除文件夹") {
                    if deletion.kind == .project { workspace.deleteProject(deletion.id) }
                    else { workspace.deleteFolder(deletion.id) }
                    dismiss()
                }.buttonStyle(XWButtonStyle(kind: .danger))
            }.padding(.top, 24)
        }
        .padding(25).frame(width: 400)
        .foregroundStyle(XWTheme.text).background(XWTheme.color(0x1e1e1b))
    }
}
