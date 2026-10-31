import AppKit
import GoIDECore

/// Line numbers plus diagnostic markers, drawn alongside a TextKit 1 NSTextView.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineIndex = LineIndex("")

    /// Worst diagnostic severity per zero-based line.
    var diagnosticMarkers: [Int: Diagnostic.Severity] = [:] {
        didSet { if diagnosticMarkers != oldValue { needsDisplay = true } }
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.textView = textView
        clientView = textView
        clipsToBounds = true  // macOS 14+ doesn't clip by default
        textDidChange()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var font: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    /// Call after the text view's contents change.
    func textDidChange() {
        lineIndex = LineIndex(textView?.string ?? "")
        let digits = max(3, String(lineIndex.lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth + 26)
        if ruleThickness != thickness { ruleThickness = thickness }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let caretLine = lineIndex.position(of: textView.selectedRange().location).line
        let originY = textView.textContainerOrigin.y

        func draw(line: Int, fragment: NSRect) {
            let y = convert(NSPoint(x: 0, y: fragment.minY + originY), from: textView).y
            let isCaretLine = line == caretLine
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isCaretLine ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold) : font,
                .foregroundColor: isCaretLine ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ]
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.maxX - 8 - size.width, y: y + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            if let severity = diagnosticMarkers[line] {
                let color: NSColor = severity == .error ? .systemRed : .systemYellow
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 5, y: y + fragment.height / 2 - 3.5, width: 7, height: 7)).fill()
            }
        }

        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var charIndex = text.length == 0 ? 0 : text.lineRange(for: NSRange(location: chars.location, length: 0)).location
        var line = lineIndex.position(of: charIndex).line

        while charIndex < text.length && charIndex <= NSMaxRange(chars) {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: charIndex)
            draw(line: line, fragment: layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
            charIndex = NSMaxRange(lineRange)
            line += 1
        }
        // The empty last line after a trailing newline (or an empty document).
        if charIndex >= text.length, layoutManager.extraLineFragmentTextContainer != nil {
            draw(line: lineIndex.lineCount - 1, fragment: layoutManager.extraLineFragmentRect)
        }
    }
}
