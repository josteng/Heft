import Foundation
import Testing
@testable import HeftCore

/// Where the iOS editor puts a picture or a file it was handed.
@Suite("An attachment on a line of its own")
struct OwnLineAttachmentTests {

    @Test("An attachment goes on a line of its own without splitting a Windows break")
    func attachmentLine() {
        let note = "one\r\ntwo\r\n"
        // A caret inside `one` puts the embed after that line.
        let inside = MarkdownEditing.onOwnLine("![[a.png]]", at: NSRange(location: 1, length: 0), in: note)
        #expect(inside.applied(to: note) == "one\r\n![[a.png]]\r\ntwo\r\n")
        #expect(inside.selection == NSRange(location: 15, length: 0))
        // At the start of a line, before it.
        let start = MarkdownEditing.onOwnLine("![[a.png]]", at: NSRange(location: 5, length: 0), in: note)
        #expect(start.applied(to: note) == "one\r\n![[a.png]]\r\ntwo\r\n")
        // A Unix note is as it was.
        let unix = MarkdownEditing.onOwnLine("![[a.png]]", at: NSRange(location: 1, length: 0), in: "one\ntwo")
        #expect(unix.applied(to: "one\ntwo") == "one\n![[a.png]]\ntwo")
        let end = MarkdownEditing.onOwnLine("![[a.png]]", at: NSRange(location: 3, length: 0), in: "one")
        #expect(end.applied(to: "one") == "one\n![[a.png]]\n")
    }

}
