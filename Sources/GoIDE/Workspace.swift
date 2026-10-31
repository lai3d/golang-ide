import AppKit
import GoIDECore
import Observation

enum BottomTab: Hashable {
    case problems, output
}

/// A request for an editor to move the caret to a position.
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

/// An open file: its text buffer and per-editor state.
@MainActor
@Observable
final class Document: Identifiable {
    let url: URL
    let isReadOnly: Bool
    var text: String
    var isDirty = false
    var revealTarget: RevealTarget?
    @ObservationIgnored var version = 1
    /// UTF-16 caret offset, reported by the editor.
    @ObservationIgnored var caretOffset = 0

    nonisolated var id: URL { url }
    var name: String { url.lastPathComponent }
    var isGo: Bool { url.pathExtension == "go" }

    init(url: URL, text: String, isReadOnly: Bool) {
        self.url = url
        self.text = text
        self.isReadOnly = isReadOnly
    }
}

/// All state for one project folder: open documents, gopls, and go commands.
@MainActor
@Observable
final class Workspace {
    private(set) var rootURL: URL?
    private(set) var fileTree: [FileNode] = []
    private(set) var documents: [Document] = []
    private(set) var activeDocument: Document?
    private(set) var diagnostics: [String: [Diagnostic]] = [:]  // keyed by normalized path
    private(set) var lspStatus = "gopls: not started"
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var backStack: [NavigationPoint] = []
    var bottomTab: BottomTab = .problems

    @ObservationIgnored private var lsp: LSPClient?
    @ObservationIgnored private var lspReady = false
    @ObservationIgnored private var runProcess: Process?
    @ObservationIgnored private var handledLaunchArguments = false

    var currentFile: URL? { activeDocument?.url }
    var isGoFile: Bool { activeDocument?.isGo ?? false }
    var canGoBack: Bool { !backStack.isEmpty }
    var dirtyDocuments: [Document] { documents.filter(\.isDirty) }

    func diagnostics(for document: Document) -> [Diagnostic] {
        diagnostics[Self.key(for: document.url)] ?? []
    }

    /// Path relative to the project root (or the full path outside it).
    func displayPath(_ path: String) -> String {
        guard let rootURL else { return path }
        let root = Self.key(for: rootURL) + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    var allProblems: [ProblemItem] {
        diagnostics.keys.sorted().flatMap { path in
            diagnostics[path, default: []].map { ProblemItem(path: path, diagnostic: $0) }
        }
    }

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

    /// `GoIDE <folder> [file…]` opens the folder, then any listed files as tabs.
    func handleLaunchArguments() async {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        var folder: URL?
        var files: [URL] = []
        var args = CommandLine.arguments.dropFirst()[...]
        while let arg = args.popFirst() {
            if arg.hasPrefix("--") { _ = args.popFirst(); continue }  // --flag value
            var isDir: ObjCBool = false
            let url = URL(fileURLWithPath: arg).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { folder = folder ?? url } else { files.append(url) }
        }
        guard let folder else { return }
        await openFolder(folder, openDefaultFile: files.isEmpty)
        for file in files { openFile(file) }
    }

    func openFolder(_ url: URL, openDefaultFile: Bool = true) async {
        if !dirtyDocuments.isEmpty {
            guard resolveUnsaved(dirtyDocuments) else { return }
        }
        for document in documents { sendDidClose(document) }
        await stopLanguageServer()
        rootURL = url
        fileTree = FileNode.loadTree(at: url)
        documents = []
        activeDocument = nil
        diagnostics = [:]
        output = ""
        backStack = []
        if openDefaultFile, let file = Self.defaultFile(in: fileTree) {
            openFile(file)
        }
        await startLanguageServer(root: url)
    }

    func reloadTree() {
        guard let rootURL else { return }
        fileTree = FileNode.loadTree(at: rootURL)
    }

    // MARK: - Documents

    /// Opens `url` in a tab (or switches to its existing tab).
    @discardableResult
    func openFile(_ url: URL) -> Document? {
        let key = Self.key(for: url)
        if let existing = documents.first(where: { Self.key(for: $0.url) == key }) {
            activeDocument = existing
            return existing
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return nil }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            appendOutput("Cannot open \(url.path) (not UTF-8 text?)\n")
            bottomTab = .output
            return nil
        }
        let document = Document(url: url, text: contents, isReadOnly: isOutsideProject(url))
        let insertIndex = activeDocument.flatMap { active in documents.firstIndex { $0 === active } }
            .map { $0 + 1 } ?? documents.count
        documents.insert(document, at: insertIndex)
        activeDocument = document
        sendDidOpen(document)
        return document
    }

    func activate(_ document: Document) {
        activeDocument = document
    }

    func selectAdjacentTab(_ delta: Int) {
        guard let active = activeDocument, let index = documents.firstIndex(where: { $0 === active }),
              documents.count > 1 else { return }
        activeDocument = documents[(index + delta + documents.count) % documents.count]
    }

    func closeDocument(_ document: Document) {
        if document.isDirty, !resolveUnsaved([document]) { return }
        remove([document])
    }

    func closeOtherDocuments(than keep: Document) {
        let others = documents.filter { $0 !== keep }
        let dirty = others.filter(\.isDirty)
        if !dirty.isEmpty, !resolveUnsaved(dirty) { return }
        remove(others)
        activeDocument = keep
    }

