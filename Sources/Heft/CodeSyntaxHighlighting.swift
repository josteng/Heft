import AppKit
import HeftCore
import MarkdownEngineCodeBlocks

/// Shared highlight.js bridge for live and rendered fenced code blocks.
/// HighlighterSwiftBridge caches by appearance, language, and source text.
enum CodeSyntaxHighlighting {
    // The bridge's automatic appearance mode force-unwraps `NSApp`, which is
    // absent in Heft's headless render/self-test commands. Keep one pinned
    // bridge per palette and safely choose between them at call time.
    private static let lightHighlighter = HighlighterSwiftBridge(
        autoSwitchAppearance: false,
        lightBackground: .clear,
        darkBackground: .clear
    )
    private static let darkHighlighter = HighlighterSwiftBridge(
        lightTheme: "atom-one-dark",
        darkTheme: "atom-one-dark",
        autoSwitchAppearance: false,
        lightBackground: .clear,
        darkBackground: .clear
    )

    private static var highlighter: HighlighterSwiftBridge {
        guard let application = NSApp else { return lightHighlighter }
        let appearance = application.keyWindow?.effectiveAppearance
            ?? application.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? darkHighlighter
            : lightHighlighter
    }

    static func attributed(code: String, language: String?) -> AttributedString {
        guard let highlighted = highlight(code: code, language: language) else {
            return AttributedString(code)
        }
        return (try? AttributedString(highlighted, including: \.appKit)) ?? AttributedString(code)
    }

    /// Applies token colours to the code body while preserving Heft's font,
    /// paragraph geometry, and hidden fence attributes.
    static func apply(
        to storage: NSTextStorage,
        decoration: MarkdownDecoration,
        language: String?
    ) {
        guard let codeRange = contentRange(for: decoration, in: storage.string as NSString),
              codeRange.length > 0,
              let highlighted = highlight(
                  code: (storage.string as NSString).substring(with: codeRange),
                  language: language
              ),
              highlighted.length == codeRange.length
        else { return }

        highlighted.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: highlighted.length)
        ) { value, range, _ in
            guard let color = value as? NSColor else { return }
            storage.addAttribute(
                .foregroundColor, value: color,
                range: NSRange(location: codeRange.location + range.location, length: range.length)
            )
        }
    }

    private static func highlight(code: String, language: String?) -> NSAttributedString? {
        let bridge = highlighter
        guard let highlighted = bridge.highlight(code: code, language: language) else {
            return nil
        }
        guard isShell(language),
              let regex = try? NSRegularExpression(
                pattern: #"(?m)(?:^|[|;&]\s*)(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*(?:(?:sudo|env)\s+)*([A-Za-z_][A-Za-z0-9_.+-]*)"#
              ),
              let sample = bridge.highlight(code: "echo", language: "bash"),
              sample.length > 0,
              let commandColor = sample.attribute(
                .foregroundColor, at: 0, effectiveRange: nil
              ) as? NSColor
        else { return highlighted }

        let result = NSMutableAttributedString(attributedString: highlighted)
        let full = NSRange(location: 0, length: (code as NSString).length)
        for match in regex.matches(in: code, range: full) where match.numberOfRanges > 1 {
            let command = match.range(at: 1)
            guard command.location != NSNotFound, NSMaxRange(command) <= result.length else { continue }
            result.addAttribute(.foregroundColor, value: commandColor, range: command)
        }
        return result
    }

    private static func isShell(_ language: String?) -> Bool {
        guard let language = language?.lowercased() else { return false }
        return ["bash", "shell", "sh", "zsh"].contains(language)
    }

    static func contentRange(
        for decoration: MarkdownDecoration,
        in text: NSString
    ) -> NSRange? {
        let syntax = decoration.syntax.sorted { $0.location < $1.location }
        if syntax.count >= 2 {
            let start = NSMaxRange(syntax[0])
            return NSRange(location: start, length: max(0, syntax[1].location - start))
        }

        let newline = text.range(of: "\n", options: [], range: decoration.range)
        guard newline.location != NSNotFound else { return nil }
        let start = NSMaxRange(newline)
        return NSRange(location: start, length: max(0, NSMaxRange(decoration.range) - start))
    }
}
