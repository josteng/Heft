import Foundation

/// How large an embedded picture is drawn.
///
/// Obsidian writes the wanted size into the link — `![[shot.png|500]]`, or
/// `|500x300` for both — and it was ignored here, so a picture scaled down for
/// a note came out at whatever size it happened to be saved at.
public enum ImageDisplaySize {

    /// - Parameters:
    ///   - natural: the picture's own size.
    ///   - width: the width asked for in the link, if any.
    ///   - height: the height asked for in the link, if any.
    ///   - maxWidth: the room available.
    ///   - fills: whether a picture smaller than the room should grow into it.
    ///     True inside a table cell, where Obsidian fits the picture to the
    ///     column; false in prose, where a small picture stays small rather
    ///     than being blown up to the width of the page.
    public static func resolve(
        natural: CGSize,
        width: Int? = nil,
        height: Int? = nil,
        maxWidth: CGFloat,
        fills: Bool = false
    ) -> CGSize {
        guard natural.width > 0, natural.height > 0 else {
            return CGSize(width: maxWidth, height: maxWidth)
        }
        let aspect = natural.height / natural.width

        // A size in the link is what the reader asked for, and it wins over
        // the picture's own — that is the whole point of writing it.
        var wanted: CGSize
        switch (width, height) {
        case let (.some(w), .some(h)):
            wanted = CGSize(width: CGFloat(w), height: CGFloat(h))
        case let (.some(w), nil):
            wanted = CGSize(width: CGFloat(w), height: CGFloat(w) * aspect)
        case let (nil, .some(h)):
            wanted = CGSize(width: CGFloat(h) / aspect, height: CGFloat(h))
        case (nil, nil):
            wanted = fills
                ? CGSize(width: maxWidth, height: maxWidth * aspect)
                : natural
        }

        // Never wider than the room, whatever was asked for: a picture running
        // off the edge of the column is worse than a smaller picture.
        if wanted.width > maxWidth {
            wanted = CGSize(width: maxWidth, height: maxWidth * (wanted.height / wanted.width))
        }
        return CGSize(width: floor(wanted.width), height: floor(wanted.height))
    }
}
