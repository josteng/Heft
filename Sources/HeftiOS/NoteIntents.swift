import AppIntents
import HeftCore
import Observation

/// Opens a note from Shortcuts, Siri, or a Spotlight result.
///
/// An `OpenIntent` because that is what Spotlight runs when an indexed
/// entity is tapped: without one, a note found there only launched the app.
/// The parameter has to be called `target`; the protocol requires it.
struct MobileOpenNoteIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open a Note"
    static let description = IntentDescription("Opens a note from your Heft vault.")
    /// Deferred: Heft comes forward once `perform` returns, which waits for
    /// the note to be on screen, so the one shown before it is not.
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Note", requestValueDialog: "Which note?")
    var target: NoteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        await NoteOpenRequest.shared.open(target.id)
        return .result()
    }
}

/// Opens the note a Spotlight result or Siri holds. On iOS 27 the vault is
/// donated as `SiriNoteEntity`, the schema's note, and a tapped result runs
/// only an open intent whose target is that type: with `MobileOpenNoteIntent`
/// alone, a tap launched Heft on whatever note it was showing.
///
/// Not assistant-only, as the Mac's is: what that hides is not documented,
/// and Spotlight, not Siri, is what this has to answer.
@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
struct MobileSiriOpenNoteIntent {
    /// Deferred: Heft comes forward once `perform` returns, which waits for
    /// the note to be on screen, so the one shown before it is not.
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Note")
    var target: SiriNoteEntity

    func perform() async throws -> some IntentResult {
        await NoteOpenRequest.shared.open(target.id)
        return .result()
    }
}

/// The note an intent asked for, held until the root view can show it, so
/// one that arrives while the app is still launching is not lost.
@MainActor @Observable
final class NoteOpenRequest {
    static let shared = NoteOpenRequest()
    var path: String?
    /// Whether the note last asked for is on screen, or nothing is waiting.
    @ObservationIgnored var settled = true

    /// Asks for `path` and waits, briefly, until it is shown. The intents
    /// run while Heft is still in the background and bring it forward when
    /// they return, so the note opens out of sight and the one on screen
    /// before it is not shown again first. SwiftUI swaps the screen in the
    /// background too. A launch that has no window yet keeps the request
    /// for the root view; the wait only ever delays the app's arrival.
    func open(_ path: String) async {
        settled = false
        self.path = path
        for _ in 0..<15 where !settled {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }
}
