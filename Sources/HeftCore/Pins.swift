import Foundation

/// Things the reader pinned, in the order they pinned them: notes, folders,
/// tags and commands, listed first wherever they belong in the search bar.
///
/// Kept in the vault, in `.heft/pins.json` beside the proposals, so they
/// follow the vault to every Mac it syncs to. Not Obsidian's bookmarks:
/// those have no place for a command, and a file Obsidian also writes would
/// need merging. Obsidian ignores a folder starting with a dot, so the vault
/// still opens there unchanged.
///
/// The order is the order pinned and nothing else. A ranked order is what
/// Recent and Frequent already are; a pin is the reader's own choice, and
/// unpinning and pinning again moves one to the end.
public struct Pins: Equatable, Sendable {

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case note, folder, tag, command
    }

    public struct Pin: Codable, Hashable, Sendable {
        public var kind: Kind
        /// A vault-relative path for a note or a folder, a tag's name without
        /// its hash, or a command's id.
        public var value: String

        public init(_ kind: Kind, _ value: String) {
            self.kind = kind
            self.value = value
        }
    }

    public private(set) var items: [Pin]

    public init(_ items: [Pin] = []) {
        var seen = Set<Pin>()
        self.items = items.filter { seen.insert($0).inserted }
    }

    public func contains(_ pin: Pin) -> Bool { items.contains(pin) }

    public func values(of kind: Kind) -> [String] {
        items.filter { $0.kind == kind }.map(\.value)
    }

    /// Pins `pin` at the end, or unpins it if it was pinned. Returns whether
    /// it is pinned now.
    @discardableResult
    public mutating func toggle(_ pin: Pin) -> Bool {
        if let index = items.firstIndex(of: pin) {
            items.remove(at: index)
            return false
        }
        items.append(pin)
        return true
    }

    /// A note or folder moved: its pin follows it, keeping its place. A
    /// folder's move carries the pins of everything under it too.
    public mutating func move(_ kind: Kind, from oldValue: String, to newValue: String) {
        items = items.map { pin in
            guard pin.kind == kind || (kind == .folder && pin.kind == .note) else { return pin }
            if pin.kind == kind, pin.value == oldValue { return Pin(kind, newValue) }
            if kind == .folder, pin.value.hasPrefix(oldValue + "/") {
                return Pin(pin.kind, newValue + pin.value.dropFirst(oldValue.count))
            }
            return pin
        }
    }

    // MARK: - Storage

    public static func url(in vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(".heft", isDirectory: true)
            .appendingPathComponent("pins.json")
    }

    /// The vault's pins; none when there is no file yet or it cannot be read.
    /// A pin of a kind a later version added is dropped, not the whole file.
    public static func load(from vaultRoot: URL) -> Pins {
        guard let data = try? Data(contentsOf: url(in: vaultRoot)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return Pins() }
        return Pins(stored.pins.compactMap { raw in
            Kind(rawValue: raw.kind).map { Pin($0, raw.value) }
        })
    }

    /// Written whole and atomically, as the proposals are, so a reader on
    /// another Mac never sees half a file.
    public func save(to vaultRoot: URL) throws {
        let file = Self.url(in: vaultRoot)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let stored = Stored(pins: items.map { .init(kind: $0.kind.rawValue, value: $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: file, options: .atomic)
    }

    private struct Stored: Codable {
        struct Raw: Codable {
            var kind: String
            var value: String
        }
        var pins: [Raw]
    }
}
