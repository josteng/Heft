import Foundation
import HeftCore

/// Which rows the sidebar has selected, and what a click does to that.
///
/// A value rather than a handful of `@State` flags, because the interesting
/// part is not the set but the three clicks that change it, and each of them
/// has an edge the tree cannot show: a shift-click with nothing to measure
/// from, a command-click that empties the selection, a range whose ends
/// arrived in the opposite order to the rows on screen.
///
/// The order lives outside, in `visible`, which is the tree flattened the way
/// it is drawn. That is what a range means here: everything between two rows
/// *as displayed*, so a collapsed folder's hidden children are not swept up
/// by a shift-click across it.
struct SidebarSelection: Equatable {

    /// What a click means, once the modifiers have been read.
    enum Click: Equatable {
        /// No modifier. Replaces the selection with this row.
        case plain
        /// Command. Adds this row, or removes it if it was already in.
        case toggle
        /// Shift. Everything from the anchor to this row.
        case extend
    }

    private(set) var paths: Set<String> = []

    /// Which of `paths` are folders. Carried rather than looked up, because
    /// the only thing that needs it is a highlight decision taken once per
    /// row per redraw, and answering it from the tree there would flatten the
    /// whole vault on every one of them.
    private(set) var folders: Set<String> = []

    /// The row a shift-click measures from: the last one clicked without
    /// shift. Kept separately from the selection, because extending twice
    /// must both times measure from where the reader started rather than
    /// from wherever the previous extension happened to end.
    private(set) var anchor: String?

    init() {}

    init(paths: Set<String>, anchor: String? = nil, folders: Set<String> = []) {
        self.paths = paths
        self.anchor = anchor
        self.folders = folders.intersection(paths)
    }

    var isEmpty: Bool { paths.isEmpty }

    /// Whether the reader has picked out a file, as opposed to only folders.
    ///
    /// The two mean different things to the open note's highlight: picking
    /// files out is choosing what to act on and the open note must get out of
    /// the way, but clicking a folder is navigation, and losing track of which
    /// note is open every time one is opened was the bug that put this here.
    var holdsFile: Bool { paths.count > folders.count }
    var count: Int { paths.count }
    func contains(_ path: String) -> Bool { paths.contains(path) }

    /// Applies a click on `path`, with the rows as they are drawn.
    mutating func click(
        _ path: String, _ click: Click, visible: [String], folders visibleFolders: Set<String> = []
    ) {
        defer { folders.formIntersection(paths) }
        switch click {
        case .plain:
            // A plain click on a folder is navigation: it opens or closes the
            // folder, and nothing is being chosen to act on, so no row is
            // selected and none lights up. The anchor still moves, or a
            // shift-click starting from a folder would have nothing to
            // measure from.
            paths = visibleFolders.contains(path) ? [] : [path]
            folders = []
            anchor = path
        case .toggle:
            if paths.contains(path) {
                paths.remove(path)
                // The anchor still moves to what was clicked, even though the
                // click removed it: a shift-click afterwards measures from the
                // row the reader last touched, which is this one.
                anchor = path
            } else {
                paths.insert(path)
                if visibleFolders.contains(path) { folders.insert(path) }
                anchor = path
            }
        case .extend:
            // With nothing to measure from, shift is a plain click. That
            // happens on the first click into a fresh window, and treating
            // it as a no-op would look like the sidebar had ignored it.
            guard let anchor, let range = Self.range(from: anchor, to: path, in: visible) else {
                paths = [path]
                folders = visibleFolders.contains(path) ? [path] : []
                self.anchor = path
                return
            }
            paths = Set(range)
            folders = paths.intersection(visibleFolders)
        }
    }

    /// The rows between two paths inclusive, in drawn order, or nil when
    /// either end is not on screen.
    static func range(from: String, to: String, in visible: [String]) -> [String]? {
        guard let start = visible.firstIndex(of: from),
              let end = visible.firstIndex(of: to) else { return nil }
        let bounds = start <= end ? start...end : end...start
        return Array(visible[bounds])
    }

    /// Forgets rows that are no longer there.
    ///
    /// Called after anything that changes the tree. Without it a deleted row
    /// stayed in the set, so the next Command-Delete asked about files that
    /// were already in the Trash, and the count in the question was wrong.
    mutating func prune(to visible: some Sequence<String>) {
        let present = Set(visible)
        paths.formIntersection(present)
        folders.formIntersection(paths)
        if let anchor, !present.contains(anchor) { self.anchor = nil }
    }

    /// Drops anything already inside another selected folder.
    ///
    /// Trashing a folder takes its contents with it, so asking the
    /// filesystem for the child afterwards fails on a file that is no
    /// longer there, and counting both in the question tells the reader
    /// they are about to delete more things than exist.
    static func outermost(_ paths: some Sequence<String>) -> [String] {
        // Against every ancestor kept so far, not just the previous one: a
        // sibling can sort between a folder and its own child, because a
        // space sorts before a slash, so "Notes archive" lands between
        // "Notes" and "Notes/A.md" and the child looked like a top-level row.
        let all = Array(paths).sorted()
        var kept: [String] = []
        for path in all where !kept.contains(where: { path.hasPrefix($0 + "/") }) {
            kept.append(path)
        }
        return kept
    }

    /// Whether a menu or a keystroke on `path` should act on the whole
    /// selection or on that row alone.
    ///
    /// Right-clicking a row *inside* the selection acts on all of it, which
    /// is what every file manager does. Right-clicking outside it acts on
    /// that row, because the reader is pointing at something else and a menu
    /// that quietly acted on the old selection would delete the wrong files.
    func target(clicking path: String) -> [String] {
        paths.contains(path) ? Array(paths) : [path]
    }
}

extension SidebarSelection {

    /// What a click means, from the modifiers held at the time.
    ///
    /// Shift outranks command, so command-shift extends rather than toggling.
    /// Two behaviours rather than the Finder's three: extending *and* adding
    /// is a distinction almost nobody reaches for, and guessing it wrong is
    /// worse than not having it.
    static func click(command: Bool, shift: Bool) -> Click {
        if shift { return .extend }
        if command { return .toggle }
        return .plain
    }

    /// The rows the tree actually draws, top to bottom.
    ///
    /// A range means everything between two rows *as displayed*, so the
    /// children of a collapsed folder must not appear: shift-clicking across
    /// a closed folder selects the folder, not the twelve notes inside it
    /// that nobody can see and nobody meant to delete.
    static func visibleOrder(of children: [VaultItem], expanded: Set<String>) -> [String] {
        var order: [String] = []
        for child in children {
            order.append(child.relativePath)
            if child.isFolder, expanded.contains(child.relativePath) {
                order.append(contentsOf: visibleOrder(of: child.children, expanded: expanded))
            }
        }
        return order
    }

    /// The drawn rows that are folders, walked the same way as `visibleOrder`.
    /// Only the rows a click can reach are in it, which is all a click needs.
    static func visibleFolders(of children: [VaultItem], expanded: Set<String>) -> Set<String> {
        var found: Set<String> = []
        for child in children where child.isFolder {
            found.insert(child.relativePath)
            guard expanded.contains(child.relativePath) else { continue }
            found.formUnion(visibleFolders(of: child.children, expanded: expanded))
        }
        return found
    }
}
