import AppKit
import GoIDECore

/// Line numbers plus diagnostic/test markers for a TextKit 1 NSTextView. A plain view placed
/// beside the scroll view (not an NSRulerView: rulers overlap the clip view via content insets,
/// which confuses horizontal scrolling).
final class LineNumberRulerView: NSView {
    private weak var textView: NSTextView?
    /// Called when the width changes so the container can re-lay out.
    var onThicknessChange: (() -> Void)?
    private(set) var ruleThickness: CGFloat = 40 {
        didSet { if ruleThickness != oldValue { onThicknessChange?() } }
    }
    private var lineIndex = LineIndex("")

    struct TestMarker: Equatable {
        let name: String
        let status: GoTestResult.Status?
    }

    /// Test functions per zero-based line: click to run.
    var testMarkers: [Int: TestMarker] = [:] {
        didSet { if testMarkers != oldValue { needsDisplay = true } }
    }
    var onRunTest: ((String) -> Void)?

    /// Worst diagnostic severity per zero-based line.
    var diagnosticMarkers: [Int: Diagnostic.Severity] = [:] {
        didSet { if diagnosticMarkers != oldValue { needsDisplay = true } }
    }

    init(textView: NSTextView) {
        super.init(frame: .zero)
        self.textView = textView
        clipsToBounds = true  // macOS 14+ doesn't clip by default
        textDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override var isFlipped: Bool { true }

    private var font: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    /// Call after the text view's contents change.
    func textDidChange() {
        lineIndex = LineIndex(textView?.string ?? "")
        let digits = max(3, String(lineIndex.lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth + 26)
        ruleThickness = thickness
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let line = line(at: convert(event.locationInWindow, from: nil)),
              let test = testMarkers[line] else { return super.mouseDown(with: event) }
        _ = textView
        onRunTest?(test.name)
    }

    /// The zero-based line at a point in ruler coordinates.
    private func line(at point: NSPoint) -> Int? {
        guard let textView else { return nil }
        let inText = textView.convert(point, from: self)
        let index = textView.characterIndexForInsertion(at: NSPoint(x: 0, y: inText.y))
        return lineIndex.position(of: index).line
    }

    private func drawHashMarksAndLabels(in rect: NSRect) {
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
            if let test = testMarkers[line] {
                let (symbol, color): (String, NSColor) = switch test.status {
                case .passed?: ("checkmark.circle.fill", .systemGreen)
                case .failed?: ("xmark.circle.fill", .systemRed)
                case .running?: ("clock.fill", .secondaryLabelColor)
                default: ("play.fill", .systemGreen)
                }
                // Circle symbols: white glyph on a colored disc; play: just colored.
                let palette: [NSColor] = symbol.hasSuffix("circle.fill") ? [.white, color] : [color]
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                    .applying(.init(paletteColors: palette))
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Run \(test.name)")?
                    .withSymbolConfiguration(config) {
                    let size = image.size
                    image.draw(in: NSRect(x: 4, y: y + (fragment.height - size.height) / 2,
                                          width: size.width, height: size.height))
                }
            } else if let severity = diagnosticMarkers[line] {
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
