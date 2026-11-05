#if os(macOS)
import AppKit
#else
import UIKit
#endif
import HeftCore

/// Where the properties table's controls are drawn, measured from the same
/// layout the widgets drew them with: the heading and its two buttons, each
/// row's type icon, each pill's ×, "Add property", and the typed item after
/// a list's pills. The Mac's clicks and pointer, and iOS's taps, all read
/// these, so a control answers exactly where it is drawn.
///
/// `origin` is where the text container starts in the view: the Mac's
/// `textContainerInset` as a point, iOS's left and top insets.
enum PropertyGeometry {
    /// What can be tapped in the table besides its text.
    enum Target: Equatable {
        case fold
        case source
        case typeMenu(lineStart: Int)
        case removeItem(lineStart: Int, index: Int)
        case addProperty
    }

    struct Heading {
        /// The "Properties" word, or shown as YAML, the fence.
        var heading: CGRect
        /// The fold arrow before it.
        var arrow: CGRect
        /// The `{}` button after it.
        var source: CGRect
    }

    /// Where the heading is drawn, and the arrow and `{}` beside it.
    static func heading(
        in source: String, layout: LiveLayout, manager: NSTextLayoutManager?, origin: CGPoint, asText: Bool
    ) -> Heading? {
        guard PropertyEditing.blockRange(in: source) != nil,
              asText || { if case .propertyHeading? = layout.blocks[0] { true } else { false } }(),
              let manager, let content = manager.textContentManager,
              let fragment = manager.textLayoutFragment(for: content.documentRange.location),
              let line = fragment.textLineFragments.first
        else { return nil }
        let frame = fragment.layoutFragmentFrame
        let x = frame.minX + origin.x
        let y = frame.minY + origin.y
        let height = asText ? line.typographicBounds.height : frame.height
        let heading = CGRect(x: x, y: y, width: 90, height: height)
        // Centred on the word's capitals, where the eye centres a word, not
        // on its line box, whose middle sits above them. The heading is
        // drawn with its glyph box centred in the line.
        let word = asText ? "---" : "Properties"
        let font = asText
            ? NSFont.monospacedSystemFont(ofSize: Theme.bodySize - 2, weight: .regular)
            : NSFont.systemFont(ofSize: Theme.bodySize - 1, weight: .semibold)
        let glyphTop = asText
            ? y + line.typographicBounds.minY + line.glyphOrigin.y - font.ascender
            : y + (height - (font.ascender - font.descender)) / 2
        let middle = glyphTop + font.ascender - font.capHeight / 2
        let arrow = CGRect(x: x - 20, y: middle - 7, width: 14, height: 14)
        let width = ceil(NSAttributedString(string: word, attributes: [.font: font]).size().width)
        // A point lower than the capitals' middle: the braces reach above
        // the capitals and below the baseline, and centred exactly they
        // read as sitting high.
        let sourceButton = CGRect(x: x + width + 8, y: middle - 6, width: 16, height: 14)
        return Heading(heading: heading, arrow: arrow, source: sourceButton)
    }

    /// Every target, with the rect that answers for it. `offersSource` is
    /// false while every note's properties show as YAML by setting, when
    /// the per-note `{}` is not offered; `slop` grows each rect for a finger.
    static func targets(
        in source: String, layout: LiveLayout, manager: NSTextLayoutManager?, origin: CGPoint,
        asText: Bool, folded: Bool, offersSource: Bool, slop: CGFloat = 0
    ) -> [(rect: CGRect, target: Target)] {
        var targets: [(CGRect, Target)] = []
        let heading = heading(in: source, layout: layout, manager: manager, origin: origin, asText: asText)
        if let heading, offersSource {
            targets.append((heading.source.insetBy(dx: -3 - slop, dy: -3 - slop), .source))
        }
        guard !asText, let manager, let content = manager.textContentManager else { return targets }
        // The arrow and the heading both fold, as Obsidian's heading does.
        if let heading {
            targets.append((heading.arrow.insetBy(dx: -3 - slop, dy: -3 - slop).union(heading.heading), .fold))
        }
        if folded { return targets }
        for (start, widget) in layout.blocks {
            guard case .propertyRow(let row) = widget,
                  let location = content.location(content.documentRange.location, offsetBy: start),
                  let fragment = manager.textLayoutFragment(for: location),
                  let line = fragment.textLineFragments.first
            else { continue }
            let frame = fragment.layoutFragmentFrame
            let rowOrigin = CGPoint(x: frame.minX + origin.x, y: frame.minY + origin.y)
            let left = rowOrigin.x - row.indent
            let mid = rowOrigin.y + line.typographicBounds.midY
            if row.symbol != nil {
                targets.append((CGRect(x: left - 3, y: mid - 11, width: PropertyChips.symbolSide + 8, height: 22)
                    .insetBy(dx: -slop, dy: -slop), .typeMenu(lineStart: start)))
            }
            if let chips = row.chips, chips.removable {
                let baseline = rowOrigin.y + line.typographicBounds.minY + line.glyphOrigin.y
                for index in chips.labels.indices {
                    let rowBaseline = baseline + CGFloat(chips.rows[index]) * chips.rowPitch
                    let right = left + chips.column + chips.x[index] + chips.widths[index]
                    targets.append((CGRect(
                        x: right - PropertyChips.removeWidth - PropertyChips.padding + 2,
                        y: rowBaseline - chips.font.ascender - 2,
                        width: PropertyChips.removeWidth + PropertyChips.padding - 2,
                        height: chips.font.ascender - chips.font.descender + 4
                    ).insetBy(dx: -slop / 2, dy: -slop / 2), .removeItem(lineStart: start, index: index)))
                }
            }
            if row.edge == .last || row.edge == .only {
                let label = NSAttributedString(string: PropertyChips.addLabel, attributes: [
                    .font: NSFont.systemFont(ofSize: Theme.bodySize - 1),
                ]).size()
                targets.append((CGRect(
                    x: left - 3,
                    y: frame.maxY + origin.y - PropertyChips.bottomMargin - PropertyChips.addRowHeight,
                    width: LiveStyler.propertyPadding + label.width + 8, height: PropertyChips.addRowHeight
                ), .addProperty))
            }
        }
        return targets
    }

