import AppIntents
import Observation

/// Where a capture goes: today's daily note, or the vault's inbox note.
enum CaptureTarget: String, AppEnum, Identifiable {
    case today, inbox

    var id: String { rawValue }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Destination"
    static let caseDisplayRepresentations: [CaptureTarget: DisplayRepresentation] = [
        .today: "Today's Note",
        .inbox: "The Inbox",
    ]
}

/// Opens Heft on the capture sheet, aimed at one destination.
///
/// What the Control Center, Lock Screen and Action button controls run.
/// Compiled into the controls extension as well as the app, because a
/// control can only name an intent its own target holds; it runs in the app,
/// which is the process with a sheet to show.
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Capture"
    static let description = IntentDescription("Opens Heft ready to capture a line.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Destination", default: .today)
    var destination: CaptureTarget

    init() {}

    init(destination: CaptureTarget) {
        self.destination = destination
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureRequest.shared.target = destination
        return .result()
    }
}

/// The capture sheet the app has been asked to show. Set by the intent, read
/// and cleared by the root view; held here so a request made while the app
/// was still launching is not lost.
@MainActor @Observable
final class CaptureRequest {
    static let shared = CaptureRequest()
    var target: CaptureTarget?
}
