import Foundation
import FoundationModels

/// Names a chat from its first question and answer with Apple's on-device
/// model, as macOS suggests a name for a file.
///
/// Apart from Ask's agent on purpose: the agent is never asked to name
/// anything, which drifted when it was (resumed sessions kept repeating the
/// line). This runs on the Mac, costs nothing, and where the model is not
/// there, without Apple Intelligence or before it has downloaded, the chat
/// keeps its first question as its name.
enum ChatTitler {
    static func title(question: String, answer: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(
            instructions: "You name conversations. Reply with only a title of two to five words, "
                + "in the language of the conversation, with no quotes and no full stop."
        )
        let prompt = "Question: \(question.prefix(600))\n\nAnswer: \(answer.prefix(1200))"
        guard let response = try? await session.respond(to: prompt) else { return nil }
        return cleaned(response.content)
    }

    /// The first line, without quotes, markup or a full stop, and short.
    static func cleaned(_ text: String) -> String? {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = line
            .replacingOccurrences(of: "Title:", with: "", options: [.caseInsensitive, .anchored])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”‘’*_#."))
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
    }
}
