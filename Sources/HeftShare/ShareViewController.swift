import LinkPresentation
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
                untitledURL: shared.untitledURL,
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
    /// the bare URL, which Obsidian links as it is, and `untitledURL` so the
    /// sheet can look the title up.
    static func markdown(from items: [NSExtensionItem]) async -> (text: String, untitledURL: URL?) {
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
            return ((text ?? title ?? "").trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let label = (title ?? text)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label, !label.isEmpty, label != url.absoluteString else {
            return (url.absoluteString, url)
        }
        return (link(label, url), nil)
    }

    static func link(_ label: String, _ url: URL) -> String {
        let escaped = label.replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](\(url.absoluteString))"
    }

    /// The page's title, or nil if it does not come quickly.
    static func title(of url: URL) async -> String? {
        let provider = LPMetadataProvider()
        provider.timeout = 4
        let title = try? await provider.startFetchingMetadata(for: url).title
        return title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
