import Foundation
import Testing
@testable import HeftiOSShared

/// What the iOS Today widget shows of the daily note.
@Suite("Today snapshot")
struct TodaySnapshotTests {

    /// `\r\n` is one Swift Character, so a split on `\n` found no lines and
    /// the widget showed the whole note, frontmatter and all.
    @Test("A CRLF note gives the same lines as an LF one")
    func crlfLines() {
        let unix = "---\ntags: daily\n---\n# 2026-10-20\n\n- [ ] call the roofer\n- buy nails\n"
        let windows = unix.replacingOccurrences(of: "\n", with: "\r\n")

        let lines = TodaySnapshot.lines(from: windows)

        #expect(lines == TodaySnapshot.lines(from: unix))
        #expect(lines.map(\.text) == ["call the roofer", "buy nails"])
        #expect(lines.first?.done == false)
    }
}
