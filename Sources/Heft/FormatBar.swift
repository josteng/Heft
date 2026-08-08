import AppKit
import HeftCore

/// The formatting bar that appears above a selection.
///
/// A child view of the text view rather than a popover or a panel: a popover
/// steals key focus, which drops the selection it exists to act on, and a
/// floating `NSPanel` has to be moved by hand on every scroll and window
/// resize. As a subview it scrolls with the text for free and never becomes
/// first responder.
final class FormatBar: NSView {

    /// Called with the format the user picked. `nil` means the link button.
    var onFormat: ((InlineFormat?) -> Void)?

    private let stack = NSStackView()
    private let background = NSVisualEffectView()

    static let height: CGFloat = 32
    /// Gap between the bar and the top of the selected text.
    private static let gap: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true

        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.borderWidth = 0.5
        background.layer?.masksToBounds = true
        addSubview(background)

        stack.orientation = .horizontal
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        addSubview(stack)

        for format in InlineFormat.allCases {
            stack.addArrangedSubview(button(
                symbol: format.symbol, help: format.title, action: #selector(pick(_:)), tag: index(of: format)
            ))
        }
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(button(
            symbol: "link", help: "Link", action: #selector(pickLink), tag: -1
        ))

        stack.frame = NSRect(x: 0, y: 0, width: stack.fittingSize.width, height: Self.height)
        setFrameSize(NSSize(width: stack.fittingSize.width, height: Self.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        background.frame = bounds
        stack.frame = bounds
    }

    /// The bar must never take focus: clicking a button has to leave the text
    /// view's selection exactly where it was.
    override var acceptsFirstResponder: Bool { false }

    private func index(of format: InlineFormat) -> Int {
        InlineFormat.allCases.firstIndex(of: format) ?? 0
    }

    private func button(symbol: String, help: String, action: Selector, tag: Int) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .toolbar
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = action
        button.tag = tag
        button.toolTip = help
        button.refusesFirstResponder = true
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    @objc private func pick(_ sender: NSButton) {
        guard InlineFormat.allCases.indices.contains(sender.tag) else { return }
        onFormat?(InlineFormat.allCases[sender.tag])
    }

    @objc private func pickLink() {
        onFormat?(nil)
    }

    /// Places the bar above `selectionRect`, or hides it when there is nothing
    /// to format.
    func update(for selectionRect: CGRect?, in textView: NSTextView) {
        guard let selectionRect, selectionRect.width > 0 || selectionRect.height > 0 else {
            isHidden = true
            return
        }

        let size = NSSize(width: stack.fittingSize.width, height: Self.height)
        var origin = CGPoint(
            x: selectionRect.midX - size.width / 2,
            y: selectionRect.minY - size.height - Self.gap
        )

        // Keep it inside the text view, and flip below the selection when there
        // is no room above — which is the case on the document's first line.
        let bounds = textView.bounds
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        if origin.y < bounds.minY + 4 {
            origin.y = selectionRect.maxY + Self.gap
        }

        setFrameOrigin(origin)
        setFrameSize(size)
        isHidden = false
    }
}
