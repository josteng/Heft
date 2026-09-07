import Foundation

/// The machine-readable form of a verb's answer.
///
/// The verbs print tab-separated columns, which is fine to read and wrong to
/// parse: a note's path may hold a quote, a colon or a tab-adjacent space,
/// and nothing in the line says which. An agent that has to guess the shape
/// guesses wrong on exactly the paths that matter.
///
/// `JSONSerialization` rather than `Codable` because every answer here is a
/// list of a few plain fields, and a struct per verb would be more ceremony
/// than the shapes are worth. Sorted keys so a diff of two runs is readable,
/// and slashes unescaped so a path stays a path to the eye.
public enum JSONOutput {

    public static func text(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Prints it, or exits saying so. A caller that asked for JSON and got a
    /// half-written line would parse the fragment.
    public static func emit(_ value: Any) -> Never {
        guard let text = text(value) else {
            FileHandle.standardError.write(Data("could not render that answer as JSON\n".utf8))
            exit(1)
        }
        print(text)
        exit(0)
    }
}
