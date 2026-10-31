import AppKit
import GoIDECore
import SwiftUI

/// Language-server hooks the editor calls into. Offsets are UTF-16 offsets in the buffer.
struct EditorServices {
    var completions: @MainActor (Int) async -> [CompletionItem]
    var hover: @MainActor (Int) async -> String?
    var signatureHelp: @MainActor (Int) async -> SignatureHelp?
    var highlights: @MainActor (Int) async -> [DocumentHighlight]
    var definition: @MainActor (Int) -> Void
    var references: @MainActor (Int) -> Void
    var rename: @MainActor (Int) -> Void
    var codeActions: @MainActor (_ offset: Int, _ length: Int) async -> [CodeAction]
    var performAction: @MainActor (CodeAction) -> Void
    var runTest: @MainActor (String) -> Void
    var toggleBreakpoint: @MainActor (Int) -> Void
    var caretMoved: @MainActor (Int) -> Void
}

/// An NSTextView-based code editor with Go highlighting, diagnostics,
/// completion (type or Esc), hover info, and ⌘-click go-to-definition.
struct CodeEditorView: NSViewRepresentable {
    var text: String
    var highlightGo: Bool
    var isTestFile = false
    var testStatuses: [String: GoTestResult.Status] = [:]
    var breakpoints: Set<Int> = []
    var executionLine: Int?
    var isEditable: Bool
    var isActive: Bool
    var settings = EditorSettings()
    var diagnostics: [Diagnostic]
    var reveal: RevealTarget?
    var quickFixRequest = 0
    var services: EditorServices
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> EditorContainerView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let big = CGFloat.greatestFiniteMagnitude
        // TextKit 1: stable line-fragment APIs for the gutter and current-line highlight.
        let textView = CodeTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
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
        context.coordinator.applySettings(to: textView)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.isEditable = isEditable

        let coordinator = context.coordinator
        textView.onMouseMoved = { [weak coordinator] index in coordinator?.mouseMoved(to: index) }
        textView.onMouseExited = { [weak coordinator] in coordinator?.endHover() }
        textView.onMouseDown = { [weak coordinator] in coordinator?.dismissPopups() }
        textView.onCommandClick = { [weak coordinator] index in coordinator?.commandClick(at: index) }
        textView.contextItems = { [weak coordinator] offset in coordinator?.contextMenuItems(at: offset) ?? [] }

        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.didScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        let ruler = LineNumberRulerView(textView: textView)
        ruler.onRunTest = { [weak coordinator] name in coordinator?.parent.services.runTest(name) }
        ruler.onToggleBreakpoint = { [weak coordinator] line in coordinator?.parent.services.toggleBreakpoint(line) }
        let container = EditorContainerView(scrollView: scrollView, gutter: ruler)

        coordinator.textView = textView
        coordinator.ruler = ruler
        coordinator.lastQuickFixRequest = quickFixRequest
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        ruler.textDidChange()
        coordinator.applyStyling()
        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        let scrollView = container.scrollView
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        if coordinator.appliedSettings != settings {
            coordinator.applySettings(to: textView)
            coordinator.applyStyling()
        }
        if coordinator.isActive != isActive {
            container.isHidden = !isActive
            if isActive {
                if let window = textView.window {
                    window.makeFirstResponder(textView)
                    coordinator.isActive = true
                }  // else: retry on the next update, once in a window
            } else {
                coordinator.dismissPopups()
                coordinator.isActive = false
            }
        }

        if textView.string != text {
            // Changed programmatically (format, rename, reload); typing never gets here.
            coordinator.applyExternalChange(text)
        } else if coordinator.appliedDiagnostics != diagnostics || coordinator.appliedHighlightGo != highlightGo {
            coordinator.applyStyling()
        }
        coordinator.updateTestMarkers()
        if let ruler = coordinator.ruler {
            if ruler.breakpoints != breakpoints { ruler.breakpoints = breakpoints }
            if ruler.executionLine != executionLine { ruler.executionLine = executionLine }
        }
        if textView.executionLine != executionLine { textView.executionLine = executionLine }

