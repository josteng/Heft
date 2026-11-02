import Foundation
import HeftCore
import Testing

@Suite("Suggesting a tag for a captured line")
struct TagSuggestionTests {
    private let vault = """
        # Week
        - Call the garage about the brakes #car
        - Book the garage for new tyres #car
        - Oil change at the garage #car
        - Read the paper on survival models #thesis
        - Survival curves for the thesis chapter #thesis
        - Plot the survival figures #thesis
        - Buy bread and milk
        ```
        - Garage in a code block #code
        ```
        """

    private var suggester: TagSuggester { TagSuggester(examples: TagSuggester.examples(in: vault)) }

    @Test("Lines carrying a tag are its examples, without the tag; code is not prose")
    func examples() {
        let found = TagSuggester.examples(in: vault)
        #expect(found["car"]?.count == 3)
        #expect(found["thesis"]?.count == 3)
        #expect(found["code"] == nil, "a tag in a fence is not one")
        #expect(found["car"]?.allSatisfy { !$0.contains("#") } == true)
    }

    @Test("A line that reads like a tag's lines gets it")
    func suggests() {
        #expect(suggester.suggest(for: "Ask the garage when the car is ready") == "car")
        #expect(suggester.suggest(for: "Fix the survival plot") == "thesis")
    }

    @Test("Nothing when unsure, or when the line already carries the tag")
    func silent() {
        #expect(suggester.suggest(for: "Water the plants") == nil, "no shared words")
        #expect(suggester.suggest(for: "Garage survival") == nil, "two tags tie, neither leads")
        #expect(suggester.suggest(for: "Call the garage #car") == nil, "already tagged")
    }

    @Test("Probabilities add up, and only a likely tag is offered")
    func probabilities() {
        let ranked = suggester.probabilities(for: "Ask the garage when the car is ready")
        #expect(abs(ranked.map(\.probability).reduce(0, +) - 1) < 1e-9)
        #expect(ranked.first?.tag == "car")
        #expect(suggester.suggest(for: "Ask the garage when the car is ready", confidence: 0.999) == nil,
                "too sure a bar for so few lines")
    }

    @Test("Words are compared without case, accents, plurals or filler")
    func words() {
        #expect(TagSuggester.words("The Figures für Café 2026 thesis") == ["figure", "cafe", "thesis"])
    }
}
