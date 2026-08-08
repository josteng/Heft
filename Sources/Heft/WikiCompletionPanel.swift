import AppKit
import HeftCore

struct WikiCompletionItem {
    let ref: NoteRef
    let destination: String

    var symbol: String {
        switch ref.kind {
        case .markdown: "doc.text"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .canvas: "square.on.square.dashed"
        default: "doc"
        }
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

private final class WikiCompletionRow: NSView {
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
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : nil

        icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        icon.contentTintColor = selected ? .white : .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        title.stringValue = item.ref.name
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = selected ? .white : .labelColor
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)

        detail.stringValue = item.ref.folder
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = selected ? NSColor.white.withAlphaComponent(0.72) : .tertiaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingHead
        addSubview(detail)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.ref.folder.isEmpty
            ? item.ref.name
            : "\(item.ref.name), \(item.ref.folder)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 9, y: 9, width: 16, height: 16)
        let detailWidth = detail.stringValue.isEmpty ? 0 : min(150, detail.intrinsicContentSize.width)
        detail.frame = NSRect(
            x: bounds.width - detailWidth - 9, y: 8,
            width: detailWidth, height: 18
        )
        title.frame = NSRect(
            x: 34, y: 7,
            width: max(20, bounds.width - 34 - detailWidth - 16), height: 20
        )
    }

    override func mouseDown(with event: NSEvent) { onPick?() }
}
