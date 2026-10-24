import SwiftUI
import UIKit

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
