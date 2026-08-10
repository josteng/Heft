import AppKit
import SwiftUI

/// One `{{…}}` placeholder and what it means.
struct PlaceholderToken: Identifiable {
    let token: String
    let meaning: String
    var id: String { token }
}

/// The copyable token list, shared by the daily-note setup sheet and the
/// Typing settings pane.
///
/// One view rather than a copy in each: the two lists overlap almost
/// completely — a replacement's `{{date:…}}` is a template's `{{date:…}}`,
/// because both go through `MomentFormat` — so a token documented in one place
/// and not the other would read as two different systems that happen to look
/// alike.
struct PlaceholderReference: View {
    let title: String
    let tokens: [PlaceholderToken]
    /// The moment-token cheat sheet, or anything else worth saying under the
    /// list. Omitted where the surrounding text already says it.
    var footnote: String?
    /// The token column's width. The daily-note sheet and the settings pane
    /// have different widths to spend.
    var tokenWidth: CGFloat = 180

    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            ForEach(tokens) { placeholder in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(placeholder.token)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(width: tokenWidth, alignment: .leading)
                    Text(placeholder.meaning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button { copy(placeholder.token) } label: {
                        Image(systemName: copied == placeholder.token ? "checkmark" : "doc.on.doc")
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy \(placeholder.token)")
                }
            }
            if let footnote {
                Divider()
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The tokens `MomentFormat` resolves, which both callers share.
    static let dateTokens: [PlaceholderToken] = [
        PlaceholderToken(token: "{{date}}", meaning: "Today, as YYYY-MM-DD"),
        PlaceholderToken(token: "{{time}}", meaning: "Current time, such as 14:30"),
        PlaceholderToken(token: "{{date:dddd}}", meaning: "Full weekday, such as Friday"),
        PlaceholderToken(
            token: "{{date:MMMM Do YYYY}}", meaning: "Long date, such as August 8th 2026"
        ),
        PlaceholderToken(token: "{{date:GGGG-[W]WW}}", meaning: "ISO week, such as 2026-W32"),
        PlaceholderToken(token: "{{time:h:mm A}}", meaning: "12-hour time, such as 2:30 PM"),
    ]

    static let momentTokenFootnote =
        "Moment-style tokens: YYYY/YY year, MMMM/MMM/MM/M month, DD/D/Do day, dddd/ddd weekday, "
        + "GGGG and WW/W ISO week, and HH/h/mm/ss/A time. Put literal text in brackets, as in [W]."

    private func copy(_ token: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        copied = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copied == token { copied = nil }
        }
    }
}
