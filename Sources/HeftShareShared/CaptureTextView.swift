import SwiftUI
import UIKit

/// The capture's text: large, unboxed, and with each `#tag` drawn in the
/// tag colour on a rounded pill of its tint, as a note draws it. A text view rather than a
/// SwiftUI field, which cannot colour part of what it shows. Return files
/// the line instead of breaking it.
struct CaptureTextView: UIViewRepresentable {
    @Binding var text: String
    var tagColor: UIColor
    var focusRequest: Int
    var placeholder: String
    /// The capture's is large; the share sheet's, holding a link, smaller.
    var fontSize: CGFloat = 26
    /// Return files the line in a capture; in a share it breaks the line.
    var submitsOnReturn = true
    /// A capture's leftover line comes back selected, to be typed over; a
    /// share's link is kept, the caret after it.
    var selectsOnFocus = true
    var submit: () -> Void

    var font: UIFont { .systemFont(ofSize: fontSize, weight: .regular) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = PillTextView()
        view.backgroundColor = .clear
        view.font = font
        view.pillFont = font
        // Room for a pill at a line's start to reach past its letters
        // without being cut off at the view's edge.
        view.textContainerInset = UIEdgeInsets(top: 0, left: Self.pillPadding, bottom: 0, right: Self.pillPadding)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.returnKeyType = submitsOnReturn ? .done : .default
        view.alwaysBounceVertical = false
        let label = UILabel()
        label.text = placeholder
        label.font = font
        label.textColor = .placeholderText
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.pillPadding),
        ])
        context.coordinator.placeholder = label
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
            context.coordinator.style(view)
        }
        context.coordinator.placeholder?.isHidden = !text.isEmpty
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            // A line left from last time comes back selected, as Safari's
            // address bar does: typing replaces it, Delete clears it, a tap
            // keeps it. No button of its own for that, which beside the
            // sheet's close button read as a second close.
            DispatchQueue.main.async {
                view.becomeFirstResponder()
                if self.selectsOnFocus, !view.text.isEmpty { view.selectAll(nil) }
                else { view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0) }
            }
        }
    }

    /// How far a tag's pill reaches past its letters, as in a note.
    static let pillPadding: CGFloat = 5

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CaptureTextView
        weak var placeholder: UILabel?
        var focusRequest = 0

        init(_ parent: CaptureTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            guard text == "\n", parent.submitsOnReturn else { return true }
            parent.submit()
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            style(textView)
            parent.text = textView.text
            placeholder?.isHidden = !textView.text.isEmpty
        }

        /// The tags in the tag colour on its tint, everything else plain.
        /// Attributes only, so the caret stays where it is.
        func style(_ textView: UITextView) {
            let storage = textView.textStorage
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: parent.font, .foregroundColor: UIColor.label], range: whole)
            let tags = Self.tag.matches(in: storage.string, range: whole).map(\.range)
            for range in tags {
                storage.addAttribute(.foregroundColor, value: parent.tagColor, range: range)
                // Room either side for the pill, as a note kerns it: after
                // the character before the tag, and after its last one.
                if range.location > 0 {
                    storage.addAttribute(.kern, value: CaptureTextView.pillPadding,
                                         range: NSRange(location: range.location - 1, length: 1))
                }
                storage.addAttribute(.kern, value: CaptureTextView.pillPadding,
                                     range: NSRange(location: NSMaxRange(range) - 1, length: 1))
            }
            storage.endEditing()
            textView.typingAttributes = [.font: parent.font, .foregroundColor: UIColor.label]
            if let pills = textView as? PillTextView {
                pills.tags = tags
                pills.pillColor = parent.tagColor
                pills.setNeedsLayout()
            }
        }

        private static let tag = try! NSRegularExpression(pattern: #"(?<![\w/&])#[A-Za-z][\w/-]*"#)
    }
}

/// A text view that draws a rounded pill behind each tag, as a note does: a
/// text background attribute only ever draws a sharp rectangle. Sized as the
/// note's pill is, off the font rather than the line, and hugging the word
/// by the same padding.
final class PillTextView: UITextView {
    var tags: [NSRange] = []
    var pillColor: UIColor = .tintColor
    var pillFont: UIFont = .systemFont(ofSize: 26)
    /// A tag's pill behind its letters, as `Theme.tagBackgroundOpacity` has
    /// it in a note; the share extension has no `Theme`.
    static let pillOpacity: CGFloat = 0.14
    private let pills = CAShapeLayer()
    private var installed = false

    override func layoutSubviews() {
        super.layoutSubviews()
        if !installed {
            installed = true
            layer.insertSublayer(pills, at: 0)
        }
        drawPills()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        drawPills()
    }

    private func drawPills() {
        let path = UIBezierPath()
        let font = pillFont
        let height = font.ascender - font.descender + 3
        let length = (text as NSString).length
        for range in tags where NSMaxRange(range) <= length {
            guard let start = position(from: beginningOfDocument, offset: range.location),
                  let end = position(from: start, offset: range.length),
                  let span = textRange(from: start, to: end) else { continue }
            // A tag has no spaces, so it is on one line, but it can still be
            // cut by the view's width; each piece gets its own pill.
            for piece in selectionRects(for: span) where piece.rect.width > 0 {
                let line = piece.rect
                let rect = CGRect(x: line.minX - CaptureTextView.pillPadding, y: line.midY - height / 2,
                                  width: line.width + CaptureTextView.pillPadding * 2, height: height)
                path.append(UIBezierPath(roundedRect: rect, cornerRadius: height / 2))
            }
        }
        pills.path = path.cgPath
        pills.fillColor = pillColor.withAlphaComponent(Self.pillOpacity)
            .resolvedColor(with: traitCollection).cgColor
    }
}
