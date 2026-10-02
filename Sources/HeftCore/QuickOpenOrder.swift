import Foundation

/// How Quick Open orders its list while nothing is typed: a short block of
/// one kind first, then every other note ordered the other way.
///
/// Frecency alone was slow to admit a new note: one opened once today scored
/// below one opened ten times last week, so the note just made was the one
/// the switcher could not find. Obsidian answers with recency alone, which
/// loses the notes opened every morning. A short block of one above the rest
/// in the other keeps both, and the block is the reader's to size or turn
/// off, because how many recent notes are worth a row is a matter of habit.
/// Typed queries are untouched: match quality ranks them, as before.
public struct QuickOpenOrder: Equatable, Sendable {

    public enum Lead: String, CaseIterable, Identifiable, Sendable {
        /// Last opened first; the rest by frecency.
        case recent
        /// Most used first; the rest by when they were last opened.
        case frequent

        public var id: String { rawValue }

        /// The order the rest of the list follows when this one leads.
        public var other: Lead { self == .recent ? .frequent : .recent }

        public var title: String {
            switch self {
            case .recent: "Recent"
            case .frequent: "Frequent"
            }
        }
    }

    public var lead: Lead
    /// How many notes the leading block holds. Zero leaves only the second
    /// order, without headings.
    public var count: Int

    public static let countRange = 0...20
    public static let standard = QuickOpenOrder(lead: .recent, count: 5)

    public init(lead: Lead, count: Int) {
        self.lead = lead
        self.count = count.clamped(to: Self.countRange)
    }

    /// The list, split where the headings go.
    public struct Arranged: Equatable, Sendable {
        public var lead: [NoteRef]
        public var rest: [NoteRef]
        /// Which order leads. Nil when there is nothing to tell apart: an
        /// empty leading block, or nothing after it.
        public var heading: Lead?

        public var all: [NoteRef] { lead + rest }

        /// Named after the order it follows, since that is what a reader
        /// would choose it for; "Other Notes" said nothing about why a note
        /// sat where it did.
        public var restHeading: Lead? { heading?.other }

        public init(lead: [NoteRef], rest: [NoteRef], heading: Lead?) {
            self.lead = lead
            self.rest = rest
            self.heading = heading
        }

        /// What the list draws, headings included. A heading is a row the
        /// arrows reach like any other, so choosing one is the same gesture
        /// as choosing a note.
        public var rows: [Row] {
            guard let heading else { return all.map(Row.note) }
            var rows = [Row.heading(heading)] + lead.map(Row.note)
            if let restHeading, !rest.isEmpty {
                rows += [.heading(restHeading)] + rest.map(Row.note)
            }
            return rows
        }

        /// Where the selection starts: on the first note, not on a heading,
        /// so Return straight away still opens the note at the top.
        public var firstNoteRow: Int {
            rows.firstIndex { if case .note = $0 { true } else { false } } ?? 0
        }
    }

    public enum Row: Hashable, Sendable {
        case heading(Lead)
        case note(NoteRef)
    }

    /// One order on its own and in full, for a heading chosen in the list:
    /// every note in the opening history, or every note with any use.
    public static func section(
        _ kind: Lead, of byUse: [NoteRef], recent: [String], limit: Int,
        isUsed: (NoteRef) -> Bool
    ) -> [NoteRef] {
        switch kind {
        case .recent:
            let byPath = Dictionary(byUse.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
            return Array(recent.lazy.compactMap { byPath[$0] }.prefix(limit))
        case .frequent:
            return Array(byUse.lazy.filter(isUsed).prefix(limit))
        }
    }

    /// Orders the notes for an empty query.
    ///
    /// - Parameters:
    ///   - byUse: every note that may be listed, most used first, with
    ///     unused notes after in a stable order. What `VaultIndex.search`
    ///     returns for an empty query.
    ///   - recent: vault-relative paths, last opened first. Paths that are
    ///     not in `byUse` are skipped, which is how scope and deleted notes
    ///     are honoured without a second filter.
    ///   - isUsed: whether a note has any use recorded, so a "Frequent"
    ///     block never pads itself with notes merely first alphabetically.
    public func arrange(
        _ byUse: [NoteRef], recent: [String], limit: Int,
        isUsed: (NoteRef) -> Bool
    ) -> Arranged {
        let byRecency = Self.section(
            .recent, of: byUse, recent: recent, limit: .max, isUsed: isUsed
        )

        let lead: [NoteRef]
        var rest: [NoteRef]
        switch self.lead {
        case .recent:
            lead = Array(byRecency.prefix(count))
            rest = byUse
        case .frequent:
            lead = Self.section(.frequent, of: byUse, recent: recent, limit: count, isUsed: isUsed)
            // Opened notes by when, then the rest in the order they came.
            let opened = Set(byRecency.map(\.relativePath))
            rest = byRecency + byUse.filter { !opened.contains($0.relativePath) }
        }
        let taken = Set(lead.map(\.relativePath))
        rest.removeAll { taken.contains($0.relativePath) }

        let room = max(limit - lead.count, 0)
        let trimmedLead = Array(lead.prefix(limit))
        rest = Array(rest.prefix(room))
        return Arranged(
            lead: trimmedLead, rest: rest,
            heading: trimmedLead.isEmpty || rest.isEmpty ? nil : self.lead
        )
    }

    // MARK: - Storage

    public static let leadKey = "dev.stenglein.Heft.quickOpen.lead"
    public static let countKey = "dev.stenglein.Heft.quickOpen.count"

    public static var current: QuickOpenOrder { current(in: HeftDefaults.shared) }

    public static func current(in defaults: UserDefaults) -> QuickOpenOrder {
        QuickOpenOrder(
            lead: defaults.string(forKey: leadKey).flatMap(Lead.init(rawValue:)) ?? standard.lead,
            count: defaults.object(forKey: countKey) == nil
                ? standard.count : defaults.integer(forKey: countKey)
        )
    }

    public func save(in defaults: UserDefaults) {
        defaults.set(lead.rawValue, forKey: Self.leadKey)
        defaults.set(count, forKey: Self.countKey)
    }
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
