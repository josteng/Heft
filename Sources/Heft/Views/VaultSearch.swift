import AppKit
import Foundation
import HeftCore
import SwiftUI

private struct VaultSearchHit: Identifiable, Sendable {
    let query: String
    let note: NoteRef
    let line: Int
    let preview: String
    let occurrences: Int

    var id: String { "\(query)#\(note.relativePath)#\(line)" }
}

private struct VaultSearchResponse: Sendable {
    let query: String
    let hits: [VaultSearchHit]
    let totalOccurrences: Int
    let matchedNotes: Int
}

struct VaultSearchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var response = VaultSearchResponse(
        query: "", hits: [], totalOccurrences: 0, matchedNotes: 0
    )
    @State private var selection = 0
    @State private var isSearching = false
    @State private var searchesEntireVault = false

    var body: some View {
        let visible = visibleResponse
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                VaultSearchField(
                    text: $query,
                    onSubmit: openSelection,
                    onMove: move,
                    onCancel: { dismiss() }
                )
                .frame(height: 22)
                .onChange(of: query) {
                    selection = 0
                    response = emptyResponse(for: "")
                }
                PaletteDismissButton(query: $query) { dismiss() }
                if model.scopePath != nil {
                    Button { searchesEntireVault.toggle(); selection = 0 } label: {
                        Image(systemName: searchesEntireVault ? "globe" : "scope")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(searchesEntireVault ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help(searchesEntireVault ? "Searching the entire vault" : "Searching \(model.scopeName)")
                }
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Text(summary(for: visible))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if !query.isEmpty, !isSearching, visible.hits.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, 90)
                    } else {
                        VStack(spacing: 1) {
                            ForEach(Array(visible.hits.enumerated()), id: \.element.id) { index, hit in
                                VaultSearchRow(
                                    hit: hit, query: query, isSelected: index == selection
                                )
                                .id(index)
                                .onTapGesture {
                                    selection = index
                                    openSelection()
                                }
                            }
                        }
                        .padding(6)
                    }
                }
                .id(visible.query)
                .onChange(of: selection) { proxy.scrollTo(selection, anchor: .center) }
            }
            .frame(height: 420)
        }
        .frame(width: 680)
        .background(.regularMaterial)
        .onKeyPress(.escape) { dismiss(); return .handled }
        .task(id: "\(query)|\(searchesEntireVault)") { await search() }
    }

    private func summary(for response: VaultSearchResponse) -> String {
        let matchWord = response.totalOccurrences == 1 ? "match" : "matches"
        let noteWord = response.matchedNotes == 1 ? "note" : "notes"
        return "\(response.totalOccurrences) \(matchWord) in \(response.matchedNotes) \(noteWord)"
    }

    private var visibleResponse: VaultSearchResponse {
        response.query == query.trimmingCharacters(in: .whitespacesAndNewlines)
            ? response : emptyResponse(for: query)
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            isSearching = false
            response = emptyResponse(for: "")
            return
        }

        isSearching = true
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled,
              query.trimmingCharacters(in: .whitespacesAndNewlines) == term
        else { return }
        let notes = searchesEntireVault ? model.index.notes : model.scopedNotes
        let result = await Task.detached(priority: .userInitiated) {
            searchVault(notes: notes, query: term)
        }.value
        guard !Task.isCancelled,
              query.trimmingCharacters(in: .whitespacesAndNewlines) == term
        else { return }
        response = result
        selection = min(selection, max(0, result.hits.count - 1))
        isSearching = false
    }

    private func move(_ delta: Int) {
        guard !visibleResponse.hits.isEmpty else { return }
        selection = min(max(selection + delta, 0), visibleResponse.hits.count - 1)
    }

    private func openSelection() {
        guard visibleResponse.hits.indices.contains(selection) else { return }
        let hit = visibleResponse.hits[selection]
        // Land on the line that matched, not at the top of the note.
        model.open(hit.note, revealingLine: hit.line)
        dismiss()
    }
}

