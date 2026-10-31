import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { workspace.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { workspace.save() }
                    .keyboardShortcut("s")
                    .disabled(workspace.currentFile == nil)
            }
            CommandMenu("Navigate") {
                Button("Jump to Definition") {
                    Task { await workspace.jumpToDefinition(at: workspace.caretOffset) }
                }
                .keyboardShortcut("j", modifiers: [.control, .command])
                .disabled(!workspace.isGoFile)
                Button("Go Back") { workspace.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
                    .disabled(!workspace.canGoBack)
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
