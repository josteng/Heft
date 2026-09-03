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

    private static let key = "dev.stenglein.Heft.attachmentPlan"

    @Published var plan: AttachmentPlan {
        didSet {
            guard let data = try? JSONEncoder().encode(plan) else { return }
            HeftDefaults.shared.set(data, forKey: Self.key)
        }
    }

    /// What the paste path actually resolves with.
    var rules: AttachmentRules { plan.rules }

    private init() {
        // An unreadable or absent setting means the standard plan, not an empty
        // one: a plan with no rules would send every attachment to the vault
        // root and look like a deliberate choice.
        if let data = HeftDefaults.shared.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(AttachmentPlan.self, from: data),
           !stored.entries.isEmpty {
            plan = stored
        } else {
            plan = .standard
        }
    }

    func reset() { plan = .standard }
}
