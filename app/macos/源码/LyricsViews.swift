import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LyricsEditorContext: Identifiable {
    let id = UUID()
    let projectID: UUID
    let original: LyricsDocument?
}

struct XWLyricsPanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var player: PracticePlayer
    let clock: PlaybackClock
    let close: () -> Void
    let edit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsPlayback = true
    @State private var dropTarget = false
    @State private var removing: LyricsEditorContext?
    @State private var active: Int?
    private var lyrics: LyricsDocument? { workspace.currentProject?.lyrics }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("歌词").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 2)
                if workspace.importingLyrics { ProgressView().controlSize(.small) }
                Button(lyrics == nil ? "导入" : "更换", action: workspace.chooseLyrics)
                    .buttonStyle(XWButtonStyle(kind: .quiet, compact: true)).disabled(workspace.importingLyrics)
                    .accessibilityIdentifier("xw.lyrics.import")
                Menu {
                    Button(lyrics == nil ? "粘贴带时间的歌词…" : "编辑歌词…", action: edit)
                    if lyrics != nil {
                        Button("导出为 LRC…", action: workspace.exportLyrics)
                        Button("清除整体偏移") {
                            if let lyrics { workspace.shiftLyrics(-lyrics.offsetMilliseconds) }
                        }.disabled(lyrics?.offsetMilliseconds == 0)
                        Divider()
                        Button("移除本项目歌词…", role: .destructive) {
                            if let project = workspace.currentProject {
                                removing = LyricsEditorContext(projectID: project.id, original: project.lyrics)
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 18, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("歌词操作")
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 18, height: 22) }
                    .buttonStyle(XWButtonStyle(kind: .quiet, compact: true))
                    .accessibilityLabel("收起歌词").accessibilityIdentifier("xw.lyrics.close")
            }.padding(.horizontal, 12).frame(height: 40)
            Divider().overlay(XWTheme.line)
            if let lyrics {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if active == nil {
                                Text("前奏，等待歌词").font(.system(size: 11)).foregroundStyle(XWTheme.dim)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                            }
                            ForEach(Array(lyrics.cues.enumerated()), id: \.element.id) { index, cue in
                                let position = lyrics.audioTime(for: cue)
                                Button {
                                    followsPlayback = true
                                    workspace.seekAbsolute(position)
                                } label: {
                                    HStack(alignment: .top, spacing: 9) {
                                        Text(xwTime(max(0, position))).font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(XWTheme.dim).frame(width: 31, alignment: .trailing).padding(.top, 3)
                                        Text(cue.text.isEmpty ? "间奏" : cue.text)
                                            .font(.system(size: 13, weight: active == index ? .semibold : .regular))
                                            .foregroundStyle(active == index ? XWTheme.accent : XWTheme.muted)
                                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(active == index ? XWTheme.accent.opacity(0.085) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).id(cue.id)
                                .accessibilityIdentifier("xw.lyrics.cue.\(cue.id)")
                                .disabled(player.tracks.isEmpty || !workspace.timeBounds.contains(position))
                                .accessibilityLabel("\(xwTime(max(0, position), precise: true))，\(cue.text.isEmpty ? "间奏" : cue.text)")
                                .accessibilityAddTraits(active == index ? .isSelected : [])
                                .help(workspace.timeBounds.contains(position) ? "点击跳到这一句" : "这一句在当前试听范围之外")
                            }
                        }.padding(7)
                    }
                    .accessibilityIdentifier("xw.lyrics.viewport")
                    .background {
                        GeometryReader { geometry in
                            Color.clear.onChange(of: geometry.size) { _, _ in
                                guard followsPlayback, let active, lyrics.cues.indices.contains(active) else { return }
                                // Adaptive layout preserves this panel; recenter when its viewport changes.
                                var transaction = Transaction(); transaction.disablesAnimations = true
                                withTransaction(transaction) { proxy.scrollTo(lyrics.cues[active].id, anchor: .center) }
                            }
                        }
                    }
                    .onChange(of: active) { _, index in
                        guard followsPlayback, let index, lyrics.cues.indices.contains(index) else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(lyrics.cues[index].id, anchor: .center) }
                    }
                    .onChange(of: followsPlayback) { _, follow in
                        if follow, let active, lyrics.cues.indices.contains(active) { proxy.scrollTo(lyrics.cues[active].id, anchor: .center) }
                    }
                    .onAppear { if let active, lyrics.cues.indices.contains(active) { proxy.scrollTo(lyrics.cues[active].id, anchor: .center) } }
                }
                HStack(spacing: 7) {
                    Toggle("跟随", isOn: $followsPlayback).toggleStyle(.checkbox).controlSize(.mini)
                        .accessibilityLabel("歌词跟随播放")
                    Spacer(minLength: 0)
                    Button("提前", action: { workspace.shiftLyrics(100) }).help("歌词提前 0.1 秒")
                    Button("延后", action: { workspace.shiftLyrics(-100) }).help("歌词延后 0.1 秒")
                    Text(String(format: "%+.1fs", Double(lyrics.offsetMilliseconds) / 1000))
                        .monospacedDigit().frame(minWidth: 35, alignment: .trailing)
                }
                .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(XWTheme.dim)
                .padding(.horizontal, 12).frame(height: 32)
                .overlay(alignment: .top) { Rectangle().fill(XWTheme.line).frame(height: 1) }
            } else {
                VStack(spacing: 7) {
                    Text("跟着音乐，逐句练唱").font(.system(size: 13, weight: .medium))
                    Text("导入已带时间的歌词，或粘贴带时间的文字。\n支持 LRC、TXT、Markdown 和 Word。")
                        .font(.system(size: 10)).foregroundStyle(XWTheme.dim).multilineTextAlignment(.center)
                    Button("粘贴歌词…", action: edit).buttonStyle(XWButtonStyle(kind: .quiet, compact: true))
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
            }
        }
        .frame(maxHeight: .infinity).background(XWTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .onReceive(clock.$time) { updateActive($0) }
        .onChange(of: lyrics) { _, _ in updateActive(clock.time) }
        .onChange(of: workspace.listeningToResult) { _, _ in updateActive(clock.time) }
        .onChange(of: workspace.manifest?.start) { _, _ in updateActive(clock.time) }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(dropTarget ? XWTheme.accent : XWTheme.line))
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            guard providers.count == 1, let provider = providers.first, !workspace.importingLyrics else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { workspace.importLyrics(url) }
            }
            return true
        }
        .alert("移除本项目的歌词？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("移除歌词", role: .destructive) {
                guard let context = removing else { return }
                do { try workspace.saveLyrics(nil, projectID: context.projectID, replacing: context.original) }
                catch { workspace.error = error.localizedDescription }
                removing = nil
            }
        } message: { Text("原始歌词文件会保留，可以随时重新导入。") }
    }

    private func updateActive(_ time: Double) {
        let offset = workspace.listeningToResult ? workspace.manifest?.start ?? 0 : 0
        let next = lyrics?.activeIndex(at: time + offset)
        if next != active { active = next }
    }
}

