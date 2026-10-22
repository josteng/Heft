import HeftCore
import SwiftUI
import UIKit

/// The Search tab: the Mac's ⌘T search, `UniversalSearchList`, under a field
/// of its own at the top, as the iPad's panel has, rather than the tab's
/// system field, which sat at the top on some phones and floated at the
/// bottom on others. The scope chips sit under it, the chosen one coloured;
/// above the keyboard they were missing on a first launch.
struct SearchView: View {
    @State private var request = SearchRequest.shared
    @State private var query = ""
    @State private var model = SearchModel()
    @State private var action: ItemAction?
    @FocusState private var fieldFocused: Bool
    /// Whether the keyboard is up, for the close button; the field's focus
    /// state does not update from inside the bar it sits in.
    @State private var typing = false
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobileLibrary) private var library
    @Environment(\.mobilePush) private var push

    var body: some View {
        List {
            UniversalSearchList(
                query: query, model: model, setQuery: { query = $0 }, showsChips: false,
                itemAction: { action = $0 }
            )
        }
        .itemActionHost($action)
        .searchingText(query, model: model)
        .safeAreaBar(edge: .top) {
            VStack(spacing: 8) {
                field
                ScopeChips(model: model, large: true)
            }
            .padding(.bottom, 6)
            .animation(.easeOut(duration: 0.2), value: model.scope)
        }
        // Results end at the bar's edge rather than showing through the
        // field and chips, as Mail's list ends under its toolbar.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            typing = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            typing = false
        }
        .onChange(of: query) { _, typed in
            if model.enterScope(byTyping: typed) { query = "" }
        }
        .onChange(of: request.generation) { takeRequest() }
        .onAppear {
            // A scope asked for from elsewhere, a tag tapped in a note, is
            // a list to look through: the keyboard stays down for it.
            if !takeRequest() { fieldFocused = true }
            #if DEBUG
            if query.isEmpty, let preset = ProcessInfo.processInfo.environment["HEFT_IOS_QUERY"] {
                query = preset
            }
            #endif
        }
    }

    @discardableResult
    private func takeRequest() -> Bool {
        guard let scope = request.take() else { return false }
        query = ""
        model.scope = scope
        fieldFocused = false
        return true
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: model.scope?.symbol ?? "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(model.scope?.placeholder ?? BarScope.unscopedPlaceholder, text: $query)
                .focused($fieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit {
                    let commands = library.map(MobileCommand.all) ?? []
                    if let row = model.firstRow(for: query, vault: vault, commands: commands) {
                        model.act(on: row, push: push, setQuery: { query = $0 })
                    }
                }
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassEffect(in: .capsule)
        .safeAreaInset(edge: .trailing, spacing: 8) {
            // Out of the search, as the system's search tab closes: what was
            // typed and the scope go, and so does the keyboard.
            if typing || !query.isEmpty || model.scope != nil {
                Button("Close", systemImage: "xmark") {
                    query = ""
                    model.scope = nil
                    fieldFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
                .tint(.primary)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: typing || !query.isEmpty || model.scope != nil)
        .padding(.horizontal, 16)
    }
}

/// Opens the phone's Search tab in a scope from elsewhere: a tag tapped in
/// a note opens Search narrowed to that tag, as the Mac's bar does.
@MainActor @Observable
final class SearchRequest {
    static let shared = SearchRequest()
    /// Moves with each request, which is what the Search tab watches; it
    /// also takes its stack back to the search itself.
    private(set) var generation = 0
    @ObservationIgnored private var pending: BarScope?

    func open(_ scope: BarScope) {
        pending = scope
        generation += 1
    }

    /// The scope asked for, once.
    func take() -> BarScope? {
        defer { pending = nil }
        return pending
    }
}
