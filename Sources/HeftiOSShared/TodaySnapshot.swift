import Foundation

/// Today's daily note as the widget shows it.
///
/// The widget is a process of its own and cannot open the vault, as the
/// share sheet cannot, so the app writes this to the App Group after every
/// scan and save, and the widget draws only what is here.
struct TodaySnapshot: Codable, Equatable {
    struct Line: Codable, Equatable, Hashable {
        var text: String
        /// nil for a line that is not a task.
        var done: Bool?
        /// A section heading, drawn as a small label.
        var heading: Bool?
    }

    var day: Date
    var title: String
    var exists: Bool
    /// The latest lines, from just before where a capture goes.
    var lines: [Line]
    /// The first lines, for a widget set to show the start of the note.
    var opening: [Line] = []

    static let widgetKind = "dev.stenglein.HeftMobile.today"
    private static let group = "group.dev.stenglein.HeftMobile"

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Today.json")
    }

    static func load() -> TodaySnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TodaySnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The first lines worth showing: no frontmatter, no line that is only
    /// tags, and the markup a widget cannot draw taken off what is left.
    /// `latest` keeps the last lines rather than the first: what was added
    /// most recently, which in a daily note is what is worth a glance.
    static func lines(from markdown: String, limit: Int = 8, latest: Bool = false) -> [Line] {
        // `\r\n` is one Character, which neither `"\n"` below matches.
        let unix = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var body = unix[...]
        if body.hasPrefix("---\n"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex) {
            body = body[end.upperBound...]
        }
        var found: [Line] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // A daily note's title heading says the date the widget already
            // shows above it.
            if line.hasPrefix("# ") { continue }
            if line.isEmpty || line.split(separator: " ").allSatisfy({ $0.hasPrefix("#") && !$0.hasPrefix("# ") && $0.count > 1 }) {
                continue
            }
            var done: Bool?
            let heading = line.hasPrefix("#")
            for (marker, state) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where line.hasPrefix(marker) {
                line.removeFirst(marker.count)
                done = state
            }
            if done == nil {
                while line.hasPrefix("#") { line.removeFirst() }
                for marker in ["- ", "* ", "+ ", "> "] where line.hasPrefix(marker) { line.removeFirst(2) }
            }
            line = plain(line.trimmingCharacters(in: .whitespaces))
            guard !line.isEmpty else { continue }
            found.append(Line(text: line, done: done, heading: heading ? true : nil))
            if !latest, found.count == limit { break }
        }
        return latest ? Array(found.suffix(limit)) : found
    }

    /// `[[Target|Text]]` as its text, `[Text](url)` as its text, and no
    /// emphasis or highlight marks.
    private static func plain(_ line: String) -> String {
        var text = line
        let patterns: [(String, String)] = [
            (#"\[\[[^\]|]*\|([^\]]*)\]\]"#, "$1"),
            (#"\[\[([^\]]*)\]\]"#, "$1"),
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"(\*\*|__|==|~~|\*|`)"#, ""),
        ]
        for (pattern, template) in patterns {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }
}
