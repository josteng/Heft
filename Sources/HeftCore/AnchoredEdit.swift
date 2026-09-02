import Foundation

/// A find-and-replace an agent can propose without restating the whole note.
///
/// `propose` takes a complete body on purpose: a full body cannot fail to
/// apply, and the review is a diff either way. But on a long note that costs
/// the agent the entire text a second time just to change a paragraph, and
/// most of what it writes back is a transcription of what it read.
///
/// An anchored edit keeps the property that matters. It is resolved *here*,
/// against the note as it is now, and either produces a complete body or fails
/// loudly and immediately — so the agent learns straight away, rather than the
/// user discovering a half-applied patch at review time. What reaches the
/// proposal store is an ordinary full-body proposal.
public struct AnchoredEdit: Sendable, Equatable, Codable {
    public let old: String
    public let new: String

    public init(old: String, new: String) {
        self.old = old
        self.new = new
    }
}

public enum AnchoredEditError: LocalizedError, Equatable {
    case emptyAnchor(index: Int)
    case notFound(index: Int)
    case ambiguous(index: Int, count: Int)

    public var errorDescription: String? {
        switch self {
        case let .emptyAnchor(index):
            return "edit \(index + 1): \"old\" is empty, which matches nothing in particular"
        case let .notFound(index):
            return "edit \(index + 1): \"old\" does not appear in the note"
        case let .ambiguous(index, count):
            return "edit \(index + 1): \"old\" appears \(count) times; "
                + "include enough surrounding text to name one of them"
        }
    }
}

extension AnchoredEdit {
    /// Applies edits in order, each against the result of the last.
    ///
    /// Each anchor must match exactly once. Ambiguity is refused rather than
    /// resolved by taking the first: an agent that meant the other one would
    /// otherwise produce a plausible-looking proposal that changes the wrong
    /// paragraph, which is the failure this whole flow exists to prevent.
    public static func apply(_ edits: [AnchoredEdit], to text: String) throws -> String {
        var result = text
        for (index, edit) in edits.enumerated() {
            guard !edit.old.isEmpty else { throw AnchoredEditError.emptyAnchor(index: index) }
            let count = occurrences(of: edit.old, in: result)
            guard count > 0 else { throw AnchoredEditError.notFound(index: index) }
            guard count == 1 else {
                throw AnchoredEditError.ambiguous(index: index, count: count)
            }
            guard let range = result.range(of: edit.old) else {
                throw AnchoredEditError.notFound(index: index)
            }
            result.replaceSubrange(range, with: edit.new)
        }
        return result
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = found.lowerBound < found.upperBound
                ? found.upperBound
                : haystack.index(after: found.lowerBound)
            if searchStart >= haystack.endIndex { break }
        }
        return count
    }
}
