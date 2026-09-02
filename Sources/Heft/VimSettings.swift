import HeftVimCore
import SwiftUI

@MainActor
final class VimSettings: ObservableObject {
    static let shared = VimSettings()

    @Published var isEnabled: Bool {
        didSet {
            guard !isApplyingVaultDefault else { return }
            followsVaultDefault = false
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }
    @Published private(set) var mode: VimMode = .normal
    @Published private(set) var message: String?
    @Published var continuesMarkdownStructure: Bool {
        didSet {
            UserDefaults.standard.set(
                continuesMarkdownStructure,
                forKey: Self.continuesMarkdownStructureKey
            )
        }
    }
    @Published var matchesTypographicQuotes: Bool {
        didSet {
            UserDefaults.standard.set(
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
    private var isApplyingVaultDefault = false
    private(set) var followsVaultDefault: Bool

    private init() {
        let defaults = UserDefaults.standard
        followsVaultDefault = defaults.object(forKey: Self.enabledKey) == nil
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        continuesMarkdownStructure = defaults.object(
            forKey: Self.continuesMarkdownStructureKey
        ) == nil || defaults.bool(forKey: Self.continuesMarkdownStructureKey)
        matchesTypographicQuotes = defaults.object(
            forKey: Self.matchesTypographicQuotesKey
        ) == nil || defaults.bool(forKey: Self.matchesTypographicQuotesKey)
    }

    func adoptVaultDefault(_ enabled: Bool) {
        guard followsVaultDefault, isEnabled != enabled else { return }
        isApplyingVaultDefault = true
        isEnabled = enabled
        isApplyingVaultDefault = false
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
            Toggle(isOn: $vim.isEnabled) {
                HStack(spacing: 8) {
                    Text("Vim key bindings")
                    Text("EXPERIMENTAL")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.12), in: .capsule)
                }
            }
            Text("Initially follows the vault's Obsidian Vim setting; changing this toggle creates an "
                + "app-wide preference. Uses native Swift key handling. Your notes remain ordinary Markdown, "
                + "and Heft does not bundle or link against Vim or Neovim.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Available now: Normal, Insert, Replace, Visual, Visual Line, and Visual Block modes; "
                + "counts and operator-motion commands; text objects; dot-repeat; visual paste; line "
                + "indentation; f/F/t/T, %, *, and #; block insertion; undo/redo; and zz/zt/zb.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("Preserve Markdown structure in Vim edits", isOn: $vim.continuesMarkdownStructure)
            Text("Continues bullet, numbered, task, and blockquote markers with o/O, and retains the "
                + "marker when cc, S, or a Visual Line change replaces an item. This is a Heft "
                + "convenience rather than standard Vim behavior.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("Match typographic quotes in text objects", isOn: $vim.matchesTypographicQuotes)
            Text("Lets ci\" and ca\" work on \u{201C}curly quotes\u{201D} and \u{00AB}guillemets\u{00BB}, "
                + "and ci' on \u{2018}curly single quotes\u{2019}. Typing substitutions replace the "
                + "straight characters as you write, so without this the quotes in your notes are no "
                + "longer the ones those commands look for. Turn it off for strict Vim, which matches "
                + "only \" and '.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 630)
    }
}
