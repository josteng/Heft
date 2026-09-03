import AppKit
import HeftCore

/// One row of a completion menu.
///
/// Deliberately not "a note": the same panel now offers callout kinds, and
/// carrying a `NoteRef` meant the panel could only ever answer one kind of
/// question. Title, detail and symbol are what a row actually draws.
struct WikiCompletionItem {
    let title: String
    let detail: String
    let symbol: String
    /// What accepting this row writes.
    let destination: String

    init(title: String, detail: String, symbol: String, destination: String) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.destination = destination
    }

    init(ref: NoteRef, destination: String) {
        title = ref.name
        detail = ref.folder
        symbol = switch ref.kind {
        case .markdown: "doc.text"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .canvas: "square.on.square.dashed"
        default: "doc"
        }
        self.destination = destination
    }

    init(callout: CalloutSuggestion) {
        title = callout.kind.rawValue
        // The spelling that was typed, when it was not the canonical name, so
        // it is clear why `tldr` offered `abstract`.
        detail = callout.matchedAlias ?? ""
        symbol = callout.kind.symbol
        destination = callout.insertion
    }
}

/// Non-activating completion menu anchored to the editor's insertion point.
/// It stays a child of the text view so typing never leaves the document and
/// the menu naturally follows its line while scrolling.
final class WikiCompletionPanel: NSView {
    var onPick: ((Int) -> Void)?

    private let background = NSVisualEffectView()
    private var rows: [WikiCompletionRow] = []
    private static let width: CGFloat = 390
    private static let rowHeight: CGFloat = 34
    private static let padding: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        wantsLayer = true

        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.layer?.masksToBounds = true
        addSubview(background)

        shadow = {
            let value = NSShadow()
            value.shadowColor = NSColor.black.withAlphaComponent(0.3)
            value.shadowBlurRadius = 12
            value.shadowOffset = NSSize(width: 0, height: -3)
            return value
        }()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        background.frame = bounds
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(
                x: Self.padding,
                y: Self.padding + CGFloat(index) * Self.rowHeight,
                width: bounds.width - Self.padding * 2,
                height: Self.rowHeight
            )
        }
    }

    func show(
        items: [WikiCompletionItem], selected: Int,
        below anchor: NSRect, in textView: NSTextView
    ) {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { index, item in
            let row = WikiCompletionRow(item: item, selected: index == selected)
            row.onPick = { [weak self] in self?.onPick?(index) }
            addSubview(row)
            return row
        }

        let height = Self.padding * 2 + CGFloat(items.count) * Self.rowHeight
        let visible = textView.visibleRect.insetBy(dx: 6, dy: 6)
        var x = anchor.minX
        var y = anchor.maxY + 5
        if y + height > visible.maxY { y = anchor.minY - height - 5 }
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - Self.width))
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - height))
        frame = NSRect(x: x, y: y, width: Self.width, height: height)
        needsLayout = true
        isHidden = false
    }

    func dismiss() {
        isHidden = true
        rows.forEach { $0.removeFromSuperview() }
        rows = []
    }
}

final class WikiCompletionRow: NSView {
    var onPick: (() -> Void)?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let selected: Bool

    init(item: WikiCompletionItem, selected: Bool) {
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        // Read straight from the settings rather than tinted by the
        // environment: this row is AppKit, so the scene's `appAccentTint` does
        // not reach it. The panel is rebuilt each time it opens, so it picks
        // up a changed accent without needing to observe anything.
        layer?.backgroundColor = selected
            ? AppearanceSettings.shared.accentColor.cgColor
            : nil

        icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        icon.contentTintColor = selected ? .white : .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        title.stringValue = item.title
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = selected ? .white : .labelColor
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)

        detail.stringValue = item.detail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = selected ? NSColor.white.withAlphaComponent(0.72) : .tertiaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingHead
        addSubview(detail)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.detail.isEmpty
            ? item.title
            : "\(item.title), \(item.detail)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 9, y: 9, width: 16, height: 16)
        // Measured through the cell, which counts the field's own insets.
        let columns = CompletionRowLayout.split(
            available: max(0, bounds.width - 34 - 9 - 8),
            title: Self.measure(title),
            detail: Self.measure(detail)
        )
        detail.frame = NSRect(
            x: bounds.width - columns.detail - 9, y: 8,
            width: columns.detail, height: 18
        )
        detail.isHidden = columns.detail == 0
        title.frame = NSRect(x: 34, y: 7, width: max(20, columns.title), height: 20)
    }

    private static func measure(_ field: NSTextField) -> CGFloat {
        guard !field.stringValue.isEmpty else { return 0 }
        // The glyphs are not the whole story: a text field draws its string
        // inside about four points of inset, and `intrinsicContentSize` leaves
        // them out. A frame of that width is a couple of points short, which
        // is all it takes for the field to give up and render "Daily" as
        // "…ily". `cellSize` includes them.
        return ceil(field.cell?.cellSize.width ?? field.intrinsicContentSize.width) + 1
    }

    /// What the row's two columns ended up at, for tests: the folder hint
    /// going quietly to a few points is the failure that matters here.
    var measuredColumns: (title: CGFloat, detail: CGFloat) {
        (title.frame.width, detail.isHidden ? 0 : detail.frame.width)
    }

    override func mouseDown(with event: NSEvent) { onPick?() }
}
