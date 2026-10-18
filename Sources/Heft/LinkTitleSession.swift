import Foundation
import HeftCore

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
