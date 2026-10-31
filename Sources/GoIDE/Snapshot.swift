import AppKit

/// Debug aid: `GoIDE <folder> --snapshot out.png [--snapshot-delay 4]` renders the
/// main window to a PNG (off-screen, no Screen Recording permission needed) and quits.
@MainActor
enum Snapshot {
    static func scheduleIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        var delay = 4.0
        if let d = args.firstIndex(of: "--snapshot-delay"), d + 1 < args.count, let v = Double(args[d + 1]) { delay = v }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if args.contains("--snapshot-format"), let workspace = Workspace.current {
                await workspace.formatActiveDocument()
                try? await Task.sleep(for: .milliseconds(300))
            }
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
               let view = window.contentView?.superview ?? window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("snapshot written to \(path)")
            } else {
                print("snapshot failed: no window")
            }
            exit(0)  // skip the unsaved-changes prompt
        }
    }
}
