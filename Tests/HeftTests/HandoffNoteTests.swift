import Foundation
import Testing
@testable import HeftCore

@Suite("Handoff payload")
struct HandoffNoteTests {

    @Test("A note survives the trip")
    func roundTrip() {
        let sent = HandoffNote(path: "Projects/Plan.md", vault: "Notebook")
        #expect(HandoffNote(userInfo: sent.userInfo) == sent)
    }

    @Test("Paths that leave the vault, or are not notes, are refused")
    func refused() {
        for path in ["../Plan.md", "Projects/../../Plan.md", "/etc/Plan.md", "Projects//Plan.md",
                     "./Plan.md", "Projects/Plan.txt", ""] {
            #expect(HandoffNote(userInfo: ["path": path, "vault": "Notebook"]) == nil, "\(path)")
        }
        #expect(HandoffNote(userInfo: nil) == nil)
    }
}
