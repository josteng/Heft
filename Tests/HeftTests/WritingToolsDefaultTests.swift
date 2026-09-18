import AppKit
import Testing
@testable import Heft

/// What a bare editor view offers the system before anyone configures it.
///
/// AppKit puts the Writing Tools affordance on any text view holding a
/// selection, and showing it opens a remote view connection to a UI service.
/// The suite builds these views by the dozen outside any window, where that
/// connection raised and took the whole run down with it.
@MainActor
@Suite("Writing Tools default")
struct WritingToolsDefaultTests {

    @Test("A view built outside the editor does not offer Writing Tools")
    func bareViewKeepsWritingToolsOff() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        #expect(view.writingToolsBehavior == .none)
    }

    @Test("The editor can still turn Writing Tools on")
    func theEditorCanOptIn() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.writingToolsBehavior = .default
        #expect(view.writingToolsBehavior == .default)
    }

    /// AppKit reads the property through the Objective-C accessor, so an
    /// override that only Swift can see would not reach it.
    @Test("The override is what Objective-C sees")
    func objectiveCSeesTheOverride() throws {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        let seen = try #require(
            (view as AnyObject).value(forKey: "writingToolsBehavior") as? Int
        )
        #expect(seen == NSWritingToolsBehavior.none.rawValue)
    }

    /// The other two that draw through a UI service. Both are on by default
    /// on a plain `NSTextView`, and the editor names what it wants itself.
    @Test("A bare view offers neither completion nor predictions")
    func theOtherServicesAreOffToo() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        #expect(view.isAutomaticTextCompletionEnabled == false)
        #expect(view.inlinePredictionType == .no)
    }

    @Test("The editor can still turn those on")
    func theEditorCanOptIntoThoseToo() {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.isAutomaticTextCompletionEnabled = true
        view.inlinePredictionType = .default
        #expect(view.isAutomaticTextCompletionEnabled)
        #expect(view.inlinePredictionType == .default)
    }

    /// Both are read through the Objective-C accessors as well.
    @Test("Objective-C sees those overrides too")
    func objectiveCSeesTheOthers() throws {
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        let completion = try #require(
            (view as AnyObject).value(forKey: "automaticTextCompletionEnabled") as? Bool
        )
        #expect(completion == false)
        let predictions = try #require(
            (view as AnyObject).value(forKey: "inlinePredictionType") as? Int
        )
        #expect(predictions == NSTextInputTraitType.no.rawValue)
    }
}
