import Foundation

/// The instructions a coding agent needs in order to work with a vault.
///
/// The proposal verbs are useless if nothing tells an agent they exist. Someone
/// running Claude Code *in their vault* has a session that knows only what the
/// folder tells it, and a folder of markdown says nothing about Heft — so the
/// agent does the obvious thing and writes the notes directly, which is exactly
/// what proposals exist to prevent.
///
/// `CLAUDE.md` at the vault root is where such a session looks, so that is
/// where this goes. It is generated rather than pasted by hand so it can be
/// re-run after an upgrade, and it is written between markers so re-running
/// updates Heft's section and leaves everything else in the file alone.
public enum AgentGuide {
    public static let markerStart = "<!-- heft:agent-guide start -->"
    public static let markerEnd = "<!-- heft:agent-guide end -->"

    /// The guide's revision. Bump it whenever the wording an agent depends on
    /// changes: a new verb, a changed flag, a rule that now reads differently.
    ///
    /// The stamp exists because the guide is copied *into the user's vault*.
    /// Once written it is frozen there, and an upgraded Heft has no way to
    /// reach it — so a vault set up a year ago goes on telling its agent about
    /// a command line that no longer exists. The version is what lets the
    /// commands notice and say so.
    public static let version = 6
    static let versionMarker = "<!-- heft:agent-guide version:"

    /// What a vault's `CLAUDE.md` currently carries.
    public enum Status: Equatable, Sendable {
        case absent
        case current
        /// Present, but written by an older Heft. Carries the version found;
        /// a guide from before the stamp existed reads as 0.
        case outdated(found: Int)
    }

    public static func status(of existing: String?) -> Status {
        guard let existing, existing.contains(markerStart) else { return .absent }
        let found = versionStamp(in: existing) ?? 0
        return found >= version ? .current : .outdated(found: found)
    }

