import AppKit
import GoIDECore

/// User-adjustable editor settings (stored in UserDefaults, edited in Settings).
struct EditorSettings: Equatable {
    static let fontSizeKey = "editorFontSize"
    static let tabWidthKey = "editorTabWidth"

    var fontSize: Double = 13
    var tabWidth: Int = 4
}

@MainActor
enum EditorTheme {
    static func font(_ settings: EditorSettings) -> NSFont {
        .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
    }

    static func paragraphStyle(_ settings: EditorSettings) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font(settings)]).width
        style.tabStops = []
        style.defaultTabInterval = spaceWidth * CGFloat(settings.tabWidth)  // gofmt uses tabs
        return style
    }

    static func baseAttributes(_ settings: EditorSettings) -> [NSAttributedString.Key: Any] {
        [.font: font(settings), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle(settings)]
    }

    // System colors adapt to light and dark mode automatically.
    static func color(for kind: GoTokenKind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .type: .systemTeal
        case .builtin: .systemPurple
        case .function: .systemBlue
        case .string: .systemOrange
        case .number: .systemIndigo
        case .comment: .systemGreen
        }
    }
}
