import Foundation
import HeftCore
import Testing

/// The Mac's replacements, carried in the vault for iOS to type with.
@Suite("The replacements the vault carries")
struct SharedTypingSetupTests {
    private func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A custom rule and a switched-off group arrive as the Mac has them")
    func roundTrip() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = SharedTypingSetup(
            disabledGroups: [SmartTypographyGroup.arrows.rawValue],
            custom: [CustomSubstitution(trigger: ":sig", replacement: "Best, Sam")]
        )
        try setup.write(to: root)
        let read = try #require(SharedTypingSetup.read(from: root))
        #expect(read == setup)
        let rules = SmartTypography.rules(for: read.config)
        #expect(SmartTypography.substitution(in: "x :sig", caret: 6, rules: rules)?.replacement == "Best, Sam")
        #expect(SmartTypography.substitution(in: "a ->", caret: 4, rules: rules) == nil, "arrows were switched off")
    }

    @Test("Writing what is already there leaves the file alone")
    func unchangedIsNotRewritten() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = SharedTypingSetup(pairsMarkdown: false)
        try setup.write(to: root)
        let url = SharedTypingSetup.url(in: root)
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        try setup.write(to: root)
        let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(date == past)
    }

    @Test("The defaults make no file, since iOS assumes them")
    func defaultsWriteNothing() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        try SharedTypingSetup().write(to: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".heft").path))
    }

    @Test("An edit from another device is taken in; the Mac's own writing is not")
    func editsAreToldFromOwnWrites() {
        let mine = SharedTypingSetup(custom: [CustomSubstitution(trigger: "a", replacement: "b")])
        let edited = SharedTypingSetup(custom: [CustomSubstitution(trigger: "a", replacement: "c")])
        #expect(SharedTypingSetup.edit(inVault: edited, mine: mine, lastWritten: mine) == edited)
        #expect(SharedTypingSetup.edit(inVault: mine, mine: mine, lastWritten: mine) == nil)
        // The Mac changed its own since it last wrote: the vault is just behind.
        #expect(SharedTypingSetup.edit(inVault: mine, mine: edited, lastWritten: mine) == nil)
        #expect(SharedTypingSetup.edit(inVault: edited, mine: mine, lastWritten: nil) == nil)
    }
}