    /// The stamped revision, or nil for a guide written before stamping.
    public static func versionStamp(in text: String) -> Int? {
        guard let start = text.range(of: versionMarker) else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "-->") else { return nil }
        return Int(rest[..<end.lowerBound].trimmingCharacters(in: .whitespaces))
    }

    /// The line an out-of-date vault should see, naming the one command that
    /// fixes it. Deliberately not a repair Heft performs on its own: the file
    /// is the user's, may hold their own instructions, and rewriting it
    /// unasked is the behaviour proposals exist to avoid.
    public static func refreshAdvice(found: Int, vaultPath: String) -> String {
        "note: this vault's Heft agent guide is version \(found), "
            + "but this Heft writes version \(version). "
            + "Run `heft agent-setup \"\(vaultPath)\"` to refresh it."
    }

    /// The guidance itself, pointing at whichever binary is installed.
    public static func section(binaryPath: String) -> String {
        """
        \(markerStart)
        \(versionMarker) \(version) -->
        <!-- Written by `heft agent-setup`. Edits between these markers are
             replaced when it is run again; everything else in this file is
             left alone. -->

        # This vault is edited in Heft

        > Everything from here to the end of this section is rewritten by
        > `heft agent-setup`. Put your own notes **outside** it — above this
        > line or below the closing one — where nothing touches them.

        `heft` below is `\(binaryPath)`.

        ## Do not write notes directly

        Do not use Write or Edit on `.md` files in this vault. Propose the
        change instead; it is reviewed in the editor, hunk by hunk, and applied
        from there.

        ```bash
        heft read . "Note Name" > /tmp/note.md   # read a note
        # ...write the complete new body to /tmp/new.md...
        heft propose . "Path/To/Note.md" \\
            --from /tmp/new.md \\
            --summary "one line on what this changes"
        ```

        `propose` takes the whole new body of the note, not a patch. Heft works
        out the hunks itself, against the note as it is *now*.

        ## Changing part of a long note

        Restating a long note just to change a paragraph is mostly
        transcription. `--replace` takes anchored edits on stdin instead:

        ```bash
        echo '[{"old": "the exact text to replace", "new": "its replacement"}]' \\
            | heft propose . "Path/To/Note.md" --replace \\
                --summary "one line on what this changes"
        ```

        Each `old` must appear **exactly once** in the note; Heft refuses an
        anchor that matches twice rather than guessing which you meant. Edits
        apply in order, each to the result of the last. Heft resolves them
        against the current note and stores an ordinary full-body proposal, so
        a bad anchor fails here and now rather than at review time.

        ## Finding things

        ```bash
        heft help                # every verb and flag; --json for the machine form
        heft find . <query>      # full-text search across the vault
        heft files .             # every note, vault-relative
        heft files . --by-use    # ordered by what this person actually opens
        heft proposals .         # what is already waiting for review
        heft diff . <id>         # what one of them would change
        ```

        `heft help` is the whole surface, so nothing here needs to list it
        twice. Everything above is read-only and safe to run against a live
        vault; `heft help --json` says which verbs are.

        ## Ask the vault, do not grep it

        Heft keeps a resolved link index. It knows things the filesystem does
        not, and reimplementing them outside the app means reimplementing the
        parser and getting it subtly wrong on the syntax it was written for —
        `[[Note|alias]]`, `[[Note#Heading]]`, `![[chart.png\\|500]]`.

        ```bash
        heft backlinks . "Note"  # what links here, with the referencing line
        heft links . "Note"      # what it links out to, resolved or not
        heft outline . "Note"    # its headings, with line numbers
        heft tags .              # tags with counts; add a tag to list its notes
        heft config .            # daily-note folder, date format, attachments
        ```

        Read `heft config .` before writing anything that has to fit the
        vault's conventions: it gives the daily-note folder and filename
        format, the attachment folder, and whether this vault prefers
        wikilinks over Markdown links. Guessing produces notes that look
        wrong in the editor and links that do not resolve.

        ## When they ask how to do something in the app

        `heft keys` prints the app's keyboard shortcuts. The person you are
        helping is reading these notes in a Mac app, and "how do I search the
        vault" is a fair question to be asked in the middle of a task. Run it
        rather than guessing: a wrong shortcut is worse than no answer.

        `heft outline` is usually the right thing to read before restructuring
        a long note, and `heft backlinks` before renaming or moving one:
        renaming repoints path-shaped links, but prose that mentions the old
        name is yours to fix.

        ## After proposing

        Say what you proposed, and stop. Do not wait for the review, and do not
        apply your own proposal by writing the file as well.
        \(markerEnd)
        """
    }

    /// What a brand-new `CLAUDE.md` opens with, above Heft's section.
    ///
    /// There is no second marker pair for "the user's part", on purpose: that
    /// would invent a third place — text outside both regions — and imply Heft
    /// manages two halves of the file. The contract is simpler stated than
    /// fenced: what is between the markers is Heft's, everything else is the
    /// user's. But a file that is *only* a generated block says nothing about
    /// that and reads as machinery, so a new one gets somewhere to write.
    public static func preamble(vaultName: String) -> String {
        """
        # \(vaultName)

        Notes for coding agents working in this vault.

        Write your own instructions here — conventions, what lives where, what
        to leave alone. This part of the file is yours: Heft only rewrites the
        section between its markers below, and never touches anything else.
        """
    }

    /// What an editor writes on a drawn marker.
    ///
    /// The opening one names the section it begins; it says nothing about
    /// where to write, because the space directly above it is the file's own
    /// beginning and pointing at it reads as a description of whatever
    /// happens to be there. Only the closing marker has room below it that is
    /// unambiguously the user's.
    public static func boundaryLabel(isEnd: Bool) -> String {
        isEnd
            ? "End of the section Heft manages — anything below is yours"
            : "Start of the section Heft manages — rewritten by heft agent-setup"
    }

    /// The guide currently in `text`, markers included.
    public static func managedSection(in text: String) -> String? {
        guard let start = text.range(of: markerStart),
              let end = text.range(of: markerEnd),
              start.lowerBound < end.lowerBound
        else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    /// Everything but the line naming the installed binary, which differs
    /// between a debug run and an installed one without anyone having typed
    /// anything.
    static func comparable(_ section: String) -> String {
        section
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("`heft` below is") }
            .joined(separator: "\n")
    }

    /// Saves the section about to be replaced, if someone has typed inside it.
    ///
    /// The markers are HTML comments and so invisible in a rendered editor: a
    /// note added at the end of the guide looks like it is at the end of the
    /// file, and is in fact on managed ground. Refusing to refresh would be
    /// worse than the disease, so the words are kept instead.
    ///
    /// Only when the stamped version matches this one. An older guide is
    /// *expected* to differ, and backing that up on every upgrade would file
    /// away copies nobody wanted.
    @discardableResult
    public static func backUpIfEdited(
        existing: String?,
        replacement: String,
        vaultRoot: URL,
        now: Date = Date()
    ) throws -> URL? {
        guard let existing, let previous = managedSection(in: existing) else { return nil }
        guard versionStamp(in: previous) == version else { return nil }
        guard comparable(previous) != comparable(replacement) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = vaultRoot.appendingPathComponent(".heft/claude-md", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("\(formatter.string(from: now)).md")
        try previous.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    /// `existing` with the guide added, or its previous copy replaced.
    ///
    /// Idempotent on purpose: this file is the user's, and may well hold notes
    /// of their own about their vault. Re-running after an upgrade has to
    /// refresh Heft's section without touching a word of the rest.
    /// `preamble` is used only when there is no file yet. An existing
    /// `CLAUDE.md` already has whatever the user put above the guide, and
    /// inserting a heading into it would be exactly the meddling the markers
    /// promise not to do.
    public static func merged(
        into existing: String?, section: String, preamble: String? = nil
    ) -> String {
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            guard let preamble else { return section + "\n" }
            return preamble + "\n\n" + section + "\n"
        }

        guard let start = existing.range(of: markerStart),
              let end = existing.range(of: markerEnd),
              start.lowerBound < end.lowerBound
        else {
            // No section yet. Append, leaving whatever is already there first:
            // the user's own notes about their vault outrank ours.
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            return existing + separator + section + "\n"
        }

        var updated = existing
        updated.replaceSubrange(start.lowerBound..<end.upperBound, with: section)
        return updated
    }
}
