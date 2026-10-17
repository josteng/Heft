import Foundation
import FoundationModels
import HeftCore
import LinkPresentation

/// Titles for a pasted web address: the page's own, read the way Messages
/// reads a link preview, and short versions from Apple's on-device model,
/// offered as the rename field offers names.
///
/// Fetching the title loads the page, so the site sees a visit; that is
/// why it sits behind a setting. The short titles never leave the Mac, and
/// without Apple Intelligence there are none.
enum LinkTitles {
    static func pageTitle(_ url: URL) async -> String? {
        let provider = LPMetadataProvider()
        // The title is all that is wanted; no icon, no preview image.
        provider.shouldFetchSubresources = false
        provider.timeout = 6
        return try? await provider.startFetchingMetadata(for: url).title
    }

    static func shortTitles(_ title: String, _ url: URL) async -> [String] {
        guard case .available = SystemLanguageModel.default.availability else { return [] }
        let session = LanguageModelSession(
            instructions: "You shorten web page titles into link text for notes. Reply with exactly "
                + "three alternatives, one per line, each two to six words, in the title's "
                + "language, saying what the page is about. Leave out the site's name and section. "
                + "No numbering, no quotes, no full stop."
        )
        let prompt = "Page title: \(title)\nAddress: \(url.absoluteString)"
        guard let response = try? await session.respond(to: prompt) else { return [] }
        return cleaned(response.content, avoiding: [title])
    }

    /// One title a line, without list marks or quotes, each once and none
    /// a repeat of what is already offered.
    static func cleaned(_ text: String, avoiding taken: [String]) -> [String] {
        var seen = Set(taken.map { $0.lowercased() })
        var titles: [String] = []
        for line in text.split(separator: "\n") {
            let title = String(line)
                .replacingOccurrences(of: #"^\s*(\d+[.)]|[-*•])\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”‘’*_#."))
            guard !title.isEmpty, title.count <= 80, seen.insert(title.lowercased()).inserted else { continue }
            titles.append(title)
        }
        return Array(titles.prefix(3))
    }
}

/// The rows the completion menu offers for one pasted address, as they
/// arrive: the site's name at once, the page's title above it when it
/// loads, short titles below. No row keeps the address as it is: typing on,
/// Escape or a click does that, as it closes every completion menu.
struct LinkTitleSession {
    let id = UUID()
    let link: PastedLink
    var pageTitle: String?
    var shortTitles: [String] = []
    /// Set once the arrow keys moved, so a title arriving later does not
    /// take the selection away from the row that was chosen.
    var userMoved = false

    init(link: PastedLink) {
        self.link = link
    }

    var items: [WikiCompletionItem] {
        var rows: [WikiCompletionItem] = []
        if let pageTitle {
            rows.append(WikiCompletionItem(
                title: pageTitle, detail: "Page title", symbol: "textformat", destination: pageTitle
            ))
        }
        let site = link.siteName
        if site.lowercased() != pageTitle?.lowercased() {
            rows.append(WikiCompletionItem(title: site, detail: "Site name", symbol: "globe", destination: site))
        }
        for title in shortTitles {
            rows.append(WikiCompletionItem(
                title: title, detail: "Short title", symbol: "sparkles", destination: title
            ))
        }
        return rows
    }
}
