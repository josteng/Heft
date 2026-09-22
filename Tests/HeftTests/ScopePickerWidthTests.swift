import AppKit
import Foundation
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// The scope picker sits between the traffic lights and the sidebar toggle,
/// and a toolbar item wider than that room is not squeezed but moved to the
/// overflow menu at the far end of the window, taking the picker away and
/// sliding the toggle left. Its ideal width is what the toolbar lays out.
@MainActor
@Suite("The scope picker fits above the sidebar", .serialized)
struct ScopePickerWidthTests {

    static let longFolder = "A Folder With An Unusually Long Name For A Sidebar"

    static func model() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-scope-picker-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(longFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Start".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        try "Inside".write(to: folder.appendingPathComponent("Inside.md"), atomically: true, encoding: .utf8)
        let model = AppModel(
            registry: VaultRegistry(),
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Note.md")
        )
        return (model, root)
    }

    /// The width the toolbar would give the picker.
    static func idealWidth(_ model: AppModel, sidebar: CGFloat) -> CGFloat {
        let column = SidebarColumn()
        column.update(width: sidebar)
        let host = NSHostingView(rootView: WorkspaceScopePicker(column: column).environmentObject(model))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    @Test("A long folder name stays within the room beside the window controls")
    func longNameIsCapped() throws {
        let (model, root) = try Self.model()
        defer {
            model.closeWorkspace()
            try? FileManager.default.removeItem(at: root)
        }
        model.setScope(to: VaultItem(
            url: root.appendingPathComponent(Self.longFolder, isDirectory: true),
            relativePath: Self.longFolder, kind: .folder, name: Self.longFolder
        ))
        try #require(model.scopeName == Self.longFolder)

        for sidebar in [SidebarColumn.minWidth, 300, 380] {
            let room = sidebar - SidebarColumn.windowControlsWidth
            let width = Self.idealWidth(model, sidebar: sidebar)
            #expect(width <= room, "at \(sidebar) the picker asks for \(width) of \(room)")
        }
    }

    /// The split view whose first column is the sidebar; the inspector
    /// wraps it in another one.
    static func sidebarSplit(in view: NSView) -> (NSSplitView, NSSplitViewItem)? {
        if let split = view as? NSSplitView,
           let item = (split.delegate as? NSSplitViewController)?.splitViewItems.first,
           item.behavior == .sidebar {
            return (split, item)
        }
        for subview in view.subviews {
            if let found = sidebarSplit(in: subview) { return found }
        }
        return nil
    }

    /// The minimum is only a request: a modifier wrapped around the one that
    /// sets it once hid it from the split view, and the sidebar could be
    /// dragged to 140, where the picker went to the overflow menu again.
    @Test("The sidebar cannot be dragged narrower than its minimum")
    func minimumIsEnforced() throws {
        _ = NSApplication.shared
        let (model, root) = try Self.model()
        let registry = VaultRegistry()
        let hosting = NSHostingView(
            rootView: ContentView().environmentObject(model).environmentObject(registry)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            model.closeWorkspace()
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))

        let (split, sidebar) = try #require(Self.sidebarSplit(in: hosting))
        #expect(sidebar.viewController.view.frame.width > 0, "the sidebar never opened")
        split.setPosition(100, ofDividerAt: 0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        let width = sidebar.viewController.view.frame.width
        #expect(width == 0 || width >= SidebarColumn.minWidth, "the sidebar went to \(width)")
    }

    @Test("All Notes is shown in full at the narrowest sidebar")
    func allNotesFitsAtMinimum() throws {
        let (model, root) = try Self.model()
        defer {
            model.closeWorkspace()
            try? FileManager.default.removeItem(at: root)
        }
        let unconstrained = Self.idealWidth(model, sidebar: 2000)
        let narrowest = Self.idealWidth(model, sidebar: SidebarColumn.minWidth)
        #expect(narrowest == unconstrained, "cut to \(narrowest) from \(unconstrained)")
    }
}

/// The scope picker is a menu on a click and the window's root folder on a
/// drag. The press is fed its events directly; see `HandleView.track`.
@MainActor
@Suite("The scope picker drags out its folder")
struct ScopePickerDragTests {

    static func press(moving distance: CGFloat) -> (clicked: Bool, dragged: URL?) {
        let handle = ScopeMenuHandle.HandleView(frame: NSRect(x: 0, y: 0, width: 96, height: 28))
        handle.folder = URL(fileURLWithPath: "/tmp/Example Vault", isDirectory: true)
        var result: (clicked: Bool, dragged: URL?) = (false, nil)
        handle.clicked = { result.clicked = true }
        handle.dragged = { folder, _ in result.dragged = folder }

        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        var queue = [event(.leftMouseUp, x: 20)]
        if distance > 0 { queue.insert(event(.leftMouseDragged, x: 20 + distance), at: 0) }
        handle.track(from: event(.leftMouseDown, x: 20)) { queue.isEmpty ? nil : queue.removeFirst() }
        return result
    }

    @Test("A drag carries the window's root folder, not the menu")
    func dragCarriesFolder() {
        let result = Self.press(moving: 12)
        #expect(result.dragged?.lastPathComponent == "Example Vault")
        #expect(!result.clicked)
    }

    @Test("A click, or a press that barely moves, opens the menu")
    func clickOpensMenu() {
        for distance: CGFloat in [0, 2] {
            let result = Self.press(moving: distance)
            #expect(result.clicked, "moved \(distance)")
            #expect(result.dragged == nil, "moved \(distance)")
        }
    }

    @Test("Pressing the picker cannot move the window")
    func doesNotMoveWindow() {
        #expect(!ScopeMenuHandle.HandleView().mouseDownCanMoveWindow)
    }
}
