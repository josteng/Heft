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
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Note", requestValueDialog: "Which note?")
    var target: NoteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run { NoteOpenRequest.shared.path = target.id }
        return .result()
    }
}

/// The note an intent asked for, held until the root view can show it, so
/// one that arrives while the app is still launching is not lost.
@MainActor @Observable
final class NoteOpenRequest {
    static let shared = NoteOpenRequest()
    var path: String?
}
