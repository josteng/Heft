import Foundation

/// A family of built-in substitutions that can be switched on or off as a unit.
///
/// Groups rather than individual rules: nobody wants `1/2` without `3/4`, and a
/// settings pane with forty checkboxes is a settings pane nobody reads. A rule
/// somebody dislikes inside a group they otherwise want can be replaced by
/// disabling the group and adding the wanted rules back as custom ones.
public enum SmartTypographyGroup: String, CaseIterable, Sendable, Codable {
    case quotes
    case dashes
    case ellipsis
    case arrows
    case guillemets
    case comparisons
    case symbols
    case fractions

    public var title: String {
        switch self {
        case .quotes: "Curly Quotes"
        case .dashes: "Dashes"
        case .ellipsis: "Ellipsis"
        case .arrows: "Arrows"
        case .guillemets: "Guillemets"
        case .comparisons: "Comparisons"
        case .symbols: "Symbols"
        case .fractions: "Fractions"
        }
    }

    /// Shown under the toggle, as literal before/after text.
    public var detail: String {
        switch self {
        case .quotes: #""quoted" and it's → “quoted” and it’s"#
        case .dashes: "-- → –, --- → —, and a fourth dash gives back ---"
        case .ellipsis: "... → …"
        case .arrows: "-> → →, <- → ←, => → ⇒, <-> → ↔, <=> → ⇔, --> → ⟶"
        case .guillemets: "<< → «, >> → »"
        case .comparisons: ">= → ≥, <= → ≤, != and /= → ≠, ~= → ≈"
        case .symbols: "(c) → ©, (r) → ®, (tm) → ™, +- → ±, (deg) → °"
        case .fractions: "1/2 → ½, 3/4 → ¾, and the rest down to 1/10"
        }
    }
}

/// When a rule fires: the moment its trigger is complete, or once the word has
/// been ended by a space, a punctuation mark, or Return.
///
/// The second is how macOS text replacement behaves, and is what makes a
/// word-shaped trigger usable for a longer snippet: `sig` can expand to a whole
/// signature without also firing inside "signal" the moment you reach the g.
public enum SubstitutionFiring: String, Codable, Sendable, CaseIterable {
    case immediately
    case afterWord

    public var title: String {
        switch self {
        case .immediately: "Immediately"
        case .afterWord: "After a space"
        }
    }
}

/// A replacement the user typed in themselves, in the Typing settings pane.
///
/// Carries its own identity rather than being addressed by index so the
/// settings table can keep row focus while the list is edited.
public struct CustomSubstitution: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var trigger: String
    public var replacement: String
    public var isEnabled: Bool
    public var firing: SubstitutionFiring

    public init(
        id: UUID = UUID(), trigger: String = "", replacement: String = "", isEnabled: Bool = true,
        firing: SubstitutionFiring = .immediately
    ) {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.isEnabled = isEnabled
        self.firing = firing
    }

    /// Hand-written rather than synthesized so a rule stored before `firing`
    /// existed still decodes. A synthesized `init(from:)` ignores property
    /// defaults and would fail the whole list on one missing key, silently
    /// emptying the user's table.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        firing = try container.decodeIfPresent(SubstitutionFiring.self, forKey: .firing)
            ?? .immediately
    }

    public var isUsable: Bool { !trigger.isEmpty && !replacement.isEmpty && isEnabled }
}

/// A ready-made replacement offered in the settings pane.
///
/// A library rather than rules seeded into a fresh install: a rule nobody
/// asked for is a rule nobody can explain the presence of, and the interesting
/// ones here are worth *seeing* — the placeholder syntax is much easier to
/// copy from a working example than to assemble from a token list.
public struct SubstitutionExample: Sendable, Identifiable {
    public let title: String
    public let trigger: String
    public let replacement: String
    public let firing: SubstitutionFiring
    public var id: String { trigger }

    public init(
        title: String, trigger: String, replacement: String,
        firing: SubstitutionFiring = .immediately
    ) {
        self.title = title
        self.trigger = trigger
        self.replacement = replacement
        self.firing = firing
    }

    /// A fresh rule for the user's table, with its own identity so the same
    /// example can be added twice and edited into two different things.
    public func rule() -> CustomSubstitution {
        CustomSubstitution(trigger: trigger, replacement: replacement, firing: firing)
    }
}

