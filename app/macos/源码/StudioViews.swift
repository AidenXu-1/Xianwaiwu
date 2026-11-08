import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StudioRootView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var state = StudioViewState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            brandBar
            if let error = workspace.error, !state.exportPresented {
                XWIssueBanner(message: error) { workspace.error = nil }
                    .padding(.horizontal, 28).padding(.vertical, 8)
            }
            if workspace.showingHome {
                StudioLibraryView(workspace: workspace, store: workspace.library, state: state)
                    .transition(.opacity)
            } else {
                ZStack {
                    XWRetainedContent(hidden: !workspace.showingScore, interactive: workspace.showingScore, slide: 12, reducedMotion: reduceMotion) {
                        XWScoreView(workspace: workspace, task: workspace.scoreTask, player: workspace.player)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    XWRetainedContent(hidden: workspace.showingScore, interactive: !workspace.showingScore, slide: -8, reducedMotion: reduceMotion) { XWWorkArea(workspace: workspace, state: state) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .id(workspace.currentProject?.id)
                XWPlayerBar(workspace: workspace, player: workspace.player, openExport: openExport)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(XWTheme.text)
        .background(XWTheme.background)
        .tint(XWTheme.accent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: workspace.showingHome)
        .overlay {
            if state.dropTarget {
                RoundedRectangle(cornerRadius: 14).fill(XWTheme.background.opacity(0.95))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(XWTheme.accent, style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "music.note").font(.system(size: 33, weight: .light))
                            Text("松开，用这首歌创建项目").font(.system(size: 17, weight: .medium))
                        }.foregroundStyle(XWTheme.accent)
                    }
                    .padding(10).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $state.dropTarget, perform: acceptFiles)
        .sheet(isPresented: $state.exportPresented) {
            XWExportSheet(workspace: workspace, state: state)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $state.deleting) { deletion in
            XWDeleteSheet(workspace: workspace, deletion: deletion) { state.deleting = nil }
                .preferredColorScheme(.dark)
        }
        .sheet(item: $state.lyricsEditor) { context in
            XWLyricsEditor(workspace: workspace, context: context)
                .preferredColorScheme(.dark)
        }
        .onChange(of: workspace.processing) { _, processing in
            if processing { state.progressVisible = true }
        }
        .onChange(of: workspace.currentProject?.id) { _, _ in
            state.resultsPresented = false
            state.exportPresented = false
            state.lyricsEditor = nil
            state.lyricsVisible = workspace.currentProject?.lyrics != nil
        }
        .onChange(of: workspace.currentProject?.lyrics) { _, lyrics in
            if lyrics != nil { state.lyricsVisible = true }
        }
        .onChange(of: workspace.mode) { _, _ in
            state.resultsPresented = false
            state.exportPresented = false
            state.exportTracks = []
            state.exportSuccess = nil
            state.progressVisible = workspace.processingCurrentProject
        }
        .onAppear(perform: installKeyboard)
        .onDisappear {
            if let monitor = state.keyMonitor { NSEvent.removeMonitor(monitor); state.keyMonitor = nil }
        }
    }

    private var brandBar: some View {
        HStack(spacing: 10) {
            XWBrandMark()
            Text("弦外屋").font(.system(size: 15, weight: .semibold)).tracking(0.8)
            Rectangle().fill(XWTheme.line).frame(width: 1, height: 13).padding(.horizontal, 2)
            Text("STEM STUDIO").font(.system(size: 10, weight: .medium)).tracking(0.8).foregroundStyle(XWTheme.dim)
            Spacer(minLength: 12)
            if !workspace.showingHome {
                Button(action: workspace.showHome) { Label("所有项目", systemImage: "chevron.left") }
                    .buttonStyle(XWButtonStyle(kind: .quiet, compact: true))
                    .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 46)
        .background(workspace.showingHome ? XWTheme.background : XWTheme.bar)
        .overlay(alignment: .bottom) {
            if !workspace.showingHome { Rectangle().fill(XWTheme.line.opacity(0.65)).frame(height: 1) }
        }
    }

    private func openExport() {
        guard workspace.manifest != nil, workspace.canExportCurrentSelection else { return }
        state.exportTracks = Set(workspace.manifest?.tracks.map(\.id) ?? [])
        state.exportSuccess = nil
        state.exportStarted = false
        state.exportPresented = true
    }

    private func acceptFiles(_ providers: [NSItemProvider]) -> Bool {
        guard !workspace.busy, !workspace.importing else {
            workspace.error = "请先完成或取消当前任务，再创建新项目。"
            return false
        }
        guard providers.count == 1, let provider = providers.first else {
            workspace.error = "一次创建一个新项目，请只拖入一首歌"
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async { workspace.importURLs([url]) }
        }
        return true
    }

    private func installKeyboard() {
        guard state.keyMonitor == nil else { return }
        state.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !state.exportPresented, state.deleting == nil, !state.resultsPresented,
                  state.lyricsEditor == nil,
                  NSApp.modalWindow == nil, NSApp.mainWindow?.attachedSheet == nil else { return event }
            if event.keyCode == 53, workspace.rangeEditing {
                workspace.cancelRange()
                return nil
            }
            let editingText = NSApp.keyWindow?.firstResponder is NSTextView
            guard event.keyCode == 49, !editingText, !workspace.showingHome,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            // Buttons use Space themselves when they have keyboard focus.
            if NSApp.keyWindow?.firstResponder is NSButton || XWKeyboardFocus.hasButton { return event }
            if !event.isARepeat { workspace.togglePlayback() }
            return nil
        }
    }
}

private struct XWWorkArea: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: StudioViewState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View { workArea }
    private var panelAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.10) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
    }

    private func setLyricsVisible(_ visible: Bool) { state.lyricsVisible = visible }

    private var workArea: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 540
            VStack(spacing: compact ? 10 : 14) {
                songHeader(compact: compact)
                HStack(spacing: 9) {
                    ForEach(XWMode.all) { mode in
                        XWModeButton(mode: mode, selected: (workspace.mode == "leadback" ? "lead3" : workspace.mode) == mode.id,
                                     completed: workspace.versions.contains { $0.manifest.mode == mode.id },
                                     compact: compact) { workspace.selectMode(mode.id) }
                            .disabled(workspace.rangeEditing || workspace.importing)
                    }
                }
                if let issue = workspace.sourceIssue {
                    HStack(spacing: 10) {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).lineLimit(2)
                        Spacer(minLength: 4)
                        Button("重新定位原音频", action: workspace.relocateSource)
                            .buttonStyle(XWButtonStyle(kind: .selected, compact: true))
                            .disabled(workspace.busy || workspace.sourceRelocationProjectID != nil)
                    }
                    .foregroundStyle(XWTheme.accent)
                    .padding(10).background(XWTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                }
                let wide = geometry.size.width >= 1030
                let layout = wide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))
                let panelHeight: CGFloat = compact ? 100 : 180
                let panelGap: CGFloat = compact ? 10 : 14
                // Keep the waveform at the same structural position during panel and layout changes.
                layout {
                    XWAudioPanel(workspace: workspace, player: workspace.player, state: state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Reveal a full-size panel through a growing slot. Text never gets squeezed,
                    // and the same interpolated slot gives its space back to the waveform.
                    XWRetainedContent(hidden: !state.lyricsVisible, interactive: state.lyricsVisible, slide: wide ? 304 : 0, reducedMotion: reduceMotion, duration: 0.24, identity: "xw.lyrics.host", settlesInput: true) {
                        lyricsPanel
                    }
                        .frame(width: wide ? 290 : nil, height: wide ? nil : panelHeight)
                        .frame(maxHeight: wide ? .infinity : nil)
                        .padding(.leading, wide ? 14 : 0)
                        .padding(.top, wide ? 0 : panelGap)
                        .frame(width: wide ? (state.lyricsVisible ? 304 : 0) : nil,
                               height: wide ? nil : (state.lyricsVisible ? panelHeight + panelGap : 0),
                               alignment: wide ? .topTrailing : .topLeading)
                        .clipped()
                        .allowsHitTesting(state.lyricsVisible)
                        .accessibilityHidden(!state.lyricsVisible)
                }
                .clipped()
                .animation(reduceMotion ? nil : panelAnimation, value: state.lyricsVisible)
            }
            .padding(.horizontal, 28)
            .padding(.top, compact ? 13 : 20)
            .padding(.bottom, 18)
        }
    }

    private func songHeader(compact: Bool) -> some View {
        HStack(spacing: 12) {
            XWProjectCover(size: compact ? 45 : 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(workspace.currentTitle).font(.system(size: 20, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail).help(workspace.currentTitle)
                    .accessibilityLabel(workspace.currentTitle)
                if let source = workspace.currentProject?.source {
                    Text("\(xwTime(source.duration))  ·  \(source.url.pathExtension.uppercased())  ·  \(source.sampleRate / 1000, specifier: "%.1f") kHz  ·  \(source.channels == 1 ? "单声道" : "立体声")")
                        .font(.system(size: 10)).foregroundStyle(XWTheme.dim).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: workspace.openScore) { Label("乐谱", systemImage: "music.note.list") }
                .buttonStyle(XWSongAccessoryStyle())
                .help("打开弹唱谱，进入专注练习")
                .disabled(workspace.rangeEditing)
                .accessibilityIdentifier("xw.score.open")
            Button { setLyricsVisible(!state.lyricsVisible) } label: { Label("歌词", systemImage: "text.alignleft") }
                .buttonStyle(XWSongAccessoryStyle(selected: state.lyricsVisible))
                .help(state.lyricsVisible ? "收起歌词" : "展开歌词")
                .accessibilityValue(state.lyricsVisible ? "已展开" : "已收起")
                .accessibilityIdentifier("xw.lyrics.toggle")
            if !workspace.availableResults.isEmpty {
                Button { state.resultsPresented.toggle() } label: {
                    HStack(spacing: 5) {
                        Text("已有结果")
                        Text("\(workspace.availableResults.count)").foregroundStyle(XWTheme.text)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(XWButtonStyle(kind: .quiet, compact: true))
                .disabled(workspace.rangeEditing || workspace.exporting)
                .popover(isPresented: $state.resultsPresented, arrowEdge: .bottom) {
                    XWResultsMenu(workspace: workspace) { state.resultsPresented = false; state.progressVisible = false }
                }
            }
        }.frame(minHeight: compact ? 45 : 54)
    }

    private var lyricsPanel: some View {
        XWLyricsPanel(workspace: workspace, player: workspace.player, clock: workspace.player.clock,
                      close: { setLyricsVisible(false) }, edit: {
            guard let project = workspace.currentProject else { return }
            state.lyricsEditor = LyricsEditorContext(projectID: project.id, original: project.lyrics)
        })
    }

}

/// Keep an expensive SwiftUI subtree alive while its native visibility and input are disabled.
private struct XWRetainedContent<Content: View>: NSViewRepresentable {
    var hidden: Bool
    var interactive: Bool
    var slide: CGFloat? = nil
    var reducedMotion = false
    var duration: Double? = nil
    var identity: String? = nil
    var settlesInput = false
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> XWRetainedContainer {
        let hosting = NSHostingView(rootView: content().foregroundStyle(XWTheme.text).tint(XWTheme.accent))
        hosting.sizingOptions = []
        hosting.appearance = NSAppearance(named: .darkAqua)
        return XWRetainedContainer(hosting: hosting)
    }
    func updateNSView(_ view: XWRetainedContainer, context: Context) {
        // Hosted children observe their own models. Visibility never replaces their root.
        view.interactive = interactive
        view.settlesInput = settlesInput
        if let identity { view.identifier = NSUserInterfaceItemIdentifier(identity) }
        if let slide { view.present(!hidden, slide: reducedMotion ? 0 : slide, reducedMotion: reducedMotion, duration: duration) }
        else { view.isHidden = hidden }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: XWRetainedContainer, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

final class XWRetainedContainer: NSView {
    let hosting: NSView
    var interactive = true
    var settlesInput = false
    private var presented: Bool?
    private var animationVersion = 0
    private var completion: XWPageAnimationCompletion?
    init(hosting: NSView) {
        self.hosting = hosting
        super.init(frame: .zero)
        wantsLayer = true
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); hosting.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactive, !settlesInput || layer?.animation(forKey: "page-switch") == nil else { return nil }
        return super.hitTest(point)
    }
    override func accessibilityChildren() -> [Any]? { interactive && !isHidden ? [hosting] : [] }
    func present(_ visible: Bool, slide: CGFloat, reducedMotion: Bool, duration: Double?) {
        guard presented != visible, let layer else { return }
        let initial = presented == nil
        presented = visible; animationVersion += 1
        let version = animationVersion
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        let x = layer.presentation()?.sublayerTransform.m41 ?? layer.sublayerTransform.m41
        let targetX: CGFloat = visible ? 0 : slide
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = visible ? 1 : 0
        layer.sublayerTransform = CATransform3DMakeTranslation(targetX, 0, 0)
        CATransaction.commit()
        if initial { return }
        isHidden = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity; fade.toValue = visible ? 1 : 0
        let move = CABasicAnimation(keyPath: "sublayerTransform.translation.x")
        move.fromValue = x; move.toValue = targetX
        let group = CAAnimationGroup(); group.animations = [fade, move]
        group.duration = reducedMotion ? 0.10 : duration ?? (visible ? 0.22 : 0.18)
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        let end = XWPageAnimationCompletion { [weak self] in
            guard let self, self.animationVersion == version else { return }
            self.completion = nil
        }
        completion = end; group.delegate = end
        layer.add(group, forKey: "page-switch")
    }
}

private final class XWPageAnimationCompletion: NSObject, CAAnimationDelegate {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) { if flag { action() } }
}

private struct XWSongAccessoryStyle: ButtonStyle {
    var selected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? XWTheme.accent : XWTheme.muted)
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(selected ? XWTheme.accent.opacity(0.11) : .clear, in: shape)
            .overlay(shape.strokeBorder(selected ? XWTheme.accent.opacity(0.45) : .clear)
                .allowsHitTesting(false))
            .contentShape(shape)
            .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.16), value: selected)
            .modifier(XWSurfaceInteraction(pressed: configuration.isPressed, radius: 6))
    }
}

