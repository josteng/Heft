import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// Each settings pane has to report the height it needs, because that is what
/// `NSTabViewController` resizes the window to.
///
/// The failure this guards has happened three times and always looks the same:
/// a pane clipped halfway down a control, or given a scroll bar. It used to be
/// measured by hand off screen; now the number comes from
/// `NSHostingController.preferredContentSize`, which is what AppKit actually
/// sizes from — so these ask the same questions of the mechanism that ships.
@Suite("Settings pane sizes")
@MainActor
struct SettingsPaneSizeTests {

    /// What AppKit will size the window to. Built the way the window builds
    /// them, cap included, or a test measures something that never ships.
    static func height(of pane: SettingsPane, registry: VaultRegistry) -> CGFloat {
        let host = NSHostingController(
            rootView: AnyView(
                pane.content
                    .environmentObject(registry)
                    .frame(width: SettingsPane.width)
                    .frame(maxHeight: SettingsPane.maximumHeight)
            )
        )
        host.sizingOptions = [.preferredContentSize]
        host.view.layoutSubtreeIfNeeded()
        return host.preferredContentSize.height
    }

    /// Nothing clamps `preferredContentSize`, so a tall pane simply makes a
    /// tall window — one that cannot be resized and does not scroll, so its
    /// bottom is unreachable. The cap has to leave room for the titlebar and
    /// the tab bar on the screen it is actually on, which is the part a
    /// constant chosen once would get wrong on somebody else's display.
    @Test("The height cap leaves room for the window's own chrome")
    func capLeavesRoomForChrome() {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        let chrome: CGFloat = 120
        let tallest = SettingsPane.maximumHeight + chrome
        #expect(
            tallest <= screen,
            "a capped pane still makes a \(tallest)pt window on a \(screen)pt screen"
        )
        // And not so tight that an ordinary pane is scrolled for no reason.
        #expect(SettingsPane.maximumHeight >= 400)
    }

    @Test("Every pane fits the window it will be shown in")
    func panesFitTheirWindow() throws {
        try withVault { registry, _ in
            for pane in SettingsPane.allCases {
                let height = Self.height(of: pane, registry: registry)
                #expect(height <= SettingsPane.maximumHeight + 1, "\(pane.title) wants \(height)")
            }
        }
    }

    private func withVault(_ body: @MainActor (VaultRegistry, URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "note".write(
            to: root.appendingPathComponent("Inbox.md"), atomically: true, encoding: .utf8
        )

        let registry = VaultRegistry()
        let model = AppModel(
            registry: registry, descriptor: WorkspaceDescriptor(vaultPath: root.path)
        )
        registry.register(model: model, openWindow: { _ in })
        defer {
            model.closeWorkspace()
            StartupSettings.shared.set(.standard, for: root)
        }
        try body(registry, root)
    }

    /// Choosing an option that needs a path adds a field, and the pattern option
    /// adds the token list as well. A window measured once per tab clips both.
    @Test("A pane that grows reports that it has grown")
    func paneGrowsWithItsChoice() throws {
        try withVault { registry, vault in
            @MainActor func height(_ choice: StartupNote.Choice) -> CGFloat {
                StartupSettings.shared.set(
                    StartupNote(choice: choice, text: "Inbox.md"), for: vault
                )
                return Self.height(of: .startup, registry: registry)
            }
            let plain = height(.nothing)
            let named = height(.note)
            let pattern = height(.pattern)

            #expect(plain > 0)
            #expect(named > plain, "a path field should need room: \(named) vs \(plain)")
            // By a lot: the pattern option carries the whole token list, which
            // is worth a couple of hundred points. A few points more would be
            // satisfied by its longer sentence alone.
            #expect(
                pattern > named + 120,
                "the token list should need real room: \(pattern) vs \(named)"
            )
        }
    }

    /// The other failure: a pane that filled itself in on appear measured as its
    /// own empty placeholder, because `onAppear` never fires for a view that is
    /// never on screen.
    @Test("A pane measures at its real size, not its empty one")
    func paneMeasuresItsRealContent() throws {
        let empty = Self.height(of: .startup, registry: VaultRegistry())
        try withVault { registry, _ in
            let real = Self.height(of: .startup, registry: registry)
            #expect(
                real > empty,
                "with a vault open the pane has content: \(real) against \(empty) without"
            )
        }
    }

    /// Every pane has to be measurable: one that comes back at nothing would be
    /// a window with no height at all.
    @Test("Every tab measures to something")
    func everyTabMeasures() {
        let registry = VaultRegistry()
        for tab in SettingsPane.allCases {
            #expect(
                Self.height(of: tab, registry: registry) > 80,
                "\(tab.title) measured to nothing"
            )
        }
    }
}

extension SettingsPaneSizeTests {

