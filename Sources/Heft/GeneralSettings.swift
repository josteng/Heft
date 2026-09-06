import Foundation
import HeftCore
import SwiftUI

/// The app-wide preferences that are not about how anything looks.
///
/// Kept apart from Startup, which answers one question per vault, and from
/// Appearance, which is about the page. These are about how the app behaves:
/// where a new note lands, and whether a window opens with its calendar.
///
/// App-wide rather than per-vault, for the reason `AttachmentSettings` is: they
/// describe how this person works rather than how one vault is arranged. The
/// one that could go either way is the named new-note folder, and a vault
/// without it gets the folder made on demand rather than a silent fallback.
@MainActor
final class GeneralSettings: ObservableObject {
    static let shared = GeneralSettings()

    private static let newNoteKey = "dev.stenglein.Heft.general.newNoteLocation"
    private static let calendarKey = "dev.stenglein.Heft.general.calendarVisibility"
    private static let agentOfferKey = "dev.stenglein.Heft.general.offersAgentSetup"

    @Published var newNoteLocation: NewNoteLocation {
        didSet {
            HeftDefaults.shared.set(newNoteLocation.stored, forKey: Self.newNoteKey)
        }
    }

    @Published var calendarVisibility: CalendarVisibility {
        didSet {
            HeftDefaults.shared.set(calendarVisibility.rawValue, forKey: Self.calendarKey)
        }
    }

    /// Whether a vault without agent instructions is offered them. Off is
    /// for someone who does not use agents and would otherwise answer the
    /// question once per vault; the menu item and the command line still
    /// write the guide on request.
    @Published var offersAgentSetup: Bool {
        didSet {
            HeftDefaults.shared.set(offersAgentSetup, forKey: Self.agentOfferKey)
        }
    }

    private init() {
        offersAgentSetup = HeftDefaults.shared.object(forKey: Self.agentOfferKey) == nil
            || HeftDefaults.shared.bool(forKey: Self.agentOfferKey)
        newNoteLocation = NewNoteLocation(
            stored: HeftDefaults.shared.string(forKey: Self.newNoteKey) ?? ""
        )
        calendarVisibility = HeftDefaults.shared.string(forKey: Self.calendarKey)
            .flatMap(CalendarVisibility.init(rawValue:)) ?? .whenDailyNotesAreInScope
    }
}

/// The General pane.
///
/// The state is read in `body` and written back through a `Binding`, never
/// copied in `onAppear`: the Settings window measures each pane off screen to
/// size itself, and `onAppear` never fires for a view that is never on screen,
/// so a pane filled in there measures as its own empty placeholder.
struct GeneralSettingsView: View {
    @ObservedObject private var settings = GeneralSettings.shared

    /// Which of the four the picker is on. Held apart from the folder text so
    /// that switching away from "a folder" and back does not lose what was
    /// typed, the way an attachment rule keeps its name while switched off.
    private enum Choice: String, CaseIterable, Identifiable {
        case beside, focus, root, folder
        var id: String { rawValue }

        var title: String {
            switch self {
            case .beside: "Beside the note I am reading"
            case .focus: "In the folder this window is showing"
            case .root: "At the top of the vault"
            case .folder: "In one folder"
            }
        }
    }

    /// Empty, not a guess. It was "Inbox", which is a *note* in at least one
    /// real vault — so the suggestion would have made a folder beside a file
    /// of the same name, which is the one thing a default here must not do.
    @State private var typedFolder = ""

    private var choice: Binding<Choice> {
        Binding(
            get: {
                switch settings.newNoteLocation {
                case .besideTheOpenNote: .beside
                case .focusedFolder: .focus
                case .vaultRoot: .root
                case .folder: .folder
                }
            },
            set: { new in
                settings.newNoteLocation = switch new {
                case .beside: .besideTheOpenNote
                case .focus: .focusedFolder
                case .root: .vaultRoot
                case .folder: .folder(typedFolder)
                }
            }
        )
    }

    private var folder: Binding<String> {
        Binding(
            get: {
                if case .folder(let path) = settings.newNoteLocation { return path }
                return typedFolder
            },
            set: { new in
                typedFolder = new
                if case .folder = settings.newNoteLocation {
                    settings.newNoteLocation = .folder(new)
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: choice) {
                    ForEach(Choice.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel(
                        "New notes go",
                        detail: "Where ⌘N puts a note. Picking a folder in the sidebar first still wins."
                    )
                }
                if choice.wrappedValue == .folder {
                    // Bordered and with its label hidden, the way the Startup
                    // pane's path field is: a plain `TextField` in a grouped
                    // Form draws as right-aligned text with no edge to it, so
                    // it reads as a value someone else set rather than as
                    // something to type in.
                    LabeledContent {
                        TextField("", text: folder, prompt: Text("Projects/Notes"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    } label: {
                        SettingLabel(
                            "Folder",
                            detail: "Made when the first note goes in it, if it is not there yet."
                        )
                    }
                }
            }

            Section {
                Picker(selection: Binding(
                    get: { settings.calendarVisibility },
                    set: { settings.calendarVisibility = $0 }
                )) {
                    ForEach(CalendarVisibility.allCases) { Text($0.title).tag($0) }
                } label: {
                    // What the setting decides is how a window *opens*. Saying
                    // so matters because ⇧⌘D still works either way, and a
                    // setting that looked absolute would read as broken the
                    // first time it was overridden by hand.
                    SettingLabel(
                        "Show the calendar",
                        detail: settings.calendarVisibility == .whenDailyNotesAreInScope
                            ? "How a window opens: without the calendar when it is showing a folder "
                                + "that holds no daily notes. ⇧⌘D shows and hides it at any time."
                            : "How every window opens. ⇧⌘D shows and hides it at any time."
                    )
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { settings.offersAgentSetup },
                    set: { settings.offersAgentSetup = $0 }
                )) {
                    SettingLabel(
                        "Offer agent setup for new vaults",
                        detail: settings.offersAgentSetup
                            ? "A vault without agent instructions is asked once whether to add them. "
                                + "Not Now is remembered for that vault."
                            : "Never asked. File ▸ Set Up Agent Access still writes the instructions when you want them."
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}
