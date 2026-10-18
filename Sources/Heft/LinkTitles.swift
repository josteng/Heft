import Foundation
import FoundationModels
import HeftCore
import LinkPresentation

/// Titles for a pasted web address: the page's own, read the way Messages
/// reads a link preview, and short versions from Apple's on-device model,
/// offered as the rename field offers names.
///
/// AppKit-free, because the iOS share sheet compiles this same file to
/// offer the same titles for a shared link.
///
/// Fetching the title loads the page, so the site sees a visit; that is
/// why it sits behind a setting. The short titles never leave the Mac, and
/// without Apple Intelligence there are none.
enum LinkTitles {
    static func pageTitle(_ url: URL) async -> String? {
        let provider = LPMetadataProvider()
        // The title is all that is wanted; no icon, no preview image.
        provider.shouldFetchSubresources = false
        provider.timeout = 6
        return try? await provider.startFetchingMetadata(for: url).title
    }

    static func shortTitles(_ title: String, _ url: URL) async -> [String] {
        guard case .available = SystemLanguageModel.default.availability else { return [] }
        let session = LanguageModelSession(
            instructions: "You shorten web page titles into link text for notes. Reply with exactly "
                + "three alternatives, one per line, each two to six words, in the title's "
                + "language, saying what the page is about. Leave out the site's name and section. "
                + "No numbering, no quotes, no full stop."
        )
        let prompt = "Page title: \(title)\nAddress: \(url.absoluteString)"
        guard let response = try? await session.respond(to: prompt) else { return [] }
        return cleaned(response.content, avoiding: [title])
    }

    /// Text for a link to `note` that reads right inside `sentence`: how the
    /// note is referred to at that point, such as a paper's short name or
    /// a plural, in the sentence's own language. Never the sentence again,
    /// and never just the note's whole name, which the link already is.
    static func linkTexts(sentence: String, note: String, opening: String) async -> [String] {
        guard case .available = SystemLanguageModel.default.availability else { return [] }
        let session = LanguageModelSession(instructions: linkTextInstructions)
        let prompt = "Unfinished sentence: \(sentence)\nLinked note: \(note)\nThe note begins:\n\(opening.prefix(600))"
        guard let response = try? await session.respond(to: prompt, generating: LinkTextIdeas.self)
        else { return [] }
        return usable(response.content.texts, sentence: sentence, note: note)
    }

    /// What the model wrote, without the sentence repeated back or the
    /// note's whole name, which the link already is.
    static func usable(_ texts: [String], sentence: String, note: String) -> [String] {
        let lead = sentence.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = texts.filter { (text: String) -> Bool in
            let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
            return lead.isEmpty || !lowered.hasPrefix(lead)
        }
        return cleaned(kept.joined(separator: "\n"), avoiding: [note])
    }

    private static let linkTextInstructions = """
        You write the visible text of a link to a note, to be placed at the end of an unfinished \
        sentence. Give only the words that go inside the link: how the note is referred to there, \
        short, in the sentence's language and fitting its grammar. For example, for the note \
        "Smith2023 - Large models in radiology" after "As shown by", good link texts are \
        "Smith2023", "Smith et al." and "the radiology study". Never repeat the sentence.
        """

    /// One title a line, without list marks or quotes, each once and none
    /// a repeat of what is already offered.
    static func cleaned(_ text: String, avoiding taken: [String]) -> [String] {
        var seen = Set(taken.map { $0.lowercased() })
        var titles: [String] = []
        for line in text.split(separator: "\n") {
            let title = String(line)
                .replacingOccurrences(of: #"^\s*(\d+[.)]|[-*•])\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”‘’*_#."))
            guard !title.isEmpty, title.count <= 80, seen.insert(title.lowercased()).inserted else { continue }
            titles.append(title)
        }
        return Array(titles.prefix(3))
    }
}

/// What the model is asked to fill in for link text: exactly three ways to
/// write it, which guided generation holds it to rather than lines that
/// have to be picked apart afterwards.
@Generable
struct LinkTextIdeas {
    @Guide(description: "Three ways to write the link's visible text, each one to five words", .count(3))
    var texts: [String]
}
