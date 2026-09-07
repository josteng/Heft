import Foundation

/// The rules that make the proposal contract enforced rather than asked for.
///
/// `CLAUDE.md` asks an agent not to write notes directly. Asking works most of
/// the time and fails exactly when it matters: a long session, a compacted
/// context, a model that decided this once was fine. Claude Code will refuse a
/// tool outright when a project says so, and a vault is a project.
///
/// Two rules, and both are deliberately narrow:
///
/// - **Editing a file inside the vault is denied**, by path rather than by
///   tool name. Denying the tools outright would also stop the agent writing
///   the scratch file the guide's own workflow uses
///   (`heft propose --from /tmp/new.md`), which would make the setup that
///   enforces the contract the setup that prevents following it.
/// - **`heft` is allowed without asking.** Every proposal verb is one, and a
///   contract that costs a permission prompt per command is one people turn
///   off. Nothing `heft` does writes a note: `propose` writes to
///   `.heft/proposals`, and the editor applies it.
///
/// One rule covers all three writing tools, and it has to be spelled `Edit`.
/// Claude Code checks path-scoped permissions against `Edit(path)` and
/// `Read(path)` rules only. A path rule written for `Write`, `NotebookEdit`
/// or `Glob` is accepted and then never consulted, and warned about at
/// startup; the documentation says to write `Edit(docs/**)` in place of
/// `Write(docs/**)`. So `Edit(**)` is what actually denies the Write tool,
/// and the older spellings are removed rather than left as rules that look
/// like they are doing the work and are not.
///
/// This is a guardrail, not a sandbox. An agent with a shell can still write a
/// file, and the point is not to stop a determined one; it is that the easy
/// path and the correct path are the same path.
public enum AgentPermissions {

    /// Where Claude Code looks, relative to the vault root.
    public static let path = ".claude/settings.json"

    public static let allow = ["Bash(heft:*)"]

    /// `Edit` covers Write and NotebookEdit as well: the check is on the path,
    /// not on which tool asked.
    public static let deny = ["Edit(**)"]

    /// Rules an earlier Heft wrote that Claude Code no longer consults.
    ///
    /// Removed on merge rather than ignored, for two reasons that are worth
    /// keeping apart. Each one earns a warning at startup, which trains the
    /// reader to skip warnings. And a rule that is never consulted still
    /// reads as protection to whoever opens the file, so leaving it makes the
    /// settings claim a guarantee it does not provide.
    ///
    /// Deliberately not claiming more than that. An earlier version of this
    /// comment said such a rule made Claude Code decline the file's
    /// permission mode outright, which the documentation does not say; the
    /// case for removing them does not need it.
    public static let superseded = ["Write(**)", "NotebookEdit(**)"]

    /// The vault's settings with Heft's rules present, and everything else in
    /// the file exactly as it was.
    ///
    /// Merged rather than written, for the reason the guide is merged rather
    /// than written: this is the user's file. They may have allowed their own
    /// commands, set a model, or turned something off, and none of that is
    /// ours to drop. Idempotent, so running `agent-setup` again after an
    /// upgrade adds nothing twice.
    ///
    /// A rule the user has deliberately deleted comes back, which is the one
    /// thing this cannot tell from a rule that was never there. That is the
    /// same trade `agent-setup` already makes with the guide: it is a setup
    /// command, and it sets things up.
    public static func merged(into existing: String?) -> String {
        var root = parsed(existing) ?? [:]
        var permissions = root["permissions"] as? [String: Any] ?? [:]

        for (key, wanted) in [("allow", allow), ("deny", deny)] {
            var rules = (permissions[key] as? [String] ?? []).filter { !superseded.contains($0) }
            for rule in wanted where !rules.contains(rule) { rules.append(rule) }
            permissions[key] = rules
        }
        root["permissions"] = permissions

        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return existing ?? "" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// True when the file already carries every rule.
    public static func isSatisfied(by existing: String?) -> Bool {
        guard let permissions = (parsed(existing)?["permissions"]) as? [String: Any] else {
            return false
        }
        let allowed = permissions["allow"] as? [String] ?? []
        let denied = permissions["deny"] as? [String] ?? []
        guard allow.allSatisfy(allowed.contains), deny.allSatisfy(denied.contains) else {
            return false
        }
        // A file still carrying a rule Claude Code rejects is not satisfied,
        // however many of the right rules are beside it: the whole file is
        // what gets set aside.
        return !(allowed + denied).contains(where: superseded.contains)
    }

    /// A file that is not JSON at all is treated as no file.
    ///
    /// Refusing to proceed would leave the vault unprotected over a stray
    /// comma, and the alternative — overwriting — would throw away whatever
    /// the user meant to write. Neither is good, so the caller is told and
    /// decides; `install` declines to touch it.
    public static func parsed(_ text: String?) -> [String: Any]? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// Whether there is a file here that cannot be merged into.
    public static func isUnreadable(_ text: String?) -> Bool {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return parsed(text) == nil
    }
}
