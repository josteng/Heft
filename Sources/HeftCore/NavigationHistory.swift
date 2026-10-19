import Foundation

/// Where a window has been, for Back and Forward: a browser's history.
///
/// Visiting the place already current records nothing, so going back, which
/// moves the history first and then shows the place, is not recorded again
/// when the window reports what it now shows.
public struct NavigationHistory<Place: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var places: [Place] = []
    public private(set) var index = -1
    /// How many places are kept; the oldest go first.
    public let limit: Int

    public init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    public var current: Place? { places.indices.contains(index) ? places[index] : nil }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < places.count - 1 }

    /// A place shown: after the current one, dropping what was ahead of it.
    public mutating func visit(_ place: Place) {
        guard place != current else { return }
        places.removeSubrange((index + 1)...)
        places.append(place)
        if places.count > limit { places.removeFirst(places.count - limit) }
        index = places.count - 1
    }

    /// The place before the current one, passing over any that can no
    /// longer be shown, such as a note since deleted. Nil, and nothing
    /// moved, when there is none.
    public mutating func back(skipping unusable: (Place) -> Bool = { _ in false }) -> Place? {
        step(by: -1, skipping: unusable)
    }

    public mutating func forward(skipping unusable: (Place) -> Bool = { _ in false }) -> Place? {
        step(by: 1, skipping: unusable)
    }

    private mutating func step(by direction: Int, skipping unusable: (Place) -> Bool) -> Place? {
        var next = index + direction
        while places.indices.contains(next) {
            if !unusable(places[next]) {
                index = next
                return places[next]
            }
            next += direction
        }
        return nil
    }
}