struct XWLyricsEditor: View {
    @ObservedObject var workspace: Workspace
    let context: LyricsEditorContext
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var issue: String?

    init(workspace: Workspace, context: LyricsEditorContext) {
        self.workspace = workspace; self.context = context
        _text = State(initialValue: context.original?.lrcText ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(context.original == nil ? "粘贴带时间的歌词" : "编辑歌词").font(.system(size: 18, weight: .semibold))
            Text("每句保留开始时间，例如：[00:16.430]第一句歌词。修改后会检查时间，再保存到这首歌。")
                .font(.system(size: 11)).foregroundStyle(XWTheme.muted)
            TextEditor(text: $text).font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden).padding(9).background(XWTheme.background, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("带时间的歌词内容")
            if let issue { Text(issue).font(.system(size: 11)).foregroundStyle(XWTheme.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(XWButtonStyle())
                Button("保存歌词", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(XWButtonStyle(kind: .primary)).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 570, height: 460).background(XWTheme.panel).foregroundStyle(XWTheme.text)
    }

    private func save() {
        guard let project = workspace.currentProject, project.id == context.projectID else {
            issue = "项目已切换，请关闭窗口后重新编辑。"; return
        }
        do {
            let document = try LyricsImport.parse(text, name: context.original?.sourceName ?? "粘贴的歌词", duration: project.source.duration)
            try workspace.saveLyrics(document, projectID: context.projectID, replacing: context.original)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
