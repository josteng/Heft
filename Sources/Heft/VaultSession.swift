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

    init(root: URL) {
        self.root = root.standardizedFileURL
        settings = ObsidianSettings.load(vaultRoot: self.root)
        recentPaths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        reload()
        watcher = VaultWatcher(root: self.root) { [weak self] in
            self?.vaultDidChangeOnDisk()
        }
    }

    deinit {
        reloadTask?.cancel()
        watcher?.stop()
    }

    private var recentsKey: String {
        "dev.stenglein.Heft.recents.\(root.path)"
    }

    func recordRecent(_ relativePath: String) {
        recentPaths.removeAll { $0 == relativePath }
        recentPaths.insert(relativePath, at: 0)
        if recentPaths.count > 40 { recentPaths.removeLast(recentPaths.count - 40) }
        UserDefaults.standard.set(recentPaths, forKey: recentsKey)
    }

    func replaceRecentPath(_ oldPath: String, with newPath: String) {
        recentPaths = recentPaths.map { $0 == oldPath ? newPath : $0 }
        UserDefaults.standard.set(recentPaths, forKey: recentsKey)
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

    private var sessions: [String: WeakSession] = [:]
    private var documentOwners: [String: UUID] = [:]
    private var focusedFolders: [UUID: String] = [:]
    private var workspaceWindows: [UUID: WeakWindow] = [:]
    private static let lastVaultPathKey = "dev.stenglein.Heft.vaultPath"

    var lastVaultURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.lastVaultPathKey) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func session(for url: URL) -> VaultSession {
        let root = url.standardizedFileURL
        if let existing = sessions[root.path]?.value { return existing }
        let session = VaultSession(root: root)
        sessions[root.path] = WeakSession(session)
        UserDefaults.standard.set(root.path, forKey: Self.lastVaultPathKey)
        return session
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
