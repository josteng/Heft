import Foundation

/// Bridges foreground App Intents to SwiftUI's live window registry. Intent
/// execution can begin before the first WindowGroup has appeared, so requests
/// are queued briefly and drained when a workspace registers itself.
@MainActor
final class IntentNavigation {
    static let shared = IntentNavigation()

    private weak var registry: VaultRegistry?
    private var pending: [(url: URL, vaultRoot: URL)] = []

    private init() {}

    func attach(_ registry: VaultRegistry) {
        self.registry = registry
        let requests = pending
        pending.removeAll()
        for request in requests {
            _ = registry.openFromIntent(request.url, in: request.vaultRoot)
        }
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
