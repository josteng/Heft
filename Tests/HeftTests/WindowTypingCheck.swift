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
