import Foundation

/// What the reader has opened in a vault, as the app records it, readable
/// by the command line too: an agent asked "what have I been working on" can
/// only answer from what Heft saw, since opening a note leaves no trace in
/// the files.
public enum VaultUse {
    /// The key the app keeps a vault's opening history under, last first.
    public static func recentsKey(forVaultAt root: String) -> String {
        "dev.stenglein.Heft.recents.\(root)"
    }

    /// Vault-relative paths, the one opened last first.
    public static func recentPaths(forVaultAt root: String, in defaults: UserDefaults = HeftDefaults.shared) -> [String] {
        defaults.stringArray(forKey: recentsKey(forVaultAt: root)) ?? []
    }
}
