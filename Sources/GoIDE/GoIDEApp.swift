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
}

@main
struct GoIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspace = Workspace()

    var body: some Scene {
        WindowGroup("GoIDE") {
            ContentView()
                .environment(workspace)
                .onAppear { appDelegate.workspace = workspace }
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { workspace.presentOpenPanel() }
                    .keyboardShortcut("o")
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
                Button("Save") { workspace.save() }
                    .keyboardShortcut("s")
                    .disabled(workspace.activeDocument == nil)
                Button("Save All") { workspace.saveAll() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            CommandMenu("Navigate") {
                Button("Jump to Definition") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.jumpToDefinition(from: document, at: document.caretOffset) }
                }
                .keyboardShortcut("j", modifiers: [.control, .command])
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
            CommandMenu("Go") {
                Button("Run") { workspace.runGo(["run", "."]) }
                    .keyboardShortcut("r")
                Button("Build") { workspace.runGo(["build", "./..."]) }
                    .keyboardShortcut("b")
                Button("Test") { workspace.runGo(["test", "./..."]) }
                    .keyboardShortcut("u")
                Divider()
                Button("Stop") { workspace.stopRun() }
                    .keyboardShortcut(".")
                Divider()
                Button("Restart gopls") { Task { await workspace.restartLanguageServer() } }
            }
        }
    }
}
