import Foundation
import HeftCore
import SwiftUI

/// What each vault opens when Heft starts.
///
/// Per vault, not app-wide: "always open `Thesis/Overview`" means nothing
/// in another vault, and a setting that quietly points at a note that is not
/// there is worse than no setting. Keyed by the vault's standardized path, the
/// way the frecency stores are — `standardizedFileURL` rewrites `/private/tmp`
/// to `/tmp`, so anything building such a key by hand has to standardize too or
/// it writes somewhere nothing reads.
@MainActor
final class StartupSettings: ObservableObject {
    static let shared = StartupSettings()

    private static let prefix = "dev.stenglein.Heft.startupNote:"

    private init() {}

    static func key(forVaultAt path: String) -> String {
        prefix + (path as NSString).standardizingPath
    }

    func setting(for vault: URL) -> StartupNote {
        let key = Self.key(forVaultAt: vault.standardizedFileURL.path)
        guard let data = HeftDefaults.shared.data(forKey: key),
              let stored = try? JSONDecoder().decode(StartupNote.self, from: data)
        else { return .standard }
        return stored
    }

    func set(_ setting: StartupNote, for vault: URL) {
        let key = Self.key(forVaultAt: vault.standardizedFileURL.path)
        guard let data = try? JSONEncoder().encode(setting) else { return }
        HeftDefaults.shared.set(data, forKey: key)
        objectWillChange.send()
    }
}
