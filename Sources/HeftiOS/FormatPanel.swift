import HeftCore
import UIKit

/// Everything the format panel can do, so the panel only reports which one
/// was tapped and the editor decides what that writes.
enum FormatTool: Hashable {
    case title, heading, subheading, body
    case bold, italic, strikethrough, code
    /// Highlights in the current colour; `color` only picks it, nil being
    /// the plain `==` highlight.
    case highlight, color(HighlightColor?)
    case task, bullets, numbers
    case outdent, indent
    case quote, callout
    /// `[[ ]]` at the caret, or around the selection; from ⌘K and the
    /// menu bar, which the panel itself has no button for.
    case link
}

/// What applies where the caret is, which the panel shows filled in.
struct FormatState: Equatable {
    var headingLevel = 0
    var inline: Set<FormatTool> = []
    var list: FormatTool?
    var quoted = false
}

/// The panel Aa puts in the keyboard's place, laid out as Notes lays out
/// its own: the line's style written in that style, the inline styles as one
/// capsule, then lists, indent and quote. What is on at the caret is filled.
final class FormatPanel: UIInputView {
    var onTool: (FormatTool) -> Void = { _ in }
    var onClose: () -> Void = {}

    private var buttons: [FormatTool: UIButton] = [:]
    private var state = FormatState()
    private weak var colorDot: UIButton?

