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

    /// The guidance itself, pointing at whichever binary is installed.
    public static func section(binaryPath: String) -> String {
        """
        \(markerStart)
        <!-- Written by `heft agent-setup`. Edits between these markers are
             replaced when it is run again; everything else in this file is
             left alone. -->

        # This vault is edited in Heft

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

        ## Finding things

        ```bash
        heft find . <query>      # full-text search across the vault
        heft files .             # every note, vault-relative
        heft proposals .         # what is already waiting for review
        heft diff . <id>         # what one of them would change
        ```

        ## After proposing

        Say what you proposed, and stop. Do not wait for the review, and do not
        apply your own proposal by writing the file as well.
        \(markerEnd)
        """
    }

    /// `existing` with the guide added, or its previous copy replaced.
    ///
    /// Idempotent on purpose: this file is the user's, and may well hold notes
    /// of their own about their vault. Re-running after an upgrade has to
    /// refresh Heft's section without touching a word of the rest.
    public static func merged(into existing: String?, section: String) -> String {
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return section + "\n" }

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
