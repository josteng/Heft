import Foundation

/// What the sidebar has just done to the vault, and how to put it back.
///
/// The editor has had undo since the first day, because `NSTextView` brings
/// its own. The tree had none: a note dragged into the wrong folder, or
/// trashed by a keystroke aimed at the wrong row, could only be put back by
/// hand, and the reader had to work out where it came from. That asymmetry is
/// what this closes.
///
/// Deliberately not `NSUndoManager`. The editor's manager belongs to the text
/// view and is emptied whenever a different note is opened, which is exactly
/// what a file operation must survive: moving a note usually opens something
/// else. A small stack of our own also keeps the two out of each other's way,
/// so ⌘Z in the text never undoes a move and ⌘Z in the tree never rewrites a
/// sentence.
enum UndoRouting {
    /// Who ⌘Z belongs to at this moment.
    ///
    /// One item in the menu owns the key and asks this, rather than two items
    /// both claiming ⌘Z. A *disabled* menu item swallows its own key
    /// equivalent, so a second Undo that was usually disabled took the key
    /// away from the editor's own and undoing text stopped working
    /// altogether. One owner, one decision, no state where the key does
    /// nothing.
    enum Target: Equatable { case sidebar, text }

    /// The tree wins only when it is what the keys are pointed at *and* it
    /// has something to put back. Everything else, including a tree with a
    /// step but the caret in a note, belongs to the text.
    static func target(sidebarOwnsKeys: Bool, sidebarHasStep: Bool) -> Target {
        sidebarOwnsKeys && sidebarHasStep ? .sidebar : .text
    }
}

struct SidebarUndo: Equatable {

    /// One reversible thing that happened. Every case carries where the files
    /// ended up, because that is what has to be found again to reverse it.
    enum Step: Equatable {
        /// Files moved from one folder to another, listed as they ended up.
        /// `origins` are the paths they came from, in the same order.
        case moved(to: [String], from: [String])
        /// A file renamed, in the same folder or another.
        case renamed(to: String, from: String)
        /// Files copied in, which are undone by removing the copies.
        case pasted([String])
        /// Files trashed, paired with where the Trash put them, which is what
        /// makes a restore possible at all.
        case trashed([(original: String, inTrash: URL)])

        static func == (lhs: Step, rhs: Step) -> Bool {
            switch (lhs, rhs) {
            case (.moved(let a, let b), .moved(let c, let d)): (a, b) == (c, d)
            case (.renamed(let a, let b), .renamed(let c, let d)): (a, b) == (c, d)
            case (.pasted(let a), .pasted(let b)): a == b
            case (.trashed(let a), .trashed(let b)):
                a.map(\.original) == b.map(\.original) && a.map(\.inTrash) == b.map(\.inTrash)
            default: false
            }
        }

        /// What the reader is offered, as the menu item's own words.
        var name: String {
            switch self {
            case .moved(let to, _): to.count == 1 ? "Move" : "Move of \(to.count) Items"
            case .renamed: "Rename"
            case .pasted(let paths): paths.count == 1 ? "Paste" : "Paste of \(paths.count) Items"
            case .trashed(let items):
                items.count == 1 ? "Move to Trash" : "Move of \(items.count) Items to Trash"
            }
        }
    }

    /// Only the last operation. A deeper stack would have to answer what
    /// happens when a step's files have since been changed by hand or by an
    /// agent, and the honest answer is that it cannot know; one step back is
    /// the depth a reader is actually holding in their head after a mis-drag.
    private(set) var step: Step?

    /// What ⌘Z would put back, or nil when there is nothing to undo.
    var name: String? { step?.name }

    mutating func record(_ step: Step) { self.step = step }

    /// Takes the step, leaving nothing behind: undoing twice must not undo
    /// the same move twice, which on a move that went somewhere since would
    /// put a file back that is no longer there.
    mutating func take() -> Step? {
        defer { step = nil }
        return step
    }

    mutating func clear() { step = nil }
}
