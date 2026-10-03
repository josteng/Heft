import AppKit
import HeftCore
import SwiftUI

/// Renaming under the title: one of three places, kept alike with the others
/// listed at `AppModel.rename`.
///
/// Rename the open note from the window's title, as TextEdit and Preview
/// do: a click on the title opens a small popover with its name.
///
/// The title stays AppKit's own, because the document icon beside it is too:
/// it drags as the file, and ⌘-click walks up its folders. SwiftUI's editable
/// title (`navigationTitle` with a binding) and its title menu are not shown
/// for a window that is not a document's on macOS 26, checked by asking the
/// accessibility API what the title was. So a click inside AppKit's title
/// label, found by its text in the window's frame, opens it. If a later macOS
/// draws the title some other way, the click does nothing and Rename Note
/// still opens the popover, under the title or the dialog in its place.
struct TitleClickToRename: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.model = model
        // After this pass: the title has its new text once SwiftUI has set it.
        DispatchQueue.main.async { context.coordinator.window = view.window }
        if model.titleRenameRequest != context.coordinator.handledRequest {
            context.coordinator.handledRequest = model.titleRenameRequest
            DispatchQueue.main.async { context.coordinator.present() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var model: AppModel
        var handledRequest = 0
        private weak var titleView: NSView?
        weak var window: NSWindow?
        private var monitor: Any?
        private var popover: NSPopover?
        private var pending: DispatchWorkItem?
        /// Where a press on the title began, to tell a click from a drag.
        private var pressedAt: NSPoint?

        init(model: AppModel) {
            self.model = model
            handledRequest = model.titleRenameRequest
            super.init()
            // Clicks on the title never reach its label: the title bar takes
            // them first, to drag or zoom the window, so a recognizer on the
            // label heard nothing. Watching the window's mouse events as they
            // arrive needs no view to be handed the click, and passes every
            // event on as it was.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// The label showing the open note's name in the window's frame,
        /// outside its content, looked for when it is needed. Found once and
        /// kept, it went stale: opening another note changed the title after
        /// the search had already run and found nothing, and nothing searched
        /// again.
        private func currentTitleView() -> NSView? {
            guard let window, let title = model.current?.name,
                  let frame = window.contentView?.superview else { return nil }
            if let titleView, (titleView as? NSTextField)?.stringValue == title, titleView.window === window {
                return titleView
            }
            titleView = Self.label(showing: title, in: frame, skipping: window.contentView)
            return titleView
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let titleView = currentTitleView()
            else { return }
            let inside = titleView.bounds.contains(titleView.convert(event.locationInWindow, from: nil))
            switch event.type {
            case .leftMouseDown:
                // A second press is a double click, which zooms the window.
                pending?.cancel()
                pending = nil
                pressedAt = inside && event.clickCount == 1 ? event.locationInWindow : nil
            case .leftMouseUp:
                guard inside, let start = pressedAt else { return }
                pressedAt = nil
                // Moved, it was the window being dragged by its title.
                guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4 else { return }
                let work = DispatchWorkItem { [weak self] in self?.present() }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            default:
                break
            }
        }

        static func label(showing title: String, in view: NSView, skipping content: NSView?) -> NSTextField? {
            if view === content { return nil }
            if let field = view as? NSTextField, !field.isEditable, field.stringValue == title { return field }
            for child in view.subviews {
                if let found = label(showing: title, in: child, skipping: content) { return found }
            }
            return nil
        }

        /// The popover under the title, or the plain dialog when there is no
        /// title to hang it from.
        func present() {
            guard popover == nil, let item = model.currentItem else { return }
            guard let anchor = currentTitleView() else {
                _ = model.rename(item)
                return
            }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            let content = TitleRenameView(item: item) { [weak popover] in popover?.performClose(nil) }
                .environmentObject(model)
            let controller = NSHostingController(rootView: content)
            // As big as the field and no bigger: without this the popover
            // took a large default size around a small field.
            controller.sizingOptions = [.preferredContentSize]
            popover.contentViewController = controller
            popover.animates = true
            // Hung from where the title is now, in the window's frame, not
            // from the title itself: macOS slides the title under the
            // pointer, and a popover hung from it slid along.
            // Below the title always. The edge is in the hanging view's own
            // coordinates, where y runs down only if the view is flipped: the
            // window's frame is not, so `.maxY` there was above the title,
            // and below only when the screen left no room above.
            func below(_ view: NSView) -> NSRectEdge { view.isFlipped ? .maxY : .minY }
            if let frame = anchor.window?.contentView?.superview {
                popover.show(relativeTo: anchor.convert(anchor.bounds, to: frame), of: frame, preferredEdge: below(frame))
            } else {
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: below(anchor))
            }
            self.popover = popover
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
        }
    }
}

