import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct XWDeletion: Identifiable {
    enum Kind { case project, folder }
    let id: UUID
    let title: String
    let kind: Kind
}

final class StudioViewState: ObservableObject {
    @Published var dropTarget = false
    @Published var exportPresented = false
    @Published var exportTracks = Set<String>()
    @Published var exportSuccess: URL?
    @Published var exportStarted = false
    @Published var deleting: XWDeletion?
    @Published var folderCreating = false
    @Published var folderName = ""
    @Published var resultsPresented = false
    @Published var progressVisible = true
    @Published var lyricsVisible = false
    @Published var lyricsEditor: LyricsEditorContext?
    var keyMonitor: Any?
}

struct StudioLibraryView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: LibraryStore
    @ObservedObject var state: StudioViewState
    @FocusState private var folderFocused: Bool

    private var projects: [ProjectRecord] {
        store.projects.filter { workspace.selectedFolderID == nil || $0.folderID == workspace.selectedFolderID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 960
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 24) {
                    importZone
                    HStack(alignment: .top, spacing: narrow ? 18 : 24) {
                        projectList(narrow: narrow)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        Rectangle().fill(XWTheme.line.opacity(0.7)).frame(width: 1)
                        folders
                            .frame(width: narrow ? 200 : 232, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic, axes: .vertical)
        }
    }

    private var importZone: some View {
        Button(action: workspace.chooseInput) {
            HStack(spacing: 18) {
                Image(systemName: workspace.importing ? "waveform" : "plus")
                    .font(.system(size: 23, weight: .light))
                    .foregroundStyle(XWTheme.accent)
                    .frame(width: 51, height: 51)
                    .background(XWTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(XWTheme.accent.opacity(0.16)))
                VStack(alignment: .leading, spacing: 8) {
                    Text(workspace.importing ? "正在打开这首歌…" : "拖入一首歌，创建新项目")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(XWTheme.text)
                    Text("也可以点击这里，从 Finder 选择一首歌曲")
                        .font(.system(size: 11)).foregroundStyle(XWTheme.color(0x9a9186))
                    Text("MP3 · WAV · FLAC · M4A · AAC · AIFF")
                        .font(.system(size: 10)).foregroundStyle(XWTheme.dim).padding(.top, 6)
                }
                Spacer(minLength: 12)
                XWWelcomeWave().frame(width: 230, height: 72)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .leading)
            .background(LinearGradient(colors: [XWTheme.color(0x211e19), XWTheme.color(0x1b1b18)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(XWTheme.color(0x66533f), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .buttonStyle(XWImportStyle())
        .disabled(workspace.busy || workspace.importing)
        .accessibilityLabel("拖入一首歌，创建新项目。点击选择音频")
        .help("打开本地音频（⌘O）")
    }

    private func projectList(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("最近项目").font(.system(size: 13, weight: .semibold))
                Text("\(projects.count) 个").font(.system(size: 10)).foregroundStyle(XWTheme.dim)
                Spacer(minLength: 2)
                if FileManager.default.fileExists(atPath: Project.sample.path) {
                    Button("打开示例项目") { workspace.importFile(Project.sample) }
                        .buttonStyle(XWButtonStyle(kind: .quiet, compact: true))
                        .disabled(workspace.busy || workspace.importing)
                }
            }.frame(height: 26)
            if projects.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "music.note.list").font(.system(size: 21, weight: .light)).foregroundStyle(XWTheme.dim)
                    Text(workspace.selectedFolderID == nil ? "导入一首歌，创建第一个项目" : "把项目拖到这个文件夹，或创建一个新项目")
                        .font(.system(size: 11)).foregroundStyle(XWTheme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 116)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(XWTheme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(projects) { project in
                        projectRow(project, narrow: narrow)
                    }
                }
            }
        }
    }

    private func projectRow(_ project: ProjectRecord, narrow: Bool) -> some View {
        let done = !project.results.isEmpty
        let latestResult = project.results.max { $0.createdAt < $1.createdAt }
        let active = project.id == workspace.activeTaskProjectID && workspace.processing
        return HStack(spacing: 0) {
            Button { workspace.openProject(project.id) } label: {
                HStack(spacing: 12) {
                    XWProjectCover(size: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(project.title).font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).truncationMode(.tail).foregroundStyle(XWTheme.text)
                        Text("\(xwTime(project.source.duration)) · \(project.source.url.pathExtension.uppercased())")
                            .font(.system(size: 10)).foregroundStyle(XWTheme.dim).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if !narrow {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(done ? XWMode.resolve(latestResult?.mode ?? project.mode).title : "等待分离")
                                .font(.system(size: 10)).foregroundStyle(XWTheme.muted)
                            Text(done ? "\(project.results.count) 份结果" : "已创建项目")
                                .font(.system(size: 9)).foregroundStyle(XWTheme.dim)
                        }.frame(width: 120, alignment: .leading)
                    }
                    Text(active ? "分离中" : done ? "已完成" : "待处理")
                        .font(.system(size: 10))
                        .foregroundStyle(active ? XWTheme.accent : done ? XWTheme.green : XWTheme.muted)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background((active ? XWTheme.accent : done ? XWTheme.green : .white).opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                    Text(relativeDate(project.updatedAt))
                        .font(.system(size: 9)).foregroundStyle(XWTheme.dim)
                        .lineLimit(1).frame(width: 48, alignment: .trailing)
                }
                .padding(.leading, 14).padding(.vertical, 12).padding(.trailing, 7)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(XWProjectStyle()).disabled(workspace.importing)
                .accessibilityLabel("\(project.title)，\(xwTime(project.source.duration))，\(done ? "已有分离结果" : "待处理")")
            Button { state.deleting = XWDeletion(id: project.id, title: project.title, kind: .project) } label: {
                Image(systemName: "trash").font(.system(size: 12)).frame(width: 15)
            }.buttonStyle(XWButtonStyle(kind: .quiet, compact: true))
                .padding(.trailing, 7)
                .accessibilityLabel("删除项目 \(project.title)")
                .disabled(workspace.busy || workspace.importing)
        }
        .background(XWTheme.color(0x1b1b18), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(XWTheme.line.opacity(0.85)).allowsHitTesting(false))
        .help(project.title)
        .onDrag { NSItemProvider(object: project.id.uuidString as NSString) }
        .contextMenu {
            Button("打开项目") { workspace.openProject(project.id) }
            Menu("移到文件夹") {
                Button("全部项目") { moveProject(project.id, to: nil) }
                ForEach(store.folders) { folder in
                    Button(folder.name) { moveProject(project.id, to: folder.id) }
                }
            }
            Divider()
            Button("删除项目…", role: .destructive) { state.deleting = XWDeletion(id: project.id, title: project.title, kind: .project) }
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("我的文件夹").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 5)
                Button {
                    state.folderCreating = true
                    folderFocused = true
                } label: { Label("新建", systemImage: "plus") }
                    .buttonStyle(XWButtonStyle(kind: .quiet, compact: true)).disabled(workspace.busy)
            }.frame(height: 26).padding(.bottom, 9)
            XWFolderRow(title: "全部项目", count: store.projects.count, selected: workspace.selectedFolderID == nil,
                        select: { workspace.selectedFolderID = nil }, accept: { acceptProject($0, into: nil) })
            ForEach(store.folders) { folder in
                HStack(spacing: 0) {
                    XWFolderRow(title: folder.name, count: store.projects.filter { $0.folderID == folder.id }.count,
                                selected: workspace.selectedFolderID == folder.id,
                                select: { workspace.selectedFolderID = folder.id }, accept: { acceptProject($0, into: folder.id) })
                    Button { state.deleting = XWDeletion(id: folder.id, title: folder.name, kind: .folder) } label: {
                        Image(systemName: "trash").font(.system(size: 11)).frame(width: 12)
                    }.buttonStyle(XWButtonStyle(kind: .quiet, compact: true))
                        .accessibilityLabel("删除文件夹 \(folder.name)")
                }.disabled(workspace.busy)
            }
            if state.folderCreating {
                HStack(spacing: 5) {
                    TextField("例如：大冰", text: $state.folderName)
                        .textFieldStyle(.plain).font(.system(size: 11)).padding(8)
                        .background(XWTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(XWTheme.accent.opacity(0.55)))
                        .focused($folderFocused).onSubmit(createFolder)
                        .onChange(of: state.folderName) { _, value in
                            if value.count > 24 { state.folderName = String(value.prefix(24)) }
                        }
                        .onExitCommand { state.folderCreating = false; state.folderName = "" }
                        .accessibilityLabel("文件夹名称")
                    Button("创建", action: createFolder).buttonStyle(XWButtonStyle(kind: .selected, compact: true))
                        .disabled(state.folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.top, 8)
            }
        }
    }

    private func createFolder() {
        do {
            let folder = try store.createFolder(name: state.folderName)
            workspace.selectedFolderID = folder.id
            state.folderName = ""
            state.folderCreating = false
        } catch { workspace.error = error.localizedDescription }
    }

    private func moveProject(_ project: UUID, to folder: UUID?) {
        guard !workspace.busy else { return }
        workspace.moveProject(project, to: folder)
    }

    private func acceptProject(_ providers: [NSItemProvider], into folder: UUID?) -> Bool {
        guard !workspace.busy, let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String, let id = UUID(uuidString: value) else { return }
            DispatchQueue.main.async { moveProject(id, to: folder) }
        }
        return true
    }

    private func relativeDate(_ date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
}

private final class XWFolderHover: ObservableObject { @Published var drop = false }

private struct XWFolderRow: View {
    let title: String
    let count: Int
    let selected: Bool
    let select: () -> Void
    let accept: ([NSItemProvider]) -> Bool
    @StateObject private var state = XWFolderHover()

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: selected ? "folder.fill" : "folder").font(.system(size: 14))
                Text(title).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 10)).foregroundStyle(selected ? XWTheme.accent : XWTheme.dim)
            }.frame(maxWidth: .infinity, minHeight: 39, alignment: .leading)
        }
        .buttonStyle(XWButtonStyle(kind: selected || state.drop ? .selected : .quiet, compact: true))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
        .onDrop(of: [.plainText], isTargeted: $state.drop, perform: accept)
    }
}

private struct XWImportStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(XWSurfaceInteraction(pressed: configuration.isPressed, radius: 15))
    }
}

private struct XWProjectStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(XWSurfaceInteraction(pressed: configuration.isPressed, radius: 11))
    }
}

struct XWProjectCover: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "music.note")
            .font(.system(size: size * 0.39, weight: .medium))
            .foregroundStyle(XWTheme.color(0xe9c699))
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [XWTheme.color(0x604838), XWTheme.color(0x252a28), XWTheme.color(0x171a18)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.22))
            .overlay(RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(XWTheme.color(0x67503c).opacity(0.8)))
            .accessibilityHidden(true)
    }
}

private struct XWWelcomeWave: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<48 {
                let position = Double(index)
                let envelope = 0.22 + 0.78 * abs(sin(position * 0.082))
                let texture = 0.15 + 0.85 * abs(sin(position * 1.73) * cos(position * 0.21))
                let height = 5 + size.height * 0.85 * envelope * texture
                let rect = CGRect(x: size.width * position / 48, y: (size.height - height) / 2, width: 2.5, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(XWTheme.accent.opacity(0.15 + position / 80)))
            }
        }.mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .trailing))
    }
}