/// One "type this, get that" rule.
public struct SmartTypographyRule: Sendable, Equatable {
    /// The literal text that must end at the caret for the rule to fire.
    public let from: String
    public let to: String
    /// What must be true of the text in front of `from`.
    public let requires: Precondition
    public let firing: SubstitutionFiring

    public enum Precondition: Sendable, Equatable {
        case none
        /// Start of line, whitespace, or an opening bracket or quote — what
        /// tells an opening quote from a closing one.
        case openingBoundary
        /// Start of line or whitespace. Keeps `1/2` from firing inside `31/2`.
        case wordStart
        /// The line up to here must hold something other than whitespace and
        /// the given characters. Stops rules whose trigger doubles as block
        /// markup from eating it: `---` at the start of a line is frontmatter
        /// or a thematic break, and `>>` there is a nested block quote.
        case prose(Set<Character>)
        /// The character in front must not be a letter or digit, so a word-ish
        /// custom trigger does not fire in the middle of a longer word.
        case notInsideWord
    }

    public init(
        from: String, to: String, requires: Precondition = .none,
        firing: SubstitutionFiring = .immediately
    ) {
        self.from = from
        self.to = to
        self.requires = requires
        self.firing = firing
    }
}

/// What a replacement's `{{…}}` placeholders resolve against.
///
/// Only custom replacements use these; no built-in rule contains a
/// placeholder, and the expansion is skipped entirely for text without `{{`.
public struct SubstitutionExpansion: Sendable {
    public var date: Date
    public var noteTitle: String

    public init(date: Date = Date(), noteTitle: String = "") {
        self.date = date
        self.noteTitle = noteTitle
    }
}

/// What the editor should do about a substitution that just became due.
public struct TextSubstitution: Equatable, Sendable {
    /// Range in the current source occupied by the typed text.
    public let range: NSRange
    public let replacement: String
    /// The text being replaced, kept so backspace can put it back.
    public let original: String
    /// Where the caret goes, measured from the start of the replacement.
    /// Usually its end; a `{{caret}}` placeholder puts it somewhere inside.
    public let caretOffset: Int

    public init(range: NSRange, replacement: String, original: String, caretOffset: Int? = nil) {
        self.range = range
        self.replacement = replacement
        self.original = original
        self.caretOffset = caretOffset ?? (replacement as NSString).length
    }

    /// Where the caret belongs once the replacement is in.
    public var caret: Int { range.location + caretOffset }

    /// The range the replacement occupies afterwards, which is what a revert
    /// has to find still intact.
    public var replacedRange: NSRange {
        NSRange(location: range.location, length: (replacement as NSString).length)
    }
}

public struct SmartTypographyConfig: Sendable, Equatable {
    /// Master switch. Off means the engine never looks at anything, including
    /// custom rules.
    public var isEnabled: Bool
    public var enabledGroups: Set<SmartTypographyGroup>
    public var custom: [CustomSubstitution]

    public init(
        isEnabled: Bool = true,
        enabledGroups: Set<SmartTypographyGroup> = Set(SmartTypographyGroup.allCases),
        custom: [CustomSubstitution] = []
    ) {
        self.isEnabled = isEnabled
        self.enabledGroups = enabledGroups
        self.custom = custom
    }

    public static let `default` = SmartTypographyConfig()
    public static let off = SmartTypographyConfig(isEnabled: false, enabledGroups: [], custom: [])
}

/// Obsidian-style typing substitutions: `->` becomes `→` as you type, and one
/// backspace puts `->` back.
///
/// Pure, so the whole rule table — including the parts that are easy to get
/// subtly wrong, like not firing inside code fences or on the `---` that opens
/// frontmatter — is covered by the test suite rather than by clicking around.
///
/// The engine looks at the document *after* a character has been typed and
/// asks whether the text now ending at the caret matches a rule. That is why
/// it needs no notion of a trigger key: a rule is just a string to look for.
public enum SmartTypography {

    // MARK: Rules

