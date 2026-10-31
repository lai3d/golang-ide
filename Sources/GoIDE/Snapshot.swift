import AppKit

/// Debug aid: renders the main window (plus popups) to a PNG off-screen — no Screen
/// Recording permission needed — then exits.
///
///     GoIDE <folder> [file…] --snapshot out.png [--snapshot-delay 4]
///         [--snapshot-search QUERY] [--snapshot-line N --snapshot-type TEXT] [--snapshot-format]
@MainActor
enum Snapshot {
    static func scheduleIfRequested() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--snapshot") else { return }
        let delay = value("--snapshot-delay").flatMap(Double.init) ?? 4

        Task {
            try? await Task.sleep(for: .seconds(delay))
            let workspace = Workspace.current

            if let query = value("--snapshot-search"), let workspace {
                workspace.showSearch()
                workspace.searchQuery = query
                await workspace.performSearch()
                if let file = workspace.searchResults.first, let match = file.matches.first {
                    workspace.open(match, in: file)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let line = value("--snapshot-line").flatMap(Int.init),
               let textView = NSApp.windows.first?.firstResponder as? NSTextView {
                // Caret at the end of 1-based `line`.
                let ns = textView.string as NSString
                var start = 0
                for _ in 1..<max(line, 1) {
                    start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))
                }
                let lineRange = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
                var end = NSMaxRange(lineRange)
                if end > lineRange.location, end <= ns.length, ns.character(at: end - 1) == 0x0A { end -= 1 }
                textView.setSelectedRange(NSRange(location: end, length: 0))
            }
            if let text = value("--snapshot-type"),
               let textView = NSApp.windows.first?.firstResponder as? NSTextView {
                // Type like a user would (exercises completion / signature triggers).
                for character in text {
                    textView.insertText(String(character), replacementRange: textView.selectedRange())
                    try? await Task.sleep(for: .milliseconds(40))
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
            if let column = value("--snapshot-references").flatMap(Int.init), let workspace,
               let document = workspace.activeDocument,
               let textView = NSApp.windows.first?.firstResponder as? NSTextView {
                // Caret is at the end of --snapshot-line; step back to the given 0-based column.
                let ns = textView.string as NSString
                let lineStart = ns.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0)).location
                await workspace.findReferences(in: document, at: lineStart + column)
                try? await Task.sleep(for: .milliseconds(400))
            }
            if args.contains("--snapshot-format"), let workspace {
                await workspace.formatActiveDocument()
                try? await Task.sleep(for: .milliseconds(300))
            }

            if let window = NSApp.windows.first(where: { $0.isVisible && $0.parent == nil && $0.contentView != nil }),
               let image = render(window) {
                try? image.write(to: URL(fileURLWithPath: path))
                print("snapshot written to \(path)")
            } else {
                print("snapshot failed: no window")
            }
            exit(0)  // skip the unsaved-changes prompt
        }
    }

    /// The window's frame view plus any visible child windows (completion, signature
    /// popups) composited at their on-screen offsets, as PNG data.
    private static func render(_ window: NSWindow) -> Data? {
        guard let root = window.contentView?.superview ?? window.contentView,
              let base = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: base)

        let image = NSImage(size: root.bounds.size)
        image.lockFocus()
        base.draw(in: root.bounds)
        for child in window.childWindows ?? [] where child.isVisible {
            guard let view = child.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let origin = NSPoint(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY)
            NSColor.black.withAlphaComponent(0.15).setFill()  // stand-in for the window shadow
            NSRect(origin: origin, size: view.bounds.size).insetBy(dx: -1, dy: -1).frame()
            rep.draw(in: NSRect(origin: origin, size: view.bounds.size))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
