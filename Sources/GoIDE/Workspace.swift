import AppKit
import GoIDECore
import Observation

enum BottomTab: Hashable {
    case problems, output
}

/// A request for the editor to move the caret to a position.
struct RevealTarget: Equatable {
    let id = UUID()
    let position: TextPosition
}

struct NavigationPoint: Equatable {
    let url: URL
    let position: TextPosition
}

struct ProblemItem: Identifiable {
    let path: String
    let diagnostic: Diagnostic
    var id: UUID { diagnostic.id }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// All state for one open project folder: files, editor buffer, gopls, and go commands.
@MainActor
@Observable
final class Workspace {
    private(set) var rootURL: URL?
    private(set) var fileTree: [FileNode] = []
    private(set) var currentFile: URL?
    private(set) var text = ""
    private(set) var isDirty = false
    private(set) var diagnostics: [String: [Diagnostic]] = [:]  // keyed by normalized path
    private(set) var lspStatus = "gopls: not started"
    private(set) var output = ""
    private(set) var isRunning = false
    var bottomTab: BottomTab = .problems
    var revealTarget: RevealTarget?
    private(set) var backStack: [NavigationPoint] = []
    /// UTF-16 caret offset in the current file, reported by the editor.
    @ObservationIgnored var caretOffset = 0

    @ObservationIgnored private var lsp: LSPClient?
    @ObservationIgnored private var lspReady = false
    @ObservationIgnored private var documentVersion = 0
    @ObservationIgnored private var runProcess: Process?
    @ObservationIgnored private var handledLaunchArguments = false

    var currentDiagnostics: [Diagnostic] {
        guard let currentFile else { return [] }
        return diagnostics[Self.key(for: currentFile)] ?? []
    }

    var allProblems: [ProblemItem] {
        diagnostics.keys.sorted().flatMap { path in
            diagnostics[path, default: []].map { ProblemItem(path: path, diagnostic: $0) }
        }
    }

    var isGoFile: Bool { currentFile?.pathExtension == "go" }

    /// Files outside the project (stdlib, module cache) are opened read-only.
    var isReadOnly: Bool {
        guard let currentFile, let rootURL else { return false }
        return !Self.key(for: currentFile).hasPrefix(Self.key(for: rootURL) + "/")
    }

    var canGoBack: Bool { !backStack.isEmpty }