private struct XWModeButton: View {
    let mode: XWMode
    let selected: Bool
    let completed: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.symbol).font(.system(size: 16))
                    .foregroundStyle(selected ? XWTheme.accent : XWTheme.muted)
                    .frame(width: 33, height: 33)
                    .background(selected ? XWTheme.accent.opacity(0.075) : XWTheme.color(0x292924), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(mode.title).font(.system(size: 12, weight: .semibold))
                        if mode.id == "music6" { Text("实验").font(.system(size: 9)).foregroundStyle(XWTheme.dim) }
                    }
                    Text(mode.detail).font(.system(size: 10)).foregroundStyle(selected ? XWTheme.color(0xaa9a89) : XWTheme.dim)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if completed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(selected ? XWTheme.accent : XWTheme.green)
                        .font(.system(size: 12)).help("已有结果")
                } else {
                    Text("\(mode.count) 轨").font(.system(size: 9)).foregroundStyle(selected ? XWTheme.accent : XWTheme.dim)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: compact ? 55 : 62, alignment: .leading)
            .background(selected ? XWTheme.color(0x2c251e) : XWTheme.color(0x1c1c19), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? XWTheme.color(0x9a704e) : XWTheme.line))
        }
        .buttonStyle(XWModeStyle())
        .accessibilityLabel("\(mode.title)，\(mode.detail)，\(mode.count) 条音轨")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct XWModeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(XWSurfaceInteraction(pressed: configuration.isPressed, radius: 11))
    }
}

