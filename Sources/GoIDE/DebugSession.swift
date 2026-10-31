import AppKit
import GoIDECore
import Observation

enum DebugState: Equatable {
    case starting, running, stopped, terminated
}

/// Where the debuggee is paused (one-based line, as DAP reports it).
struct ExecutionLocation: Equatable {
    let path: String
    let line: Int
}

/// A variable (or scope) in the Variables tree; children load when expanded.
@MainActor
@Observable
final class VariableNode: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let type: String?
    let reference: Int
    var children: [VariableNode]?
    var isExpanded = false

    init(_ variable: DebugVariable) {
        name = variable.name
        value = variable.value
        type = variable.type
        reference = variable.variablesReference
    }
}

/// One Delve debugging session, driven over DAP.
@MainActor
@Observable
final class DebugSession {
    let title: String
    private(set) var state: DebugState = .starting
    private(set) var stopReason: String?
    private(set) var frames: [StackFrame] = []
    private(set) var selectedFrameID: Int?
    private(set) var scopes: [VariableNode] = []
    private(set) var errorMessage: String?

    @ObservationIgnored private let client = DAPClient()
    @ObservationIgnored private var threadID: Int?
    @ObservationIgnored var onLocation: ((ExecutionLocation?) -> Void)?
    @ObservationIgnored var onOutput: ((String) -> Void)?

    init(title: String) {
        self.title = title
    }

    var isActive: Bool { state != .terminated }

    /// Launches Delve, sets breakpoints (one-based lines per path) and starts the program.
    func start(dlv: URL, directory: URL, launch: JSONValue, breakpoints: [String: Set<Int>]) async {
        client.onEvent = { event, body in
            Task { @MainActor in self.handle(event: event, body: body) }
        }
        client.onExit = {
            Task { @MainActor in self.finish() }
        }
        do {
            try await client.start(dlv: dlv, directory: directory, environment: ToolLocator.environment()) { text in
                Task { @MainActor in self.onOutput?(text) }
            }
            try await client.request("initialize", arguments: [
                "clientID": "goide", "clientName": "GoIDE", "adapterID": "go",
                "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
                "supportsVariableType": true,
            ])
            try await client.request("launch", arguments: launch)
            await client.waitForEvent("initialized")
            for (path, lines) in breakpoints where !lines.isEmpty {
                await setBreakpoints(path: path, lines: lines)
            }
            try await client.request("configurationDone")
            if state == .starting { state = .running }
        } catch {
            errorMessage = error.localizedDescription
            onOutput?("Debugger error: \(error.localizedDescription)\n")
            await client.shutdown()
            finish()
        }
    }

    func setBreakpoints(path: String, lines: Set<Int>) async {
        guard state != .terminated else { return }
        _ = try? await client.request("setBreakpoints", arguments: [
            "source": ["path": .string(path)],
            "breakpoints": .array(lines.sorted().map { ["line": .int($0)] }),
        ])
    }

    // MARK: Execution control

    func resume() { command("continue") }
    func stepOver() { command("next") }
    func stepInto() { command("stepIn") }
    func stepOut() { command("stepOut") }

    func pause() {
        guard state == .running else { return }
        Task { try? await client.request("pause", arguments: ["threadId": .int(threadID ?? 1)]) }
    }

    func stop() {
        Task {
            await client.shutdown()
            finish()
        }
    }

    private func command(_ name: String) {
        guard state == .stopped, let threadID else { return }
        state = .running
        frames = []
        scopes = []
        onLocation?(nil)
        Task {
            do {
                try await client.request(name, arguments: ["threadId": .int(threadID)])
            } catch {
                onOutput?("\(name) failed: \(error.localizedDescription)\n")
            }
        }
    }

    // MARK: Inspection

    func select(frameID: Int) async {
        guard let frame = frames.first(where: { $0.id == frameID }) else { return }
        selectedFrameID = frameID
        if let path = frame.path { onLocation?(ExecutionLocation(path: path, line: frame.line)) }
        guard let body = try? await client.request("scopes", arguments: ["frameId": .int(frameID)]) else { return }
        let nodes = DebugVariable.parseScopes(body).map(VariableNode.init)
        scopes = nodes
        // Locals (and Arguments) open by default; Globals stay collapsed (expensive).
        for node in nodes where !node.name.lowercased().contains("global") {
            await expand(node)
        }
    }

    func expand(_ node: VariableNode) async {
        node.isExpanded = true
        guard node.children == nil, node.reference > 0,
              let body = try? await client.request("variables", arguments: ["variablesReference": .int(node.reference)])
        else { return }
        node.children = DebugVariable.parseVariables(body).map(VariableNode.init)
    }

    // MARK: Events

    private func handle(event: String, body: JSONValue) {
        switch event {
        case "stopped":
            state = .stopped
            stopReason = body["reason"]?.stringValue
            if let thread = body["threadId"]?.intValue { threadID = thread }
            Task { await refreshStack() }
        case "continued":
            state = .running
        case "output":
            if let text = body["output"]?.stringValue, body["category"]?.stringValue != "telemetry" {
                onOutput?(text)
            }
        case "terminated", "exited":
            if event == "exited", let code = body["exitCode"]?.intValue {
                onOutput?("\n[program exited with status \(code)]\n")
            }
            if event == "terminated" {
                Task {
                    await client.shutdown()
                    finish()
                }
            }
        default:
            break
        }
    }

    private func refreshStack() async {
        if threadID == nil,
           let threads = try? await client.request("threads"),
           let first = threads["threads"]?[0]?["id"]?.intValue {
            threadID = first
        }
        guard let threadID,
              let body = try? await client.request("stackTrace", arguments: ["threadId": .int(threadID), "levels": 50])
        else { return }
        frames = StackFrame.parseAll(body)
        // Start at the first frame with source (skips runtime frames without a path).
        if let frame = frames.first(where: { $0.path != nil }) ?? frames.first {
            await select(frameID: frame.id)
        }
    }

    private func finish() {
        guard state != .terminated else { return }
        state = .terminated
        frames = []
        scopes = []
        onLocation?(nil)
    }
}
