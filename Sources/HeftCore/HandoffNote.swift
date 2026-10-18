import Foundation

/// The note one device has open, as Handoff carries it to the other.
///
/// The two apps have different bundle identifiers and different paths to the
/// same vault, so what travels is the note's place inside the vault and the
/// vault folder's name; each side finds its own copy from there. Handoff
/// itself needs only that both apps declare `activityType` and are signed by
/// the same team.
public struct HandoffNote: Equatable, Sendable {
    public static let activityType = "dev.stenglein.Heft.handoffNote"

    /// Vault-relative, with the `.md`.
    public var path: String
    /// The vault folder's name, which picks between vaults when there are
    /// several and is otherwise not needed.
    public var vault: String

    public init(path: String, vault: String) {
        self.path = path
        self.vault = vault
    }

    public var userInfo: [String: String] { ["path": path, "vault": vault] }

    /// Nil for anything that is not a note inside a vault: the payload comes
    /// from another device, and `../` must not reach outside the folder.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let raw = userInfo?["path"] as? String else { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard raw.lowercased().hasSuffix(".md"), !raw.hasPrefix("/"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        path = raw
        vault = userInfo?["vault"] as? String ?? ""
    }
}
