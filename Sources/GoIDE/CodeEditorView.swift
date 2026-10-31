import AppKit
import GoIDECore
import SwiftUI

/// An NSTextView-based code editor with Go highlighting and diagnostic underlines.
struct CodeEditorView: NSViewRepresentable {
    var text: String
    var highlightGo: Bool
    var diagnostics: [Diagnostic]
    var reveal: RevealTarget?
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = true
        let textView = scrollView.documentView as! NSTextView

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = EditorTheme.font
        textView.typingAttributes = EditorTheme.baseAttributes
        textView.defaultParagraphStyle = EditorTheme.paragraphStyle
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.backgroundColor = .textBackgroundColor

        // No soft wrap: code scrolls horizontally.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)

        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.applyStyling()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        if textView.string != text {
            // A different file was opened (typing never gets here: text already matches).
            textView.string = text
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
            coordinator.applyStyling()
        } else if coordinator.appliedDiagnostics != diagnostics || coordinator.appliedHighlightGo != highlightGo {
            coordinator.applyStyling()
        }

        if let reveal, reveal.id != coordinator.lastRevealID {
            coordinator.lastRevealID = reveal.id
            let index = LineIndex(textView.string)
            let range = NSRange(location: index.offset(of: reveal.position), length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: NSTextView?
        var appliedDiagnostics: [Diagnostic] = []
        var appliedHighlightGo = false
        var lastRevealID: UUID?

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.onChange(textView.string)
            applyStyling()
        }

        /// Auto-indent: keep the current line's indentation, and add a tab after `{` / `(`.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            let before = ns.substring(with: NSRange(location: lineRange.location,
                                                    length: selection.location - lineRange.location))
            let indent = String(before.prefix { $0 == "\t" || $0 == " " })
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            let extra = (trimmed.hasSuffix("{") || trimmed.hasSuffix("(")) ? "\t" : ""
            textView.insertText("\n" + indent + extra, replacementRange: selection)
            return true
        }

        func applyStyling() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = textView.string
            let fullRange = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.setAttributes(EditorTheme.baseAttributes, range: fullRange)
            if parent.highlightGo {
                for token in GoHighlighter.tokenize(text) {
                    storage.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.kind), range: token.range)
                }
            }
            let index = LineIndex(text)
            for diagnostic in parent.diagnostics {
                var range = index.range(from: diagnostic.start, to: diagnostic.end)
                if range.length == 0 { range.length = min(1, storage.length - range.location) }
                guard range.length > 0 else { continue }
                let color: NSColor = diagnostic.severity == .error ? .systemRed : .systemYellow
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: color,
                    .toolTip: diagnostic.message,
                ], range: range)
            }
            storage.endEditing()

            appliedDiagnostics = parent.diagnostics
            appliedHighlightGo = parent.highlightGo
        }
    }
}
