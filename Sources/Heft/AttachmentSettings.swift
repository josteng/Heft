import Foundation
import HeftCore
import SwiftUI

/// The reader's own ordering of the attachment rules, app-wide.
///
/// App-wide rather than per-vault: the rules are about how this person files
/// things, and the one that does the vault-specific work — `.learned` — reads
/// the vault it is asked about. A vault that wants its own answer says so in
/// `.obsidian/app.json`, which is the first rule by default.
@MainActor
final class AttachmentSettings: ObservableObject {
    static let shared = AttachmentSettings()

    private static let key = AttachmentPlan.defaultsKey

    @Published var plan: AttachmentPlan {
        didSet {
            guard let data = try? JSONEncoder().encode(plan) else { return }
            HeftDefaults.shared.set(data, forKey: Self.key)
        }
    }

    /// What the paste path actually resolves with.
    var rules: AttachmentRules { plan.rules }

    private init() {
        plan = AttachmentPlan.stored(in: HeftDefaults.shared)
    }

    func reset() { plan = .standard }
}
