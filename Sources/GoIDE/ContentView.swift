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
                EditorHeader()
                Divider()
                if workspace.currentFile != nil {
                    CodeEditorView(
                        text: workspace.text,
                        highlightGo: workspace.isGoFile,
                        diagnostics: workspace.currentDiagnostics,
                        reveal: workspace.revealTarget,
                        onChange: { workspace.updateText($0) })
                } else {
                    Text("Select a file")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 200)

            BottomPanel()
                .frame(minHeight: 100, idealHeight: 180)
        }
    }
}

struct EditorHeader: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 6) {
            if let file = workspace.currentFile {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(file.lastPathComponent).fontWeight(.medium)
                if workspace.isDirty {
                    Circle().fill(.secondary).frame(width: 7, height: 7).help("Unsaved changes")
                }
                Spacer()
                Text(relativePath(file)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func relativePath(_ url: URL) -> String {
        guard let root = workspace.rootURL?.path, url.path.hasPrefix(root) else { return url.path }
        return String(url.path.dropFirst(root.count).drop(while: { $0 == "/" }))
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
                        Text("\(item.fileName):\(item.diagnostic.start.line + 1):\(item.diagnostic.start.character + 1)")
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