    public static func rules(for group: SmartTypographyGroup) -> [SmartTypographyRule] {
        switch group {
        case .quotes:
            // Opening forms are listed first and fall through to the closing
            // ones, which accept anything: that ordering *is* the open/close
            // decision.
            [
                SmartTypographyRule(from: "\"", to: "\u{201C}", requires: .openingBoundary),
                SmartTypographyRule(from: "\"", to: "\u{201D}"),
                SmartTypographyRule(from: "'", to: "\u{2018}", requires: .openingBoundary),
                SmartTypographyRule(from: "'", to: "\u{2019}"),
            ]
        case .dashes:
            // A chain: `--` gives an en dash, another `-` upgrades it to an em
            // dash, and a fourth gives literal `---` back — the escape hatch
            // for anybody who wanted three dashes mid-sentence.
            [
                SmartTypographyRule(from: "\u{2014}-", to: "---", requires: .prose(["-"])),
                SmartTypographyRule(from: "\u{2013}-", to: "\u{2014}", requires: .prose(["-"])),
                SmartTypographyRule(from: "--", to: "\u{2013}", requires: .prose(["-"])),
            ]
        case .ellipsis:
            [SmartTypographyRule(from: "...", to: "\u{2026}")]
        case .arrows:
            // The three-character arrows are chains, like the dashes: by the
            // time the third character arrives the first two have already
            // become `←`, `≤` or `–`, so the rule matches what is on screen
            // rather than what was typed. Listed first so they win over the
            // two-character rules that would otherwise match the same suffix.
            [
                SmartTypographyRule(from: "\u{2190}>", to: "\u{2194}"),
                SmartTypographyRule(from: "\u{2264}>", to: "\u{21D4}"),
                SmartTypographyRule(from: "\u{2013}>", to: "\u{27F6}", requires: .prose(["-"])),
                SmartTypographyRule(from: "->", to: "\u{2192}"),
                SmartTypographyRule(from: "<-", to: "\u{2190}"),
                SmartTypographyRule(from: "=>", to: "\u{21D2}"),
            ]
        case .guillemets:
            // `>>` is guarded because a line that so far holds only `>` is a
            // nested block quote being typed. `<<` needs no such guard, and
            // opening a line with «a quotation» is exactly when you want it.
            [
                SmartTypographyRule(from: "<<", to: "\u{00AB}"),
                SmartTypographyRule(from: ">>", to: "\u{00BB}", requires: .prose([">"])),
            ]
        case .comparisons:
            [
                SmartTypographyRule(from: ">=", to: "\u{2265}", requires: .prose([">"])),
                SmartTypographyRule(from: "<=", to: "\u{2264}"),
                SmartTypographyRule(from: "/=", to: "\u{2260}"),
                // Not in the plugin this borrows from, but the two forms
                // everybody who writes code reaches for first.
                SmartTypographyRule(from: "!=", to: "\u{2260}"),
                SmartTypographyRule(from: "~=", to: "\u{2248}"),
            ]
        case .symbols:
            // `.notInsideWord` keeps `f(c)` — an argument list in prose —
            // from turning into `f©`.
            [
                SmartTypographyRule(from: "(c)", to: "\u{00A9}", requires: .notInsideWord),
                SmartTypographyRule(from: "(r)", to: "\u{00AE}", requires: .notInsideWord),
                SmartTypographyRule(from: "(tm)", to: "\u{2122}", requires: .notInsideWord),
                SmartTypographyRule(from: "(deg)", to: "\u{00B0}", requires: .notInsideWord),
                SmartTypographyRule(from: "+-", to: "\u{00B1}"),
            ]
        case .fractions:
            // `1/10` before `1/1`-prefixed entries would matter if there were
            // any; there are not, but longest-first is the habit to keep.
            [
                ("1/10", "\u{2152}"),
                ("1/2", "\u{00BD}"), ("1/3", "\u{2153}"), ("2/3", "\u{2154}"),
                ("1/4", "\u{00BC}"), ("3/4", "\u{00BE}"),
                ("1/5", "\u{2155}"), ("2/5", "\u{2156}"), ("3/5", "\u{2157}"), ("4/5", "\u{2158}"),
                ("1/6", "\u{2159}"), ("5/6", "\u{215A}"),
                ("1/7", "\u{2150}"),
                ("1/8", "\u{215B}"), ("3/8", "\u{215C}"), ("5/8", "\u{215D}"), ("7/8", "\u{215E}"),
                ("1/9", "\u{2151}"),
            ].map { SmartTypographyRule(from: $0.0, to: $0.1, requires: .wordStart) }
        }
    }

