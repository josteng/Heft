import HeftCore
import SwiftUI

/// The Search tab: the Mac's ⌘T search, `UniversalSearchList`, under the
/// tab's own field, which opens ready to type.
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
        // A bar under the title, staying put as the results scroll and
        // without a list section's gap above it. Not above the keyboard:
        // the tab's floating search field draws over anything put there.
        .safeAreaBar(edge: .top) {
            ScopeChips(model: model, large: true)
                .padding(.bottom, 6)
        }
        .navigationTitle(model.scope?.title ?? "Search")
        .searchable(text: $query, prompt: model.scope?.placeholder ?? BarScope.unscopedPlaceholder)
        // The search tab collapses its field into the tab bar, which left the
        // tab looking like a list of recent notes; it opens ready to type.
        .searchFocused($fieldFocused)
        .onChange(of: query) { _, typed in
            if model.enterScope(byTyping: typed) { query = "" }
        }
        .onSubmit(of: .search) {
            let commands = library.map(MobileCommand.all) ?? []
            if let row = model.firstRow(for: query, vault: vault, commands: commands) {
                model.act(on: row, push: push, setQuery: { query = $0 })
            }
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
}
