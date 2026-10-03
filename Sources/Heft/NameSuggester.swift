import Foundation
import FoundationModels

/// Names for a note, suggested from what is in it by Apple's on-device
/// model, offered under the rename field as Finder offers them.
///
/// AppKit has no public rename suggestions, so this is Heft's own, on the
/// same model that names Ask's chats. Nothing leaves the Mac, and without
/// Apple Intelligence, or with the setting off, the field offers nothing.
enum NameSuggester {
    static func suggestions(for text: String, current: String) async -> [String] {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 20, case .available = SystemLanguageModel.default.availability else { return [] }
        let session = LanguageModelSession(
            instructions: "You suggest file names for notes. Reply with exactly three names, one per "
                + "line, each two to eight words, in the note's language, naming what the note is "
                + "about. No numbering, no quotes, no file extension, no full stop."
        )
        let prompt = "Current name: \(current)\n\nNote:\n\(body.prefix(2500))"
        guard let response = try? await session.respond(to: prompt) else { return [] }
        return cleaned(response.content, current: current)
    }

    /// One name a line, without list marks or characters a file name cannot
    /// hold, each once and none the name it already has.
    static func cleaned(_ text: String, current: String) -> [String] {
        var names: [String] = []
        for line in text.split(separator: "\n") {
            var name = String(line)
                .replacingOccurrences(of: #"^\s*(\d+[.)]|[-*•])\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”‘’*_#."))
            name = name.replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression)
            if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)) }
            guard !name.isEmpty, name.count <= 80, name.lowercased() != current.lowercased(),
                  !names.contains(where: { $0.lowercased() == name.lowercased() })
            else { continue }
            names.append(name)
        }
        return Array(names.prefix(3))
    }
}
