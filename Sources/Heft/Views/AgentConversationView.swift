import HeftCore
import SwiftUI

/// A chat with the reader's agent, in the search bar's place for its list.
///
/// The question, then the answer as it is written, with what the agent is
/// doing under it while it works. A proposal the answer left is a card here,
/// so it can be accepted, rejected with a word back to the agent, or opened
/// in review, without leaving the conversation that asked for it.
struct AgentConversationView: View {
    @ObservedObject var runner: AgentRunner
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Closes the bar, after opening a note or a review.
    let onLeave: () -> Void

    /// Whether the view follows the answer down as it is written. Only the
    /// reader's own scrolling turns it off, never the answer growing: up,
    /// and what they are reading holds still; back at the bottom, or a new
    /// message sent, and it follows again. As claude.ai and ChatGPT do.
    @State private var follows = true
    @State private var atBottom = true
    /// Whether the reader is scrolling right now, as against the content
    /// moving under them because the answer grew.
    @State private var readerScrolls = false

    /// The proposals of the turn at `index` a later turn proposed again,
    /// by id or by note: shown as replaced, so the current version is only
    /// ever the newest card, and deciding it does not mark the old one.
    static func replaced(in chat: AgentChat, before index: Int) -> Set<String> {
        let later = chat.turns.dropFirst(index + 1).flatMap(\.proposals)
        let ids = Set(later.map(\.id))
        let paths = Set(later.map(\.notePath))
        return Set(chat.turns[index].proposals
            .filter { ids.contains($0.id) || paths.contains($0.notePath) }
            .map(\.id))
    }

