import AppKit
import GoIDECore
import SwiftUI

/// Language-server hooks the editor calls into. Offsets are UTF-16 offsets in the buffer.
struct EditorServices {
    var completions: @MainActor (Int) async -> [CompletionItem]
    var hover: @MainActor (Int) async -> String?
    var definition: @MainActor (Int) -> Void
    var caretMoved: @MainActor (Int) -> Void
}

/// An NSTextView-based code editor with Go highlighting, diagnostics,
/// completion (type or Esc), hover info, and ⌘-click go-to-definition.
struct CodeEditorView: NSViewRepresentable {
    var text: String
    var highlightGo: Bool
    var isEditable: Bool
    var diagnostics: [Diagnostic]
    var reveal: RevealTarget?
    var services: EditorServices
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let big = CGFloat.greatestFiniteMagnitude
        let textView = CodeTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: big, height: big)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true  // no soft wrap: code scrolls horizontally
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: big, height: big)

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
        textView.isEditable = isEditable

        let coordinator = context.coordinator
        textView.onMouseMoved = { [weak coordinator] index in coordinator?.mouseMoved(to: index) }
        textView.onMouseExited = { [weak coordinator] in coordinator?.endHover() }
        textView.onMouseDown = { [weak coordinator] in coordinator?.dismissPopups() }
        textView.onCommandClick = { [weak coordinator] index in coordinator?.commandClick(at: index) }

        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.didScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        coordinator.textView = textView
        textView.string = text
        coordinator.applyStyling()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }

        if textView.string != text {
            // A different file was opened (typing never gets here: text already matches).
            coordinator.dismissPopups()
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
            let location = index.offset(of: reveal.position)
            let word = GoIdentifier.wordRange(in: textView.string as NSString, at: location)
                ?? NSRange(location: location, length: 0)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(word)
            textView.window?.makeFirstResponder(textView)
            if word.length > 0 { textView.showFindIndicator(for: word) }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.dismissPopups()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: CodeTextView?
        var appliedDiagnostics: [Diagnostic] = []
        var appliedHighlightGo = false
        var lastRevealID: UUID?

        private let completionPopup = CompletionPopup()
        private var completionItems: [CompletionItem] = []
        private var completionTask: Task<Void, Never>?
        private var lastReplacement: String?
        private var isApplyingCompletion = false

        private var hoverTask: Task<Void, Never>?
        private var hoverWord: NSRange?
        private var hoverPopover: NSPopover?

        init(_ parent: CodeEditorView) {
            self.parent = parent
            super.init()
            completionPopup.onAccept = { [weak self] item in self?.accept(item) }
        }

        // MARK: Text changes

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            lastReplacement = replacementString
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.onChange(textView.string)
            applyStyling()
            endHover()

            let typed = lastReplacement
            lastReplacement = nil
            guard parent.highlightGo, !isApplyingCompletion else { return }

            if let typed, typed.utf16.count == 1, let unit = typed.utf16.first,
               unit == 0x2E || GoIdentifier.isIdentifier(unit) {
                if unit == 0x2E {  // "." starts a fresh member completion
                    completionItems = []
                    completionPopup.hide()
                    scheduleCompletion(after: .zero)
                } else {
                    refilterCompletions()
                    scheduleCompletion(after: .milliseconds(80))
                }
            } else if typed == "", completionPopup.isVisible {
                refilterCompletions()
                scheduleCompletion(after: .milliseconds(80))
            } else {
                hideCompletions()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.services.caretMoved(textView.selectedRange().location)
        }

        // MARK: Keys

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if completionPopup.isVisible {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    completionPopup.moveSelection(by: -1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    completionPopup.moveSelection(by: 1)
                    return true
                case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
                    completionPopup.moveSelection(by: -CompletionPopup.visibleRows)
                    return true
                case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
                    completionPopup.moveSelection(by: CompletionPopup.visibleRows)
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    if let item = completionPopup.selectedItem { accept(item) }
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    hideCompletions()
                    return true
                case #selector(NSResponder.deleteBackward(_:)):
                    return false  // keep the list open; textDidChange refilters
                default:
                    hideCompletions()
                }
            }

            switch selector {
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                // Esc / ⌥Esc: show completions on demand.
                if parent.highlightGo && textView.isEditable { scheduleCompletion(after: .zero) }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                autoIndentNewline(in: textView)
                return true
            default:
                return false
            }
        }

        /// Keep the current line's indentation, and add a tab after `{` / `(`.
        private func autoIndentNewline(in textView: NSTextView) {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            let before = ns.substring(with: NSRange(location: lineRange.location,
                                                    length: selection.location - lineRange.location))
            let indent = String(before.prefix { $0 == "\t" || $0 == " " })
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            let extra = (trimmed.hasSuffix("{") || trimmed.hasSuffix("(")) ? "\t" : ""
            textView.insertText("\n" + indent + extra, replacementRange: selection)
        }

        // MARK: Completion

        private func scheduleCompletion(after delay: Duration) {
            completionTask?.cancel()
            completionTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                let offset = textView.selectedRange().location
                let items = await self.parent.services.completions(offset)
                guard !Task.isCancelled else { return }
                self.completionItems = items
                self.refilterCompletions()
            }
        }

        private func refilterCompletions() {
            guard let textView, let window = textView.window, !completionItems.isEmpty else {
                completionPopup.hide()
                return
            }
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            let start = GoIdentifier.prefixStart(in: ns, before: caret)
            let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
            if let first = prefix.utf16.first, !GoIdentifier.isIdentifierStart(first) {
                completionPopup.hide()  // typing a number
                return
            }
            let matches = completionItems.filter { FuzzyMatch.matches(prefix, $0.filterText) }
            if matches.isEmpty || (matches.count == 1 && matches[0].insertText == prefix) {
                completionPopup.hide()
                return
            }
            endHover()
            let anchor = textView.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
            completionPopup.show(matches, below: anchor, in: window)
        }

        private func hideCompletions() {
            completionTask?.cancel()
            completionTask = nil
            completionItems = []
            completionPopup.hide()
        }

        private func accept(_ item: CompletionItem) {
            hideCompletions()
            guard let textView else { return }
            isApplyingCompletion = true
            defer { isApplyingCompletion = false }

            let caret = textView.selectedRange().location
            let start = GoIdentifier.prefixStart(in: textView.string as NSString, before: caret)
            textView.undoManager?.beginUndoGrouping()
            textView.insertText(item.insertText, replacementRange: NSRange(location: start, length: caret - start))
            var newCaret = start + item.insertText.utf16.count

            // Extra edits (e.g. an auto-added import) sit above the caret; apply bottom-up.
            let index = LineIndex(textView.string)
            let extras = item.additionalEdits
                .map { (range: index.range(from: $0.start, to: $0.end), text: $0.newText) }
                .filter { NSMaxRange($0.range) <= start }
                .sorted { $0.range.location > $1.range.location }
            for edit in extras {
                textView.insertText(edit.text, replacementRange: edit.range)
                newCaret += edit.text.utf16.count - edit.range.length
            }
            textView.undoManager?.endUndoGrouping()
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))
            textView.scrollRangeToVisible(NSRange(location: newCaret, length: 0))
        }

        // MARK: Hover

        func mouseMoved(to index: Int?) {
            guard parent.highlightGo, let textView, !completionPopup.isVisible else { return }
            guard let index, let word = GoIdentifier.wordRange(in: textView.string as NSString, at: index) else {
                endHover()
                return
            }
            if word == hoverWord { return }
            endHover()
            hoverWord = word
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                let markdown = await self.parent.services.hover(index)
                guard !Task.isCancelled, self.hoverWord == word, let markdown else { return }
                self.showHover(markdown, for: word)
            }
        }

        func endHover() {
            hoverTask?.cancel()
            hoverTask = nil
            hoverWord = nil
            hoverPopover?.close()
            hoverPopover = nil
        }

        private func showHover(_ markdown: String, for range: NSRange) {
            guard let textView, let window = textView.window else { return }
            let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
            let viewRect = textView.convert(window.convertFromScreen(screenRect), from: nil)
            let host = NSHostingController(rootView: HoverView(markdown: markdown))
            host.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = false
            popover.contentViewController = host
            popover.show(relativeTo: viewRect, of: textView, preferredEdge: .minY)
            hoverPopover = popover
        }

        // MARK: Definition & misc

        func commandClick(at index: Int) {
            dismissPopups()
            guard parent.highlightGo else { return }
            parent.services.definition(index)
        }

        func dismissPopups() {
            endHover()
            hideCompletions()
        }

        @objc func didScroll(_ notification: Notification) {
            dismissPopups()
        }

        // MARK: Styling

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

/// NSTextView that reports hover positions and ⌘-clicks.
final class CodeTextView: NSTextView {
    var onMouseMoved: ((Int?) -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var onCommandClick: ((Int) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?(characterIndex(atWindowPoint: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        if event.modifierFlags.contains(.command), let index = characterIndex(atWindowPoint: event.locationInWindow) {
            setSelectedRange(NSRange(location: index, length: 0))
            onCommandClick?(index)
            return
        }
        super.mouseDown(with: event)
    }

    /// Index of the character under a window point, or nil when the point isn't over text.
    func characterIndex(atWindowPoint windowPoint: NSPoint) -> Int? {
        let length = (string as NSString).length
        guard length > 0, let window else { return nil }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let insertion = characterIndexForInsertion(at: convert(windowPoint, from: nil))
        for candidate in [insertion, insertion - 1] where candidate >= 0 && candidate < length {
            let rect = firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            if rect.width > 0, rect.insetBy(dx: -0.5, dy: -0.5).contains(screenPoint) { return candidate }
        }
        return nil
    }
}
