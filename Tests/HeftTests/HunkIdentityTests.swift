import Foundation
import HeftCore
import Testing
@testable import Heft

/// A review card keeps its identity when another is decided, so the decided
/// one can leave and the rest move up instead of the list redrawing.
@Suite("Hunk identity")
struct HunkIdentityTests {

    @Test("Deciding the first hunk leaves the others' keys unchanged")
    func keysSurviveADecision() {
        let base = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\n"
        let proposed = base
            .replacingOccurrences(of: "two", with: "TWO")
            .replacingOccurrences(of: "eleven", with: "ELEVEN")
        let before = NoteDiff.between(original: base, proposed: proposed).hunks
        #expect(before.count == 2)
        let afterFirst = base.replacingOccurrences(of: "two", with: "TWO")
        let after = NoteDiff.between(original: afterFirst, proposed: proposed).hunks
        #expect(after.count == 1)

        let keysBefore = ProposalReviewSheet.keyed(before).map(\.key)
        let keysAfter = ProposalReviewSheet.keyed(after).map(\.key)
        #expect(keysAfter == [keysBefore[1]], "the hunk left behind is the one it was")
    }

    @Test("Two hunks making the same change are told apart")
    func twins() {
        let base = "a\nx\nb\nc\nd\ne\nf\ng\nh\ni\nx\nj\n"
        let proposed = base.replacingOccurrences(of: "x", with: "y")
        let keys = ProposalReviewSheet.keyed(NoteDiff.between(original: base, proposed: proposed).hunks).map(\.key)
        #expect(keys.count == 2)
        #expect(Set(keys).count == 2)
    }
}
