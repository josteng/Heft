import HeftCore
import Testing

/// A hunk's header says what accepting it does, in words that agree with the
/// count: one line, two lines, never "line(s)".
@Suite("Hunk headers")
struct HunkLabelTests {
    private func hunk(removed: [String], added: [String], at line: Int = 10) -> NoteDiff.Hunk {
        NoteDiff.Hunk(id: 1, originalRange: line..<(line + removed.count), removed: removed, added: added)
    }

    @Test("Counts agree with their noun")
    func countsAgree() {
        #expect(hunk(removed: [], added: ["a"]).reviewLabel == "Insert 1 line at line 11")
        #expect(hunk(removed: [], added: ["a", "b"]).reviewLabel == "Insert 2 lines at line 11")
        #expect(hunk(removed: ["a"], added: []).reviewLabel == "Delete 1 line at line 11")
        #expect(hunk(removed: ["a", "b", "c"], added: []).reviewLabel == "Delete 3 lines at line 11")
    }

    @Test("A replacement names both counts only when they differ")
    func replacementCounts() {
        #expect(hunk(removed: ["a"], added: ["b"]).reviewLabel == "Replace 1 line at line 11")
        #expect(hunk(removed: ["a", "b"], added: ["c", "d"]).reviewLabel == "Replace 2 lines at line 11")
        #expect(hunk(removed: ["a"], added: ["b", "c"]).reviewLabel == "Replace 1 line with 2 at line 11")
        #expect(hunk(removed: ["a", "b"], added: ["c"]).reviewLabel == "Replace 2 lines with 1 at line 11")
    }

    @Test("A conflict says which side the lines are on")
    func conflictWording() {
        #expect(hunk(removed: [], added: ["a", "b"]).conflictLabel == "Disk adds 2 lines at line 11")
        #expect(hunk(removed: ["a"], added: []).conflictLabel == "Disk drops 1 line at line 11")
        #expect(hunk(removed: ["a"], added: ["b", "c"]).conflictLabel == "Line 11: 1 of yours, 2 on disk")
    }
}
