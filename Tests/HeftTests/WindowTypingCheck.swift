import AppKit
import Darwin
import Foundation
import HeftCore
import SwiftUI
import Testing
@testable import Heft

/// What a held key costs with the whole window around the editor.
///
/// `TypingPerformanceCheck` measures the editor alone. The app around it can
/// cost more than the editor does: every view in the window observes the
/// model, so anything the model publishes per keystroke redraws the sidebar,
/// the calendar, the status bar and the toolbar for each character typed.
/// This hosts the real `ContentView` over a generated vault, types at the
/// cadence of a held key, and reports main-thread CPU as a share of wall
/// time, which is the figure Activity Monitor shows.
/// A copy of `WindowToolbarConfiguration`'s per-render behaviour, hosted on
/// its own to see what it costs.
private struct ProbeToolbarConfiguration: NSViewRepresentable {
    let registry: VaultRegistry
    let workspaceID: UUID
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.toolbar?.displayMode = .iconOnly
        window.toolbar?.allowsDisplayModeCustomization = false
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        registry.register(window: window, for: workspaceID)
    }
}

@MainActor
@Suite("Typing in the whole window", .serialized)
struct WindowTypingCheck {

    /// A vault big enough for the sidebar to have real rows.
    static func makeVault(notes: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heft-window-typing-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<notes {
            let body = "# Note \(index)\n\nLinks to [[Note \((index + 1) % notes)]] and #topic\(index % 7).\n"
            try body.write(
                to: folder.appendingPathComponent("Note \(index).md"), atomically: true, encoding: .utf8
            )
        }
        try TypingPerformanceCheck.realistic(sections: 24).write(
            to: root.appendingPathComponent("Long.md"), atomically: true, encoding: .utf8
        )
        return root
    }

    /// CPU time of the calling thread, in seconds.
    static func threadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(mach_thread_self(), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }

    /// Every view under `view`, counted by class, so a view added on each
    /// render shows up as a histogram that grows.
    static func viewHistogram(_ view: NSView) -> [String: Int] {
        var counts: [String: Int] = [:]
        func walk(_ v: NSView) {
            counts[String(describing: type(of: v)), default: 0] += 1
            v.subviews.forEach(walk)
        }
        walk(view)
        return counts
    }

    static func pump(until deadline: Date) {
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }

    struct Measurement {
        let keystrokes: Int
        let cadence: Double
        let cpuShare: Double
    }

    /// Types `keystrokes` characters into the open note at `cadence` seconds
    /// apart, draining the run loop between them as the app would.
    static func measure(keystrokes: Int, cadence: Double) throws -> Measurement {
        let root = try makeVault(notes: 300)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = NSApplication.shared
        let registry = VaultRegistry()
        let model = AppModel(
            registry: registry,
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Long.md")
        )
        let hosting = NSHostingView(
            rootView: ContentView().environmentObject(model).environmentObject(registry)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        pump(until: Date(timeIntervalSinceNow: 1.0))
        defer {
            model.closeWorkspace()
            window.orderOut(nil)
        }

        guard let textView = find(HeftTextKit2View.self, in: hosting) else {
            throw NSError(domain: "WindowTypingCheck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "the window never showed an editor",
            ])
        }
        window.makeFirstResponder(textView)
        let source = textView.string as NSString
        textView.setSelectedRange(NSRange(location: min(400, source.length), length: 0))
        pump(until: Date(timeIntervalSinceNow: 0.3))

        let cpuStart = threadCPU()
        let wallStart = Date()
        for _ in 0..<keystrokes {
            let pressed = Date()
            textView.insertText("d", replacementRange: textView.selectedRange())
            pump(until: pressed.addingTimeInterval(cadence))
        }
        // The restyle a burst defers lands after the last key.
        pump(until: Date(timeIntervalSinceNow: 0.2))
        let cpu = threadCPU() - cpuStart
        let wall = Date().timeIntervalSince(wallStart)
        return Measurement(keystrokes: keystrokes, cadence: cadence, cpuShare: cpu / wall)
    }

