import AppKit

/// Small modal dialogs for file operations.
@MainActor
enum Prompt {
    static func text(title: String, message: String = "", initial: String, confirm: String, allowEmpty: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // Pre-select the name without its extension, like Finder.
        let base = (initial as NSString).deletingPathExtension as NSString
        DispatchQueue.main.async {
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: base.length)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty && !allowEmpty ? nil : value
    }

    /// Rename dialog: returns the new name and whether to preview first (Preview… button).
    static func rename(title: String, message: String, initial: String) -> (String, preview: Bool)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Preview…")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async { field.currentEditor()?.selectAll(nil) }
        let response = alert.runModal()
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch response {
        case .alertFirstButtonReturn: return (value, false)
        case .alertThirdButtonReturn: return (value, true)
        default: return nil
        }
    }

    static func confirm(title: String, message: String, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func attempt(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
