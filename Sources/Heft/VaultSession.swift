import AppKit
import Combine
import Foundation
import HeftCore

/// Restorable identity for one workspace window. The UUID deliberately makes
/// two windows with the same vault and scope distinct SwiftUI windows.
struct WorkspaceDescriptor: Codable, Hashable {
    var id = UUID()
    var vaultPath: String? = nil
    var scopePath: String? = nil
    var notePath: String? = nil
    var calendarVisible: Bool? = nil
}

/// Vault-wide state shared by every window attached to the same root.
///
/// A vault gets exactly one scanner, index and FSEvents stream. Editor buffers,
/// navigation and chrome remain on `AppModel`, which is created once per window.
@MainActor
final class VaultSession: ObservableObject {
    let root: URL
    @Published private(set) var settings: ObsidianSettings
    @Published private(set) var tree: VaultItem?
    @Published private(set) var index = VaultIndex.empty
    @Published private(set) var isLoading = false
    @Published private(set) var diskChangeGeneration = 0
    @Published private(set) var recentPaths: [String] = []

    private var watcher: VaultWatcher?
    private var reloadTask: Task<Void, Never>?
    private var contentChangeObserver: NSObjectProtocol?

    init(root: URL) {
        self.root = root.standardizedFileURL
        settings = ObsidianSettings.load(vaultRoot: self.root)
        recentPaths = HeftDefaults.shared.stringArray(forKey: recentsKey) ?? []
        reload()
        watcher = VaultWatcher(root: self.root) { [weak self] in
            self?.vaultDidChangeOnDisk()
        }
        let rootPath = self.root.path
        contentChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: VaultContentChangeNotification.name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.object as? String == rootPath else { return }
            Task { @MainActor [weak self] in
                self?.vaultDidChangeOnDisk()
            }
        }
    }

    deinit {
        reloadTask?.cancel()
        watcher?.stop()
        if let contentChangeObserver {
            DistributedNotificationCenter.default().removeObserver(contentChangeObserver)
        }
    }

    private var recentsKey: String {
        "dev.stenglein.Heft.recents.\(root.path)"
    }

    /// How often each note is opened, discounted by how long ago.
    ///
    /// Kept alongside `recentPaths` rather than replacing it: the two answer
    /// different questions. The sidebar's Recent list is a history and has to
    /// stay in the order things happened; this is a ranking, and a note opened
    /// every morning should outrank one opened once by accident an hour ago.
    private(set) lazy var noteFrecency = FrecencyStore.notes(forVaultAt: root.path)

    func recordRecent(_ relativePath: String) {
        recentPaths.removeAll { $0 == relativePath }
        recentPaths.insert(relativePath, at: 0)
        if recentPaths.count > 40 { recentPaths.removeLast(recentPaths.count - 40) }
        HeftDefaults.shared.set(recentPaths, forKey: recentsKey)
        noteFrecency.record(relativePath)
    }

    func replaceRecentPath(_ oldPath: String, with newPath: String) {
        recentPaths = recentPaths.map { $0 == oldPath ? newPath : $0 }
        HeftDefaults.shared.set(recentPaths, forKey: recentsKey)
    }

    /// Coalesced because iCloud and atomic saves arrive as event bursts.
    func reload(immediately: Bool = false) {
        isLoading = true
        reloadTask?.cancel()
        let root = root
        reloadTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            let scanned = await Task.detached(priority: .userInitiated) { () -> (VaultItem, VaultIndex, ObsidianSettings) in
                let tree = VaultScanner.scan(root: root)
                return (tree, VaultIndex.build(root: tree), ObsidianSettings.load(vaultRoot: root))
            }.value
            guard !Task.isCancelled, let self else { return }
            tree = scanned.0
            index = scanned.1
            settings = scanned.2
            isLoading = false
        }
    }

    private func vaultDidChangeOnDisk() {
        diskChangeGeneration += 1
        reload()
    }
}

