import Foundation
import Testing
@testable import Heft

/// Vim mode is off until someone turns it on, and the command palette is one
/// of the two places to do that. The command reads as what it will do, and
/// doing it flips the app-wide setting.
@MainActor
@Suite("The Vim palette command", .serialized)
struct VimToggleCommandTests {
    @Test("The palette offers Vim mode, worded for the current state, and toggles it")
    func togglesVimMode() throws {
        let command = try #require(AppCommand.registry.first { $0.id == "toggleVim" })
        #expect(command.matches("vim"))
        #expect(command.matches("modal"))

        let vim = VimSettings.shared
        let before = vim.isEnabled
        defer { vim.isEnabled = before }
        let model = AppModel(registry: VaultRegistry(), descriptor: nil)
        defer { model.closeWorkspace() }

        vim.isEnabled = false
        #expect(command.title(on: model) == "Turn on Vim mode")
        command.perform(on: model)
        #expect(vim.isEnabled)
        #expect(command.title(on: model) == "Turn off Vim mode")
        command.perform(on: model)
        #expect(!vim.isEnabled)
    }
}
