import GoIDECore
import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        NavigationSplitView {
            FileTreeView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            if workspace.rootURL == nil {
                WelcomeView()
            } else {
                EditorArea()
            }
        }
        .navigationTitle(workspace.rootURL?.lastPathComponent ?? "GoIDE")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.runGo(["build", "./..."]) } label: {
                    Label("Build", systemImage: "hammer")
                }
                .help("go build ./... (⌘B)")
                Button { workspace.runGo(["test", "./..."]) } label: {
                    Label("Test", systemImage: "checkmark.diamond")
                }
                .help("go test ./... (⌘U)")
                Button { workspace.runGo(["run", "."]) } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .help("go run . (⌘R)")
                Button { workspace.stopRun() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop (⌘.)")
                .disabled(!workspace.isRunning)
            }
        }
        .task { await workspace.handleLaunchArguments() }
    }
}

struct WelcomeView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("GoIDE").font(.largeTitle.bold())
            Text("Open a Go module folder to get started.")
                .foregroundStyle(.secondary)
            Button("Open Folder…") { workspace.presentOpenPanel() }
                .keyboardShortcut("o")
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileTreeView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let selection = Binding<URL?>(
            get: { workspace.currentFile },
            set: { if let url = $0 { workspace.openFile(url) } })

        List(workspace.fileTree, children: \.children, selection: selection) { node in
            Label(node.name, systemImage: Self.icon(for: node))
                .lineLimit(1)
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("Reload") { workspace.reloadTree() }
        }
    }

    private static func icon(for node: FileNode) -> String {
        if node.isDirectory { return "folder" }
        switch node.url.pathExtension {
        case "go": return "doc.text"
        case "mod", "sum": return "shippingbox"
        case "md": return "doc.richtext"
        default: return "doc"
        }
    }
}

struct EditorArea: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                TabBar()
                Divider()
                ZStack {
                    // Every open document keeps a live editor (undo, scroll, selection);
                    // only the active one is shown.
                    ForEach(workspace.documents) { document in
                        DocumentEditor(document: document, isActive: document === workspace.activeDocument)
                    }
                    if workspace.documents.isEmpty {
                        Text("Select a file")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(minHeight: 200)

            BottomPanel()
                .frame(minHeight: 100, idealHeight: 180)
        }
    }
}

struct DocumentEditor: View {
    @Environment(Workspace.self) private var workspace
    let document: Document
    let isActive: Bool

    var body: some View {
        CodeEditorView(
            text: document.text,
            highlightGo: document.isGo,
            isEditable: !document.isReadOnly,
            isActive: isActive,
            diagnostics: workspace.diagnostics(for: document),
            reveal: document.revealTarget,
            services: EditorServices(
                completions: { await workspace.completions(in: document, at: $0) },
                hover: { await workspace.hover(in: document, at: $0) },
                definition: { offset in Task { await workspace.jumpToDefinition(from: document, at: offset) } },
                caretMoved: { document.caretOffset = $0 }),
            onChange: { workspace.updateText(of: document, to: $0) })
    }
}

struct TabBar: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 0) {
            Button { workspace.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(!workspace.canGoBack)
                .help("Go Back (⌃⌘←)")
                .padding(.horizontal, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(workspace.documents) { document in
                            TabItem(document: document,
                                    title: title(for: document),
                                    isActive: document === workspace.activeDocument)
                                .id(document.id)
                        }
                    }
                }
                .onChange(of: workspace.activeDocument?.id) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
    }

    /// Adds the parent folder when two open files share a name.
    private func title(for document: Document) -> String {
        let clash = workspace.documents.contains { $0 !== document && $0.name == document.name }
        guard clash else { return document.name }
        return "\(document.url.deletingLastPathComponent().lastPathComponent)/\(document.name)"
    }
}

struct TabItem: View {
    @Environment(Workspace.self) private var workspace
    let document: Document
    let title: String
    let isActive: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: document.isReadOnly ? "lock.fill" : "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            ZStack {
                if document.isDirty && !isHovering {
                    Circle().fill(.secondary).frame(width: 7, height: 7)
                } else {
                    Button { workspace.closeDocument(document) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .opacity(isHovering || isActive ? 1 : 0)
                    .help("Close Tab (⌘W)")
                }
            }
            .frame(width: 14, height: 14)
        }
        .font(.system(size: 12))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { workspace.activate(document) }
        .onHover { isHovering = $0 }
        .help(document.url.path)
        .contextMenu {
            Button("Close Tab") { workspace.closeDocument(document) }
            Button("Close Other Tabs") { workspace.closeOtherDocuments(than: document) }
            Button("Close All Tabs") { workspace.closeAllDocuments() }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
        }
    }
}

struct BottomPanel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HStack {
                Picker("Panel", selection: $workspace.bottomTab) {
                    Text("Problems (\(workspace.allProblems.count))").tag(BottomTab.problems)
                    Text("Output").tag(BottomTab.output)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if workspace.isRunning { ProgressView().controlSize(.small) }
                Text(workspace.lspStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            switch workspace.bottomTab {
            case .problems: ProblemsList()
            case .output: OutputView()
            }
        }
    }
}

struct ProblemsList: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let problems = workspace.allProblems
        if problems.isEmpty {
            Text("No problems")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(problems) { item in
                Button { workspace.reveal(item) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.diagnostic.severity == .error ? .red : .yellow)
                        Text("\(workspace.displayPath(item.path)):\(item.diagnostic.start.line + 1):\(item.diagnostic.start.character + 1)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(item.diagnostic.message)
                            .lineLimit(2)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

struct OutputView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(workspace.output.isEmpty ? "No output yet. Use Build (⌘B), Test (⌘U) or Run (⌘R)." : workspace.output)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(workspace.output.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .onChange(of: workspace.output) {
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }
}