        if quickFixRequest != coordinator.lastQuickFixRequest {
            coordinator.lastQuickFixRequest = quickFixRequest
            if isActive { coordinator.showQuickFixes() }
        }

        if let reveal, reveal.id != coordinator.lastRevealID {
            coordinator.lastRevealID = reveal.id
            coordinator.performReveal(reveal, in: scrollView)
        }
    }

    static func dismantleNSView(_ container: EditorContainerView, coordinator: Coordinator) {
        coordinator.dismissPopups()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: CodeTextView?
        weak var ruler: LineNumberRulerView?
        var appliedDiagnostics: [Diagnostic] = []
        var appliedHighlightGo = false
        var lastRevealID: UUID?
        var lastQuickFixRequest = 0
        var isActive: Bool?

        private let completionPopup = CompletionPopup()
        private var completionItems: [CompletionItem] = []
        private var completionTask: Task<Void, Never>?
        private var lastReplacement: String?
        private var isApplyingCompletion = false
        private var isApplyingExternalChange = false

        private let signaturePopup = SignaturePopup()
        private var signatureTask: Task<Void, Never>?

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
            ruler?.textDidChange()
            applyStyling()
            endHover()
            clearOccurrences()  // stale after an edit; the selection change re-requests

            let typed = lastReplacement
            lastReplacement = nil
            guard parent.highlightGo, !isApplyingCompletion, !isApplyingExternalChange else { return }

            // Parameter hints: open on "(" / ",", follow edits while open.
            if typed == "(" || typed == "," {
                scheduleSignatureHelp(after: .zero)
            } else if signaturePopup.isVisible {
                scheduleSignatureHelp(after: .milliseconds(80))
            }

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
            ruler?.needsDisplay = true
            if signaturePopup.isVisible { scheduleSignatureHelp(after: .milliseconds(80)) }
            scheduleOccurrences()
        }

        // MARK: Occurrence highlights

        private var occurrenceTask: Task<Void, Never>?
        private var occurrenceRanges: [NSRange] = []

        /// Highlights other uses of the symbol at the caret, after a short pause.
        private func scheduleOccurrences() {
            occurrenceTask?.cancel()
            guard let textView, parent.highlightGo, textView.selectedRange().length == 0 else {
                clearOccurrences()
                return
            }
            let offset = textView.selectedRange().location
            let ns = textView.string as NSString
            // Only when the caret touches an identifier (either side of it).
            guard GoIdentifier.wordRange(in: ns, at: offset) != nil || GoIdentifier.wordRange(in: ns, at: offset - 1) != nil else {
                clearOccurrences()
                return
            }
            occurrenceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                let highlights = await self.parent.services.highlights(offset)
                guard !Task.isCancelled, let textView = self.textView, textView.selectedRange().location == offset else { return }
                self.showOccurrences(highlights, in: textView)
            }
        }

        private func showOccurrences(_ highlights: [DocumentHighlight], in textView: NSTextView) {
            clearOccurrences()
            guard highlights.count > 1, let layoutManager = textView.layoutManager else { return }
            let index = LineIndex(textView.string)
            let length = (textView.string as NSString).length
            for highlight in highlights {
                let range = index.range(from: highlight.start, to: highlight.end)
                guard NSMaxRange(range) <= length, range.length > 0 else { continue }
                let color: NSColor = highlight.kind == .write
                    ? .systemOrange.withAlphaComponent(0.28)
                    : .systemBlue.withAlphaComponent(0.16)
                // Temporary attributes: drawn by the layout manager, not part of the text or undo.
                layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
                occurrenceRanges.append(range)
            }
        }

        private func clearOccurrences() {
            guard let layoutManager = textView?.layoutManager, !occurrenceRanges.isEmpty else { return }
            let length = (textView?.string as NSString?)?.length ?? 0
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            occurrenceRanges = []
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

            if selector == #selector(NSResponder.cancelOperation(_:)), signaturePopup.isVisible {
                hideSignatureHelp()
                return true
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

        /// Applies a programmatic change as one undoable edit, keeping the caret's line/column.
        func applyExternalChange(_ newText: String) {
            guard let textView, let storage = textView.textStorage else { return }
            dismissPopups()
            guard let change = TextDiff.replacement(from: textView.string, to: newText) else { return }
            let caret = textView.selectedRange().location
            let caretPosition = LineIndex(textView.string).position(of: caret)

            isApplyingExternalChange = true
            defer { isApplyingExternalChange = false }
            let undoable = textView.shouldChangeText(in: change.range, replacementString: change.text)
            storage.replaceCharacters(in: change.range, with: change.text)
            if undoable {
                textView.didChangeText()
            } else {  // read-only view: just refresh
                ruler?.textDidChange()
                applyStyling()
            }

            let delta = change.text.utf16.count - change.range.length
            let newCaret: Int
            if caret <= change.range.location {
                newCaret = caret
            } else if caret >= NSMaxRange(change.range) {
                newCaret = caret + delta
            } else {
                newCaret = LineIndex(newText).offset(of: caretPosition)
            }
            textView.setSelectedRange(NSRange(location: min(max(newCaret, 0), storage.length), length: 0))
        }

        // MARK: Signature help

        private func scheduleSignatureHelp(after delay: Duration) {
            signatureTask?.cancel()
            signatureTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                let offset = textView.selectedRange().location
                let help = await self.parent.services.signatureHelp(offset)
                guard !Task.isCancelled, textView.selectedRange().location == offset else { return }
                guard let help, let window = textView.window else {
                    self.signaturePopup.hide()
                    return
                }
                // Anchor at the callee (`fmt.Printf`), like Xcode/VS Code, so it stays put while typing.
                let start = GoIdentifier.callStart(in: textView.string as NSString, before: offset) ?? offset
                let anchor = textView.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
                self.signaturePopup.show(help, above: anchor, in: window)
            }
        }

        private func hideSignatureHelp() {
            signatureTask?.cancel()
            signatureTask = nil
            signaturePopup.hide()
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

        /// Selects the target and scrolls to it once the view has a real size
        /// (a freshly created editor is still zero-sized during its first update).
        func performReveal(_ reveal: RevealTarget, in scrollView: NSScrollView, attempt: Int = 0) {
            guard let textView else { return }
            guard textView.window != nil, scrollView.contentView.bounds.width > 0 else {
                if attempt < 20 {
                    DispatchQueue.main.async { [weak self, weak scrollView] in
                        guard let self, let scrollView else { return }
                        self.performReveal(reveal, in: scrollView, attempt: attempt + 1)
                    }
                }
                return
            }
            let text = textView.string as NSString
            let location = LineIndex(textView.string).offset(of: reveal.position)
            let length = max(0, min(reveal.length, text.length - location))
            let highlight = length > 0
                ? NSRange(location: location, length: length)
                : GoIdentifier.wordRange(in: text, at: location) ?? NSRange(location: location, length: 0)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: location, length: length))
            scrollToReveal(highlight, in: scrollView)
        }

        /// Puts `range` about a third of the way down, and avoids horizontal scrolling
        /// when the line start is visible anyway.
        func scrollToReveal(_ range: NSRange, in scrollView: NSScrollView) {
            guard let textView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)  // the view may have just been unhidden
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y

            // The clip view extends under the line-number ruler; its content insets mark the
            // usable area, so "scrolled fully left" is x = -insets.left, not 0.
            let clip = scrollView.contentView
            let insets = clip.contentInsets
            let visible = clip.bounds
            let usableWidth = visible.width - insets.left - insets.right
            let usableHeight = visible.height - insets.top - insets.bottom
            var origin = visible.origin
            let visibleTop = visible.minY + insets.top
            if rect.minY < visibleTop || rect.maxY > visibleTop + usableHeight {
                origin.y = rect.midY - usableHeight / 3 - insets.top
            }
            origin.x = rect.maxX + 20 < usableWidth
                ? -insets.left
                : rect.maxX - usableWidth + 40 - insets.left
            let maxY = max(-insets.top, textView.frame.height - visible.height + insets.bottom)
            origin.y = min(max(-insets.top, origin.y), maxY)
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }

        // MARK: Settings

        var appliedSettings: EditorSettings?

        func applySettings(to textView: NSTextView) {
            let settings = parent.settings
            textView.font = EditorTheme.font(settings)
            textView.typingAttributes = EditorTheme.baseAttributes(settings)
            textView.defaultParagraphStyle = EditorTheme.paragraphStyle(settings)
            appliedSettings = settings
        }

        // MARK: Test markers

        private var testMarkerKey = ""

        /// ▶ / ✓ / ✗ next to test functions in _test.go files.
        func updateTestMarkers(force: Bool = false) {
            guard let textView, let ruler else { return }
            guard parent.isTestFile else {
                if !ruler.testMarkers.isEmpty { ruler.testMarkers = [:] }
                return
            }
            let tests = GoTestFinder.testFunctions(in: textView.string)
            let key = tests.map { "\($0.name)@\($0.line):\(String(describing: parent.testStatuses[$0.name]))" }.joined(separator: ",")
            guard force || key != testMarkerKey else { return }
            testMarkerKey = key
            ruler.testMarkers = Dictionary(tests.map { ($0.line, LineNumberRulerView.TestMarker(
                name: $0.name, status: parent.testStatuses[$0.name])) }, uniquingKeysWith: { a, _ in a })
        }

        // MARK: Definition & misc

        func commandClick(at index: Int) {
            dismissPopups()
            guard parent.highlightGo else { return }
            parent.services.definition(index)
        }

        /// Language actions at the top of the editor's right-click menu.
        func contextMenuItems(at offset: Int) -> [NSMenuItem] {
            guard parent.highlightGo else { return [] }
            dismissPopups()
            return [
                ActionMenuItem(title: "Jump to Definition") { [weak self] in self?.parent.services.definition(offset) },
                ActionMenuItem(title: "Find References") { [weak self] in self?.parent.services.references(offset) },
                ActionMenuItem(title: "Rename Symbol…") { [weak self] in self?.parent.services.rename(offset) },
                ActionMenuItem(title: "Quick Fix…") { [weak self] in
                    DispatchQueue.main.async { self?.showQuickFixes() }  // after this menu closes
                },
            ]
        }

        /// Pops up the code actions for the caret/selection below the caret (⌥↩).
        func showQuickFixes() {
            guard let textView, parent.highlightGo else { return }
            dismissPopups()
            let selection = textView.selectedRange()
            Task { [weak self] in
                guard let self else { return }
                let actions = await self.parent.services.codeActions(selection.location, selection.length)
                guard let textView = self.textView, let window = textView.window else { return }
                let menu = NSMenu()
                menu.autoenablesItems = false
                let groups: [(String, [CodeAction])] = [
                    ("Quick Fixes", actions.filter { $0.kind == nil || $0.kind!.hasPrefix("quickfix") }),
                    ("Refactor", actions.filter { $0.kind?.hasPrefix("refactor") == true }),
                    ("Source", actions.filter {
                        guard let kind = $0.kind else { return false }
                        return !kind.hasPrefix("quickfix") && !kind.hasPrefix("refactor")
                    }),
                ]
                for (title, group) in groups where !group.isEmpty {
                    if !menu.items.isEmpty { menu.addItem(.separator()) }
                    menu.addItem(NSMenuItem.sectionHeader(title: title))
                    for action in group.sorted(by: { $0.isPreferred && !$1.isPreferred }) {
                        menu.addItem(ActionMenuItem(title: action.title) { [weak self] in
                            self?.parent.services.performAction(action)
                        })
                    }
                }
                if menu.items.isEmpty {
                    let none = NSMenuItem(title: "No Actions Available", action: nil, keyEquivalent: "")
                    none.isEnabled = false
                    menu.addItem(none)
                }
                let screen = textView.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: nil)
                let rect = textView.convert(window.convertFromScreen(screen), from: nil)
                menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: textView)
            }
        }

        func dismissPopups() {
            endHover()
            hideCompletions()
            hideSignatureHelp()
        }

        @objc func didScroll(_ notification: Notification) {
            dismissPopups()
            ruler?.needsDisplay = true  // the gutter is a sibling view: redraw to follow
        }

        // MARK: Styling

        func applyStyling() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = textView.string
            let fullRange = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.setAttributes(EditorTheme.baseAttributes(parent.settings), range: fullRange)
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

            var markers: [Int: Diagnostic.Severity] = [:]
            for diagnostic in parent.diagnostics {
                let line = diagnostic.start.line
                if let existing = markers[line], existing.rawValue <= diagnostic.severity.rawValue { continue }
                markers[line] = diagnostic.severity
            }
            ruler?.diagnosticMarkers = markers
            updateTestMarkers(force: true)

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
    var contextItems: ((Int) -> [NSMenuItem])?
    private var hoverArea: NSTrackingArea?
    /// Zero-based line where the debugger is paused (highlighted).
    var executionLine: Int? {
        didSet { if executionLine != oldValue { needsDisplay = true } }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        // Right-clicking outside the selection moves the caret there first, like Xcode.
        if let index = characterIndex(atWindowPoint: event.locationInWindow),
           !NSLocationInRange(index, selectedRange()) {
            setSelectedRange(NSRange(location: index, length: 0))
        }
        let items = contextItems?(selectedRange().location) ?? []
        for (position, item) in items.enumerated() { menu.insertItem(item, at: position) }
        if !items.isEmpty { menu.insertItem(.separator(), at: items.count) }
        return menu
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true  // move the current-line highlight
    }

    /// Subtle highlight behind the caret's line; green behind the debugger's line.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let executionLine, let fragment = lineFragmentRect(forLine: executionLine) {
            NSColor.systemGreen.withAlphaComponent(0.22).setFill()
            fragment.intersection(rect).fill()
        }
        guard selectedRange().length == 0, let layoutManager, let textContainer else { return }
        let text = string as NSString
        let location = selectedRange().location
        var lineRect: NSRect
        if text.length == 0 || (location >= text.length && text.hasSuffix("\n")) {
            guard layoutManager.extraLineFragmentTextContainer === textContainer else { return }
            lineRect = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, text.length - 1))
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        lineRect.origin.x = 0
        lineRect.origin.y += textContainerOrigin.y
        lineRect.size.width = bounds.width
        NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
        lineRect.intersection(rect).fill()
    }

    /// The full-width rect of a zero-based line, in view coordinates.
    func lineFragmentRect(forLine line: Int) -> NSRect? {
        guard let layoutManager else { return nil }
        let text = string as NSString
        var start = 0
        for _ in 0..<line {
            guard start < text.length else { return nil }
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
        }
        guard start < text.length else { return nil }
        var rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start),
                                                  effectiveRange: nil)
        rect.origin.x = 0
        rect.origin.y += textContainerOrigin.y
        rect.size.width = bounds.width
        return rect
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

/// An NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// Gutter + scroll view side by side.
final class EditorContainerView: NSView {
    let scrollView: NSScrollView
    let gutter: LineNumberRulerView

    init(scrollView: NSScrollView, gutter: LineNumberRulerView) {
        self.scrollView = scrollView
        self.gutter = gutter
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
        gutter.onThicknessChange = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = gutter.ruleThickness
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        gutter.needsDisplay = true
    }
}
