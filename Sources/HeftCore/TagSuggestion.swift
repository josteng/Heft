import Foundation

/// The tag a line being captured probably wants, learned from the lines in
/// the vault that already carry one.
///
/// Every prose line with an inline `#tag` is an example of that tag: its
/// words, the tags taken out. A new line is classified by naive Bayes over
/// those words, with Laplace smoothing, and a tag is suggested only when it
/// is at least `confidence` likely. On a real vault, held-out lines were
/// tagged right about nine times in ten at 0.8, on six lines in ten; a
/// heuristic of summed word rarities with a fixed score cut-off did little
/// better than always naming the most common tag, because its scores grew
/// with the vault and the cut-off meant nothing. A probability means the
/// same in any vault.
///
/// There is no separate memory of suggestions taken or passed over: a line
/// filed with a tag is an example at the next scan, so the vault is what
/// learns.
public struct TagSuggester: Sendable {
    /// Per tag, lower-cased: how many example lines it has.
    let lines: [String: Int]
    /// Per tag: how often each word occurs in its lines.
    let wordCounts: [String: [String: Int]]
    /// Per tag: how many words its lines hold in all.
    let wordTotals: [String: Int]
    let vocabularySize: Int
    let lineTotal: Int
    /// Each tag's spelling, by its lower-cased key.
    let spelling: [String: String]

    /// How likely the best tag must be before it is offered.
    public static let confidence = 0.8

    /// `examples` holds, per tag, the lines that carry it.
    public init(examples: [String: [String]]) {
        var lines: [String: Int] = [:]
        var wordCounts: [String: [String: Int]] = [:]
        var wordTotals: [String: Int] = [:]
        var vocabulary = Set<String>()
        var spelling: [String: String] = [:]
        for (tag, texts) in examples {
            let key = tag.lowercased()
            spelling[key] = spelling[key] ?? tag
            for text in texts {
                let words = Self.words(text)
                guard !words.isEmpty else { continue }
                lines[key, default: 0] += 1
                for word in words {
                    wordCounts[key, default: [:]][word, default: 0] += 1
                    vocabulary.insert(word)
                }
                wordTotals[key, default: 0] += words.count
            }
        }
        self.lines = lines
        self.wordCounts = wordCounts
        self.wordTotals = wordTotals
        vocabularySize = vocabulary.count
        lineTotal = lines.values.reduce(0, +)
        self.spelling = spelling
    }

    public static let empty = TagSuggester(examples: [:])

    /// The examples in a note: each prose line carrying inline tags, by tag,
    /// with the tags taken out of the line.
    public static func examples(in source: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        NoteText.forEachProseLine(NoteText.splitFrontmatter(source).body) { _, line in
            let tags = NoteTags.inline(in: line)
            guard !tags.isEmpty else { return }
            let text = withoutTags(line)
            for tag in Set(tags.map(NoteTags.normalise)) { result[tag, default: []].append(text) }
        }
        return result
    }

    /// The examples of many notes together.
    public static func examples(in sources: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for source in sources {
            for (tag, lines) in examples(in: source) { result[tag, default: []] += lines }
        }
        return result
    }

    /// Each tag `text` does not carry yet, with how likely it is, most likely
    /// first. Empty when the line has no words to go on. The tags it carries
    /// are weighed with the rest and only then left out: dropped first, the
    /// one tag left over was certain by default, and a line written with
    /// `#car` was offered another tag.
    public func probabilities(for text: String) -> [(tag: String, probability: Double)] {
        let present = Set(NoteTags.inline(in: text).map { NoteTags.normalise($0).lowercased() })
        let words = Self.words(Self.withoutTags(text))
        guard !words.isEmpty, lineTotal > 0 else { return [] }
        var logs: [(key: String, value: Double)] = []
        for (key, count) in lines {
            var value = log(Double(count) / Double(lineTotal))
            let denominator = Double((wordTotals[key] ?? 0) + vocabularySize)
            for word in words {
                value += log(Double((wordCounts[key]?[word] ?? 0) + 1) / denominator)
            }
            logs.append((key, value))
        }
        guard let top = logs.map(\.value).max() else { return [] }
        let sum = logs.reduce(0.0) { $0 + exp($1.value - top) }
        return logs
            .filter { !present.contains($0.key) }
            .map { (spelling[$0.key] ?? $0.key, exp($0.value - top) / sum) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    /// The tag to suggest for `text`, without its `#`, or nil when no tag is
    /// at least `confidence` likely.
    public func suggest(for text: String, confidence: Double = Self.confidence) -> String? {
        guard let best = probabilities(for: text).first, best.probability >= confidence else { return nil }
        return best.tag
    }

    // MARK: Words

    /// Too common to say anything, in English and German.
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "about", "into", "that", "this", "your", "our", "are", "was", "has",
        "have", "not", "but", "all", "any", "can", "get", "how", "what", "when", "who", "why", "out", "off", "via",
        "der", "die", "das", "und", "mit", "für", "fur", "von", "den", "dem", "des", "ein", "eine", "einen", "auf",
        "aus", "bei", "nach", "zum", "zur", "ist", "sind", "noch", "auch", "oder", "wie", "wer", "nicht",
    ]

    /// A line's words as compared: lower case without accents, letters and
    /// digits only, three letters or more, no bare numbers or stop words, a
    /// plain plural "s" taken off ("figures", not "thesis").
    public static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).compactMap { raw in
            guard raw.count >= 3, !raw.allSatisfy(\.isNumber), !stopWords.contains(raw) else { return nil }
            if raw.count > 4, raw.hasSuffix("s"), !["ss", "is", "us"].contains(where: raw.hasSuffix) {
                return String(raw.dropLast())
            }
            return raw
        }
    }

    static func withoutTags(_ line: String) -> String {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return tagPattern.stringByReplacingMatches(in: line, range: range, withTemplate: " ")
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"(?<![\w/&])#[A-Za-z][\w/-]*"#)
}
