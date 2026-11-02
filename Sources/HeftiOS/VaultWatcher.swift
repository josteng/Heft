import Foundation
import UIKit

/// Hears about notes changed on another device while Heft is open.
///
/// iOS has no FSEvents, and a rescan on launch and on returning to the
/// foreground missed every change made while the app stayed in front: a note
/// edited on the Mac kept its old place in Recent, and an open note its old
/// text, until something else rescanned. As a file presenter for the vault
/// folder this is told when something in it changes, which iCloud's writes
/// do: traced on a phone, a note saved on the Mac was heard as soon as it
/// came down. Once a minute while the app is in front each note is also
/// asked whether iCloud has a newer version, in case a change is ever not
/// presented; more often would only spend battery, as the wait is iCloud's. A note that has is fetched, and `changed`
/// runs once it is here, for the vault to rescan; the rescan moves Recent,
/// and the open note re-reads itself on every scan that lands, merging into
/// unsaved typing as it does for any change from elsewhere.
///
/// A Spotlight metadata query was the first try: on a phone it gathered no
/// notes at all for a vault in another app's iCloud folder.
@MainActor
final class VaultWatcher: NSObject {
    private let root: URL
    private let notes: () -> [URL]
    private let changed: () -> Void
    private var presenter: Presenter?
    private var polling: Task<Void, Never>?
    private var pending: Task<Void, Never>?

    /// How often the notes are asked whether iCloud has newer versions.
    private static let interval: Duration = .seconds(60)

    init(root: URL, notes: @escaping () -> [URL], changed: @escaping () -> Void) {
        self.root = root
        self.notes = notes
        self.changed = changed
    }

    func start() {
        guard presenter == nil else { return }
        let presenter = Presenter(url: root) { [weak self] url in
            Task { @MainActor in self?.heard(url) }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self, !Task.isCancelled else { return }
                if UIApplication.shared.applicationState == .active { await self.check() }
            }
        }
    }

    func stop() {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
        polling?.cancel()
        pending?.cancel()
    }

    /// The file presenter's news: something in the vault changed.
    private func heard(_ url: URL) {
        if Self.isOutdated(url) { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        rescanSoon(after: .milliseconds(800))
    }

    /// Every note asked whether iCloud has a newer version; those that have
    /// are fetched, and the vault rescanned once they can have arrived.
    private func check() async {
        let urls = notes()
        let outdated = await Task.detached(priority: .utility) {
            urls.filter { url in
                var fresh = url
                fresh.removeAllCachedResourceValues()
                return VaultWatcher.isOutdated(fresh)
            }
        }.value
        guard !outdated.isEmpty else { return }
        for url in outdated { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        rescanSoon(after: .seconds(3))
    }

    private func rescanSoon(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.changed()
        }
    }

    nonisolated static func isOutdated(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true,
              let status = values.ubiquitousItemDownloadingStatus
        else { return false }
        return status != .current
    }

    /// The vault folder, presented: iCloud writes what it brings down under
    /// file coordination, which tells a folder's presenters which item
    /// changed.
    private final class Presenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue.main
        private let heard: @Sendable (URL) -> Void

        init(url: URL, heard: @escaping @Sendable (URL) -> Void) {
            presentedItemURL = url
            self.heard = heard
        }

        func presentedSubitemDidChange(at url: URL) { heard(url) }
        func presentedSubitemDidAppear(at url: URL) { heard(url) }
        func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { heard(newURL) }
    }
}
