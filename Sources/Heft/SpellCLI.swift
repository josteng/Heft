import AppKit
import Foundation
import HeftCore

/// `heft spell <vault> [note]`, the editor's red underlines without a window.
///
/// It lives in the app target rather than beside the other verbs in `HeftCore`
/// because `NSSpellChecker` is AppKit, and `HeftCore` not importing AppKit is
/// what lets the rest of the command line run anywhere. The checker itself
/// needs no window and no run loop, so the answer here is the one the editor
/// would draw.
///
/// What it skips is not a second opinion about markdown: it is
/// `SpellCheckScope` over the same decorations the live surface styles with,
/// so a word this reports is a word the editor underlines.
enum SpellCLI {

    struct Finding {
        /// `spelling` or `grammar`, which is the red underline and the blue one.
        let kind: String
        let path: String
        let line: Int
        let column: Int
        let text: String
        /// Corrections for a misspelling; for grammar, what is wrong with it.
        let note: String
    }

    static func run(vaultPath: String, arguments: [String]) -> Never {
        let root = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        let split = CommandLineSpec.split(arguments, forVerb: "spell")
        let wantsJSON = split.flags.contains("--json")
        let grammar = !split.flags.contains("--no-grammar")

        var limit = Int.max
        if let index = split.flags.firstIndex(of: "--limit") {
            guard index + 1 < split.flags.count, let value = Int(split.flags[index + 1]),
                  value > 0
            else {
                FileHandle.standardError.write(Data(
                    "--limit takes a positive whole number\n".utf8))
                exit(1)
            }
            limit = value
        }

        let index = VaultIndex.open(vaultAt: root)
        let notes: [String]
        if let named = split.positional.first {
            guard let found = index.note(named: named) else {
                FileHandle.standardError.write(Data("no such note: \(named)\n".utf8))
                exit(1)
            }
            notes = [found.relativePath]
        } else {
            notes = index.notes.map(\.relativePath).sorted()
        }

        // One tag for the run, so a word ignored in one note stays ignored in
        // the next, the way it does across an editing session.
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { NSSpellChecker.shared.closeSpellDocument(withTag: tag) }

        var findings: [Finding] = []
        var truncated = false
        for relative in notes {
            guard let text = try? String(
                contentsOf: root.appendingPathComponent(relative), encoding: .utf8
            ) else { continue }
            for finding in check(text, path: relative, tag: tag, grammar: grammar) {
                guard findings.count < limit else { truncated = true; break }
                findings.append(finding)
            }
            if truncated { break }
        }

        if wantsJSON {
            JSONOutput.emit(findings.map {
                [
                    "kind": $0.kind, "path": $0.path, "line": $0.line,
                    "column": $0.column, "text": $0.text, "note": $0.note,
                ]
            })
        }

        guard !findings.isEmpty else {
            print("nothing to correct")
            exit(0)
        }
        for finding in findings {
            // Tab-separated like the other verbs, and `path:line:column` first
            // so a terminal that linkifies it can open the note at the word.
            let place = "\(finding.path):\(finding.line):\(finding.column)"
            print("\(place)\t\(finding.kind)\t\(finding.text)\t\(finding.note)")
        }
        if truncated {
            print("— stopped at \(findings.count). Raise --limit for the rest.")
        }
        exit(0)
    }

    /// What the checker finds in one note, in document order.
    ///
    /// One `check` call over the whole note rather than a walk of
    /// `checkSpelling(of:startingAt:)`. The walking form takes a language, and
    /// passing nil for it, as a vault that mixes languages must, makes it give
    /// up after the first couple of words; this form identifies the language
    /// itself and is what the text view uses, so the answer matches the
    /// underlines. It is also the only form that reports grammar.
    ///
    /// The checker reads the whole note rather than each prose run, because a
    /// word's neighbours are what decide whether it is a name. The excluded
    /// spans are dropped from its answer instead.
    static func check(_ text: String, path: String, tag: Int, grammar: Bool) -> [Finding] {
        let source = text as NSString
        let exclusions = SpellCheckScope.exclusions(
            for: LiveDecorator.decorations(in: text), in: source
        )
        var types = NSTextCheckingResult.CheckingType.spelling.rawValue
        if grammar { types |= NSTextCheckingResult.CheckingType.grammar.rawValue }
        let results = NSSpellChecker.shared.check(
            text, range: NSRange(location: 0, length: source.length), types: types,
            options: nil, inSpellDocumentWithTag: tag, orthography: nil, wordCount: nil
        )

        var findings: [Finding] = []
        for result in results {
            switch result.resultType {
            case .spelling:
                guard !SpellCheckScope.excludes(result.range, in: exclusions) else { continue }
                let place = position(of: result.range.location, in: source)
                findings.append(Finding(
                    kind: "spelling", path: path, line: place.line, column: place.column,
                    text: source.substring(with: result.range),
                    note: (NSSpellChecker.shared.guesses(
                        forWordRange: result.range, in: text, language: nil,
                        inSpellDocumentWithTag: tag
                    ) ?? []).prefix(5).joined(separator: ", ")
                ))
            case .grammar:
                // A grammar result covers the sentence and carries the clause
                // it objects to as an offset inside it, so the reported place
                // is the clause rather than wherever the sentence began.
                for detail in result.grammarDetails ?? [] {
                    let inner = (detail[NSGrammarRange] as? NSValue)?.rangeValue
                    let span = inner.map {
                        NSRange(location: result.range.location + $0.location, length: $0.length)
                    } ?? result.range
                    guard NSMaxRange(span) <= source.length,
                          !SpellCheckScope.excludes(span, in: exclusions) else { continue }
                    let place = position(of: span.location, in: source)
                    findings.append(Finding(
                        kind: "grammar", path: path, line: place.line, column: place.column,
                        text: source.substring(with: span),
                        note: (detail[NSGrammarUserDescription] as? String) ?? ""
                    ))
                }
            default:
                continue
            }
        }
        return findings.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// One-based line and column, counted in characters as an editor shows
    /// them rather than in UTF-16 units.
    ///
    /// By hand rather than through `enumerateSubstrings`, which enumerates the
    /// partial line the offset sits in as a line of its own and put every
    /// column at 1.
    private static func position(of offset: Int, in source: NSString) -> (line: Int, column: Int) {
        var line = 1
        var lineStart = 0
        var index = 0
        while index < offset {
            if source.character(at: index) == 0x0A {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        let head = source.substring(with: NSRange(location: lineStart, length: offset - lineStart))
        return (line, head.count + 1)
    }
}
