import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: Workspace?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace, !workspace.dirtyDocuments.isEmpty else { return .terminateNow }
        return workspace.resolveUnsaved(workspace.dirtyDocuments) ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a dead language server's stdin must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Snapshot.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        workspace?.stopDebugging()  // ends dlv and the debuggee
    }
}

@main
struct GoIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspace = Workspace()
    @AppStorage("formatOnSave") private var formatOnSave = true

    private static func functionKey(_ key: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt32(key))!))
    }

    var body: some Scene {
        WindowGroup("GoIDE") {
            ContentView()
                .environment(workspace)
                .onAppear {
                    appDelegate.workspace = workspace
                    Workspace.current = workspace
                }
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { workspace.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .printItem) {
                Button("Open Quickly…") { workspace.showQuickOpen() }
                    .keyboardShortcut("p")
                    .disabled(workspace.rootURL == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") {
                    if let document = workspace.activeDocument { workspace.closeDocument(document) }
                }
                .keyboardShortcut("w")
                .disabled(workspace.activeDocument == nil)
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Save") { Task { await workspace.saveActiveFormatted() } }
                    .keyboardShortcut("s")
                    .disabled(workspace.activeDocument == nil)
                Button("Save All") { Task { await workspace.saveAllFormatted() } }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Project…") { workspace.showSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("Navigate") {
                Button("Open Quickly…") { workspace.showQuickOpen() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(workspace.rootURL == nil)
                Divider()
                Button("Jump to Definition") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.jumpToDefinition(from: document, at: document.caretOffset) }
                }
                .keyboardShortcut("j", modifiers: [.control, .command])
                .disabled(!workspace.isGoFile)
                Button("Find References") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.findReferences(in: document, at: document.caretOffset) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!workspace.isGoFile)
                Button("Call Hierarchy") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.showCallHierarchy(in: document, at: document.caretOffset) }
                }
                .keyboardShortcut("h", modifiers: [.control, .option])
                .disabled(!workspace.isGoFile)
                Button("Go Back") { workspace.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
                    .disabled(!workspace.canGoBack)
                Divider()
                Button("Next Tab") { workspace.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { workspace.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
            CommandMenu("Refactor") {
                Button("Rename Symbol…") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.promptRename(in: document, at: document.caretOffset) }
                }
                .keyboardShortcut("e", modifiers: [.control, .command])
                .disabled(!workspace.isGoFile)
                Button("Quick Fix…") { workspace.requestQuickFix() }
                    .keyboardShortcut(.return, modifiers: .option)
                    .disabled(!workspace.isGoFile)
            }
            CommandMenu("Debug") {
                Button("Start Debugging") { workspace.startDebugging() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(workspace.rootURL == nil || workspace.isDebugging)
                Button("Stop Debugging") { workspace.stopDebugging() }
                    .disabled(!workspace.isDebugging)
                Divider()
                Button("Continue") { workspace.debugSession?.resume() }
                    .keyboardShortcut("y", modifiers: [.control, .command])
                    .disabled(workspace.debugSession?.state != .stopped)
                Button("Pause") { workspace.debugSession?.pause() }
                    .disabled(workspace.debugSession?.state != .running)
                Button("Step Over") { workspace.debugSession?.stepOver() }
                    .keyboardShortcut(Self.functionKey(NSF6FunctionKey), modifiers: [])
                    .disabled(workspace.debugSession?.state != .stopped)
                Button("Step Into") { workspace.debugSession?.stepInto() }
                    .keyboardShortcut(Self.functionKey(NSF7FunctionKey), modifiers: [])
                    .disabled(workspace.debugSession?.state != .stopped)
                Button("Step Out") { workspace.debugSession?.stepOut() }
                    .keyboardShortcut(Self.functionKey(NSF8FunctionKey), modifiers: [])
                    .disabled(workspace.debugSession?.state != .stopped)
                Divider()
                Button("Toggle Breakpoint") { workspace.toggleBreakpointAtCaret() }
                    .keyboardShortcut("\\", modifiers: .command)
                    .disabled(!workspace.isGoFile)
                Button("Remove All Breakpoints") { workspace.clearBreakpoints() }
                    .disabled(workspace.breakpoints.isEmpty)
            }
            CommandMenu("Go") {
                Button("Run") { workspace.runGo(["run", "."]) }
                    .keyboardShortcut("r")
                Button("Build") { workspace.runGo(["build", "./..."]) }
                    .keyboardShortcut("b")
                Button("Test All") { workspace.runTests(.all) }
                    .keyboardShortcut("u")
                Button("Test Package") { workspace.runActivePackageTests() }
                    .keyboardShortcut("u", modifiers: [.control, .command])
                Button("Run Test at Cursor") { workspace.runTestAtCaret() }
                    .keyboardShortcut("u", modifiers: [.control, .option, .command])
                Divider()
                Button("Stop") { workspace.stopRun() }
                    .keyboardShortcut(".")
                Divider()
                Button("Format Document") { Task { await workspace.formatActiveDocument() } }
                    .keyboardShortcut("f", modifiers: [.option, .shift])
                    .disabled(!workspace.isGoFile)
                Toggle("Format on Save", isOn: $formatOnSave)
                Divider()
                Button("Restart gopls") { Task { await workspace.restartLanguageServer() } }
            }
        }
        Settings {
            SettingsView().environment(workspace)
        }
    }
}