/// The open note's name, in a popover just big enough for it, with the names
/// Apple Intelligence suggests listed under the field once they come.
///
/// The suggestions are rows of the popover itself. As SwiftUI's suggestion
/// menu they were a window of their own, hung from a field in a popover hung
/// from the title: it was cut off, and closed when the title moved under the
/// pointer. Applied when the popover closes, by Return or a click elsewhere,
/// as TextEdit applies its own; Esc puts the name back first.
struct TitleRenameView: View {
    @EnvironmentObject private var model: AppModel
    let item: VaultItem
    let close: () -> Void
    @State private var name: String
    @State private var suggestions: [String] = []
    /// Whether names are coming, so their room is there from the start.
    @State private var isSuggesting: Bool
    /// The suggestion ↓ and ↑ have reached, which Return takes.
    @State private var highlighted: Int?
    @State private var cancelled = false
    /// Whether the suggestions have come, even if there were none.
    @State private var loaded = false
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(item: VaultItem, close: @escaping () -> Void) {
        self.item = item
        self.close = close
        _name = State(initialValue: item.name)
        _isSuggesting = State(initialValue: item.isMarkdown && GeneralSettings.shared.suggestsNames
            && OnDeviceModel.unavailableReason == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit {
                    if let highlighted, suggestions.indices.contains(highlighted) {
                        name = suggestions[highlighted]
                    }
                    close()
                }
                .onExitCommand {
                    cancelled = true
                    close()
                }
                .onKeyPress(.downArrow) { step(1) }
                .onKeyPress(.upArrow) { step(-1) }
            // The room for three names is there from the start, so the
            // popover never resizes and the field never moves: growing it as
            // they arrived fought AppKit's own sizing, and the field slid.
            if isSuggesting {
                Text("Suggested")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(0..<3, id: \.self) { index in
                    if suggestions.indices.contains(index) {
                        SuggestionRow(title: suggestions[index], isHighlighted: highlighted == index) {
                            name = suggestions[index]
                            close()
                        }
                        .transition(.opacity)
                    } else {
                        Text(index == 0 ? (loaded ? "No names to suggest" : "Suggesting…") : " ")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(width: 260, alignment: .leading)
        .padding(10)
        .onAppear { nameFocused = true }
        .task { await suggest() }
        .onDisappear(perform: apply)
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let next = (highlighted ?? (delta > 0 ? -1 : suggestions.count)) + delta
        highlighted = suggestions.indices.contains(next) ? next : nil
        return .handled
    }

    private func suggest() async {
        guard isSuggesting else { return }
        let url = item.url
        let text = await Task.detached { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }.value
        let names = await NameSuggester.suggestions(for: text, current: item.name)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            suggestions = names
            loaded = true
        }
    }

    /// Through the same rename the sidebar uses, so a name that is taken or
    /// a note open elsewhere is refused the same way.
    private func apply() {
        guard !cancelled else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        _ = model.rename(item, to: trimmed)
    }
}

/// One suggested name, lit under the pointer or the arrows as a menu's row.
private struct SuggestionRow: View {
    let title: String
    let isHighlighted: Bool
    let choose: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHighlighted || isHovering ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear))
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
