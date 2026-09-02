import Foundation

/// Bridges foreground App Intents to SwiftUI's live window registry. Intent
/// execution can begin before the first WindowGroup has appeared, so requests
/// are queued briefly and drained when a workspace registers itself.
@MainActor
final class IntentNavigation {
    static let shared = IntentNavigation()

    private weak var registry: VaultRegistry?
    private var pending: [(url: URL, vaultRoot: URL)] = []
    /// Paths from the `heft` command line tool. Held separately because they
    /// have no vault yet: working out which vault a path belongs to is the
    /// registry's job, and it cannot be asked before one exists.
    private var pendingPaths: [String] = []

    private init() {}

    func attach(_ registry: VaultRegistry) {
        self.registry = registry
        let requests = pending
        pending.removeAll()
        for request in requests {
            _ = registry.openFromIntent(request.url, in: request.vaultRoot)
        }
        let paths = pendingPaths
        pendingPaths.removeAll()
        for path in paths {
            registry.openPath(path)
        }
    }

    /// Opens a path from outside the app, once there is a window to open it in.
    ///
    /// Launching Heft by URL means the request routinely arrives before the
    /// first `WindowGroup` has appeared, which is the same race the intent
    /// queue above exists for.
    func openPath(_ path: String) {
        guard let registry else {
            pendingPaths.append(path)
            return
        }
        if !registry.openPath(path) { pendingPaths.append(path) }
    }

    func open(_ url: URL, in vaultRoot: URL) {
        guard let registry else {
            pending.append((url.standardizedFileURL, vaultRoot.standardizedFileURL))
            return
        }
        if !registry.openFromIntent(url, in: vaultRoot) {
            pending.append((url.standardizedFileURL, vaultRoot.standardizedFileURL))
        }
    }
}