private struct VaultSearchRow: View {
    let hit: VaultSearchHit
    let query: String
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "doc.text")
                .frame(width: 16)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(hit.note.name).fontWeight(.medium)
                    Text(location)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                    Spacer(minLength: 8)
                    if hit.occurrences > 1 {
                        Text("\(hit.occurrences) matches")
                            .font(.system(size: 10))
                            .foregroundStyle(
                                isSelected
                                    ? AnyShapeStyle(.white.opacity(0.75))
                                    : AnyShapeStyle(.tertiary)
                            )
                    }
                }
                highlightedPreview
                    .font(.system(size: 12))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor) }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
    }

    private var location: String {
        hit.note.folder.isEmpty ? "Line \(hit.line)" : "\(hit.note.folder) · Line \(hit.line)"
    }

    private var highlightedPreview: Text {
        let plain = hit.preview
        var result = AttributedString(plain)
        var cursor = plain.startIndex
        while cursor < plain.endIndex,
              let range = plain.range(
                of: query, options: .caseInsensitive, range: cursor..<plain.endIndex
              ),
              let lower = AttributedString.Index(range.lowerBound, within: result),
              let upper = AttributedString.Index(range.upperBound, within: result) {
            result[lower..<upper].font = .system(size: 12, weight: .bold)
            if !isSelected { result[lower..<upper].foregroundColor = .accentColor }
            cursor = range.upperBound
        }
        return Text(result)
    }
}

private func searchVault(notes: [NoteRef], query: String) -> VaultSearchResponse {
    var hits: [VaultSearchHit] = []
    var totalOccurrences = 0
    var matchedNotes = Set<String>()

    for note in notes {
        guard let text = try? String(contentsOf: note.url, encoding: .utf8) else { continue }
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let occurrences = occurrenceCount(of: query, in: rawLine)
            guard occurrences > 0 else { continue }
            totalOccurrences += occurrences
            matchedNotes.insert(note.relativePath)
            let preview = contextPreview(in: rawLine, query: query)
            hits.append(VaultSearchHit(
                query: query, note: note, line: offset + 1,
                preview: preview.isEmpty ? "Empty line" : preview,
                occurrences: occurrences
            ))
        }
    }

    let lowerQuery = query.lowercased()
    hits.sort { left, right in
        let leftRank = filenameRank(left.note.name, query: lowerQuery)
        let rightRank = filenameRank(right.note.name, query: lowerQuery)
        if leftRank != rightRank { return leftRank > rightRank }
        if left.occurrences != right.occurrences { return left.occurrences > right.occurrences }
        let pathOrder = left.note.relativePath.localizedStandardCompare(right.note.relativePath)
        if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
        return left.line < right.line
    }

    return VaultSearchResponse(
        query: query, hits: Array(hits.prefix(500)),
        totalOccurrences: totalOccurrences, matchedNotes: matchedNotes.count
    )
}

private func filenameRank(_ name: String, query: String) -> Int {
    let candidate = name.lowercased()
    if candidate == query { return 3 }
    if candidate.hasPrefix(query) { return 2 }
    if candidate.contains(query) { return 1 }
    return 0
}

private struct VaultSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onMove: (Int) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search vault contents"
        field.font = .systemFont(ofSize: 16)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: VaultSearchField

        init(_ parent: VaultSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  parent.text != field.stringValue
            else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}

private func contextPreview(in line: String, query: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let match = trimmed.range(of: query, options: [.caseInsensitive, .literal]) else {
        return trimmed.isEmpty ? "Empty line" : trimmed
    }

    let matchStart = trimmed.distance(from: trimmed.startIndex, to: match.lowerBound)
    let matchEnd = trimmed.distance(from: trimmed.startIndex, to: match.upperBound)
    let startOffset = max(0, matchStart - 55)
    let endOffset = min(trimmed.count, matchEnd + 95)
    let start = trimmed.index(trimmed.startIndex, offsetBy: startOffset)
    let end = trimmed.index(trimmed.startIndex, offsetBy: endOffset)
    let prefix = startOffset > 0 ? "…" : ""
    let suffix = endOffset < trimmed.count ? "…" : ""
    return prefix + trimmed[start..<end] + suffix
}

private func emptyResponse(for query: String) -> VaultSearchResponse {
    VaultSearchResponse(query: query, hits: [], totalOccurrences: 0, matchedNotes: 0)
}

private func occurrenceCount(of query: String, in text: String) -> Int {
    guard !query.isEmpty else { return 0 }
    var count = 0
    var remainder = text[...]
    while let range = remainder.range(of: query, options: [.caseInsensitive, .literal]) {
        count += 1
        remainder = remainder[range.upperBound...]
    }
    return count
}
