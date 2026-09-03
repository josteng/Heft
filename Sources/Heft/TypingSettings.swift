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

    var config: SmartTypographyConfig {
        SmartTypographyConfig(
            isEnabled: substitutionsEnabled, enabledGroups: enabledGroups, custom: customRules
        )
    }

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

    private static func persist(_ groups: Set<SmartTypographyGroup>) {
        let disabled = Set(SmartTypographyGroup.allCases).subtracting(groups)
        HeftDefaults.shared.set(disabled.map(\.rawValue).sorted(), forKey: disabledGroupsKey)
    }

    private init() {
        let defaults = HeftDefaults.shared
        substitutionsEnabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)
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
    /// Taken from the screen rather than fixed: this tab is a long list, and a
    /// constant chosen to be safe on a small display wasted most of a large
    /// one, leaving the rule table below the fold on a screen with room to
    /// spare. The reserve covers the title bar, the tab strip, and enough
    /// margin that the window is not jammed against the Dock.
    private static var maxPaneHeight: CGFloat {
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - 140
        return min(max(available, 460), 1000)
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
    /// than the tab wanted. Scrolling the whole pane puts the rows at their
    /// natural height inside the scrolled content, where nothing can collapse
    /// them.
    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .frame(width: 630)
        .frame(minHeight: Self.minPaneHeight, maxHeight: Self.maxPaneHeight)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $settings.substitutionsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text Substitutions").font(.headline)
                    Text("Replaces what you type as you type it. One backspace undoes a "
                         + "replacement and leaves what you typed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            Group {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(SmartTypographyGroup.allCases, id: \.self) { group in
                        Toggle(isOn: settings.binding(for: group)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.title)
                                Text(group.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                Divider()

                customRulesSection
            }
            .disabled(!settings.substitutionsEnabled)
            .opacity(settings.substitutionsEnabled ? 1 : 0.4)

            // Substitutions never fire inside code, math, frontmatter, links,
            // tags or URLs. Saying so here saves the "why did it not work in
            // my code block" question, and the "why did it wreck my code
            // block" one.
            Text("Nothing is replaced inside code, math, frontmatter, links, tags, or URLs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        // Room on the right for the pane's own overlay scroller, which would
        // otherwise sit on top of the remove buttons.
        .padding(.trailing, 8)
        .frame(width: 630, alignment: .leading)
    }

    @ViewBuilder
    private var customRulesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Replacements").font(.headline)
                Spacer(minLength: 12)
                // A popover, exactly as the daily-note sheet documents the
                // same tokens: the list is long enough to push the rules
                // themselves off the pane, and it is reference material read
                // once, not a control.
                // A real bordered button, not the daily-note sheet's plain
                // grey label: there it sits directly under the template field
                // it documents, while here it competes with eight toggles and
                // a table, and read as decoration until it had a border.
                Button { isPlaceholderHelpPresented.toggle() } label: {
                    Label("Placeholders", systemImage: "questionmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
            Text("A trigger that starts with a letter or digit only fires at the start of a "
                 + "word. \"Immediately\" replaces as soon as the trigger is complete; "
                 + "\"After a space\" waits for a space, a punctuation mark, or Return, the way "
                 + "macOS text replacement does, which is what longer snippets want.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.customRules.isEmpty {
                Text("No replacements yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                // Every row at its natural height: the pane around them is
                // what scrolls.
                VStack(spacing: 4) {
                    ForEach($settings.customRules) { $rule in
                        customRuleRow($rule)
                    }
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
