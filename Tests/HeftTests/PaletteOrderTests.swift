import Foundation
import HeftCore
import Testing
@testable import Heft

/// What the palette shows first. Frecency answers "what does this reader
/// run", which is the right question until the answer cannot run today.
@MainActor
@Suite("Palette order")
struct PaletteOrderTests {

    /// A stand-in, so the rule can be checked without a window or a vault.
    private struct Row: Equatable {
        let name: String
        let enabled: Bool
    }

    private func order(_ rows: [Row]) -> [String] {
        AppCommand.sinkingDisabled(rows) { $0.enabled }.map(\.name)
    }

    @Test("A disabled command sinks below every enabled one")
    func disabledSinks() {
        let rows = [
            Row(name: "review", enabled: false),
            Row(name: "today", enabled: true),
            Row(name: "export", enabled: false),
            Row(name: "sidebar", enabled: true),
        ]
        #expect(order(rows) == ["today", "sidebar", "review", "export"])
    }

    @Test("Ranking survives inside each group")
    func rankingIsKept() {
        // What arrives is already in frecency order; the rule must not
        // reshuffle it, or the most-used enabled command stops being first.
        let rows = [
            Row(name: "most used", enabled: true),
            Row(name: "next", enabled: true),
            Row(name: "most used but off", enabled: false),
            Row(name: "next but off", enabled: false),
        ]
        #expect(order(rows) == ["most used", "next", "most used but off", "next but off"])
    }

    @Test("The first row is runnable whenever any row is")
    func firstRowRuns() {
        // The property Return depends on: it acts on the selection, which
        // starts at the top, so the top must not be a dead row.
        let rows = [
            Row(name: "off", enabled: false),
            Row(name: "on", enabled: true),
        ]
        #expect(order(rows).first == "on")
    }

    @Test("Nothing is dropped, so a disabled command stays findable")
    func nothingIsHidden() {
        let rows = [
            Row(name: "a", enabled: false),
            Row(name: "b", enabled: false),
            Row(name: "c", enabled: true),
        ]
        #expect(order(rows).count == rows.count)
        #expect(Set(order(rows)) == ["a", "b", "c"])
    }

    @Test("All disabled keeps every row, in order")
    func allDisabled() {
        let rows = [Row(name: "a", enabled: false), Row(name: "b", enabled: false)]
        #expect(order(rows) == ["a", "b"])
    }

    @Test("The palette asks the model whether a command can run")
    func paletteUsesTheRule() throws {
        // The registry itself must go through the rule, or the suite above
        // tests a function nothing calls.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Heft/Views/AppCommands.swift"),
            encoding: .utf8
        )
        #expect(source.contains("sinkingDisabled(ranked) { $0.isEnabled(on: model) }"))
    }
}
