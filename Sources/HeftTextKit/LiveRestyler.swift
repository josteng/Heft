#if os(macOS)
import AppKit
#else
import UIKit
#endif
import HeftCore

/// The restyle pass both editors run, and the widgets it hands TextKit.
///
/// It keeps the previous pass and diffs it against the next one, so only
/// where the two disagree is rewritten; the rest keeps its attributes, and
/// with them its layout. What to reveal, and when a pass may run at all, is
/// the editor's: a mouse drag, an input method, a Writing Tools session and
/// a touch placing a caret each hold it back differently.
final class LiveRestyler {
    /// The widgets the last pass computed, keyed by paragraph start.
    private(set) var layout = LiveLayout()
    /// How far the text has moved since `layout` was computed.
    ///
    /// Only non-nil between an edit and the pass that follows it, which on
    /// the Mac is the whole of a held key, because those defer their styling.
    private(set) var pendingShift: (fromOldOffset: Int, delta: Int)?
    /// What the storage's attributes currently represent. Together with the
    /// settings they were produced under, what makes a pass incremental.
    private(set) var styled: RestyleScope.Snapshot?
    private var styleKey = ""
    /// `ImageCache.generation` as of the last full pass. A figure replaced
    /// at the same size moves no widget, so the signature cannot say so.
    private var styledImageGeneration = ImageCache.generation

    enum Outcome {
        /// The last pass styled exactly this; nothing was decorated.
        case current
        /// The decorations moved with the text but nothing about them
        /// changed, so what is on screen is already right.
        case unchanged(spellExclusions: [NSRange])
        /// Attributes were rewritten, and `relayout` is the layout they made
        /// stale, for the editor to drop once its own bookkeeping is done.
        case restyled(spellExclusions: [NSRange], relayout: Relayout)
    }

    enum Relayout {
        case none
        case ranges([NSRange])
        case document

        func apply(to manager: NSTextLayoutManager?) {
            guard let manager, let content = manager.textContentManager else { return }
            switch self {
            case .none:
                break
            case .ranges(let ranges):
                // A widget belongs to the first paragraph of the construct it
                // draws, and the rewritten attributes already invalidate those
                // paragraphs. Asking explicitly is what guarantees the layout
                // manager comes back for a fragment whose *widget* changed
                // while its text did not — a table gaining a row, say.
                for range in ranges { LiveRestyler.invalidate(range, in: manager) }
            case .document:
                manager.invalidateLayout(for: content.documentRange)
            }
        }
    }

    /// For a new document. The layout and the shift describe the text that
    /// is going, and TextKit builds the new text's first fragment during the
    /// assignment, before any pass, so they go first.
    func reset() {
        layout = LiveLayout()
        styled = nil
        pendingShift = nil
    }

    /// Forgets that the storage is styled at all, forcing the next pass to do
    /// the whole document. Replacing the text drops every attribute, so the
    /// next pass cannot assume anything it did not rewrite is still styled.
    func forgetStyling() { styled = nil }

    /// Drops a shift that describes no real edit, such as replacing the whole
    /// text, which would remap the new document's offsets into the old one.
    func discardShift() { pendingShift = nil }

    /// Records that the text moved by `delta` from `oldEnd`, an offset in the
    /// text before the edit, without moving the widgets: the next pass shifts
    /// them itself when it carries them over.
    func noteEdit(endingAt oldEnd: Int, delta: Int) {
        guard delta != 0 else { return }
        if let pending = pendingShift {
            pendingShift = (min(pending.fromOldOffset, oldEnd), pending.delta + delta)
        } else {
            pendingShift = (oldEnd, delta)
        }
    }

