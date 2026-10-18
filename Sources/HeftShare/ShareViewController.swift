import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet's entry point: reads what was shared, then hands a line of
/// markdown to `ShareView`.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { @MainActor in
            let shared = await SharedContent.markdown(from: items)
            let host = UIHostingController(rootView: ShareView(
                initialText: shared.text,
                url: shared.url,
                pageTitle: shared.title,
                finish: { [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                },
                cancel: { [weak self] in
                    self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
                }
            ))
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }
}

/// What a share becomes in a note.
enum SharedContent {
    /// A page as `[Title](url)`, text as it came. Safari passes the page title
    /// as the item's content text; an app that shares only the address gets
    /// the bare URL, which Obsidian links as it is, and the sheet looks the
    /// title up.
    static func markdown(from items: [NSExtensionItem]) async
        -> (text: String, url: URL?, title: String?) {
        var url: URL?
        var text: String?
        var title: String?
        for item in items {
            if title == nil, let content = item.attributedContentText?.string, !content.isEmpty {
                title = content
            }
            for provider in item.attachments ?? [] {
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
                } else if text == nil,
                          provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    text = try? await provider.loadItem(
                        forTypeIdentifier: UTType.plainText.identifier) as? String
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

    /// Brackets in the title become parentheses rather than being escaped:
    /// `\[` is valid markdown, but not every editor reads a link around it,
    /// and a title reads the same either way.
    static func link(_ label: String, _ url: URL) -> String {
        let plain = label.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
        return "[\(plain)](\(url.absoluteString))"
    }
}
