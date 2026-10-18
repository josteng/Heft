import HeftCore
import SwiftUI
import UIKit

/// The Search tab: the Mac's ⌘T search, `UniversalSearchList`, under a field
/// of its own at the top, as the iPad's panel has, rather than the tab's
/// system field, which sat at the top on some phones and floated at the
/// bottom on others. The scope chips sit under it, the chosen one coloured;
/// above the keyboard they were missing on a first launch.
struct SearchView: View {
    @State private var query = ""
    @State private var model = SearchModel()
    @FocusState private var fieldFocused: Bool
    @Environment(MobileVault.self) private var vault
    @Environment(\.mobileLibrary) private var library
    @Environment(\.mobilePush) private var push

    var body: some View {
        List {
            UniversalSearchList(query: query, model: model, setQuery: { query = $0 }, showsChips: false)
        }
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
    }
}
