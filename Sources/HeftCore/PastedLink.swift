import Foundation

/// A web address just pasted on its own, and the link it can become:
/// `https://example.com/post` as `[The post's title](https://example.com/post)`.
///
/// The editor offers the page's title, short versions of it and the site's
/// name in the completion menu; this is the part that says whether a paste
/// is such an address and what accepting a title writes.
public struct PastedLink: Equatable, Sendable {
    /// Where the address now sits in the note.
    public let range: NSRange
    public let address: String

    public init(range: NSRange, address: String) {
        self.range = range
        self.address = address
    }

    /// The address `pasted` became once inserted at `location`, when it is a
    /// single web address written as plain text. Not inside code, where it
    /// is an example, and not where it is already part of a link: after
    /// `](` or `<`, or inside `[[ ]]`.
    public static func after(pasting pasted: String, at location: Int, in source: String) -> Self? {
        let address = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        // A copied address may bring a line break with it, and nothing else.
        guard pasted.trimmingCharacters(in: .newlines) == address,
              !address.contains(where: \.isWhitespace),
              MarkdownEditing.isWebAddress(address)
        else { return nil }
        let text = source as NSString
        let range = NSRange(location: location, length: (address as NSString).length)
        guard NSMaxRange(range) <= text.length, text.substring(with: range) == address else { return nil }

        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: location - line.location))
        guard before.filter({ $0 == "`" }).count % 2 == 0,
              !before.hasSuffix("("), !before.hasSuffix("<"),
              before.components(separatedBy: "[[").count == before.components(separatedBy: "]]").count,
              !HighlightCompletionContext.isInsideFence(line.location, in: source)
        else { return nil }
        return Self(range: range, address: address)
    }

    /// Whether the address is still there as pasted, with the caret right
    /// after it: anything typed or moved since means the moment has passed.
    public func isCurrent(in source: String, caret: NSRange) -> Bool {
        let text = source as NSString
        return caret.length == 0 && caret.location == NSMaxRange(range)
            && NSMaxRange(range) <= text.length && text.substring(with: range) == address
    }

    /// The site's own name, `example.com`, offered before any title arrives.
    public var siteName: String {
        guard let host = URL(string: address)?.host?.lowercased() else { return address }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The edit that turns the address into a link reading `text`.
    public func linking(_ text: String) -> MarkdownEditing.Edit {
        // A bracket in a title would end the link text early.
        let escaped = text
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let link = MarkdownEditing.link(text: escaped, to: address)
        return MarkdownEditing.Edit(
            range: range, replacement: link,
            selection: NSRange(location: range.location + (link as NSString).length, length: 0)
        )
    }

    /// A page's title as a link should read: one line, its spaces
    /// collapsed, and nil when there is nothing usable.
    public static func cleanedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let words = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty, words.count <= 300 else { return nil }
        return words
    }
}
