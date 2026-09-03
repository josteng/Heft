import AppKit
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// The rules as the pane presents them: a fixed set, each switched on or off,
/// in the reader's order.
@Suite("Attachment plan")
struct AttachmentPlanTests {

    private func context(
        noteFolder: String = "Notes",
        obsidian: String = "",
        learned: String? = nil,
        folders: Set<String> = []
    ) -> AttachmentRules.Context {
        AttachmentRules.Context(
            noteFolder: noteFolder, obsidianSetting: obsidian, learned: learned,
            folderExists: { folders.contains($0) }
        )
    }

    /// The bug that made the first pane unusable: two copies of one rule were
    /// indistinguishable, and the list scrambled its own numbering. A fixed set
    /// cannot have two of anything.
    @Test("Every rule appears exactly once, with a stable identity")
    func identitiesAreUniqueAndStable() {
        let ids = AttachmentPlan.standard.entries.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate rows: \(ids)")

        // Typing in a folder field must not change a row's identity, or the
        // row is rebuilt on every keystroke and takes the focus with it.
        var entry = AttachmentPlan.Entry(choice: .named, folder: "A")
        let before = entry.id
        entry.folder = "Something else entirely"
        #expect(entry.id == before)
    }

    @Test("Only switched-on rules are resolved, in the order shown")
    func orderAndEnablementDecide() {
        var plan = AttachmentPlan.standard
        let folders: Set<String> = ["Notes/Assets"]
        // Learned alone.
        #expect(plan.rules.destination(in: context(learned: "Learned")).folder == "Learned")

        // Switching on a named rule and putting it first overrules the habit.
        let named = plan.entries.firstIndex { $0.choice == .named }!
        plan.entries[named].isEnabled = true
        plan.entries[named].folder = "Assets"
        plan.entries.move(fromOffsets: IndexSet(integer: named), toOffset: 0)
        #expect(plan.rules.destination(
            in: context(learned: "Learned", folders: folders)
        ).folder == "Notes/Assets")

        // Switching it off again hands the answer back.
        plan.entries[0].isEnabled = false
        #expect(plan.rules.destination(
            in: context(learned: "Learned", folders: folders)
        ).folder == "Learned")
    }

    /// One vault spells the same idea three ways, which is the case that made a
    /// single configured name useless.
    @Test("A named rule takes several names, tried in order")
    func severalNames() {
        #expect(AttachmentPlan.folders(in: " Attachments , Attachemnts ,, Assets ")
            == ["Attachments", "Attachemnts", "Assets"])

        var plan = AttachmentPlan(entries: [
            .init(choice: .named, folder: "Attachments, Attachemnts", isEnabled: true)
        ])
        #expect(plan.rules.destination(
            in: context(folders: ["Notes/Attachemnts"])
        ).folder == "Notes/Attachemnts")

        plan.entries[0].folder = ""
        #expect(plan.rules.rules.isEmpty, "a name-less rule offers nothing")
    }

    /// A rule under one that cannot decline is dead, and the row says so.
    @Test("Rules under one that always answers are marked unreachable")
    func unreachableRules() {
        var plan = AttachmentPlan(entries: [
            .init(choice: .besideTheNote, isEnabled: true),
            .init(choice: .learned, isEnabled: true),
        ])
        #expect(plan.isReachable(0))
        #expect(!plan.isReachable(1))

        // Switched off, it blocks nothing.
        plan.entries[0].isEnabled = false
        #expect(plan.isReachable(1))

        // And a fixed folder only always answers once it names one.
        var fixed = AttachmentPlan(entries: [
            .init(choice: .fixed, folder: "", isEnabled: true),
            .init(choice: .learned, isEnabled: true),
        ])
        #expect(fixed.isReachable(1))
        fixed.entries[0].folder = "Media"
        #expect(!fixed.isReachable(1))
    }

    /// A settings file is a format, and one written before a rule existed still
    /// has to open — with the new rule switched off rather than missing.
    @Test("A plan written before a rule existed still opens")
    func olderPlansStillOpen() throws {
        let old = AttachmentPlan(entries: [.init(choice: .learned, isEnabled: true)])
        let data = try JSONEncoder().encode(old)
        let read = try JSONDecoder().decode(AttachmentPlan.self, from: data)

        #expect(read.entries.first?.choice == .learned, "what was set stays set, and first")
        #expect(read.entries.count == AttachmentPlan.standard.entries.count)
        #expect(read.entries.dropFirst().allSatisfy { !$0.isEnabled }, "the rest arrive off")
    }

    @Test("An empty or unreadable plan falls back to the standard one")
    func emptyPlanFallsBack() throws {
        let data = try #require("{}".data(using: .utf8))
        let read = try JSONDecoder().decode(AttachmentPlan.self, from: data)
        #expect(read == .standard)
    }
}

/// The wording, which is what makes the pane usable and what no rendering
/// technique can check.
@Suite("Attachment rule rows")
@MainActor
struct AttachmentRowTests {

    private func row(
        _ choice: AttachmentRules.Choice, obsidian: String = "", reachable: Bool = true
    ) -> AttachmentRuleRow {
        AttachmentRuleRow(
            entry: AttachmentPlan.Entry(choice: choice, folder: "Attachments", isEnabled: true),
            obsidianSetting: obsidian, isReachable: reachable,
            canMoveUp: true, canMoveDown: true, onChange: { _ in }, onMove: { _ in }
        )
    }

    @Test("Every rule says in words what it does")
    func everyRuleExplainsItself() {
        for entry in AttachmentPlan.standard.entries {
            #expect(
                row(entry.choice).explanationText.count > 30,
                "\(entry.id) needs an explanation, not a title alone"
            )
        }
    }

    @Test("A rule that can never run says that instead")
    func unreachableSaysSo() {
        #expect(row(.learned, reachable: false).explanationText.contains("Never used"))
    }

    @Test("Obsidian's row names the value it would follow, or says there is none")
    func obsidianRowNamesItsValue() {
        #expect(row(.obsidian, obsidian: "Files").explanationText.contains("Files"))
        #expect(row(.obsidian).explanationText.contains("none set"))
    }

    @Test("The rows draw")
    func rowsRender() throws {
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(AttachmentPlan.standard.entries) { entry in
                AttachmentRuleRow(
                    entry: entry, obsidianSetting: "", isReachable: true,
                    canMoveUp: true, canMoveDown: true, onChange: { _ in }, onMove: { _ in }
                )
            }
        }
        .padding(12)
        .frame(width: 580)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "ImageRenderer produced nothing")
        let data = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        var inked = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if pixel.alphaComponent > 0.1 && pixel.brightnessComponent < 0.75 { inked += 1 }
            }
        }
        #expect(inked > 50, "the rows look blank (\(inked) dark samples)")

        if let directory = ProcessInfo.processInfo.environment["HEFT_SNAPSHOT_DIR"] {
            try? rep.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("AttachmentRows.png")
            )
        }
    }
}
