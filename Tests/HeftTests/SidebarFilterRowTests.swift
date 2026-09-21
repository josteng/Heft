import AppKit
import Foundation
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// The sidebar's filter field and the menu beside it sit in one row, and the
/// three modes fill that row differently: Files creates, Recent orders, Tags
/// does neither and takes the width instead. Laying the row out per mode is
/// the only way to see that the field lands where it should, which is what
/// the eye notices when tabbing between modes.
@MainActor
@Suite("The sidebar's filter row", .serialized)
struct SidebarFilterRowTests {

    /// The row as the sidebar builds it, laid out at a sidebar's width.
    static func host(_ mode: SidebarMode, model: AppModel) -> NSHostingView<some View> {
        var text = ""
        let row = SidebarFilterRow(
            mode: mode,
            filter: Binding(get: { text }, set: { text = $0 }),
            creationTargetName: "Vault",
            onNewNote: {},
            onNewFolder: {}
        )
        .environmentObject(model)
        let host = NSHostingView(rootView: row)
        host.frame = CGRect(x: 0, y: 0, width: 250, height: 40)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// SwiftUI's plain text field is an AppKit view underneath, so its frame
    /// is the field's real width rather than a number this test computes.
    static func frame(matching name: String, in view: NSView) -> CGRect? {
        if String(describing: type(of: view)).contains(name) {
            return view.convert(view.bounds, to: nil)
        }
        for subview in view.subviews {
            if let found = frame(matching: name, in: subview) { return found }
        }
        return nil
    }

    static func model() throws -> (AppModel, VaultRegistry, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-filter-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Start".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let registry = VaultRegistry()
        let model = AppModel(
            registry: registry,
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
        registry.register(model: model) { _ in }
        return (model, registry, root)
    }

    @Test("The filter field does not move between the modes that have a menu")
    func fieldDoesNotMoveBetweenModes() throws {
        let (model, _, root) = try Self.model()
        defer {
            model.closeWorkspace()
            try? FileManager.default.removeItem(at: root)
        }
        try #require(model.scopeRoot != nil, "the Files mode's menu needs a vault to create in")

        var frames: [SidebarMode: CGRect] = [:]
        for mode in SidebarMode.allCases {
            let host = Self.host(mode, model: model)
            frames[mode] = try #require(
                Self.frame(matching: "TextField", in: host),
                "no text field laid out in \(mode)"
            )
        }
        let files = try #require(frames[.files])
        #expect(frames[.recent] == files, "Recent puts the field at \(frames[.recent]!), Files at \(files)")

        // Tags has nothing to create and nothing to order, so it gets the
        // menu's square and the gap beside it, and not a pixel more.
        let tags = try #require(frames[.tags])
        #expect(tags.origin == files.origin)
        #expect(
            tags.width == files.width + SidebarFilterRow.controlSize + SidebarFilterRow.spacing,
            "Tags gives the field \(tags.width), Files \(files.width)"
        )
    }

    @Test("The menu is the same button whichever mode draws it")
    func theMenuKeepsItsSize() throws {
        let (model, _, root) = try Self.model()
        defer {
            model.closeWorkspace()
            try? FileManager.default.removeItem(at: root)
        }

        let plus = try #require(Self.frame(matching: "FocusRing", in: Self.host(.files, model: model)))
        let arrows = try #require(Self.frame(matching: "FocusRing", in: Self.host(.recent, model: model)))
        #expect(plus == arrows, "the plus is \(plus.size), the arrows are \(arrows.size)")
    }
}
