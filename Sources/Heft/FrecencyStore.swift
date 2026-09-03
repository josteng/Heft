import Foundation
import HeftCore

/// A `Frecency` that persists itself.
///
/// Deliberately not an `ObservableObject`. Recording a use must not publish a
/// change: the palette and the switcher read the ranking when they open, and a
/// store that told SwiftUI it had changed on every note opened would re-render
/// the window for a number nothing on screen is showing.
final class FrecencyStore {
    private let key: String
    private var frecency: Frecency

    init(key: String) {
        self.key = key
        frecency = Frecency(decoding: UserDefaults.standard.data(forKey: key))
    }

    func record(_ identifier: String) {
        frecency.record(identifier)
        UserDefaults.standard.set(frecency.encoded, forKey: key)
    }

    func score(_ identifier: String) -> Double { frecency.score(identifier) }

    func ranked<Key>(
        _ keys: [Key],
        by identity: (Key) -> String,
        tiebreak: (Key, Key) -> Bool
    ) -> [Key] {
        frecency.ranked(keys, by: identity, tiebreak: tiebreak)
    }

    /// What the command palette has been used for. App-wide: the commands are
    /// the app's, not a vault's.
    static let commands = FrecencyStore(key: "dev.stenglein.Heft.frecency.commands")

    /// Per vault, because "the note I keep opening" is a fact about a vault.
    static func notes(forVaultAt path: String) -> FrecencyStore {
        FrecencyStore(key: "dev.stenglein.Heft.frecency.notes.\(path)")
    }

    /// What an *agent* has been working on, kept separately and never mixed
    /// into the reader's.
    ///
    /// Two indices rather than one, because they answer different questions
    /// for different readers. Folding agent activity into the store above
    /// would let one `heft propose` loop over thirty notes displace weeks of
    /// the reader's own signal in a switcher they did not ask to have
    /// reordered. Keeping it out entirely loses something real, though: once a
    /// proposal is accepted the record that an agent ever worked on that note
    /// is gone, and a session resuming tomorrow has no way to ask what it did
    /// yesterday.
    static func agentNotes(forVaultAt path: String) -> FrecencyStore {
        FrecencyStore(key: "dev.stenglein.Heft.frecency.agent.\(path)")
    }
}
