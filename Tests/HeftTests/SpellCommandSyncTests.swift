import AppKit
import Foundation
import Testing
@testable import Heft

/// One setting behind three surfaces. The settings pane binds to it directly,
/// so what needs proving is that the palette reads it live rather than a copy
/// taken when the list was built, and that the menu items write to it.
@MainActor
@Suite("Spell command sync")
struct SpellCommandSyncTests {

    /// A model is needed only because a command's title is a function of one;
    /// these three read the settings singleton and ignore it.
    private func model() -> AppModel {
        AppModel(registry: VaultRegistry(), descriptor: nil)
    }

    private func command(_ id: String) -> AppCommand? {
        AppCommand.registry.first { $0.id == id }
    }

    private func title(_ id: String, _ model: AppModel) -> String? {
        command(id)?.title(on: model)
    }

    @Test("All three commands are in the palette")
    func present() {
        #expect(command("toggleSpelling") != nil)
        #expect(command("toggleGrammar") != nil)
        #expect(command("toggleAutocorrect") != nil)
    }

    /// Read at display time, not captured when the list was built, or the
    /// palette offers to turn on what is already on.
    @Test("Each palette title follows its setting")
    func titlesFollowTheSetting() {
        let settings = TypingSettings.shared
        let spelling = settings.checksSpelling
        let grammar = settings.checksGrammar
        let correction = settings.correctsSpelling
        defer {
            settings.checksSpelling = spelling
            settings.checksGrammar = grammar
            settings.correctsSpelling = correction
        }

        let model = model()
        defer { model.closeWorkspace() }

        settings.checksSpelling = true
        settings.checksGrammar = true
        settings.correctsSpelling = true
        #expect(title("toggleSpelling", model) == "Turn off spell checking")
        #expect(title("toggleGrammar", model) == "Turn off grammar checking")
        #expect(title("toggleAutocorrect", model) == "Turn off automatic spelling correction")

        settings.checksSpelling = false
        settings.checksGrammar = false
        settings.correctsSpelling = false
        #expect(title("toggleSpelling", model) == "Turn on spell checking")
        #expect(title("toggleGrammar", model) == "Turn on grammar checking")
        #expect(title("toggleAutocorrect", model) == "Turn on automatic spelling correction")
    }

    /// Grammar cannot be on without spelling, so the palette does not offer it
    /// while spelling is off.
    @Test("The grammar command is disabled while spelling is off")
    func grammarEnablement() {
        let settings = TypingSettings.shared
        let was = settings.checksSpelling
        defer { settings.checksSpelling = was }

        let model = model()
        defer { model.closeWorkspace() }

        settings.checksSpelling = true
        #expect(command("toggleGrammar")?.isEnabled(on: model) == true)
        settings.checksSpelling = false
        #expect(command("toggleGrammar")?.isEnabled(on: model) == false)
    }
}
