/// A presentation is the current note split at top-level thematic breaks.
/// The parser has already distinguished slide separators from `---` used as
/// frontmatter delimiters or inside fenced code blocks.
public enum PresentationDeck {
    public static func slides(from blocks: [MDBlock]) -> [[MDBlock]] {
        var slides: [[MDBlock]] = [[]]

        for block in blocks {
            if case .thematicBreak = block {
                slides.append([])
            } else {
                slides[slides.count - 1].append(block)
            }
        }

        let nonempty = slides.filter { !$0.isEmpty }
        return nonempty.isEmpty ? [[]] : nonempty
    }
}
