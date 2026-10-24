import AppKit

/// Fonts, colors and measurements shared by the reader and the editor.
/// Every color is dynamic, so light and dark mode switch without re-rendering.
enum Style {
    /// The widest a line of text gets, at 100 %: about 80 characters.
    static let column: CGFloat = 720
    /// The smallest margin left and right of the text.
    static let margin: CGFloat = 28
    static let zoomLevels: [CGFloat] = [0.75, 0.85, 1, 1.15, 1.3, 1.5, 1.75, 2, 2.5]

    static func bodyFont(scale: CGFloat) -> NSFont { .systemFont(ofSize: 15 * scale) }
    static func codeFont(scale: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: 13 * scale, weight: .regular) }
    static func editorFont(scale: CGFloat) -> NSFont { .systemFont(ofSize: 14 * scale) }
    static func editorMonoFont(scale: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: 13 * scale, weight: .regular) }

    static func headingFont(level: Int, scale: CGFloat) -> NSFont {
        let sizes: [CGFloat] = [30, 24, 19.5, 17, 15, 14]
        let size = sizes[min(max(level, 1), 6) - 1] * scale
        return .systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
    }

    /// Background of code blocks, inline code and table headers.
    static let codeBackground = NSColor(name: "codeBackground") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 0, alpha: 0.045)
    }

    /// Lines: table borders, rules, the bar beside quotes, under big headings.
    static let rule = NSColor(name: "rule") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.13)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