    /// Every rule the config turns on, custom ones first so a user rule can
    /// override a built-in with the same trigger.
    public static func rules(for config: SmartTypographyConfig) -> [SmartTypographyRule] {
        guard config.isEnabled else { return [] }
        var rules = config.custom.filter(\.isUsable).map { custom in
            SmartTypographyRule(
                from: custom.trigger,
                to: custom.replacement,
                requires: startsWordCharacter(custom.trigger) ? .notInsideWord : .none,
                firing: custom.firing
            )
        }
        for group in SmartTypographyGroup.allCases where config.enabledGroups.contains(group) {
            rules.append(contentsOf: self.rules(for: group))
        }
        return rules
    }

    // MARK: Library

    /// Replacements worth having, offered in the settings pane and editable
    /// once added.
    ///
    /// Every trigger starts with `,,`, which is why they all fire
    /// immediately: a punctuation-led trigger is unambiguous the moment it is
    /// complete, and waiting for a space would leave one behind in the middle
    /// of a code fence.
    ///
    /// `+` rather than the `;` that expander conventions favour, because that
    /// convention is a US-layout one: `;` is unshifted there and Shift+comma
    /// on a German keyboard, where `+` has a key of its own. It is also a
    /// single keystroke, it has no meaning in markdown except as a list bullet
    /// (which is `+` followed by a space), and — unlike `<<`, which turns into
    /// `«` before the trigger is finished — it collides with no built-in rule.
    /// `+- ` still becomes `± `, since that needs the dash. Anybody who wants
    /// `;` or `,,` back only has to edit the rows.
    public static let library: [SubstitutionExample] = [
        SubstitutionExample(
            title: "Link to today's daily note",
            trigger: "+today",
            replacement: "[[{{date:YYYY-MM-DD}}]]"
        ),
        SubstitutionExample(
            title: "Link to this week's note",
            trigger: "+week",
            replacement: "[[{{date:GGGG-[W]WW}}]]"
        ),
        SubstitutionExample(
            title: "Today's date",
            trigger: "+date",
            replacement: "{{date:YYYY-MM-DD}}"
        ),
        SubstitutionExample(
            title: "Today's date, written out",
            trigger: "+ldate",
            replacement: "{{date:dddd, MMMM Do YYYY}}"
        ),
        SubstitutionExample(
            title: "Time now",
            trigger: "+now",
            replacement: "{{time:HH:mm}}"
        ),
        SubstitutionExample(
            title: "Timed log entry",
            trigger: "+log",
            replacement: "- {{time:HH:mm}} {{caret}}"
        ),
        SubstitutionExample(
            title: "Task",
            trigger: "+task",
            replacement: "- [ ] {{caret}}"
        ),
        SubstitutionExample(
            title: "Code block",
            trigger: "+code",
            replacement: "```\n{{caret}}\n```"
        ),
        SubstitutionExample(
            title: "Table",
            trigger: "+table",
            replacement: "| {{caret}} |  |\n| --- | --- |\n|  |  |"
        ),
        SubstitutionExample(
            title: "Note callout",
            trigger: "+note",
            replacement: "> [!note]\n> {{caret}}"
        ),
        SubstitutionExample(
            title: "Shrug",
            trigger: "+shrug",
            replacement: "\u{00AF}\\_(\u{30C4})_/\u{00AF}"
        ),
    ]

    // MARK: Matching

    /// The substitution due at `caret`, if any.
    ///
    /// - Parameters:
    ///   - source: the document *after* the character was typed.
    ///   - caret: the caret's location in `source`, in UTF-16 units.
    ///   - endingWord: the word was just ended without a character being typed
    ///     — Return. Only `.afterWord` rules can fire then, since anything
    ///     immediate already fired as it was typed.
    public static func substitution(
        in source: String, caret: Int, config: SmartTypographyConfig,
        expansion: SubstitutionExpansion = SubstitutionExpansion(), endingWord: Bool = false
    ) -> TextSubstitution? {
        substitution(
            in: source, caret: caret, rules: rules(for: config),
            expansion: expansion, endingWord: endingWord
        )
    }