private struct XWAudioPanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var player: PracticePlayer
    @ObservedObject var state: StudioViewState
    @State private var hoverGuide = XWWaveformGuide()
    private let trackColumn: CGFloat = 180
    private var result: Bool {
        workspace.listeningToResult && workspace.manifest != nil && !workspace.rangeEditing &&
        workspace.availableResults.contains { $0.id == workspace.selectedResultID }
    }
    private var displayBounds: ClosedRange<Double> { workspace.timeBounds }
    private var dataBounds: ClosedRange<Double> {
        if result, let manifest = workspace.manifest { return manifest.start...manifest.end }
        return 0...(workspace.currentProject?.source.duration ?? 0)
    }
    private var selectedRange: ClosedRange<Double>? {
        if workspace.rangeEditing { return workspace.draftRange }
        if !result && workspace.hasCustomRange { return workspace.range }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            if !result {
                XWRangeEditor(workspace: workspace)
                    .padding(.horizontal, 13).padding(.vertical, 7).zIndex(2)
            }
            VStack(spacing: 0) {
                XWRuler(bounds: displayBounds).padding(.leading, trackColumn + 13).padding(.trailing, 19)
                if workspace.processingCurrentProject && state.progressVisible {
                    XWProcessingView(workspace: workspace)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geometry in
                        let count = workspace.manifest?.tracks.count ?? 0
                        let minimumRowHeight: CGFloat = count >= 6 ? 42 : count == 3 ? 64 : 82
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                if result, let manifest = workspace.manifest {
                                    ForEach(manifest.tracks, id: \.id) { track in
                                        trackRow(track, height: max(minimumRowHeight, geometry.size.height / CGFloat(max(1, manifest.tracks.count))))
                                    }
                                } else {
                                    originalRow.frame(minHeight: max(44, geometry.size.height))
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                        }.scrollIndicators(.automatic, axes: .vertical)
                    }
                    .padding(.leading, 13).padding(.trailing, 15)
                }
            }
            .overlay { XWWaveformGuideOverlay(guide: hoverGuide) }
        }
        .background(XWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(XWTheme.line).allowsHitTesting(false))
    }

    private var panelHeader: some View {
        ViewThatFits(in: .horizontal) {
            panelTools(showNote: true)
            panelTools(showNote: false)
        }
        .padding(.horizontal, 15).frame(height: 47)
        .overlay(alignment: .bottom) { Rectangle().fill(XWTheme.line.opacity(0.7)).frame(height: 1) }
    }

    private func panelTools(showNote: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button {
                    workspace.original(); state.progressVisible = false
                } label: { Label("原曲", systemImage: "music.note") }
                    .buttonStyle(XWButtonStyle(kind: !result ? .secondary : .quiet, compact: true))
                    .disabled(workspace.rangeEditing || workspace.sourceIssue != nil || workspace.source == nil)
                    .accessibilityAddTraits(!result ? .isSelected : [])
                    .accessibilityIdentifier("xw.listen.original")
                Button {
                    workspace.separated(); state.progressVisible = false
                } label: { Label("分离结果", systemImage: "square.stack.3d.up") }
                    .buttonStyle(XWButtonStyle(kind: result ? .secondary : .quiet, compact: true))
                    .disabled(!workspace.hasResultForCurrentMode || workspace.rangeEditing)
                    .help(workspace.hasResultForCurrentMode ? "试听这项分离的结果" : "先完成这项分离，再试听结果")
                    .accessibilityAddTraits(result ? .isSelected : [])
                    .accessibilityIdentifier("xw.listen.result")
            }
            .padding(3).background(XWTheme.color(0x141412), in: RoundedRectangle(cornerRadius: 8))
            if showNote {
                HStack(spacing: 5) {
                    Circle().fill(result && player.audibleTracks.isEmpty ? XWTheme.dim : XWTheme.green).frame(width: 5, height: 5)
                    Text(listenNote).font(.system(size: 10)).foregroundStyle(XWTheme.dim).lineLimit(1)
                }.fixedSize()
            }
            Spacer(minLength: 3)
            if workspace.processingCurrentProject {
                Button("处理进度") { state.progressVisible = true }
                    .buttonStyle(XWButtonStyle(kind: state.progressVisible ? .selected : .secondary, compact: true))
            }
            if result {
                if (workspace.manifest?.tracks.count ?? 0) <= 3, let target = quickTarget {
                    Button(target == "instrumental" ? "只听伴奏" : "只听主唱") {
                        if player.solo == [target] { workspace.clearSolo() }
                        else {
                            workspace.clearSolo(); workspace.toggleSolo(target)
                            if !player.playing { workspace.togglePlayback() }
                        }
                    }.buttonStyle(XWButtonStyle(kind: player.solo == [target] ? .selected : .secondary, compact: true))
                }
                if !player.solo.isEmpty {
                    Button("清除独奏", action: workspace.clearSolo).buttonStyle(XWButtonStyle(kind: .selected, compact: true))
                }
                Button("全关") { workspace.setAll(false) }.buttonStyle(XWButtonStyle(compact: true))
                Button("全开") { workspace.setAll(true) }.buttonStyle(XWButtonStyle(compact: true))
            }
        }
    }

    private var quickTarget: String? {
        guard let manifest = workspace.manifest else { return nil }
        if manifest.tracks.contains(where: { $0.id == "lead" }) { return "lead" }
        if manifest.tracks.contains(where: { $0.id == "instrumental" }) { return "instrumental" }
        return nil
    }

    private var listenNote: String {
        if workspace.rangeEditing { return "选段试听" }
        if !result { return "正在听原曲" }
        if player.audibleTracks.isEmpty { return "全部静音" }
        return player.solo.isEmpty ? "\(player.audibleTracks.count) 条音轨已开启" : "独奏 \(player.solo.count) 轨"
    }

    private var originalRow: some View {
        HStack(spacing: 11) {
            HStack(spacing: 9) {
                XWTrackBadge(id: "original", size: 37)
                VStack(alignment: .leading, spacing: 5) {
                    Text("原始音频").font(.system(size: 13, weight: .semibold))
                    Text(workspace.rangeEditing ? "拖动框选处理范围" : "完整混合 · \(xwRange(workspace.range, duration: workspace.currentProject?.source.duration))")
                        .font(.system(size: 10)).foregroundStyle(XWTheme.dim).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: trackColumn - 11)
            ZStack {
                XWWaveform(peaks: workspace.wave, dataBounds: dataBounds, displayBounds: displayBounds,
                           clock: player.clock, clockOffset: 0, selection: selectedRange,
                           editing: workspace.rangeEditing, label: "原曲播放位置", identifier: "xw.waveform.original", seek: workspace.seekAbsolute,
                           updateRange: workspace.updateDraft, beginRange: workspace.canEditRange ? workspace.beginRange : nil,
                           hoverGuide: hoverGuide)
                if workspace.wave.isEmpty {
                    Text(workspace.sourceIssue == nil ? "正在读取音频波形…" : "请重新定位原音频")
                        .font(.system(size: 11)).foregroundStyle(XWTheme.dim).allowsHitTesting(false)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func trackRow(_ track: Manifest.Row, height: CGFloat) -> some View {
        let on = player.audibleTracks.contains(track.id)
        return HStack(spacing: 11) {
            HStack(spacing: 8) {
                XWTrackBadge(id: track.id)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if height >= 70 { Text(XWTheme.trackDetail(track.id)).font(.system(size: 9)).foregroundStyle(XWTheme.dim).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading).opacity(on ? 1 : 0.55)
                HStack(spacing: 4) {
                    Button { workspace.toggleSolo(track.id) } label: { Text("S").font(.system(size: 10, weight: .semibold)).frame(width: 11) }
                        .buttonStyle(XWButtonStyle(kind: player.solo.contains(track.id) ? .primary : .secondary, compact: true))
                        .accessibilityLabel("\(player.solo.contains(track.id) ? "取消独奏" : "独奏")\(track.label)")
                        .accessibilityAddTraits(player.solo.contains(track.id) ? .isSelected : [])
                        .help("独奏\(track.label)，可同时选择多轨")
                    Button { workspace.toggleTrack(track.id) } label: {
                        Image(systemName: player.enabled.contains(track.id) ? "speaker.wave.2" : "speaker.slash")
                            .font(.system(size: 11)).frame(width: 12)
                    }
                    .buttonStyle(XWButtonStyle(kind: player.enabled.contains(track.id) ? .secondary : .quiet, compact: true))
                    .accessibilityLabel("\(player.enabled.contains(track.id) ? "静音" : "开启")\(track.label)")
                    .help("\(player.enabled.contains(track.id) ? "静音" : "开启")\(track.label)")
                }
            }.frame(width: trackColumn - 11)
            XWWaveform(peaks: workspace.trackWaves[track.id] ?? [], dataBounds: dataBounds, displayBounds: displayBounds,
                       clock: player.clock, clockOffset: workspace.manifest?.start ?? 0,
                       color: XWTheme.trackColor(track.id), audible: on,
                       label: "\(track.label)播放位置", identifier: "xw.waveform.\(track.id)", seek: workspace.seekAbsolute,
                       hoverGuide: hoverGuide)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .overlay(alignment: .bottom) { Rectangle().fill(XWTheme.line.opacity(0.5)).frame(height: 1) }
    }
}

private struct XWRuler: View {
    let bounds: ClosedRange<Double>
    var body: some View {
        HStack {
            ForEach(0..<5) { index in
                if index > 0 { Spacer(minLength: 0) }
                Text(xwTime(bounds.lowerBound + (bounds.upperBound - bounds.lowerBound) * Double(index) / 4))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(XWTheme.dim)
            }
        }
        .frame(height: 25, alignment: .bottom).padding(.bottom, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(XWTheme.line.opacity(0.65)).frame(height: 1) }
        .accessibilityHidden(true)
    }
}

private struct XWResultsMenu: View {
    @ObservedObject var workspace: Workspace
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("这项分离的结果").font(.system(size: 14, weight: .semibold)).padding(15)
            Rectangle().fill(XWTheme.line).frame(height: 1)
            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    ForEach(workspace.availableResults) { version in
                        Button {
                            workspace.switchResult(version.id)
                            close()
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: XWMode.resolve(version.manifest.mode).symbol).foregroundStyle(XWTheme.accent).frame(width: 20)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(XWMode.resolve(version.manifest.mode).title).font(.system(size: 12, weight: .semibold))
                                    Text("\(xwRange(version.manifest.start...version.manifest.end, duration: workspace.currentProject?.source.duration)) · \(version.createdAt.formatted(.dateTime.month().day().hour().minute()))")
                                        .font(.system(size: 10)).foregroundStyle(XWTheme.dim).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if workspace.selectedResultID == version.id { Image(systemName: "checkmark").foregroundStyle(XWTheme.accent) }
                            }.frame(minHeight: 46)
                        }.buttonStyle(XWButtonStyle(kind: workspace.selectedResultID == version.id ? .selected : .quiet, compact: true))
                    }
                }.padding(8)
            }.frame(maxHeight: 300)
            if workspace.sourceIssue == nil {
                Divider()
                Button("按当前范围重新分离一份") { close(); workspace.start(force: true) }
                    .buttonStyle(XWButtonStyle(kind: .quiet, compact: true)).padding(8)
                    .disabled(!workspace.readyToRun)
            }
        }
        .frame(width: 334).foregroundStyle(XWTheme.text).background(XWTheme.panel)
    }
}

struct XWIssueBanner: View {
    let message: String
    let dismiss: () -> Void
    private var lines: [Substring] { message.split(separator: "\n", maxSplits: 1) }
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(XWTheme.color(0xdf9483)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(lines.first.map(String.init) ?? message).font(.system(size: 11, weight: .medium)).lineLimit(3)
                if lines.count > 1 {
                    DisclosureGroup("查看详情") {
                        Text(String(lines[1])).font(.system(size: 10)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
                    }.font(.system(size: 10)).foregroundStyle(XWTheme.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 11) }
                .buttonStyle(XWButtonStyle(kind: .quiet, compact: true)).accessibilityLabel("关闭提示")
        }
        .padding(10).background(XWTheme.danger.opacity(0.075), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(XWTheme.danger.opacity(0.16)))
    }
}