    /// The General pane has the same shape-changing choice the Startup one
    /// does: naming a folder adds a field and a line of explanation.
    @Test("The General pane grows when a folder has to be named")
    func generalPaneGrowsForAFolder() throws {
        try withVault { registry, _ in
            let settings = GeneralSettings.shared
            let restore = settings.newNoteLocation
            defer { settings.newNoteLocation = restore }

            settings.newNoteLocation = .besideTheOpenNote
            let plain = Self.height(of: .general, registry: registry)
            settings.newNoteLocation = .folder("Inbox")
            let named = Self.height(of: .general, registry: registry)

            #expect(plain > 0)
            #expect(named > plain, "a folder field should need room: \(named) vs \(plain)")
        }
    }
}

extension SettingsPaneSizeTests {

    /// Choosing "Never" did nothing until the next launch: the setting was
    /// read once when a window was built, and no open window was listening.
    @Test("Changing when the calendar shows reaches the open window")
    func calendarSettingReachesOpenWindows() throws {
        try withVault { registry, root in
            let model = AppModel(
                registry: registry, descriptor: WorkspaceDescriptor(vaultPath: root.path)
            )
            defer {
                model.closeWorkspace()
                GeneralSettings.shared.calendarVisibility = .whenDailyNotesAreInScope
            }

            GeneralSettings.shared.calendarVisibility = .always
            #expect(model.isCalendarVisible)

            GeneralSettings.shared.calendarVisibility = .never
            #expect(!model.isCalendarVisible, "a window built before the change never heard it")

            GeneralSettings.shared.calendarVisibility = .always
            #expect(model.isCalendarVisible)
        }
    }
}

/// The two General settings, as rules rather than as a pane.
@Suite("General settings")
struct GeneralPreferenceTests {

    @Test("Where a new note goes")
    func newNoteLocation() {
        // Beside the open note is the old behaviour, and falls back through
        // the focused folder to the vault root when nothing is open.
        #expect(NewNoteLocation.besideTheOpenNote
            .directory(openNoteFolder: "Projects", focus: "Work") == "Projects")
        #expect(NewNoteLocation.besideTheOpenNote
            .directory(openNoteFolder: nil, focus: "Work") == "Work")
        #expect(NewNoteLocation.besideTheOpenNote
            .directory(openNoteFolder: nil, focus: nil) == "")

        // The focused folder is a different answer whenever the open note sits
        // below it, which is the case the two would otherwise be confused in.
        #expect(NewNoteLocation.focusedFolder
            .directory(openNoteFolder: "Work/Projects", focus: "Work") == "Work")

        #expect(NewNoteLocation.vaultRoot
            .directory(openNoteFolder: "Projects", focus: "Work") == "")

        #expect(NewNoteLocation.folder("Inbox")
            .directory(openNoteFolder: "Projects", focus: "Work") == "Inbox")
        // A folder field left empty is not a request to write to the vault
        // root; it is a setting nobody finished, so the window's own answer
        // stands.
        #expect(NewNoteLocation.folder("")
            .directory(openNoteFolder: "Projects", focus: "Work") == "Work")
    }

    @Test("A typed folder cannot name anywhere outside the vault")
    func folderIsNormalised() {
        #expect(NewNoteLocation.normalised("/Inbox/") == "Inbox")
        #expect(NewNoteLocation.normalised("../../etc") == "etc")
        #expect(NewNoteLocation.normalised("Work//Notes") == "Work/Notes")
        #expect(NewNoteLocation.normalised("  ") == "")
        #expect(NewNoteLocation.folder("../../etc/passwd")
            .directory(openNoteFolder: nil, focus: nil) == "etc/passwd")
    }

    /// The suggestion used to be "Inbox", which is a *note* in a real vault.
    /// Accepting it would have made a folder beside a file of the same name.
    @Test("The folder field suggests nothing")
    @MainActor
    func folderFieldHasNoDefault() {
        let settings = GeneralSettings.shared
        let restore = settings.newNoteLocation
        defer { settings.newNoteLocation = restore }

        settings.newNoteLocation = .folder("")
        // An unfinished setting is not a request to write to the vault root;
        // the window's own answer stands until a folder is actually typed.
        #expect(NewNoteLocation.folder("").directory(openNoteFolder: "Work", focus: "Work")
            == "Work")
    }

    @Test("A stored location survives a round trip, and an unknown one is the default")
    func locationRoundTrips() {
        for value: NewNoteLocation in [
            .besideTheOpenNote, .focusedFolder, .vaultRoot, .folder("Inbox/Quick"),
        ] {
            #expect(NewNoteLocation(stored: value.stored) == value)
        }
        // Written by a later version, or by hand: the default, not a crash and
        // not a settings file that stops decoding.
        #expect(NewNoteLocation(stored: "something-new") == .besideTheOpenNote)
        #expect(NewNoteLocation(stored: "") == .besideTheOpenNote)
    }

    @Test("When the calendar opens")
    func calendarVisibility() {
        // The default is scope-aware and keeps what the window was last left
        // showing, because it is exactly the behaviour that was there before.
        #expect(CalendarVisibility.whenDailyNotesAreInScope
            .isVisible(dailyNotesAreInScope: true, remembered: nil))
        #expect(!CalendarVisibility.whenDailyNotesAreInScope
            .isVisible(dailyNotesAreInScope: false, remembered: nil))
        #expect(!CalendarVisibility.whenDailyNotesAreInScope
            .isVisible(dailyNotesAreInScope: true, remembered: false))

        // The other two are a standing instruction, so a restored window that
        // disagreed cannot keep overruling them.
        #expect(CalendarVisibility.always
            .isVisible(dailyNotesAreInScope: false, remembered: false))
        #expect(!CalendarVisibility.never
            .isVisible(dailyNotesAreInScope: true, remembered: true))
    }
}