    /// The colour the pencil highlights in, shown on the dot beside it.
    var highlightColor: HighlightColor? {
        didSet { if let colorDot { configureColorDot(colorDot) } }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 300), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ state: FormatState) {
        guard state != self.state else { return }
        self.state = state
        for (tool, button) in buttons { style(button, for: tool) }
    }

    // MARK: Layout

    private func build() {
        let title = UILabel()
        title.text = "Format"
        title.font = .preferredFont(forTextStyle: .title3).bold()

        var closeConfiguration = UIButton.Configuration.gray()
        closeConfiguration.image = UIImage(systemName: "xmark")
        closeConfiguration.cornerStyle = .capsule
        closeConfiguration.baseForegroundColor = .label
        let close = UIButton(configuration: closeConfiguration, primaryAction: UIAction { [weak self] _ in
            self?.onClose()
        })
        close.accessibilityLabel = "Close"
        close.widthAnchor.constraint(equalToConstant: 44).isActive = true
        close.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let header = UIStackView(arrangedSubviews: [title, UIView(), close])
        header.alignment = .center

        let styles = UIStackView(arrangedSubviews: [
            styleButton(.title, "Title", .preferredFont(forTextStyle: .title2).bold()),
            styleButton(.heading, "Heading", .preferredFont(forTextStyle: .title3).bold()),
            styleButton(.subheading, "Subheading", .preferredFont(forTextStyle: .headline)),
            styleButton(.body, "Body", .preferredFont(forTextStyle: .body)),
        ])
        styles.distribution = .fillProportionally
        styles.spacing = 4

        let inline = UIStackView(arrangedSubviews: [
            group([(.bold, "bold"), (.italic, "italic"), (.strikethrough, "strikethrough"),
                   (.code, "chevron.left.forwardslash.chevron.right")]),
            group([(.highlight, "highlighter")], trailing: colorButton()),
        ])
        inline.spacing = 10
        inline.distribution = .fillProportionally

        let blocks = UIStackView(arrangedSubviews: [
            group([(.task, "checklist"), (.bullets, "list.bullet"), (.numbers, "list.number")]),
            group([(.outdent, "decrease.indent"), (.indent, "increase.indent")]),
            group([(.quote, "text.quote")], trailing: calloutButton()),
        ])
        blocks.spacing = 10
        blocks.distribution = .fillProportionally

        let column = UIStackView(arrangedSubviews: [header, styles, inline, blocks])
        column.axis = .vertical
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            column.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])
    }

    /// A line style, written in the style it applies.
    private func styleButton(_ tool: FormatTool, _ label: String, _ font: UIFont) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        var title = AttributedString(label)
        title.font = font
        configuration.attributedTitle = title
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.onTool(tool)
        })
        button.accessibilityLabel = label
        register(button, for: tool)
        return button
    }

    /// Icons that belong together, as one capsule of segments.
    private func group(_ tools: [(FormatTool, String)], trailing: UIButton? = nil) -> UIView {
        let stack = UIStackView()
        stack.spacing = 1
        stack.distribution = .fillEqually
        for (tool, symbol) in tools {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            configuration.preferredSymbolConfigurationForImage =
                UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            configuration.background.cornerRadius = 0
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.onTool(tool)
            })
            button.accessibilityLabel = Self.label(for: tool)
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
            register(button, for: tool)
            stack.addArrangedSubview(button)
        }
        if let trailing { stack.addArrangedSubview(trailing) }
        stack.cornerConfiguration = .capsule()
        stack.clipsToBounds = true
        return stack
    }

    /// The colour the pencil uses, as Notes has it: picking one changes the
    /// highlight under the caret and every one after, and highlights nothing
    /// by itself. Heft writes a colour as an emoji after `==`; Default is
    /// the plain highlight.
    private func colorButton() -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "circle.fill")
        configuration.background.backgroundColor = .tertiarySystemFill
        configuration.background.cornerRadius = 0
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "Highlight Colour"
        button.showsMenuAsPrimaryAction = true
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        colorDot = button
        configureColorDot(button)
        return button
    }

    private func configureColorDot(_ button: UIButton) {
        var configuration = button.configuration
        configuration?.baseForegroundColor = Theme.highlightSwatch(highlightColor ?? .yellow)
        button.configuration = configuration
        let choices: [HighlightColor?] = [nil] + HighlightColor.allCases.map(Optional.some)
        button.menu = UIMenu(children: choices.map { color in
            let action = UIAction(
                title: color?.title ?? "Default",
                image: UIImage(systemName: "circle.fill")?.withTintColor(
                    Theme.highlightSwatch(color ?? .yellow), renderingMode: .alwaysOriginal
                )
            ) { [weak self] _ in
                self?.onTool(.color(color))
            }
            action.state = color == highlightColor ? .on : .off
            return action
        })
    }

    /// Beside Quote: starts `> [!]`, and the keyboard strip offers the
    /// kinds, used ones first, as it does for a callout typed by hand.
    private func calloutButton() -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "exclamationmark.bubble")
        configuration.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        configuration.baseForegroundColor = .label
        configuration.background.backgroundColor = .tertiarySystemFill
        configuration.background.cornerRadius = 0
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.onTool(.callout)
        })
        button.accessibilityLabel = "Callout"
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        return button
    }

    private func register(_ button: UIButton, for tool: FormatTool) {
        buttons[tool] = button
        style(button, for: tool)
    }

    private func isOn(_ tool: FormatTool) -> Bool {
        switch tool {
        case .title: state.headingLevel == 1
        case .heading: state.headingLevel == 2
        case .subheading: state.headingLevel == 3
        case .body: state.headingLevel == 0
        case .quote: state.quoted
        case .task, .bullets, .numbers: state.list == tool
        default: state.inline.contains(tool)
        }
    }

    private func style(_ button: UIButton, for tool: FormatTool) {
        guard var configuration = button.configuration else { return }
        let on = isOn(tool)
        let isStyle = [.title, .heading, .subheading, .body].contains(tool)
        configuration.baseForegroundColor = on ? .white : .label
        configuration.background.backgroundColor = on ? .tintColor : (isStyle ? .clear : .tertiarySystemFill)
        button.configuration = configuration
    }

    private static func label(for tool: FormatTool) -> String {
        switch tool {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .code: "Code"
        case .highlight: "Highlight"
        case .task: "Task"
        case .bullets: "Bulleted List"
        case .numbers: "Numbered List"
        case .outdent: "Outdent"
        case .indent: "Indent"
        case .quote: "Quote"
        default: ""
        }
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