    /// The caret in a row's text, for iOS: as tall as the row's letters and
    /// centred where the row's outline is centred, between the capitals'
    /// tops and the baseline. UIKit draws the caret nearly the outline's
    /// height and a point above its middle, so it touched the outline's top
    /// and not its bottom. `x` is where UIKit put it across.
    static func rowCaret(
        in source: String, selection: NSRange, layout: LiveLayout, manager: NSTextLayoutManager?,
        origin: CGPoint, x: CGFloat
    ) -> CGRect? {
        guard selection.length == 0, let row = PropertySurface.row(at: selection.location, in: source),
              case .propertyRow? = layout.blocks[row.range.location],
              let manager, let content = manager.textContentManager,
              let place = content.location(content.documentRange.location, offsetBy: selection.location),
              let fragment = manager.textLayoutFragment(for: place)
        else { return nil }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let offset = selection.location - start
        guard let line = fragment.textLineFragments.first(where: {
            NSLocationInRange(offset, $0.characterRange) || offset == NSMaxRange($0.characterRange)
        }) ?? fragment.textLineFragments.first else { return nil }
        let baseline = fragment.layoutFragmentFrame.minY + origin.y + line.typographicBounds.minY + line.glyphOrigin.y
        let font = NSFont.systemFont(ofSize: Theme.bodySize - 1)
        let height = ceil(font.ascender - font.descender)
        return CGRect(x: x, y: baseline - font.capHeight / 2 - height / 2, width: 2, height: height)
    }

    /// The property row drawn at `point`, and whether it is in the value's
    /// column.
    static func column(
        at point: CGPoint, layout: LiveLayout, manager: NSTextLayoutManager?, origin: CGPoint
    ) -> (line: Int, inValue: Bool)? {
        guard let manager, let content = manager.textContentManager else { return nil }
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = manager.textLayoutFragment(for: inContainer) else { return nil }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        guard case .propertyRow(let row)? = layout.blocks[start] else { return nil }
        let column = fragment.layoutFragmentFrame.minX + origin.x - row.indent + row.column
        return (start, point.x >= column - 4)
    }

    /// Where the caret of a list being edited stands: after the typed item
    /// drawn after the last pill. Nil unless the caret is at a list's input.
    /// In Vim's Normal mode it stands on the typed item's last letter.
    static func listCaret(
        in source: String, selection: NSRange, layout: LiveLayout, manager: NSTextLayoutManager?,
        origin: CGPoint, normal: Bool
    ) -> CGRect? {
        guard selection.length == 0,
              let row = PropertySurface.row(at: selection.location, in: source),
              selection.location >= row.valueEnd - 1,
              case .propertyRow(let drawn)? = layout.blocks[row.range.location],
              let chips = drawn.chips, let input = chips.input,
              let manager, let content = manager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: row.range.location),
              let fragment = manager.textLayoutFragment(for: location),
              let line = fragment.textLineFragments.first,
              selection.location == row.valueEnd || (normal && selection.location == row.valueEnd - 1)
        else { return nil }
        let frame = fragment.layoutFragmentFrame
        let rowOrigin = CGPoint(x: frame.minX + origin.x, y: frame.minY + origin.y)
        let baseline = rowOrigin.y + line.typographicBounds.minY + line.glyphOrigin.y + CGFloat(input.row) * chips.rowPitch
        var typedWidth = ceil(input.label.size().width)
        if normal, input.label.length > 0 {
            let last = input.label.attributedSubstring(from: NSRange(location: input.label.length - 1, length: 1))
            typedWidth -= ceil(last.size().width)
        }
        let x = rowOrigin.x - drawn.indent + chips.column + input.x + typedWidth
        return CGRect(x: x, y: baseline - chips.font.ascender, width: 2, height: chips.font.ascender - chips.font.descender)
    }
}
