import HeftCore
import SwiftUI

/// The typing substitutions setting: which built-in groups are on, and the
/// user's own replacements.
///
/// A singleton, for the same reason `AppearanceSettings` is one: it is
/// app-wide rather than per-vault, and every open window's editor has to see a
/// change the moment it is made rather than when that window next opens.
final class TypingSettings: ObservableObject {
    static let shared = TypingSettings()

    @Published var substitutionsEnabled: Bool {
        didSet { HeftDefaults.shared.set(substitutionsEnabled, forKey: Self.enabledKey) }
    }

    /// Persisted as the *disabled* set, not the enabled one.
    ///
    /// Storing what is on meant a group added in a later version was missing
    /// from every settings file written before it existed, and so arrived
    /// switched off for exactly the people who had already been to the pane.
    /// An opt-out list makes "everything, unless you said otherwise" the thing
    /// that is actually recorded.
    @Published var enabledGroups: Set<SmartTypographyGroup> {
        didSet { Self.persist(enabledGroups) }
    }

    /// Kept as an array, not a dictionary: order is the user's, and two rows
    /// are allowed to share a trigger while one of them is still being typed.
    @Published var customRules: [CustomSubstitution] {
        didSet {
            guard let data = try? JSONEncoder().encode(customRules) else { return }
            HeftDefaults.shared.set(data, forKey: Self.customKey)
        }
    }

    /// Obsidian's two settings, kept as two here for the same reason it has
    /// two: closing a bracket and closing an emphasis marker feel different
    /// enough that people want one without the other. Both default on, as
    /// they do there.
    @Published var pairsBrackets: Bool {
        didSet { HeftDefaults.shared.set(pairsBrackets, forKey: Self.bracketsKey) }
    }

    @Published var pairsMarkdown: Bool {
        didSet { HeftDefaults.shared.set(pairsMarkdown, forKey: Self.markdownKey) }
    }

    /// Whether pasting a copied list item onto a line that is already a
    /// bullet drops the pasted marker.
    ///
    /// A setting rather than a rule, because it is the one thing here that
    /// throws away a character somebody copied. Every other typing aid adds:
    /// this one decides that two markers were not meant, and being wrong
    /// about that is silent. On by default, since `- - milk` is not a thing
    /// anybody wants, but a reader who pastes Markdown *about* Markdown can
    /// turn it off and get every byte back.
    @Published var trimsPastedListMarker: Bool {
        didSet { HeftDefaults.shared.set(trimsPastedListMarker, forKey: Self.pastedMarkerKey) }
    }

    var config: SmartTypographyConfig {
        SmartTypographyConfig(
            isEnabled: substitutionsEnabled, enabledGroups: enabledGroups, custom: customRules
        )
    }

    /// The rule table for `config`, built once per configuration rather than
    /// on every keystroke, which is how often the editor asks.
    var rules: [SmartTypographyRule] {
        let config = self.config
        if let cached = cachedRules, cached.config == config { return cached.rules }
        let rules = SmartTypography.rules(for: config)
        cachedRules = (config, rules)
        return rules
    }

    private var cachedRules: (config: SmartTypographyConfig, rules: [SmartTypographyRule])?

    func binding(for group: SmartTypographyGroup) -> Binding<Bool> {
        Binding(
            get: { self.enabledGroups.contains(group) },
            set: { isOn in
                if isOn { self.enabledGroups.insert(group) } else { self.enabledGroups.remove(group) }
            }
        )
    }

    private static let enabledKey = "dev.stenglein.Heft.typing.substitutions"
    private static let disabledGroupsKey = "dev.stenglein.Heft.typing.disabledGroups"
    /// What the first version stored: the enabled set. Read once, converted,
    /// and cleared.
    private static let legacyGroupsKey = "dev.stenglein.Heft.typing.groups"
    private static let customKey = "dev.stenglein.Heft.typing.customRules"

    /// Which groups are on, given what is on disk. Pure, and separate from
    /// `UserDefaults` so the upgrade path is testable.
    static func groups(disabled: [String]?, legacyEnabled: [String]?) -> Set<SmartTypographyGroup> {
        let off: Set<String>
        if let disabled {
            off = Set(disabled)
        } else if let legacyEnabled {
            // Subtracted from the groups that version knew about, not from
            // every group there is now: a name missing from that file because
            // it had not been invented yet is not a group the user turned off.
            off = legacyKnownGroups.subtracting(legacyEnabled)
        } else {
            off = []
        }
        return Set(SmartTypographyGroup.allCases.filter { !off.contains($0.rawValue) })
    }

    /// The groups that existed while the enabled-set format was in use.
    private static let legacyKnownGroups: Set<String> = [
        "quotes", "dashes", "ellipsis", "arrows", "guillemets", "comparisons", "fractions",
    ]

    private static let bracketsKey = "dev.stenglein.Heft.typing.pairsBrackets"
    private static let markdownKey = "dev.stenglein.Heft.typing.pairsMarkdown"
    private static let pastedMarkerKey = "dev.stenglein.Heft.typing.trimsPastedListMarker"

