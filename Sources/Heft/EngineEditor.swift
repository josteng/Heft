import AppKit
import HeftCore
import MarkdownEngine
import MarkdownEngineLatex
import SwiftUI

/// Live editing surface backed by swift-markdown-engine (TextKit 2).
///
/// Evaluated as a replacement for the hand-rolled `SourceEditor`, which cannot
/// place widgets inline: TextKit 1 needs an `NSTextAttachment` placeholder
/// character in the document to reserve space, so tables, inline images and
/// inline math were preview-only. This engine paints widgets over collapsed
/// glyphs instead, leaving the text storage untouched.
///
/// **Standing caveat while unmodified:** the engine treats the text after `|`
/// inside `[[…]]` as an opaque id, and reconstructs it from a side channel on
/// write-back. If that channel misses, `![[chart.png|500]]` is written back as
/// `![[chart.png]]` — the width silently dropped. Aliased links additionally
/// display as the filename rather than the alias. Both are fixed by making
/// display ≡ storage in a fork; until then this is only pointed at scratch
/// vaults, never the user's real one.
struct EngineEditor: View {
    @Binding var text: String
    let documentID: String
    let vaultRoot: URL?
    let index: VaultIndex
    let current: NoteRef?
    let onAttachment: (NSPasteboard) -> String?
    let onFollowLink: (String) -> Void

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            fontName: "SF Pro",
            fontSize: 16,
            // Scopes the undo stack and scroll position per note, so switching
            // notes does not let an undo bleed across documents.
            documentId: documentID,
            onPasteImage: onAttachment,
            onLinkClick: onFollowLink
        )
    }

    /// Matched to the preview renderer in `Theme.swift` as closely as the
    /// engine's style surface allows.
    ///
    /// Not reachable from configuration, and therefore still preview-only:
    /// rounded table corners, the rule under H1/H2, Obsidian callouts and
    /// `#tag` styling. The first two have no exposed knob; the latter two are
    /// not in the engine's token set at all and cannot be added through
    /// `MarkdownExtension`, whose syntax model is an open/close delimiter pair.
    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default

        // Opt-in, but standard in Obsidian vaults.
        config.extensions = [HighlightExtension(), StrikethroughExtension()]

        // Semantic colours so the editor tracks light/dark and the accent.
        config.theme.bodyText = .labelColor
        config.theme.mutedText = .secondaryLabelColor
        config.theme.disabledText = .tertiaryLabelColor
        config.theme.headingMarker = .tertiaryLabelColor
        config.theme.link = .controlAccentColor
        // Unresolved links read as "create me", matching the preview.
        config.theme.incompleteLink = .systemOrange

        // Prose measure and breathing room, mirroring the preview's layout.
        config.readingWidth = Theme.contentMaxWidth
        config.textInsets.horizontal = 28
        config.textInsets.vertical = 24

        // Heading scale from Theme.heading(_:): 28/22/18/16/15/14 over a 16pt body.
        config.headings.fontMultipliers = [1.75, 1.38, 1.13, 1.0, 0.95, 0.9]
        config.headings.topSpacingEm = [1.1, 1.0, 0.65, 0.55, 0.5, 0.5]

        config.taskCheckbox.uncheckedSymbolName = "square"
        config.taskCheckbox.checkedSymbolName = "checkmark.square.fill"
        config.lists.indentPerLevel = 20

        config.services = MarkdownEditorServices(
            wikiLinks: HeftWikiLinkResolver(index: index, current: current),
            images: HeftEmbeddedImageProvider(index: index, vaultRoot: vaultRoot, current: current),
            latex: SwiftMathBridge()
        )
        return config
    }
}

/// Bridges the engine's link resolution to the vault index.
///
/// `name(forID:)` is deliberately left at its no-op default. Supplying it would
/// enable the engine's "snap-back" behaviour, which rewrites a link's target
/// text in the document — unacceptable against a vault Heft does not own.
struct HeftWikiLinkResolver: WikiLinkResolver {
    let index: VaultIndex
    let current: NoteRef?

    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        let link = WikiLinkParser.links(in: "[[\(displayName)]]").first
            ?? WikiLink(target: displayName)
        let exists = index.resolve(link, from: current) != nil
        // The id is echoed back as the target itself: Heft addresses notes by
        // path, and has no separate stable identifier to hand over.
        return WikiLinkResolution(id: displayName, exists: exists)
    }

    func fingerprint() -> AnyHashable { index.notes.count }
}

/// Resolves `![[image.png]]` embeds against the vault.
struct HeftEmbeddedImageProvider: EmbeddedImageProvider {
    let index: VaultIndex
    let vaultRoot: URL?
    let current: NoteRef?

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        let link = WikiLink(target: reference.name, isEmbed: true)
        if let hit = index.resolve(link, from: current) {
            return ImageCache.image(at: hit.url)
        }
        // Fall back to a path relative to the note, then to the vault root.
        guard let vaultRoot else { return nil }
        let candidates = [
            current?.url.deletingLastPathComponent().appendingPathComponent(reference.name),
            vaultRoot.appendingPathComponent(reference.name),
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return ImageCache.image(at: candidate)
        }
        return nil
    }

    func fingerprint() -> AnyHashable { index.allFiles.count }
}