    // MARK: - Folder

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Go module or workspace folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openFolder(url) }
    }

    /// Opens a folder passed on the command line, e.g. `swift run GoIDE ./Examples/hello`.
    func handleLaunchArguments() async {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        for arg in CommandLine.arguments.dropFirst() {
            var isDir: ObjCBool = false
            let url = URL(fileURLWithPath: arg).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                await openFolder(url)
                return
            }
        }
    }

    func openFolder(_ url: URL) async {
        if isDirty { save() }
        await stopLanguageServer()
        rootURL = url
        fileTree = FileNode.loadTree(at: url)
        currentFile = nil
        text = ""
        isDirty = false
        diagnostics = [:]
        output = ""
        backStack = []
        if let main = Self.firstFile(named: "main.go", in: fileTree) ?? Self.firstGoFile(in: fileTree) {
            openFile(main)
        }
        await startLanguageServer(root: url)
    }

    func reloadTree() {
        guard let rootURL else { return }
        fileTree = FileNode.loadTree(at: rootURL)
    }

    // MARK: - Files

    func openFile(_ url: URL) {
        guard url != currentFile else { return }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return }
        if isDirty { save() }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            appendOutput("Cannot open \(url.path) (not UTF-8 text?)\n")
            return
        }
        closeCurrentDocument()
        currentFile = url
        text = contents
        isDirty = false
        caretOffset = 0
        documentVersion = 1
        sendDidOpen()
    }

    func updateText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = true
        documentVersion += 1
        guard lspReady, isGoFile, let url = currentFile else { return }
        try? lsp?.notify("textDocument/didChange", params: [
            "textDocument": ["uri": .string(url.absoluteString), "version": .int(documentVersion)],
            "contentChanges": [["text": .string(newText)]],
        ])
    }

    func save() {
        guard let url = currentFile, !isReadOnly else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            if lspReady, isGoFile {
                try? lsp?.notify("textDocument/didSave", params: ["textDocument": ["uri": .string(url.absoluteString)]])
            }
        } catch {
            appendOutput("Save failed: \(error.localizedDescription)\n")
            bottomTab = .output
        }
    }

    func reveal(_ problem: ProblemItem) {
        let url = URL(fileURLWithPath: problem.path)
        if currentFile.map(Self.key(for:)) != problem.path { openFile(url) }
        revealTarget = RevealTarget(position: problem.diagnostic.start)
    }

    // MARK: - Language features

    func completions(at offset: Int) async -> [CompletionItem] {
        guard case let (lsp, params)? = positionRequest(at: offset),
              let result = try? await lsp.request("textDocument/completion", params: params)
        else { return [] }
        return CompletionItem.parseList(result)
    }

    func hover(at offset: Int) async -> String? {
        guard case let (lsp, params)? = positionRequest(at: offset),
              let result = try? await lsp.request("textDocument/hover", params: params)
        else { return nil }
        return HoverContent.parse(result).map { String($0.prefix(4000)) }
    }

    func jumpToDefinition(at offset: Int) async {
        guard let url = currentFile, case let (lsp, params)? = positionRequest(at: offset) else { return }
        let origin = LineIndex(text).position(of: offset)
        let result = try? await lsp.request("textDocument/definition", params: params)
        guard let location = result.map(Location.parseAll)?.first,
              let target = URL(string: location.uri), target.isFileURL
        else {
            flashStatus("No definition found")
            return
        }
        backStack.append(NavigationPoint(url: url, position: origin))
        if backStack.count > 100 { backStack.removeFirst() }
        navigate(to: URL(fileURLWithPath: target.path), position: location.start)
    }

    func goBack() {
        guard let point = backStack.popLast() else { return }
        navigate(to: point.url, position: point.position)
    }

    private func navigate(to url: URL, position: TextPosition) {
        if currentFile.map(Self.key(for:)) != Self.key(for: url) { openFile(url) }
        guard currentFile.map(Self.key(for:)) == Self.key(for: url) else { return }
        revealTarget = RevealTarget(position: position)
    }

    private func positionRequest(at offset: Int) -> (LSPClient, JSONValue)? {
        guard lspReady, isGoFile, let url = currentFile, let lsp else { return nil }
        let position = LineIndex(text).position(of: offset)
        return (lsp, ["textDocument": ["uri": .string(url.absoluteString)], "position": position.json])
    }

    private func flashStatus(_ message: String) {
        let previous = lspStatus
        lspStatus = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if lspStatus == message { lspStatus = previous }
        }
    }

    // MARK: - gopls

    func restartLanguageServer() async {
        guard let rootURL else { return }
        await stopLanguageServer()
        await startLanguageServer(root: rootURL)
    }

    private func startLanguageServer(root: URL) async {
        guard let gopls = ToolLocator.find("gopls") else {
            lspStatus = "gopls not found — go install golang.org/x/tools/gopls@latest"
            return
        }
        let client = LSPClient()
        client.onNotification = { method, params in
            Task { @MainActor in self.handleNotification(client, method: method, params: params) }
        }
        client.onExit = { status in
            Task { @MainActor in
                guard self.lsp === client else { return }
                self.lsp = nil
                self.lspReady = false
                self.lspStatus = "gopls exited (status \(status))"
            }
        }

        do {
            try client.start(executable: gopls, environment: ToolLocator.environment(), currentDirectory: root)
            lsp = client
            lspStatus = "gopls: starting…"
            _ = try await client.request("initialize", params: Self.initializeParams(root: root))
            guard lsp === client else { return }  // folder changed while initializing
            try client.notify("initialized", params: [:])
            lspReady = true
            lspStatus = "gopls: ready"
            sendDidOpen()
        } catch {
            if lsp === client { lsp = nil }
            lspStatus = "gopls failed: \(error.localizedDescription)"
        }
    }

    private func stopLanguageServer() async {
        guard let client = lsp else { return }
        lsp = nil
        lspReady = false
        client.onNotification = nil
        client.onExit = nil
        lspStatus = "gopls: stopped"
        await client.shutdown()
    }

    private func handleNotification(_ client: LSPClient, method: String, params: JSONValue) {
        guard lsp === client else { return }
        switch method {
        case "textDocument/publishDiagnostics":
            guard let published = Diagnostic.parsePublish(params), let url = URL(string: published.uri) else { return }
            let key = Self.key(for: url)
            if published.diagnostics.isEmpty {
                diagnostics.removeValue(forKey: key)
            } else {
                diagnostics[key] = published.diagnostics
            }
        case "window/showMessage":
            if let message = params["message"]?.stringValue { lspStatus = "gopls: \(message)" }
        default:
            break
        }
    }

    private func sendDidOpen() {
        guard lspReady, isGoFile, let url = currentFile else { return }
        try? lsp?.notify("textDocument/didOpen", params: [
            "textDocument": [
                "uri": .string(url.absoluteString),
                "languageId": "go",
                "version": .int(documentVersion),
                "text": .string(text),
            ],
        ])
    }

    private func closeCurrentDocument() {
        guard lspReady, isGoFile, let url = currentFile else { return }
        try? lsp?.notify("textDocument/didClose", params: ["textDocument": ["uri": .string(url.absoluteString)]])
    }

    private static func initializeParams(root: URL) -> JSONValue {
        let textDocument: JSONValue = [
            "synchronization": ["didSave": true, "dynamicRegistration": false],
            "publishDiagnostics": ["relatedInformation": false],
            "completion": [
                "completionItem": ["snippetSupport": false, "documentationFormat": ["markdown", "plaintext"]],
            ],
            "hover": ["contentFormat": ["markdown", "plaintext"]],
            "definition": ["linkSupport": false],
        ]
        let workspace: JSONValue = ["configuration": true, "workspaceFolders": true]
        return [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "GoIDE", "version": "0.1.0"],
            "rootUri": .string(root.absoluteString),
            "workspaceFolders": [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]],
            "capabilities": [
                "textDocument": textDocument,
                "workspace": workspace,
                "general": ["positionEncodings": ["utf-16"]],
            ],
        ]
    }

    // MARK: - go run / build / test

    func runGo(_ arguments: [String]) {
        guard let rootURL, !isRunning else { return }
        guard let go = ToolLocator.find("go") else {
            output = "go not found. Install Go from https://go.dev/dl/\n"
            bottomTab = .output
            return
        }
        if isDirty { save() }
        output = "$ go \(arguments.joined(separator: " "))\n"
        bottomTab = .output
        isRunning = true

        let process = Process()
        process.executableURL = go
        process.arguments = arguments
        process.currentDirectoryURL = rootURL
        process.environment = ToolLocator.environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.appendOutput(chunk) }
        }
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                // Let any final output chunks land first.
                try? await Task.sleep(for: .milliseconds(50))
                self.isRunning = false
                self.runProcess = nil
                self.appendOutput("\n[process exited with status \(status)]\n")
            }
        }
        do {
            try process.run()
            runProcess = process
        } catch {
            isRunning = false
            appendOutput("Failed to start go: \(error.localizedDescription)\n")
        }
    }

    func stopRun() {
        runProcess?.interrupt()
    }

    private func appendOutput(_ s: String) {
        output += s
    }

    // MARK: - Helpers

    static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    private static func firstFile(named name: String, in nodes: [FileNode]) -> URL? {
        if let hit = nodes.first(where: { !$0.isDirectory && $0.name == name }) { return hit.url }
        return nil
    }

    private static func firstGoFile(in nodes: [FileNode]) -> URL? {
        nodes.first(where: { !$0.isDirectory && $0.url.pathExtension == "go" })?.url
    }
}