    /// Brings `storage`'s attributes back in line with `source` and `reveal`,
    /// touching as little as it can. `context` must already carry the
    /// appearance the view is drawn in: formulae bake their colour into a
    /// bitmap.
    func restyle(
        _ storage: NSTextStorage, source: NSString, reveal: Reveal,
        context: RenderContext, width: CGFloat, minimumContentWidth: CGFloat
    ) -> Outcome {
        let key = Self.styleKey(context: context, width: width)

        // The cheapest exit, and the common one: a pass arriving after the
        // caret's has already styled this exact state. Taken before
        // decorating, because decorating is the expensive part.
        if let styled, styleKey == key, styled.reveal == reveal,
           styled.source.isEqual(to: source as String) {
            return .current
        }

        // Moving the caret changes what is revealed, not what is there, so
        // the previous parse still describes the document exactly.
        let decorations: [MarkdownDecoration]
        if let styled, styled.source.isEqual(to: source as String) {
            decorations = styled.decorations
        } else {
            // Reuse the previous parse where the edit provably could not have
            // changed anything outside one paragraph: decorating is why typing
            // would otherwise scale with the note rather than the edit.
            decorations = LiveDecorator.decorations(
                in: source,
                reusing: styled.map {
                    LiveDecorator.DecorationCache(source: $0.source, decorations: $0.decorations)
                }
            )
        }
        // Before the early return below: "nothing changed" there means the
        // same constructs, which have still *moved*, and an exclusion is a range.
        let exclusions = SpellCheckScope.exclusions(for: decorations, in: source)
        let snapshot = RestyleScope.Snapshot(source: source, decorations: decorations, reveal: reveal)
        // Anything the styler reads besides the document invalidates the lot
        // when it moves, and no part of the previous pass can be kept.
        let comparable = styleKey == key ? styled : nil
        let imagesReplaced = styledImageGeneration != context.imageGeneration
        styledImageGeneration = context.imageGeneration
        let scope = comparable.map { RestyleScope.scope(from: $0, to: snapshot) }
        styleKey = key
        styled = snapshot

        if let scope, scope.isEmpty { return .unchanged(spellExclusions: exclusions) }

        let previous = layout.signature
        layout = LiveStyler.apply(
            to: storage,
            reveal: reveal,
            context: context,
            contentWidth: max(minimumContentWidth, width - 8),
            decorations: decorations,
            incremental: scope.map {
                LiveStyler.Incremental(dirty: $0.dirty, edit: $0.edit, previous: layout)
            }
        )
        pendingShift = nil

        let relayout: Relayout
        if let scope {
            relayout = .ranges(scope.dirty)
        } else if layout.signature != previous || imagesReplaced {
            // Rewriting a paragraph already invalidates it, so a full
            // relayout is only needed when widgets appear or disappear, or a
            // picture was replaced on disk.
            relayout = .document
        } else {
            relayout = .none
        }
        return .restyled(spellExclusions: exclusions, relayout: relayout)
    }

    /// Everything a pass depends on that is not the document itself.
    private static func styleKey(context: RenderContext, width: CGFloat) -> String {
        "\(context.index.allFiles.count)/\(context.current?.relativePath ?? "")/"
            + "\(context.colorfulFormatting)/\(context.headingFont)/\(context.headingBars)/\(context.palette)/"
            + "\(context.strictLineBreaks)/\(width)/"
            + "\(context.appearance?.name.rawValue ?? "")/"
            + "\(context.accentColor)/\(context.linkColor)/\(context.tagColor)/"
            + "\(context.codeColor)/\(context.boldColor)/\(context.italicColor)/"
            + "\(context.headingColors)/\(context.imageGeneration)"
    }

    static func invalidate(_ range: NSRange, in manager: NSTextLayoutManager) {
        guard range.location != NSNotFound, range.length > 0,
              let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end)
        else { return }
        manager.invalidateLayout(for: textRange)
    }

    /// Where to look a widget up, for a fragment starting at `start` in the
    /// text as it is now.
    ///
    /// Widgets are keyed by absolute offset, so an edit above them leaves
    /// every key below it short until the next pass rebuilds them. A fragment
    /// rebuilt in between would find nothing and draw its line without its
    /// bullet: the marker below the caret vanishing as a key repeats.
    func layoutKey(for start: Int) -> Int {
        guard let shift = pendingShift, shift.delta != 0 else { return start }
        return start >= shift.fromOldOffset + shift.delta ? start - shift.delta : start
    }

    /// A paragraph's fragment, with the widgets the last pass computed for it.
    func fragment(
        for location: NSTextLocation, in textElement: NSTextElement, manager: NSTextLayoutManager
    ) -> NSTextLayoutFragment {
        let fragment = HeftLayoutFragment(textElement: textElement, range: textElement.elementRange)
        guard let content = manager.textContentManager else { return fragment }
        let start = content.offset(from: content.documentRange.location, to: location)
        fragment.elementStart = start
        let key = layoutKey(for: start)
        fragment.widget = layout.blocks[key]
        fragment.inlineMath = layout.inlineMath[key] ?? []
        fragment.inlineTags = layout.inlineTags[key] ?? []
        fragment.palette = layout.palette
        return fragment
    }
}
