import AppKit
import SwiftUI

/// Non-activating completion menu anchored to the editor's insertion point.
/// It stays a child of the text view so typing never leaves the document and
/// the menu naturally follows its line while scrolling. What it draws is
/// `WikiCompletionList`; this view only places it and routes clicks.
final class WikiCompletionPanel: NSView {
    var onPick: ((Int) -> Void)?

    private let host: CompletionHostingView
    /// The menu as drawn, in this view's coordinates. The frame is taller.
    private(set) var listRect: NSRect = .zero
    /// The most rows shown since the menu opened. The frame keeps that height
    /// so a shrinking list animates inside it instead of being cut off.
    private var capacity = 0

    override init(frame frameRect: NSRect) {
        host = CompletionHostingView(rootView: Self.list(
            rows: [], selected: 0, visibleRows: 0, growsUp: false, pick: { _ in }
        ))
        super.init(frame: frameRect)
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    /// Only the menu takes clicks; the rest of the frame is the note.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard listRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    func show(
        items: [WikiCompletionItem], selected: Int,
        below anchor: NSRect, in textView: NSTextView
    ) {
        let width = WikiCompletionMetrics.width
        let visible = Self.unobscured(textView).insetBy(dx: 6, dy: 6)
        let gap: CGFloat = 5
        let below = visible.maxY - (anchor.maxY + gap)
        let above = (anchor.minY - gap) - visible.minY
        // Below unless it only fits above, or neither and above has more
        // room; then as many rows as that side holds, and the rest scroll.
        let full = WikiCompletionMetrics.height(rows: items.count)
        let growsUp = full > below && above > below
        let room = growsUp ? above : below
        let shown = max(1, min(items.count, WikiCompletionMetrics.rows(fitting: room)))
        let height = WikiCompletionMetrics.height(rows: shown)

        var x = anchor.minX
        var y = growsUp ? anchor.minY - gap - height : anchor.maxY + gap
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - width))
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - height))

        capacity = max(capacity, shown)
        let frameHeight = WikiCompletionMetrics.height(rows: capacity)
        frame = NSRect(x: x, y: growsUp ? y + height - frameHeight : y, width: width, height: frameHeight)
        listRect = NSRect(x: 0, y: growsUp ? frameHeight - height : 0, width: width, height: height)

        host.rootView = Self.list(
            rows: WikiCompletionList.rows(for: items), selected: selected, visibleRows: shown,
            growsUp: growsUp, pick: { [weak self] index in self?.onPick?(index) }
        )
        needsLayout = true
    }

    /// What the reader can actually see of the note. The note scrolls on
    /// under the toolbar, so the visible rect runs under it too, by as much as
    /// the clip view's insets say: measured from the clip view, because at
    /// the top of the note that strip is above the text view and already cut.
    private static func unobscured(_ textView: NSTextView) -> NSRect {
        guard let clip = textView.enclosingScrollView?.contentView, clip.isFlipped else {
            return textView.visibleRect
        }
        let insets = clip.contentInsets
        var rect = clip.bounds
        rect.origin.y += insets.top
        rect.size.height = max(0, rect.height - insets.top - insets.bottom)
        return textView.convert(rect, from: clip).intersection(textView.visibleRect)
    }

    func dismiss() {
        capacity = 0
        listRect = .zero
        host.rootView = Self.list(rows: [], selected: 0, visibleRows: 0, growsUp: false, pick: { _ in })
    }

    private static func list(
        rows: [WikiCompletionList.Row], selected: Int, visibleRows: Int, growsUp: Bool,
        pick: @escaping (Int) -> Void
    ) -> WikiCompletionList {
        // Read straight from the settings: `.tint()` does not reach a view
        // painting its own highlight, and the list is rebuilt on every show,
        // so a changed accent is picked up without observing anything.
        WikiCompletionList(
            rows: rows, selected: selected, visibleRows: visibleRows, growsUp: growsUp,
            accent: Color(nsColor: AppearanceSettings.shared.accentColor), pick: pick
        )
    }
}

/// Clicking a row must leave the caret in the note.
private final class CompletionHostingView: NSHostingView<WikiCompletionList> {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}