    /// The rule-table form, so a caller that types many characters in a row
    /// (or a test) can build the table once.
    public static func substitution(
        in source: String, caret: Int, rules: [SmartTypographyRule],
        expansion: SubstitutionExpansion = SubstitutionExpansion(), endingWord: Bool = false
    ) -> TextSubstitution? {
        guard !rules.isEmpty else { return nil }
        let text = source as NSString
        guard caret > 0, caret <= text.length else { return nil }

        // Where an `.afterWord` trigger would have to end, and how much typed
        // delimiter follows it: one character for a space or a comma, none
        // for Return, which types nothing.
        let wordEnd: (end: Int, delimiter: Int)?
        if endingWord {
            wordEnd = (caret, 0)
        } else if let last = character(before: caret, in: text), endsAWord(last) {
            wordEnd = (caret - 1, 1)
        } else {
            wordEnd = nil
        }

        for rule in rules {
            let length = (rule.from as NSString).length
            guard length > 0 else { continue }

            let end: Int
            let delimiter: Int
            switch rule.firing {
            case .immediately:
                guard !endingWord else { continue }
                (end, delimiter) = (caret, 0)
            case .afterWord:
                guard let wordEnd else { continue }
                (end, delimiter) = wordEnd
            }

            guard end >= length else { continue }
            let range = NSRange(location: end - length, length: length)
            guard text.substring(with: range) == rule.from else { continue }
            guard satisfies(rule.requires, in: text, at: range.location) else { continue }
            // The context test comes last because it is the expensive one, and
            // it fails the whole attempt rather than just this rule: if the
            // caret is inside code, no rule may fire here.
            guard allowsSubstitution(in: text, at: range.location) else { return nil }

            // The delimiter is replaced along with the trigger and put back
            // unchanged, so the caret ends up after it and one backspace
            // restores both.
            let tail = text.substring(with: NSRange(location: end, length: delimiter))
            let expanded = expand(rule.to, expansion)
            return TextSubstitution(
                range: NSRange(location: range.location, length: length + delimiter),
                replacement: expanded.text + tail,
                original: rule.from + tail,
                caretOffset: expanded.caret
            )
        }
        return nil
    }

    /// Whether typing this character ends the word in front of it.
    private static func endsAWord(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation || character.isSymbol
    }

    /// Resolves a replacement's `{{…}}` placeholders and takes out the
    /// `{{caret}}` marker, reporting where it was.
    ///
    /// `MomentFormat` already knows `{{date:…}}`, `{{time:…}}` and
    /// `{{title}}` from daily-note templates, and re-emits anything it does
    /// not know — which is exactly how `{{caret}}` survives to be found here.
    static func expand(
        _ replacement: String, _ expansion: SubstitutionExpansion
    ) -> (text: String, caret: Int?) {
        guard replacement.contains("{{") else { return (replacement, nil) }
        var text = MomentFormat.expandTemplate(
            replacement, date: expansion.date, title: expansion.noteTitle
        )
        guard let marker = text.range(of: caretPlaceholder) else { return (text, nil) }
        let offset = (String(text[text.startIndex..<marker.lowerBound]) as NSString).length
        text.replaceSubrange(marker, with: "")
        return (text, offset)
    }

    public static let caretPlaceholder = "{{caret}}"

    private static func satisfies(
        _ precondition: SmartTypographyRule.Precondition, in text: NSString, at location: Int
    ) -> Bool {
        switch precondition {
        case .none:
            return true
        case .openingBoundary:
            guard let previous = character(before: location, in: text) else { return true }
            return previous.isWhitespace || "{[(<'\"\u{2018}\u{201C}".contains(previous)
        case .wordStart:
            guard let previous = character(before: location, in: text) else { return true }
            return previous.isWhitespace
        case .notInsideWord:
            guard let previous = character(before: location, in: text) else { return true }
            return !(previous.isLetter || previous.isNumber)
        case .prose(let markup):
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let prefix = text.substring(with: NSRange(
                location: line.location, length: location - line.location
            ))
            return prefix.contains { !$0.isWhitespace && !markup.contains($0) }
        }
    }

