import Foundation
import HeftCore
import Testing

/// What Heft opens when it starts.
@Suite("Startup note")
struct StartupNoteTests {

    private let day = Date(timeIntervalSince1970: 1_772_496_000)  // 2026-03-03

    private func resolve(
        _ setting: StartupNote, daily: String? = "Daily Notes/2026-03-03.md",
        last: String? = "Inbox.md"
    ) -> String? {
        setting.relativePath(on: day, dailyPath: { _ in daily }, lastNote: { last })
    }

    /// The default has to be "leave it alone", or installing an update would
    /// change where everybody's editor opens.
    @Test("Nothing is the default, and opens nothing")
    func defaultOpensNothing() {
        #expect(StartupNote.standard.choice == .nothing)
        #expect(resolve(.standard) == nil)
    }

    /// Not the same as leaving it alone: that relies on the window being
    /// restored, and a cold start where it is not comes up empty.
    @Test("The last note is a choice of its own")
    func lastNoteIsItsOwnChoice() {
        #expect(resolve(StartupNote(choice: .lastNote)) == "Inbox.md")
        #expect(resolve(StartupNote(choice: .lastNote), last: nil) == nil)
    }

    @Test("The daily note comes from the vault's own settings")
    func dailyNote() {
        #expect(resolve(StartupNote(choice: .dailyNote)) == "Daily Notes/2026-03-03.md")
        // A vault with no daily notes configured has no answer to give.
        #expect(resolve(StartupNote(choice: .dailyNote), daily: nil) == nil)
    }

    @Test("A named note is taken as written, tidied")
    func namedNote() {
        #expect(resolve(StartupNote(choice: .note, text: "Inbox.md")) == "Inbox.md")
        // `/Folder/Note` and `Folder/Note.md` name the same thing.
        #expect(resolve(StartupNote(choice: .note, text: "/Folder/Note")) == "Folder/Note.md")
        #expect(resolve(StartupNote(choice: .note, text: "  ")) == nil)
    }

    /// The same tokens a daily-note template uses, so a weekly or monthly note
    /// is expressible without the daily-note settings having to describe it.
    @Test("A pattern is worked out from the date")
    func pattern() {
        #expect(
            resolve(StartupNote(choice: .pattern, text: "Journal/{{date:YYYY}}/{{date:YYYY-MM}}.md"))
                == "Journal/2026/2026-03.md"
        )
        // moment tokens, not ICU: `GGGG-[W]WW` is the ISO week.
        #expect(
            resolve(StartupNote(choice: .pattern, text: "Weeks/{{date:GGGG-[W]WW}}"))
                == "Weeks/2026-W10.md"
        )
    }

    /// A settings file is a format, and one written before a field existed
    /// still has to open.
    @Test("A half-written setting decodes to the default")
    func decodingIsForgiving() throws {
        let data = try #require("{}".data(using: .utf8))
        let read = try JSONDecoder().decode(StartupNote.self, from: data)
        #expect(read == .standard)

        let round = StartupNote(choice: .pattern, text: "Weeks/{{date:GGGG}}.md")
        let encoded = try JSONEncoder().encode(round)
        #expect(try JSONDecoder().decode(StartupNote.self, from: encoded) == round)
    }
}
