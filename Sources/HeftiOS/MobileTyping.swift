import Foundation
import HeftCore

/// Replacements and pairing for the iOS editor: the list the Mac keeps in
/// the vault (`SharedTypingSetup`), and this device's own switches, which
/// can turn either off without touching the Mac.
@MainActor
final class MobileTyping {
    static let shared = MobileTyping()

    /// The vault's, after each scan; the Mac's defaults until one has
    /// written it.
    var setup = SharedTypingSetup() {
        didSet { if setup != oldValue { cached = nil } }
    }

    /// The vault the setup is kept in, for saving an edit made here.
    var root: URL?

    /// Changes the shared setup and writes it to the vault, where the Mac
    /// and the other devices pick it up.
    func change(_ edit: (inout SharedTypingSetup) -> Void) {
        var changed = setup
        edit(&changed)
        guard changed != setup else { return }
        setup = changed
        if let root { try? changed.write(to: root) }
    }

    var replaces: Bool {
        get { Self.flag(Self.replacesKey) }
        set { HeftDefaults.shared.set(newValue, forKey: Self.replacesKey); cached = nil }
    }

    var pairs: Bool {
        get { Self.flag(Self.pairsKey) }
        set { HeftDefaults.shared.set(newValue, forKey: Self.pairsKey) }
    }

    var pairsBrackets: Bool { pairs && setup.pairsBrackets }
    var pairsMarkdown: Bool { pairs && setup.pairsMarkdown }

    /// Built once per setup rather than on every keystroke.
    var rules: [SmartTypographyRule] {
        if let cached { return cached }
        var config = setup.config
        config.isEnabled = config.isEnabled && replaces
        let rules = SmartTypography.rules(for: config)
        cached = rules
        return rules
    }

    private var cached: [SmartTypographyRule]?

    private static let replacesKey = "dev.stenglein.Heft.iOS.typing.replaces"
    private static let pairsKey = "dev.stenglein.Heft.iOS.typing.pairs"

    private static func flag(_ key: String) -> Bool {
        HeftDefaults.shared.object(forKey: key) as? Bool ?? true
    }
}
