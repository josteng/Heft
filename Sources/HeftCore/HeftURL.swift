import Foundation

/// The `heft://` URLs the app answers to.
///
/// Two hosts, deliberately distinct. `follow` is internal: rendered text turns
/// a wikilink click back into a navigation. `open` comes from outside, and is
/// how the `heft` command line tool reaches an app that is already running —
/// arguments passed to `open --args` are dropped when the app is not being
/// launched fresh, which is the usual case, whereas a URL is delivered either
/// way.
public enum HeftURL {
    public static let scheme = "heft"

    public enum Host: String {
        case follow
        case open
    }

    /// The URL that asks Heft to open `path`.
    ///
    /// Percent encoding is what makes this safe for the paths this app deals
    /// with: an Obsidian vault lives under `Mobile Documents`, and a query
    /// value carrying a raw space produces a URL that does not parse.
    public static func open(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = Host.open.rawValue
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    /// The path an `open` URL is asking for, or nil for anything else.
    public static func openedPath(in url: URL) -> String? {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == Host.open.rawValue,
              let value = components.queryItems?
                  .first(where: { $0.name == "path" })?.value,
              !value.isEmpty
        else { return nil }
        return value
    }
}