    private static func persist(_ groups: Set<SmartTypographyGroup>) {
        let disabled = Set(SmartTypographyGroup.allCases).subtracting(groups)
        HeftDefaults.shared.set(disabled.map(\.rawValue).sorted(), forKey: disabledGroupsKey)
    }

    private init() {
        let defaults = HeftDefaults.shared
        substitutionsEnabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)
        pairsBrackets = defaults.object(forKey: Self.bracketsKey) == nil
            ? true
            : defaults.bool(forKey: Self.bracketsKey)
        pairsMarkdown = defaults.object(forKey: Self.markdownKey) == nil
            ? true
            : defaults.bool(forKey: Self.markdownKey)
        trimsPastedListMarker = defaults.object(forKey: Self.pastedMarkerKey) == nil
            ? true
            : defaults.bool(forKey: Self.pastedMarkerKey)
        let groups = Self.groups(
            disabled: defaults.array(forKey: Self.disabledGroupsKey) as? [String],
            legacyEnabled: defaults.array(forKey: Self.legacyGroupsKey) as? [String]
        )
        enabledGroups = groups
        if let data = defaults.data(forKey: Self.customKey),
           let decoded = try? JSONDecoder().decode([CustomSubstitution].self, from: data) {
            customRules = decoded
        } else {
            customRules = []
        }

        // Initialization does not run `didSet`, so a migrated set is written
        // out here; without it the legacy key would be re-read every launch.
        if defaults.object(forKey: Self.legacyGroupsKey) != nil {
            Self.persist(groups)
            defaults.removeObject(forKey: Self.legacyGroupsKey)
        }
    }
}

/// The Typing tab: the built-in groups, then a table of the user's own
/// replacements.
struct TypingSettingsView: View {
    /// The daily-note tokens, plus the one that only means something in a
    /// replacement. `{{title}}` is last because it is the least useful here:
    /// it names the note being typed into.
    static let placeholders: [PlaceholderToken] =
        [
            PlaceholderToken(
                token: SmartTypography.caretPlaceholder, meaning: "Where the caret should land"
            )
        ]
        + PlaceholderReference.dateTokens
        + [PlaceholderToken(token: "{{title}}", meaning: "The open note's name")]

    @ObservedObject private var settings = TypingSettings.shared
    /// Which row's trigger field to put the caret in after "Add". Focus rather
    /// than a sheet, so adding a replacement is one click and then typing.
    @FocusState private var focusedTrigger: UUID?
    @State private var isPlaceholderHelpPresented = false

    /// How tall the pane is allowed to get before it scrolls as a whole.
    ///
    /// From the screen on a small display, so the tab still fits with the
    /// title bar, the tab strip and a margin off the Dock; a ceiling on a
    /// large one. The ceiling was the screen's, and on a big display the
    /// tab took the window to its edge: a settings window nine hundred
    /// points tall for one tab, while every other tab sits under six
    /// hundred. What the ceiling costs is the end of the rule table, which
    /// scrolls into view.
    private static var maxPaneHeight: CGFloat {
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - 140
        return min(max(available, 460), 760)
    }

    /// And how tall it is even when it does not need to be.
    ///
    /// The eight group toggles and their examples cost most of the pane, so
    /// sizing the window to the content alone opens it with the rule table
    /// just below the bottom edge — the tab looks like it is only about the
    /// built-in substitutions. A floor keeps the table on screen from the
    /// start, at the price of some empty space before any rules exist.
    private static var minPaneHeight: CGFloat { min(720, maxPaneHeight) }

