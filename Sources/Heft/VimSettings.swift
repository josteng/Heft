import HeftVimCore
import SwiftUI
import HeftCore

@MainActor
final class VimSettings: ObservableObject {
    static let shared = VimSettings()

    // Off until someone turns it on, and app-wide. A vault's Obsidian vimMode
    // used to be adopted as the initial value, which switched modal editing
    // on without a word for anyone opening an Obsidian vault configured that
    // way on a fresh Mac; bringing that back wants a visible announcement.
    @Published var isEnabled: Bool {
        didSet { HeftDefaults.shared.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var mode: VimMode = .normal
    @Published private(set) var message: String?
    @Published var continuesMarkdownStructure: Bool {
        didSet {
            HeftDefaults.shared.set(
                continuesMarkdownStructure,
                forKey: Self.continuesMarkdownStructureKey
            )
        }
    }
    @Published var matchesTypographicQuotes: Bool {
        didSet {
            HeftDefaults.shared.set(
                matchesTypographicQuotes,
                forKey: Self.matchesTypographicQuotesKey
            )
        }
    }

    private static let enabledKey = "dev.stenglein.Heft.vim.enabled"
    private static let continuesMarkdownStructureKey =
        "dev.stenglein.Heft.vim.continuesMarkdownStructure"
    private static let matchesTypographicQuotesKey =
        "dev.stenglein.Heft.vim.matchesTypographicQuotes"
    private init() {
        let defaults = HeftDefaults.shared
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        continuesMarkdownStructure = defaults.object(
            forKey: Self.continuesMarkdownStructureKey
        ) == nil || defaults.bool(forKey: Self.continuesMarkdownStructureKey)
        matchesTypographicQuotes = defaults.object(
            forKey: Self.matchesTypographicQuotesKey
        ) == nil || defaults.bool(forKey: Self.matchesTypographicQuotesKey)
    }

    func report(mode: VimMode, message: String? = nil) {
        self.mode = mode
        self.message = message
    }
}

struct VimSettingsView: View {
    @ObservedObject private var vim = VimSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $vim.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Vim key bindings")
                            Text("EXPERIMENTAL")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.12), in: .capsule)
                        }
                        Group {
                            Text("Off by default, and app-wide; the command palette (⌘P) has the same switch. "
                                + "Uses native Swift key handling. Your notes remain ordinary Markdown, "
                                + "and Heft does not bundle or link against Vim or Neovim.")
                            Text("Available now: Normal, Insert, Replace, Visual, Visual Line, and Visual Block modes; "
                                + "counts and operator-motion commands; text objects; dot-repeat; visual paste; line "
                                + "indentation; f/F/t/T, %, *, and #; block insertion; undo/redo; and zz/zt/zb.")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The two below only mean anything while Vim is on, so they
                // grey out with it rather than inviting a change nobody can
                // see.
                Toggle(isOn: $vim.continuesMarkdownStructure) {
                    SettingLabel(
                        "Preserve Markdown structure in Vim edits",
                        detail: "Continues bullet, numbered, task, and blockquote markers with o/O, and retains the "
                            + "marker when cc, S, or a Visual Line change replaces an item. This is a Heft "
                            + "convenience rather than standard Vim behavior."
                    )
                }
                .disabled(!vim.isEnabled)
                Toggle(isOn: $vim.matchesTypographicQuotes) {
                    SettingLabel(
                        "Match typographic quotes in text objects",
                        detail: "Lets ci\" and ca\" work on \u{201C}curly quotes\u{201D} and \u{00AB}guillemets\u{00BB}, "
                            + "and ci' on \u{2018}curly single quotes\u{2019}. Typing substitutions replace the "
                            + "straight characters as you write, so without this the quotes in your notes are no "
                            + "longer the ones those commands look for. Turn it off for strict Vim, which matches "
                            + "only \" and '."
                    )
                }
                .disabled(!vim.isEnabled)
            }
        }
        .formStyle(.grouped)
    }
}