/// The two Appearance settings that are not colours.
@Suite("Appearance settings")
@MainActor
struct AppearanceBehaviourTests {

    @Test("How consecutive lines are read, and who decides")
    func lineBreaks() {
        // Following the vault is the default, so an upgrade cannot change how
        // anybody's notes read: it has to pass both vault answers through.
        #expect(LineBreakStyle.followTheVault.strictLineBreaks(vaultSetting: true))
        #expect(!LineBreakStyle.followTheVault.strictLineBreaks(vaultSetting: false))

        // The other two are the point of the setting: a plain folder of
        // Markdown has no `.obsidian` to ask, and was stuck with the default.
        #expect(!LineBreakStyle.aLineEach.strictLineBreaks(vaultSetting: true))
        #expect(LineBreakStyle.oneParagraph.strictLineBreaks(vaultSetting: false))
    }

    @Test("A setting written by a later version is the default, not a crash")
    func unknownStyleIsTheDefault() {
        #expect(LineBreakStyle(rawValue: "somethingNew") == nil)
    }

    @Test("Folder arrows are off unless asked for")
    func folderArrowsDefaultOff() {
        let key = "dev.stenglein.Heft.appearance.folderArrows"
        // An absent setting is false, which is what makes "off by default"
        // the same statement as "nobody has said anything".
        #expect(HeftDefaults.shared.object(forKey: key) == nil
            || HeftDefaults.shared.bool(forKey: key) == AppearanceSettings.shared.showsFolderArrows)
    }
}

/// Reveal is mostly a model change — which folders are open, and a request the
/// sidebar answers — so most of it can be asked for without a window.
@Suite("Reveal in the sidebar")
@MainActor
struct RevealTests {

    @Test("Revealing a note opens every folder above it and asks the sidebar to scroll")
    func revealOpensAncestors() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reveal-\(UUID().uuidString)")
        let deep = root.appendingPathComponent("Work/Projects/Heft")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "note".write(
            to: deep.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8
        )

        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(
                vaultPath: root.path, notePath: "Work/Projects/Heft/Notes.md"
            )
        )
        defer { model.closeWorkspace() }
        #expect(model.current?.relativePath == "Work/Projects/Heft/Notes.md")

        model.expandedFolders = []
        model.columnVisibility = .detailOnly
        model.revealCurrentInSidebar()

        // Every ancestor, not just the innermost: a note four deep was
        // otherwise revealed behind three closed folders.
        #expect(model.expandedFolders == ["Work", "Work/Projects", "Work/Projects/Heft"])
        // The note itself is not a folder to open; it is what gets scrolled to.
        #expect(model.revealTarget == "Work/Projects/Heft/Notes.md")
        // And a hidden sidebar comes back, or the reveal happens off screen.
        #expect(model.columnVisibility != .detailOnly)

        model.finishReveal()
        #expect(model.revealTarget == nil)
    }
}

/// "Inbox" means one thing in Heft: the note ⇧⌘I appends to. Offering it as
/// the example anywhere else makes two features look like they point at the
/// same place, and a folder named after a note is a mess nobody asked for.
@Suite("Inbox means one thing")
@MainActor
struct InboxNamingTests {

    @Test("Nothing but capture suggests the name Inbox")
    func onlyCaptureSuggestsInbox() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")

        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        for file in files where file.lastPathComponent != "InboxCapture.swift" {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                // Only what a person is shown: a literal offered in the UI.
                guard line.contains("\"Inbox") else { continue }
                // Comments explaining the rule are not suggestions.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                offenders.append("\(file.lastPathComponent): \(trimmed)")
            }
        }
        #expect(offenders.isEmpty, "these offer Inbox as an example:\n\(offenders.joined(separator: "\n"))")
    }
}
