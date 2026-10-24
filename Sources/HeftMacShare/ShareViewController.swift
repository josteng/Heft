import AppKit
import SwiftUI

/// The Mac share sheet's entry point, as `HeftShare`'s is the phone's: the
/// shared items go to `ShareView`, which reads them itself so the sheet opens
/// at once rather than after the items load.
///
/// Sandboxed because macOS runs no extension that is not; the entitlements
/// let the vault and the app's preferences back in, as for `HeftCapture`.
/// So unlike the phone's, a share here is filed straight into the vault and
/// never queued.
final class ShareViewController: NSViewController {
    override func loadView() {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let host = NSHostingController(rootView: ShareView(
            items: items,
            finish: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            cancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        ))
        addChild(host)
        let container = NSView()
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // The share sheet takes this size when it opens and keeps it, so
        // the view is laid out to one size whatever it later shows; a view
        // without a frame is shown as no sheet at all.
        container.frame = NSRect(origin: .zero, size: host.view.fittingSize)
        preferredContentSize = container.frame.size
        view = container
    }
}
