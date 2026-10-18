import HeftCore
import SwiftUI
import UIKit

/// The Search tab: the Mac's ⌘T search, `UniversalSearchList`, under a field
/// of its own at the top, as the iPad's panel has, rather than the tab's
/// system field, which sat at the top on some phones and floated at the
/// bottom on others. The scope chips ride above the keyboard while typing,
/// where the editor keeps its suggestions.
struct SearchView: View {
    @State private var query = ""
    @State private var model = SearchModel()
    @FocusState private var fieldFocused: Bool
    /// Whether the keyboard is up, when the chips ride on it; the field's
    /// focus state did not update from inside the bar it sits in.
    @State private var typing = false
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobileLibrary) private var library
    @Environment(\.mobilePush) private var push

    var body: some View {
        List {
            UniversalSearchList(query: query, model: model, setQuery: { query = $0 }, showsChips: !typing)
        }
        .searchingText(query, model: model)
        .safeAreaBar(edge: .top) { field }
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                ScopeChips(model: model, large: true)
            }
        }
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
        .onAppear {
            fieldFocused = true
            #if DEBUG
            if query.isEmpty, let preset = ProcessInfo.processInfo.environment["HEFT_IOS_QUERY"] {
                query = preset
            }
            #endif
        }
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
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}
