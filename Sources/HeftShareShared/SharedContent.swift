import Foundation
import UniformTypeIdentifiers

/// What a share becomes in a note, for the iOS and the Mac share sheets
/// alike.
public enum SharedContent {
    /// A page as `[Title](url)`, text as it came. Safari passes the page title
    /// as the item's content text; an app that shares only the address gets
    /// the bare URL, which Obsidian links as it is, and the sheet looks the
    /// title up.
    public static func markdown(from items: [NSExtensionItem]) async
        -> (text: String, url: URL?, title: String?) {
        var url: URL?
        var text: String?
        var title: String?
        for item in items {
            if title == nil, let content = item.attributedContentText?.string, !content.isEmpty {
                title = content
            }
            // What an app that sends no content text may send instead.
            if title == nil, let named = item.attributedTitle?.string, !named.isEmpty {
                title = named
            }
            for provider in item.attachments ?? [] {
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    url = address(try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier))
                } else if text == nil,
                          provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    text = plainText(try? await provider.loadItem(
                        forTypeIdentifier: UTType.plainText.identifier))
                }
            }
        }
        guard let url, url.scheme != "file" else {
            return ((text ?? title ?? "").trimmingCharacters(in: .whitespacesAndNewlines), nil, nil)
        }
        let label = (title ?? text)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label, !label.isEmpty, label != url.absoluteString else {
            return (url.absoluteString, url, nil)
        }
        return (link(label, url), url, label)
    }

    /// An item as iOS hands it over, a `URL`, or as macOS does, the
    /// address's bytes.
    static func address(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        guard let data = item as? Data else { return nil }
        return URL(dataRepresentation: data, relativeTo: nil)
    }

    static func plainText(_ item: NSSecureCoding?) -> String? {
        if let text = item as? String { return text }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Brackets in the title become parentheses rather than being escaped:
    /// `\[` is valid markdown, but not every editor reads a link around it,
    /// and a title reads the same either way.
    /// Line breaks become spaces too: a label with a blank line in it is
    /// not read as a link at all.
    public static func link(_ label: String, _ url: URL) -> String {
        let plain = label.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "[\(plain)](\(url.absoluteString))"
    }

    /// `text` with the link to `url` given `title` as its text, and any
    /// comment around it left alone. The link as it stands is
    /// `[anything](url)` or the bare address; a text holding neither, which
    /// the reader has rewritten, becomes the link.
    public static func retitled(_ text: String, url: URL, title: String) -> String {
        let replacement = link(title, url)
        var text = text
        if let range = linkRange(to: url, in: text) {
            text.replaceSubrange(range, with: replacement)
        } else if let range = text.range(of: url.absoluteString) {
            text.replaceSubrange(range, with: replacement)
        } else {
            text = replacement
        }
        return text
    }

    /// `text` with its link to `url` written as the bare address, for a
    /// share that should keep the address and no title.
    public static func unlinked(_ text: String, url: URL) -> String {
        guard let range = linkRange(to: url, in: text) else { return text }
        var text = text
        text.replaceSubrange(range, with: url.absoluteString)
        return text
    }

    /// The `[label](url)` link to `url`, from the `[` that balances the
    /// label's closing bracket: never further back, where the reader's own
    /// brackets or another link on the line begin.
    static func linkRange(to url: URL, in text: String) -> Range<String.Index>? {
        guard let tail = text.range(of: "](" + url.absoluteString + ")") else { return nil }
        var depth = 1
        var index = tail.lowerBound
        while index > text.startIndex {
            index = text.index(before: index)
            switch text[index] {
            case "]": depth += 1
            case "[":
                depth -= 1
                if depth == 0 { return index..<tail.upperBound }
            case "\n", "\r\n": return nil
            default: break
            }
        }
        return nil
    }
}