    func closeAllDocuments() {
        if !dirtyDocuments.isEmpty, !resolveUnsaved(dirtyDocuments) { return }
        remove(documents)
    }

    private func remove(_ toClose: [Document]) {
        for document in toClose {
            sendDidClose(document)
            guard let index = documents.firstIndex(where: { $0 === document }) else { continue }
            documents.remove(at: index)
            if activeDocument === document {
                activeDocument = documents.isEmpty ? nil : documents[min(index, documents.count - 1)]
            }
        }
    }

    /// Asks what to do with unsaved documents. Returns false if the user cancelled.
    func resolveUnsaved(_ dirty: [Document]) -> Bool {
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Do you want to save the changes you made to \(dirty[0].name)?"
            : "You have unsaved changes in \(dirty.count) files."
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            dirty.forEach(save)
            return dirty.allSatisfy { !$0.isDirty }
        case .alertThirdButtonReturn:
            for document in dirty {
                document.isDirty = false  // discard: the buffer is about to be closed
            }
            return true
        default:
            return false
        }
    }

    func updateText(of document: Document, to newText: String) {
        guard newText != document.text else { return }
        document.text = newText
        document.isDirty = true
        document.version += 1
        guard lspReady, document.isGo else { return }
        try? lsp?.notify("textDocument/didChange", params: [
            "textDocument": ["uri": .string(document.url.absoluteString), "version": .int(document.version)],
            "contentChanges": [["text": .string(newText)]],
        ])
    }

    func save() {
        if let activeDocument { save(activeDocument) }
    }

    func saveAll() {
        dirtyDocuments.forEach(save)
    }

    func save(_ document: Document) {
        guard !document.isReadOnly else { return }
        do {
            try document.text.write(to: document.url, atomically: true, encoding: .utf8)
            document.isDirty = false
            if lspReady, document.isGo {
                try? lsp?.notify("textDocument/didSave", params: [
                    "textDocument": ["uri": .string(document.url.absoluteString)],
                ])
            }
        } catch {
            appendOutput("Save failed: \(error.localizedDescription)\n")
            bottomTab = .output
        }
    }

    func reveal(_ problem: ProblemItem) {
        navigate(to: URL(fileURLWithPath: problem.path), position: problem.diagnostic.start)
    }

    // MARK: - Language features

    func completions(in document: Document, at offset: Int) async -> [CompletionItem] {
        guard case let (lsp, params)? = positionRequest(document, at: offset),
              let result = try? await lsp.request("textDocument/completion", params: params)
        else { return [] }
        return CompletionItem.parseList(result)
    }

    func hover(in document: Document, at offset: Int) async -> String? {
        guard case let (lsp, params)? = positionRequest(document, at: offset),
              let result = try? await lsp.request("textDocument/hover", params: params)
        else { return nil }
        return HoverContent.parse(result).map { String($0.prefix(4000)) }
    }

    func jumpToDefinition(from document: Document, at offset: Int) async {
        guard case let (lsp, params)? = positionRequest(document, at: offset) else { return }
        let origin = LineIndex(document.text).position(of: offset)
        let result = try? await lsp.request("textDocument/definition", params: params)
        guard let location = result.map(Location.parseAll)?.first,
              let target = URL(string: location.uri), target.isFileURL
        else {
            flashStatus("No definition found")
            return
        }
        backStack.append(NavigationPoint(url: document.url, position: origin))
        if backStack.count > 100 { backStack.removeFirst() }
        navigate(to: URL(fileURLWithPath: target.path), position: location.start)
    }

    func goBack() {
        guard let point = backStack.popLast() else { return }
        navigate(to: point.url, position: point.position)
    }

    func navigate(to url: URL, position: TextPosition) {
        guard let document = openFile(url) else { return }
        document.revealTarget = RevealTarget(position: position)
    }

    private func positionRequest(_ document: Document, at offset: Int) -> (LSPClient, JSONValue)? {
        guard lspReady, document.isGo, let lsp else { return nil }
        let position = LineIndex(document.text).position(of: offset)
        return (lsp, ["textDocument": ["uri": .string(document.url.absoluteString)], "position": position.json])
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
            documents.forEach(sendDidOpen)
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

    private func sendDidOpen(_ document: Document) {
        guard lspReady, document.isGo else { return }
        try? lsp?.notify("textDocument/didOpen", params: [
            "textDocument": [
                "uri": .string(document.url.absoluteString),
                "languageId": "go",
                "version": .int(document.version),
                "text": .string(document.text),
            ],
        ])
    }

    private func sendDidClose(_ document: Document) {
        guard lspReady, document.isGo else { return }
        try? lsp?.notify("textDocument/didClose", params: [
            "textDocument": ["uri": .string(document.url.absoluteString)],
        ])
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
        saveAll()
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

    /// Files outside the project (stdlib, module cache) open read-only.
    private func isOutsideProject(_ url: URL) -> Bool {
        guard let rootURL else { return false }
        return !Self.key(for: url).hasPrefix(Self.key(for: rootURL) + "/")
    }

    private static func defaultFile(in nodes: [FileNode]) -> URL? {
        let files = nodes.filter { !$0.isDirectory }
        return (files.first { $0.name == "main.go" } ?? files.first { $0.url.pathExtension == "go" })?.url
    }
}
