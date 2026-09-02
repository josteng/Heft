import Foundation

/// Turns a pasted path into one the filesystem will accept.
///
/// A path copied anywhere near a terminal is quoted for a *shell*, not for the
/// filesystem. Dragging a file into Terminal, and Finder's own path copying,
/// both hand over
/// `/Users/me/Library/Mobile\ Documents/iCloud\~md\~obsidian/…`. Those
/// backslashes are shell syntax: they exist so the shell does not split the
/// argument at the space. A real POSIX path has a plain space, and `~` inside
/// a name is an ordinary character, so pasting that text into a file panel
/// asks for a folder literally called `Mobile\ Documents` and fails.
///
/// Everything here is about accepting what the clipboard actually holds, in
/// any of the forms it arrives in, rather than the one form that happens to be
/// canonical.
public enum PathInput {

    /// The path `raw` refers to, or nil when it says nothing.
    ///
    /// `home` is injected so the tilde rule can be tested without depending on
    /// who is running the tests.
    public static func normalize(_ raw: String, home: String = NSHomeDirectory()) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Some apps put a URL on the clipboard rather than a path. Its
        // percent-encoding is undone by URL itself, and a URL never carries
        // shell escaping, so the two forms are handled apart.
        if text.hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            text = url.path
        } else {
            text = unquoted(text)
            text = unescaped(text)
        }

        // Only a *leading* tilde is the home directory. `iCloud~md~obsidian`
        // is a real folder in an Obsidian vault's path and must survive.
        if text == "~" {
            text = home
        } else if text.hasPrefix("~/") {
            text = home + text.dropFirst()
        }

        // Finder writes a folder with a trailing separator; nothing that
        // compares this against a vault root wants one.
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }

        return text.isEmpty ? nil : text
    }

    /// Strips one matching pair of surrounding quotes, which is how a path
    /// with spaces is pasted out of a script or a chat message.
    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        for quote in ["\"", "'"] where text.hasPrefix(quote) && text.hasSuffix(quote) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    /// Drops shell escaping: a backslash means "the next character is
    /// literal", which is exactly what the filesystem wanted all along.
    private static func unescaped(_ text: String) -> String {
        var result = ""
        var isEscaped = false
        for character in text {
            if isEscaped {
                result.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        // A trailing lone backslash escapes nothing, so it is part of the name.
        if isEscaped { result.append("\\") }
        return result
    }
}