    /// The pane scrolls in one piece rather than scrolling the rule table
    /// inside it.
    ///
    /// A scroll view is the only thing here that will give up height when it
    /// is squeezed, so an inner one around the rules meant the rules — and
    /// nothing else — vanished whenever the Settings window came up shorter
    /// than the tab wanted. A grouped Form scrolls as a whole and keeps every
    /// row at its natural height inside the scrolled content.
    var body: some View {
        Form {
            // Outside the substitutions group on purpose: pairing happens as
            // the key lands rather than after it, and switching substitutions
            // off is no reason to stop closing a bracket.
            Section {
                Toggle(isOn: $settings.pairsBrackets) {
                    SettingLabel(
                        "Brackets",
                        detail: "Typing ( [ or { writes the closing half and leaves the caret "
                            + "between them. With text selected, it wraps the selection."
                    )
                }
                Toggle(isOn: $settings.pairsMarkdown) {
                    SettingLabel(
                        "Markdown Syntax",
                        detail: "The same for * _ and `, at the start of a word. Typing the "
                            + "closing half yourself steps over the one already there."
                    )
                }
                Toggle(isOn: $settings.trimsPastedListMarker) {
                    SettingLabel(
                        "Trim a Pasted List Marker",
                        detail: "Pasting a copied \u{201C}- item\u{201D} onto a line that is already "
                            + "a bullet drops the pasted marker, so you get one bullet rather "
                            + "than two. The only aid here that leaves out something you copied."
                    )
                }
            } header: {
                SectionHeading("Auto-Pairing")
            }

            // One header, three cards: the switch that governs everything,
            // the built-in groups, and the user's own rules. The second and
            // third carry no header of their own, which is what makes them
            // read as part of the first; on its own the master switch sat
            // under the Auto-Pairing header and read as a third pairing
            // option.
            Section {
                // Substitutions never fire inside code, math, frontmatter,
                // links, tags or URLs. Saying so here saves the "why did it
                // not work in my code block" question, and the "why did it
                // wreck my code block" one.
                Toggle(isOn: $settings.substitutionsEnabled) {
                    SettingLabel(
                        "Replace as you type",
                        detail: "One backspace undoes a replacement and leaves what you typed. "
                            + "Nothing is replaced inside code, math, frontmatter, links, tags, or URLs."
                    )
                }
            } header: {
                SectionHeading("Text Substitutions")
            }

            Section {
                SettingLabel(
                    "Built-in replacements",
                    detail: "Each group on its own. Switch one off to keep typing its characters as they are."
                )
                // The example beside the name rather than under it: eight
                // two-line rows put the rule table below the fold of a
                // laptop screen, and an example is short enough to share
                // the line.
                ForEach(SmartTypographyGroup.allCases, id: \.self) { group in
                    Toggle(isOn: settings.binding(for: group)) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(group.title)
                            Text(group.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .disabled(!settings.substitutionsEnabled)

            Section {
                // The name is a row of the card, not a header: anything in a
                // header slot is drawn at the level of "Text Substitutions",
                // and this is one level down. A label row followed by its
                // items is how System Settings nests a group inside a card.
                SettingLabel(
                    "Your replacements",
                    detail: "A trigger that starts with a letter or digit only fires at the start of a "
                        + "word. \"Immediately\" replaces as soon as the trigger is complete; "
                        + "\"After a space\" waits for a space, a punctuation mark, or Return, the way "
                        + "macOS text replacement does, which is what longer snippets want."
                )
                customRules
            }
            .disabled(!settings.substitutionsEnabled)
        }
        .formStyle(.grouped)
        .frame(minHeight: Self.minPaneHeight, maxHeight: Self.maxPaneHeight)
    }

    @ViewBuilder
    private var customRules: some View {
        if settings.customRules.isEmpty {
            Text("No replacements yet.")
                .foregroundStyle(.tertiary)
        } else {
            // Every row at its natural height: the pane around them is
            // what scrolls.
            ForEach($settings.customRules) { $rule in
                customRuleRow($rule)
            }
        }

        HStack(spacing: 10) {
            Button {
                // New rules wait for a space, which is both what macOS
                // does and the safe default: a word-shaped trigger that
                // fires the instant it is complete goes off inside longer
                // words.
                let rule = CustomSubstitution(firing: .afterWord)
                settings.customRules.append(rule)
                focusedTrigger = rule.id
            } label: {
                Label("Add Replacement", systemImage: "plus")
            }

            // Ready-made rules, added as ordinary editable rows rather
            // than as a separate kind of thing: the fastest way to learn
            // what a replacement can do is to have a working one to
            // change.
            Menu {
                ForEach(SmartTypography.library) { example in
                    Button {
                        let rule = example.rule()
                        settings.customRules.append(rule)
                        focusedTrigger = rule.id
                    } label: {
                        Text("\(example.title)   \(example.trigger)")
                    }
                    .disabled(settings.customRules.contains { $0.trigger == example.trigger })
                }
            } label: {
                Label("Add from Library", systemImage: "books.vertical")
            }
            .menuStyle(.button)
            .fixedSize()

            Spacer(minLength: 12)

            // A popover, exactly as the daily-note sheet documents the
            // same tokens: the list is long enough to push the rules
            // themselves off the pane, and it is reference material read
            // once, not a control.
            Button { isPlaceholderHelpPresented.toggle() } label: {
                Label("Placeholders", systemImage: "questionmark.circle")
            }
            .popover(isPresented: $isPlaceholderHelpPresented, arrowEdge: .bottom) {
                PlaceholderReference(
                    title: "Placeholders",
                    tokens: Self.placeholders,
                    footnote: PlaceholderReference.momentTokenFootnote
                )
                .frame(width: 470, alignment: .leading)
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func customRuleRow(_ rule: Binding<CustomSubstitution>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: rule.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Use this replacement")

            TextField("Type this", text: rule.trigger)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .focused($focusedTrigger, equals: rule.wrappedValue.id)

            // Per rule rather than one global setting: which one a trigger
            // wants follows from the trigger. `+sig` is unambiguous the
            // moment it is complete, `omw` is not.
            Picker("", selection: rule.firing) {
                ForEach(SubstitutionFiring.allCases, id: \.self) { firing in
                    Text(firing.title).tag(firing)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .help("When this replacement fires")

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .font(.caption)

            // Multi-line replacements are allowed — this is also the snippet
            // expander — so the field takes a newline rather than treating one
            // as "done".
            TextField("Get this", text: rule.replacement, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .frame(maxWidth: .infinity)

            Button {
                settings.customRules.removeAll { $0.id == rule.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this replacement")
        }
    }
}