    private static func character(before location: Int, in text: NSString) -> Character? {
        guard location > 0 else { return nil }
        let previous = text.substring(with: NSRange(location: location - 1, length: 1))
        return previous.first
    }

    private static func startsWordCharacter(_ trigger: String) -> Bool {
        guard let first = trigger.first else { return false }
        return first.isLetter || first.isNumber
    }

    // MARK: Context

    /// Whether a substitution may happen at `location` at all.
    ///
    /// Typography is for prose. Code, math, frontmatter, wiki links, link
    /// destinations, tags and URLs are all places where `->` means `->` and
    /// turning it into `→` would corrupt the file. This is deliberately its
    /// own cheap scan rather than a call into `LiveDecorator`: it runs on
    /// every keystroke and only needs to answer one question about one
    /// position, where the decorator parses the whole document.
    public static func allowsSubstitution(in text: NSString, at location: Int) -> Bool {
        let clamped = max(0, min(location, text.length))
        let line = text.lineRange(for: NSRange(location: clamped, length: 0))
        guard !isInsideBlock(text, lineStart: line.location) else { return false }

        let prefix = text.substring(with: NSRange(
            location: line.location, length: clamped - line.location
        ))
        return !isInsideInlineSpan(prefix)
    }

    /// Frontmatter, fenced code, and `$$` math blocks, all of which are
    /// line-delimited, so the state is found by walking line starts to the
    /// caret's line and never has to look at the rest of the document.
    private static func isInsideBlock(_ text: NSString, lineStart: Int) -> Bool {
        var location = 0
        var lineNumber = 0
        var fence: Character?
        var inFrontmatter = false
        var inMathBlock = false

        while location < lineStart {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: range).trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inFrontmatter {
                // Checked before fences: a stray ``` inside frontmatter is
                // YAML, not the start of a code block.
                if trimmed == "---" { inFrontmatter = false }
            } else if let open = fence {
                if trimmed.first == open, trimmed.count >= 3, trimmed.allSatisfy({ $0 == open }) {
                    fence = nil
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.first
            } else if lineNumber == 0, trimmed == "---" {
                inFrontmatter = true
            } else if trimmed.hasPrefix("$$") {
                // A one-line `$$…$$` opens and closes at once and so leaves
                // the state alone.
                let selfClosing = trimmed.count > 3 && trimmed.hasSuffix("$$")
                if !selfClosing { inMathBlock.toggle() }
            }

            guard range.length > 0 else { break }
            location = NSMaxRange(range)
            lineNumber += 1
        }

        if fence != nil || inMathBlock { return true }
        if inFrontmatter { return true }

        // The caret's own line: an opening or closing delimiter is itself
        // markup, so nothing on it should be substituted either.
        let own = text.lineRange(for: NSRange(location: lineStart, length: 0))
        let line = text.substring(with: own)
            .trimmingCharacters(in: .newlines)
            .trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("```") || line.hasPrefix("~~~") || line.hasPrefix("$$") { return true }
        return lineStart == 0 && line == "---"
    }

    /// Inline code, inline math, an unclosed wiki link or link destination, or
    /// a tag or URL the caret is currently inside.
    private static func isInsideInlineSpan(_ prefix: String) -> Bool {
        // Odd counts mean an opener with no closer yet, so the caret is inside.
        if prefix.filter({ $0 == "`" }).count % 2 == 1 { return true }
        if dollarCount(prefix) % 2 == 1 { return true }

        if let open = prefix.range(of: "[[", options: .backwards),
           prefix.range(of: "]]", options: .backwards, range: open.upperBound..<prefix.endIndex) == nil {
            return true
        }
        if let open = prefix.range(of: "](", options: .backwards),
           prefix.range(of: ")", options: .backwards, range: open.upperBound..<prefix.endIndex) == nil {
            return true
        }

        // The word the caret sits in. A tag's `#` only counts at its start, so
        // a heading's `# ` — which is followed by a space — is prose.
        let word = prefix.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        if word.hasPrefix("#") { return true }
        return word.contains("://")
    }

    /// `$` characters, ignoring `\$`, which is an escaped literal dollar.
    private static func dollarCount(_ prefix: String) -> Int {
        var count = 0
        var escaped = false
        for character in prefix {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
            } else if character == "$" {
                count += 1
            }
        }
        return count
    }
}