/// Owns shared vault sessions and exclusive editor leases.
@MainActor
final class VaultRegistry: ObservableObject {
    @Published var presentationModel: AppModel?
    private final class WeakSession {
        weak var value: VaultSession?
        init(_ value: VaultSession) { self.value = value }
    }

    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ value: NSWindow) { self.value = value }
    }

    private final class WeakModel {
        weak var value: AppModel?
        init(_ value: AppModel) { self.value = value }
    }

    private var sessions: [String: WeakSession] = [:]
    private var documentOwners: [String: UUID] = [:]
    private var focusedFolders: [UUID: String] = [:]
    private var workspaceWindows: [UUID: WeakWindow] = [:]
    private var workspaceModels: [UUID: WeakModel] = [:]
    private var windowOpeners: [UUID: (WorkspaceDescriptor) -> Void] = [:]
    var lastVaultURL: URL? {
        CaptureVaultPreference.url
    }

    static let recentVaultsKey = "dev.stenglein.Heft.recentVaults"

    /// Every vault opened, most recent first. Stored as written; what is
    /// still *there* is decided at read time by `recentVaults`.
    @Published private(set) var recentVaultPaths: [String] =
        HeftDefaults.shared.stringArray(forKey: VaultRegistry.recentVaultsKey) ?? []

    /// The recents that can actually be opened right now.
    ///
    /// A vault in iCloud Drive can be evicted, moved or renamed between
    /// sessions, and a menu entry that errors when clicked is worse than one
    /// that is not offered. The stored list is left alone, so a vault on a
    /// volume that comes back is not forgotten for having been away.
    var recentVaults: [(url: URL, label: String)] {
        let live = recentVaultPaths.filter {
            FileManager.default.fileExists(atPath: $0)
        }
        return zip(live, RecentVaults.labels(for: live)).map {
            (URL(fileURLWithPath: $0, isDirectory: true), $1)
        }
    }

    func clearRecentVaults() {
        recentVaultPaths = []
        HeftDefaults.shared.removeObject(forKey: Self.recentVaultsKey)
    }

    func session(for url: URL) -> VaultSession {
        let root = url.standardizedFileURL
        // Recorded before the early return: reopening a vault that is already
        // running has to promote it too, or the pair being switched between
        // never reorders.
        recordRecentVault(root.path)
        if let existing = sessions[root.path]?.value { return existing }
        let session = VaultSession(root: root)
        sessions[root.path] = WeakSession(session)
        HeftDefaults.shared.set(root.path, forKey: CaptureVaultPreference.defaultsKey)
        return session
    }

    private func recordRecentVault(_ path: String) {
        let updated = RecentVaults.recording(path, in: recentVaultPaths)
        guard updated != recentVaultPaths else { return }
        recentVaultPaths = updated
        HeftDefaults.shared.set(updated, forKey: Self.recentVaultsKey)
    }

    func activeSession(containing url: URL) -> VaultSession? {
        let path = url.standardizedFileURL.path
        return sessions.values.compactMap(\.value)
            .filter { path == $0.root.path || path.hasPrefix($0.root.path + "/") }
            .max { $0.root.path.count < $1.root.path.count }
    }

    func activeSession(nestedInside url: URL) -> VaultSession? {
        let path = url.standardizedFileURL.path
        return sessions.values.compactMap(\.value).first {
            $0.root.path.hasPrefix(path + "/")
        }
    }

    enum VaultOpenResolution {
        case open(WorkspaceDescriptor)
        case overlapping(vaultName: String)
    }

    /// Shared by every "open this folder as a vault" entry point (the File
    /// menu's Open Vault in New Window, and the toolbar scope picker falling
    /// back to it for a folder outside the current vault) so they agree on
    /// reusing an already-open containing vault versus refusing a nested one.
    func resolveOpen(for url: URL) -> VaultOpenResolution {
        let chosen = url.standardizedFileURL
        if let containing = activeSession(containing: chosen) {
            let root = containing.root.path
            let scope = chosen.path == root ? nil : String(chosen.path.dropFirst(root.count + 1))
            return .open(WorkspaceDescriptor(vaultPath: root, scopePath: scope))
        }
        if let nested = activeSession(nestedInside: chosen) {
            return .overlapping(vaultName: nested.root.lastPathComponent)
        }
        return .open(WorkspaceDescriptor(vaultPath: chosen.path))
    }

    /// Opens whatever `path` names, for the `heft` command line tool.
    ///
    /// The rule is `resolveOpen`'s, so a path means the same thing here as it
    /// does everywhere else in the app: inside a vault that is already open it
    /// focuses a window on that folder, and otherwise the folder becomes a
    /// vault of its own. A window already showing that vault and folder is
    /// raised rather than duplicated, because `heft .` twice in a terminal
    /// should not leave two identical windows.
    ///
    /// Returns false when there is nothing to open or no window to open it
    /// with, which is what tells `IntentNavigation` to hold the request until
    /// a workspace exists.
    @discardableResult
    func openPath(_ path: String) -> Bool {
        guard let normalized = PathInput.normalize(path) else { return false }
        let url = URL(fileURLWithPath: normalized).standardizedFileURL

        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            return false
        }

        // A note in a vault that is already open belongs in one of its
        // windows, which is exactly what the App Intent route works out.
        if !isFolder.boolValue, let session = activeSession(containing: url),
           openFromIntent(url, in: session.root) {
            return true
        }

        let folder = isFolder.boolValue ? url : url.deletingLastPathComponent()
        guard case .open(var descriptor) = resolveOpen(for: folder) else { return false }
        if !isFolder.boolValue {
            let root = descriptor.vaultPath ?? folder.path
            descriptor.notePath = url.path.hasPrefix(root + "/")
                ? String(url.path.dropFirst(root.count + 1))
                : url.lastPathComponent
        }

        if descriptor.notePath == nil, let owner = window(showing: descriptor) {
            focusWindow(owner: owner)
            return true
        }
        guard let opener = preferredWindowOpener() else { return false }
        opener(descriptor)
        return true
    }

    /// An open window already on the same vault and focused folder.
    private func window(showing descriptor: WorkspaceDescriptor) -> UUID? {
        workspaceModels.first { _, weakModel in
            guard let model = weakModel.value else { return false }
            return model.vaultRoot?.standardizedFileURL.path == descriptor.vaultPath
                && model.scopePath == descriptor.scopePath
        }?.key
    }

    func claim(_ url: URL, for owner: UUID) -> Bool {
        let path = url.standardizedFileURL.path
        if let current = documentOwners[path], current != owner { return false }
        documentOwners[path] = owner
        return true
    }

    func release(_ url: URL, for owner: UUID) {
        let path = url.standardizedFileURL.path
        if documentOwners[path] == owner { documentOwners.removeValue(forKey: path) }
    }

    func releaseAll(for owner: UUID) {
        documentOwners = documentOwners.filter { $0.value != owner }
        focusedFolders.removeValue(forKey: owner)
        workspaceWindows.removeValue(forKey: owner)
        workspaceModels.removeValue(forKey: owner)
        windowOpeners.removeValue(forKey: owner)
    }

    func register(
        model: AppModel,
        openWindow: @escaping (WorkspaceDescriptor) -> Void
    ) {
        workspaceModels[model.workspaceID] = WeakModel(model)
        windowOpeners[model.workspaceID] = openWindow
    }

    func register(window: NSWindow, for owner: UUID) {
        workspaceWindows[owner] = WeakWindow(window)
    }

    /// Brings forward the window that already owns the note's writable buffer.
    /// Returns false only when a stale lease has outlived its window.
    func focusWindowEditing(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard let owner = documentOwners[path] else { return false }
        guard let window = workspaceWindows[owner]?.value else {
            documentOwners.removeValue(forKey: path)
            workspaceWindows.removeValue(forKey: owner)
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Opens an intent target in the best existing workspace. A focused-folder
    /// window is eligible only when the target lies inside its scope; otherwise
    /// the action creates a new full-vault window instead of changing that
    /// window's browsing boundary behind the user's back.
    func openFromIntent(_ url: URL, in vaultRoot: URL) -> Bool {
        let target = url.standardizedFileURL
        let root = vaultRoot.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return false }

        if documentOwners[target.path] != nil, focusWindowEditing(target) {
            return true
        }

        guard let targetRef = NoteRef(url: target, vaultRoot: root) else { return false }
        let relativePath = String(target.path.dropFirst(root.path.count + 1))
        let eligible = workspaceModels.compactMap { owner, weakModel -> (UUID, AppModel)? in
            guard let model = weakModel.value,
                  model.vaultRoot?.standardizedFileURL == root,
                  model.isInScope(targetRef) else { return nil }
            return (owner, model)
        }

        let ordered = eligible.sorted { lhs, rhs in
            intentWindowScore(owner: lhs.0) > intentWindowScore(owner: rhs.0)
        }
        for (owner, model) in ordered {
            model.open(targetRef)
            guard model.current?.url.standardizedFileURL == target else { continue }
            focusWindow(owner: owner)
            return true
        }

        guard let opener = preferredWindowOpener() else { return false }
        opener(WorkspaceDescriptor(vaultPath: root.path, notePath: relativePath))
        return true
    }

    private func intentWindowScore(owner: UUID) -> Int {
        guard let window = workspaceWindows[owner]?.value else { return 0 }
        if window.isKeyWindow { return 2 }
        if window.isMainWindow { return 1 }
        return 0
    }

    private func preferredWindowOpener() -> ((WorkspaceDescriptor) -> Void)? {
        if let keyOwner = workspaceWindows.first(where: { $0.value.value?.isKeyWindow == true })?.key,
           let opener = windowOpeners[keyOwner] {
            return opener
        }
        return windowOpeners.values.first
    }

    private func focusWindow(owner: UUID) {
        guard let window = workspaceWindows[owner]?.value else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func updateFocus(root: URL, scopePath: String?, for owner: UUID) {
        guard let scopePath else {
            focusedFolders.removeValue(forKey: owner)
            return
        }
        focusedFolders[owner] = root.appendingPathComponent(scopePath).standardizedFileURL.path
    }

    func isFocusedByAnotherWindow(_ folder: URL, excluding owner: UUID) -> Bool {
        let path = folder.standardizedFileURL.path
        return focusedFolders.contains { candidateOwner, candidate in
            candidateOwner != owner && (candidate == path || candidate.hasPrefix(path + "/"))
        }
    }

    func isClaimedByAnotherWindow(_ url: URL, excluding owner: UUID, includingDescendants: Bool = false) -> Bool {
        let path = url.standardizedFileURL.path
        return documentOwners.contains { candidate, candidateOwner in
            guard candidateOwner != owner else { return false }
            return candidate == path || (includingDescendants && candidate.hasPrefix(path + "/"))
        }
    }
}