    var body: some View {
        if let chat = runner.chat {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(chat.turns.enumerated()), id: \.offset) { index, turn in
                            TurnView(
                                runner: runner, turn: turn,
                                isLast: index == chat.turns.count - 1,
                                replaced: Self.replaced(in: chat, before: index),
                                onLeave: onLeave
                            )
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 40
                } action: { _, bottom in
                    atBottom = bottom
                    if readerScrolls { follows = bottom }
                }
                .onScrollPhaseChange { _, phase in
                    let scrolling = phase == .interacting || phase == .decelerating
                    // Settled where the reader left it: following only if
                    // that is the bottom.
                    if readerScrolls, !scrolling { follows = atBottom }
                    readerScrolls = scrolling
                }
                .onChange(of: chat.turns.last?.answer.count) {
                    if follows { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: chat.turns.count) {
                    // A message sent is a return to the conversation's end.
                    follows = true
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: runner.isRunning) {
                    if follows { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onAppear {
                    follows = true
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .overlay(alignment: .bottom) {
                    if !follows, runner.isRunning {
                        Button {
                            follows = true
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                proxy.scrollTo("end", anchor: .bottom)
                            }
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.regularMaterial, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct TurnView: View {
    @ObservedObject var runner: AgentRunner
    @Environment(\.appAccent) private var accent
    @EnvironmentObject private var model: AppModel
    let turn: AgentChat.Turn
    let isLast: Bool
    /// This turn's proposals that a later turn replaced.
    let replaced: Set<String>
    let onLeave: () -> Void

    private var isAnswering: Bool { isLast && runner.isRunning }

    /// This turn's proposals still waiting, as they stand now.
    private var waiting: [Proposal] {
        turn.proposals.filter { !replaced.contains($0.id) }
            .compactMap { note in model.proposals.first { $0.id == note.id } }
    }

    /// Accepts the turn's proposals together, as a group is accepted in the
    /// review centre: the text first, then moves and deletes, which would
    /// otherwise take away the file an edit was written against.
    private func acceptAll() {
        let all = waiting
        for proposal in all where !proposal.isStructural { model.acceptAll(proposal) }
        for proposal in all where proposal.isStructural { model.applyStructural(proposal) }
        for proposal in all where !model.proposals.contains(where: { $0.id == proposal.id }) {
            runner.record(.accepted, for: proposal.id)
        }
    }

    private func rejectAll() {
        for proposal in waiting {
            model.discard(proposal)
            runner.record(.rejected, for: proposal.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The question on the right, as the reader's side of a chat.
            HStack {
                Spacer(minLength: 60)
                // Drawn as an answer is, so its links show the pointing
                // hand and their own menu; as a selectable `Text` they had
                // the text cursor and the text's menu.
                SelectableAnswer(
                    text: AnswerText.question(turn.question, vaultRoot: model.vaultRoot),
                    linkColor: NSColor(accent),
                    hugsText: true,
                    menu: { AnswerText.menu(for: $0, model: model) }
                ) { url in
                    AnswerText.open(url, model: model, onLeave: onLeave)
                }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary))
            }
            if !turn.answer.isEmpty {
                AnswerText(text: turn.answer, onLeave: onLeave)
            }
            if isAnswering {
                // Along the top, so a status that wraps grows downwards and
                // the spinner and Stop stay where they were.
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(runner.activity ?? "Thinking")
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                    Spacer()
                    // Quiet, as the rest of the line is: a filled button in the
                    // accent was the loudest thing on screen while it worked.
                    Button("Stop") { runner.cancel() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(".", modifiers: .command)
                }
                .font(.callout)
            }
            if let failure = turn.failure {
                FailureView(runner: runner, failure: failure, canRetry: isLast)
            }
            if waiting.count > 1 {
                HStack {
                    Text("\(waiting.count) changes").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reject All") { rejectAll() }
                    Button("Accept All") { acceptAll() }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
                .disabled(runner.isRunning)
            }
            ForEach(turn.proposals) { note in
                ProposalCard(runner: runner, note: note, isReplaced: replaced.contains(note.id), onLeave: onLeave)
            }
            if isLast, !runner.isRunning, !turn.denials.isEmpty {
                DenialsView(runner: runner, denials: turn.denials)
            }
        }
    }
}

/// The answer, with its wikilinks made into links that open the note.
///
/// An AppKit text view rather than a selectable SwiftUI `Text`: that one
/// showed the text cursor over a link and the pointing hand below it, its
/// link areas drawn off where the words are.
struct AnswerText: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appAccent) private var accent
    let text: String
    let onLeave: () -> Void

    var body: some View {
        SelectableAnswer(text: Self.attributed(text), linkColor: NSColor(accent), menu: { Self.menu(for: $0, model: model) }) { url in
            Self.open(url, model: model, onLeave: onLeave)
        }
    }

    static let noteScheme = "heft-note"

    /// A link in a chat: a note or file in the vault opens here, a folder
    /// in it is revealed in Files, and only what is outside goes to the
    /// Finder, a folder shown there and a file opened.
    @MainActor
    static func open(_ url: URL, model: AppModel, onLeave: () -> Void) {
        if let item = model.vaultItem(forLink: url) {
            if item.isFolder {
                model.revealFolder(item.relativePath)
            } else {
                model.open(item: item)
            }
            onLeave()
            return
        }
        guard url.scheme != noteScheme else { return }
        var isFolder: ObjCBool = false
        if url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            model.revealInFinder(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// A link's right-click menu: the one its file or folder has in Files.
    @MainActor
    static func menu(for url: URL, model: AppModel) -> NSMenu? {
        guard let item = model.vaultItem(forLink: url) else { return nil }
        if item.isFolder {
            return NSHostingMenu(rootView: FolderMenu(
                item: item,
                onCreateNote: { model.createNote(in: item.url) },
                onCreateFolder: { model.createFolder(in: item.url) },
                onRename: { _ = model.rename(item) }
            ).environmentObject(model))
        }
        return NSHostingMenu(rootView: FileMenu(item: item).environmentObject(model))
    }

    /// The reader's question with each path in it shown by its name, as a
    /// link: a note in the vault opens as one, any other file as the Mac
    /// opens it. The agent was sent the whole path; the chat need not show
    /// a run of folders.
    static func question(_ text: String, vaultRoot: URL?) -> AttributedString {
        var result = AttributedString()
        var rest = text.startIndex
        // Paths and wikilinks, in the order they come.
        let wikilinks = wikilinkRanges(in: text).map { (url: URL?.none, range: $0) }
        let paths = AgentFiles.occurrences(in: text).map { (url: Optional($0.url), range: $0.range) }
        for found in (paths + wikilinks).sorted(by: { $0.range.location < $1.range.location }) {
            guard let range = Range(found.range, in: text), range.lowerBound >= rest else { continue }
            result += AttributedString(String(text[rest..<range.lowerBound]))
            guard let url = found.url else {
                // `[[Note]]` as an answer draws it: the name, a link to it.
                result += attributed(String(text[range]))
                rest = range.upperBound
                continue
            }
            let file = url.standardizedFileURL
            var name = AttributedString(file.pathExtension == "md" ? file.deletingPathExtension().lastPathComponent : file.lastPathComponent)
            let root = vaultRoot?.standardizedFileURL.path
            if let root, file.path.hasPrefix(root + "/"), file.pathExtension == "md" {
                let relative = String(file.path.dropFirst(root.count + 1))
                let encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? relative
                name.link = URL(string: "\(noteScheme)://\(encoded)")
            } else {
                name.link = file
            }
            result += name
            rest = range.upperBound
        }
        return result + AttributedString(String(text[rest...]))
    }

    /// Inline Markdown, with `[[Note]]` and `[[Note|shown]]` as links.
    static func attributed(_ text: String) -> AttributedString {
        let linked = linkingWikilinks(blocks(text))
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(text)
    }

    /// The block Markdown an answer often has, in the inline Markdown the
    /// view draws: a heading as a bold line, a task as ☐ or ☑, a list item
    /// as a bullet, and a rule left out. Left as typed, `##` and `- [ ]`
    /// showed. Code fences are kept as they are, and so is what is in them.
    static func blocks(_ text: String) -> String {
        var inFence = false
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            guard !inFence, !trimmed.hasPrefix("```") else {
                lines.append(line)
                continue
            }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                continue
            }
            if let heading = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let title = trimmed[heading.upperBound...]
                lines.append(indent + (title.contains("**") ? String(title) : "**\(title)**"))
            } else if let task = trimmed.range(of: #"^[-*+]\s+\[[ xX]\]\s+"#, options: .regularExpression) {
                let done = trimmed[task].contains { $0 == "x" || $0 == "X" }
                lines.append(indent + (done ? "☑ " : "☐ ") + trimmed[task.upperBound...])
            } else if let bullet = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                lines.append(indent + "• " + trimmed[bullet.upperBound...])
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A chat's name with any path in it shown by its file's name, as the
    /// question it came from shows it.
    static func shownTitle(_ title: String) -> String {
        String(question(title, vaultRoot: nil).characters)
    }

    /// Where each `[[…]]` is in `text`.
    static func wikilinkRanges(in text: String) -> [NSRange] {
        let pattern = try! NSRegularExpression(pattern: #"\[\[[^\[\]\n]+\]\]"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    static func linkingWikilinks(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            result += rest[..<open.lowerBound]
            let inner = rest[open.upperBound..<close.lowerBound]
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            let target = (parts.first ?? "").split(separator: "#").first.map(String.init) ?? ""
            // A link written as a path shows the note's name, as the editor
            // draws it; one with its own text shows that.
            let named = (target as NSString).lastPathComponent
            let shown = parts.count > 1 ? parts[1] : (named.hasSuffix(".md") ? String(named.dropLast(3)) : named)
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? target
            result += target.isEmpty ? String(rest[open.lowerBound..<close.upperBound]) : "[\(shown)](\(noteScheme)://\(encoded))"
            rest = rest[close.upperBound...]
        }
        return result + rest
    }
}

/// A proposal the agent left, decided here or in review.
private struct ProposalCard: View {
    @ObservedObject var runner: AgentRunner
    @EnvironmentObject private var model: AppModel
    let note: AgentChat.ProposalNote
    /// A later turn proposed this again: the newer card is the one to decide.
    var isReplaced = false
    let onLeave: () -> Void
    @State private var showsDiff = false

    private var proposal: Proposal? {
        isReplaced ? nil : model.proposals.first { $0.id == note.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(proposal?.headline ?? note.headline).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 8)
                if let proposal {
                    if let counts = counts(proposal) {
                        Text(counts).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else {
                    Text(settledText).font(.caption).foregroundStyle(.secondary)
                }
            }
            // Rejected here: what to do instead is a reply away, said rather
            // than asked, on the newest card only.
            if !isReplaced, proposal == nil, note.outcome == .rejected,
               runner.chat?.turns.last?.proposals.contains(where: { $0.id == note.id }) == true {
                Text("Reply with what to do instead.")
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            if let proposal {
                if showsDiff, !proposal.isStructural {
                    DiffPreview(diff: proposal.diff(against: model.currentText(for: proposal)))
                }
                HStack(spacing: 6) {
                    if !proposal.isStructural {
                        Button(showsDiff ? "Hide changes" : "Show changes") { showsDiff.toggle() }
                    }
                    Button("Review") { model.review(proposal); onLeave() }
                    Spacer()
                    Button("Reject") { reject(proposal) }
                    Button("Accept") { accept(proposal) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
                .disabled(runner.isRunning)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
    }

    private var symbol: String {
        switch proposal?.kind {
        case .delete: "trash"
        case .move: "arrow.right.doc.on.clipboard"
        case .create: "doc.badge.plus"
        default: "doc.text"
        }
    }

    private var settledText: String {
        if isReplaced { return "Replaced below" }
        return switch note.outcome {
        case .accepted: "Accepted"
        case .rejected: "Rejected"
        case nil: "Settled in review"
        }
    }

    private func counts(_ proposal: Proposal) -> String? {
        guard !proposal.isStructural else { return nil }
        let diff = proposal.diff(against: model.currentText(for: proposal))
        let added = diff.hunks.reduce(0) { $0 + $1.added.count }
        let removed = diff.hunks.reduce(0) { $0 + $1.removed.count }
        return "+\(added) −\(removed)"
    }

    private func accept(_ proposal: Proposal) {
        if proposal.isStructural {
            model.applyStructural(proposal)
        } else {
            model.acceptAll(proposal)
        }
        if !model.proposals.contains(where: { $0.id == proposal.id }) {
            runner.record(.accepted, for: proposal.id)
        }
    }

    /// One click: the reason, if there is one, is a reply the reader can
    /// start from the rejected card, not a question asked first.
    private func reject(_ proposal: Proposal) {
        model.discard(proposal)
        runner.record(.rejected, for: proposal.id)
    }
}

private struct DiffPreview: View {
    let diff: NoteDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(diff.hunks.prefix(6)) { hunk in
                ForEach(Array(hunk.removed.enumerated()), id: \.offset) { _, line in
                    Text("− " + line).foregroundStyle(.red)
                }
                ForEach(Array(hunk.added.enumerated()), id: \.offset) { _, line in
                    Text("+ " + line).foregroundStyle(.green)
                }
                if hunk.id != diff.hunks.prefix(6).last?.id { Divider().padding(.vertical, 2) }
            }
            if diff.hunks.count > 6 {
                Text("and \(diff.hunks.count - 6) more").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }
}

/// What the agent was refused, and the reads the reader may allow.
private struct DenialsView: View {
    @ObservedObject var runner: AgentRunner
    @EnvironmentObject private var model: AppModel
    let denials: [AgentDenial]

    /// A path as the reader knows it: inside the vault from its top,
    /// elsewhere from the home folder.
    private func shown(_ text: String) -> String {
        var result = text
        if let root = model.vaultRoot?.standardizedFileURL.path {
            result = result.replacingOccurrences(of: root + "/", with: "")
        }
        return result.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("It was not allowed to", systemImage: "hand.raised")
                .font(.callout.weight(.medium))
            ForEach(denials, id: \.self) { denial in
                Text(shown(denial.summary))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            let folders = denials.compactMap(\.allowFolder).uniqued()
            if !folders.isEmpty {
                Button("Allow reading \(folders.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) and continue") {
                    runner.allow(denials)
                }
                .controlSize(.small)
                .help(folders.joined(separator: "\n"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

/// Why a run gave no answer, and what to do about it.
private struct FailureView: View {
    @ObservedObject var runner: AgentRunner
    @ObservedObject private var settings = GeneralSettings.shared
    let failure: String
    let canRetry: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch failure {
            case "missing":
                Label("Ask runs Claude Code, which was not found", systemImage: "questionmark.circle")
                    .font(.callout.weight(.medium))
                Text("Install it, sign in once in Terminal, and ask again. Settings ▸ Ask names another command.")
                    .foregroundStyle(.secondary)
                Text(Self.installCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            case "signedOut":
                Label("Claude Code is signed out", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout.weight(.medium))
                Text("Run \(settings.agentCommand) once in Terminal to sign in, then ask again.")
                    .foregroundStyle(.secondary)
            case "Stopped":
                Text("Stopped").foregroundStyle(.secondary)
            default:
                Label("The agent stopped", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium))
                Text(failure)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            if canRetry, failure != "Stopped" {
                Button("Try again") { runner.retry() }
                    .controlSize(.small)
                    .disabled(runner.isRunning)
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
    }

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
}

/// Inline Markdown in a non-editable, selectable text view, sized to its
/// width, with real link cursors and clicks.
struct SelectableAnswer: NSViewRepresentable {
    let text: AttributedString
    /// Heft's own accent, as links are drawn in notes.
    let linkColor: NSColor
    /// As wide as its text, up to the width offered, as a question's bubble
    /// is; an answer takes the whole width.
    var hugsText = false
    /// A right-clicked link's own menu, or nil for the text's.
    var menu: (URL) -> NSMenu? = { _ in nil }
    let open: (URL) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.open = open
        context.coordinator.linkMenu = menu
        view.appearance = NSAppearance.plain(dark: colorScheme == .dark)
        view.linkTextAttributes = [.foregroundColor: linkColor, .cursor: NSCursor.pointingHand]
        let shown = Self.appKit(text)
        if view.textStorage?.isEqual(to: shown) != true {
            view.textStorage?.setAttributedString(shown)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        // Asked for an ideal size, a narrow one: the column decides the
        // width, and the answer fills whatever it is given.
        let width = proposal.width ?? 150
        guard let text = view.textStorage else { return nil }
        guard hugsText else { return CGSize(width: width, height: Self.height(of: text, width: width)) }
        let used = Self.size(of: text, width: width)
        return CGSize(width: min(width, used.width), height: used.height)
    }

    /// How tall `text` is at `width`, laid out on its own. Measuring in the
    /// view's own container left it at the width last tried, which SwiftUI
    /// tries several of: the text drawn ran past the column, its height was
    /// another width's, and an answer being written flickered between them.
    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        size(of: text, width: width).height
    }

    /// The room `text` takes at most `width` wide, laid out on its own.
    static func size(of text: NSAttributedString, width: CGFloat) -> CGSize {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(open: open) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: (URL) -> Void
        var linkMenu: (URL) -> NSMenu? = { _ in nil }
        init(open: @escaping (URL) -> Void) { self.open = open }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard let storage = view.textStorage, charIndex < storage.length else { return menu }
            let link = storage.attribute(.link, at: charIndex, effectiveRange: nil)
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            return url.flatMap(linkMenu) ?? menu
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                open(url)
            } else if let text = link as? String, let url = URL(string: text) {
                open(url)
            }
            return true
        }
    }

    /// Markdown's inline intents as the fonts AppKit draws them in.
    static func appKit(_ text: AttributedString) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let result = NSMutableAttributedString()
        for run in text.runs {
            var font = base
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular)
            }
            if intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        // A list item's lines after its first start under its text, not
        // under its bullet.
        let string = result.string as NSString
        let marker = try! NSRegularExpression(pattern: #"^[ \t]*(•|☐|☑|\d+[.)]) "#)
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { line, range, _, _ in
            guard let line, let found = marker.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            else { return }
            let prefix = (line as NSString).substring(with: found.range)
            let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
            style.headIndent = ceil(NSAttributedString(string: prefix, attributes: [.font: base]).size().width)
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }
}

extension NSAppearance {
    /// Aqua or Dark Aqua, never their vibrant forms. The right sidebar hands
    /// its views a vibrant appearance, and a text view's selection drawn in
    /// it blended into the material until it was barely there.
    static func plain(dark: Bool) -> NSAppearance? {
        NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}