    /// What one publish on the model costs the window: every view observes
    /// it, so this is the price of an index change, a note switch, or any
    /// property that is published too eagerly.
    static func measurePublish(publishes: Int) throws -> PublishCost {
        let root = try makeVault(notes: 300)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let registry = VaultRegistry()
        let model = AppModel(
            registry: registry,
            descriptor: WorkspaceDescriptor(vaultPath: root.path, notePath: "Long.md")
        )
        // `HEFT_WINDOW_PART` hosts one part of the window on its own, which
        // is how a cost is attributed to the sidebar, the editor, or the
        // chrome around them.
        let part = ProcessInfo.processInfo.environment["HEFT_WINDOW_PART"] ?? "full"
        let rootView: AnyView
        switch part {
        case "sidebar": rootView = AnyView(SidebarView())
        case "editor": rootView = AnyView(EditorPane(topChromeHeight: 0))
        case "calendar": rootView = AnyView(CalendarPanel())
        default: rootView = AnyView(ContentView())
        }
        let hosting = NSHostingView(
            rootView: rootView.environmentObject(model).environmentObject(registry)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        pump(until: Date(timeIntervalSinceNow: 1.0))
        defer {
            model.closeWorkspace()
            window.orderOut(nil)
        }
        print("WINDOW part: \(part)")
        // What pumping alone costs, so the figure is the publish and not the
        // harness.
        let idleStart = threadCPU()
        pump(until: Date(timeIntervalSinceNow: 1.0))
        let idlePerSecond = threadCPU() - idleStart
        print(String(format: "WINDOW idle pump: %.1fms of main thread per second", idlePerSecond * 1000))

        // In batches, so a cost that grows with every publish shows as such
        // rather than hiding in an average.
        let batch = max(1, publishes / 3)
        var costs: [Double] = []
        var done = 0
        let viewsBefore = viewHistogram(hosting)
        defer {
            let viewsAfter = viewHistogram(hosting)
            var grown: [String] = []
            for (name, count) in viewsAfter where count > (viewsBefore[name] ?? 0) {
                grown.append("\(name) +\(count - (viewsBefore[name] ?? 0))")
            }
            let before = viewsBefore.values.reduce(0, +)
            let after = viewsAfter.values.reduce(0, +)
            let grownList = grown.sorted().joined(separator: ", ")
            print("WINDOW views: \(before) before, \(after) after; grown: \(grownList)")
        }
        while done < publishes {
            let count = min(batch, publishes - done)
            let cpuStart = threadCPU()
            for _ in 0..<count {
                model.objectWillChange.send()
                pump(until: Date(timeIntervalSinceNow: 0.05))
            }
            let spent = threadCPU() - cpuStart - idlePerSecond * 0.05 * Double(count)
            costs.append(spent / Double(count) * 1000)
            done += count
            print(String(format: "WINDOW after %d publishes: %.1fms each, %.0fMB resident", done, costs.last ?? 0, residentMB()))
        }
        print("WINDOW publish batches: " + costs.map { String(format: "%.1fms", $0) }.joined(separator: ", "))
        // For inspecting the process from outside while it is still alive:
        // `heap` and `sample` want a pid, and stdout only reaches a log at exit.
        if let hold = Double(ProcessInfo.processInfo.environment["HEFT_WINDOW_HOLD"] ?? "") {
            if let pidFile = ProcessInfo.processInfo.environment["HEFT_WINDOW_PIDFILE"] {
                try? "\(ProcessInfo.processInfo.processIdentifier)".write(
                    toFile: pidFile, atomically: true, encoding: .utf8
                )
            }
            pump(until: Date(timeIntervalSinceNow: hold))
        }
        return PublishCost(perPublish: costs.reduce(0, +) / Double(costs.count),
                           first: costs.first ?? 0, last: costs.last ?? 0)
    }

    struct PublishCost {
        let perPublish: Double
        let first: Double
        let last: Double
    }

    /// The window's toolbars used to be rebuilt on every publish and leaked
    /// each time, so the third batch here cost three times the first. The
    /// bound on growth is the guard for that; the bound on the cost itself
    /// is what an index change or a note switch may take.
    @Test("A publish on the model costs the same the hundredth time as the first")
    func publishCost() throws {
        let publishes = Int(ProcessInfo.processInfo.environment["HEFT_WINDOW_PUBLISHES"] ?? "") ?? 60
        let cost = try Self.measurePublish(publishes: publishes)
        print(String(format: "WINDOW publish: %.1fms of main thread each", cost.perPublish))
        // The leak grew the third batch by half over the first; a flat cost
        // varies by a millisecond or two between batches.
        #expect(cost.last <= cost.first * 1.15 + 3, "the cost of a publish must not grow with their number")
        #expect(cost.perPublish < 60)
    }

    @Test("A held key leaves most of a core free")
    func heldKey() throws {
        // Short by default: this holds the main thread for the duration, and
        // every other main-actor test in the suite waits behind it.
        let keystrokes = Int(ProcessInfo.processInfo.environment["HEFT_WINDOW_KEYSTROKES"] ?? "") ?? 60
        let sample = try Self.measure(keystrokes: keystrokes, cadence: 0.03)
        print(String(
            format: "WINDOW held key: %.0f%% of a core, %d keystrokes %.0fms apart",
            sample.cpuShare * 100, sample.keystrokes, sample.cadence * 1000
        ))
        #expect(sample.cpuShare < 0.5, "a held key must not take the whole core")
    }
}
