import AppKit
import HeftCore
import Testing
@testable import Heft

/// Appearance ▸ Headings: the face headings are set in, and whether they
/// carry the bar in their level's colour.
@Suite("Heading style")
@MainActor
struct HeadingStyleTests {

    /// A Mac that has drawn the bar keeps it after the update; a first launch
    /// starts plain.
    @Test("What a Mac without the setting starts with")
    func before() throws {
        let defaults = try #require(UserDefaults(suiteName: "dev.stenglein.Heft.headings-\(UUID().uuidString)"))
        #expect(AppearanceSettings.headingColorBeforeTheSetting(colorful: true, in: defaults) == .none)
        defaults.set(["/vault"], forKey: VaultRegistry.recentVaultsKey)
        #expect(AppearanceSettings.headingColorBeforeTheSetting(colorful: true, in: defaults) == .levelColors)
        #expect(AppearanceSettings.headingColorBeforeTheSetting(colorful: false, in: defaults) == .none)
    }

    @Test("New York is the serif, a step larger; System is as it was")
    func faces() {
        let system = Theme.headingFont(1, size: 28, face: .system)
        #expect(system == NSFont.systemFont(ofSize: 28, weight: .bold))
        let serif = Theme.headingFont(1, size: 28, face: .newYork)
        #expect(serif.pointSize == 30)
        #expect(serif.fontDescriptor.symbolicTraits.contains(.bold) == false, "lighter at the top")
        #expect(serif.fontName.contains("NewYork"), "got \(serif.fontName)")
        #expect(Theme.headingFont(4, size: 16, face: .newYork).pointSize == 17)
        #expect(Theme.headingFont(5, size: 15, face: .newYork).pointSize == 15)
    }

    private func styled(_ note: String, font: AppearancePreferences.HeadingFont, bars: Bool) -> HeftTextKit2View {
        let context = RenderContext(
            index: .empty, current: nil, vaultRoot: nil,
            headingFont: font, headingBars: bars
        )
        let editor = LiveTextEditor(
            text: .constant(note), documentIdentity: "h.md", generation: 0,
            generationKeepsPosition: false, findSelection: nil, insertion: nil,
            context: context, onAttachment: { _ in nil }, onFollowLink: { _ in },
            onVimSearch: { _ in }
        )
        let coordinator = LiveTextEditor.Coordinator(editor)
        let view = HeftTextKit2View(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        view.textContainer?.size = NSSize(width: 644, height: 1_000_000)
        view.textLayoutManager?.delegate = coordinator
        view.textStorage?.delegate = coordinator
        view.delegate = coordinator
        view.string = note
        view.setSelectedRange(NSRange(location: (note as NSString).length, length: 0))
        coordinator.restyle(view)
        return view
    }

    private func hasBar(_ view: HeftTextKit2View) -> Bool {
        view.liveLayout.blocks.values.contains {
            if case .headingAccent = $0 { return true }
            return false
        }
    }

    @Test("The bar is drawn only with Level Colors")
    func bars() {
        let note = "## Plans\n\nText.\n"
        #expect(hasBar(styled(note, font: .system, bars: true)))
        #expect(!hasBar(styled(note, font: .system, bars: false)))
    }

    @Test("Headings, quoted ones too, are set in the chosen face")
    func face() throws {
        let note = "## Plans\n\n> ### Quoted\n\nText.\n"
        let view = styled(note, font: .newYork, bars: false)
        let storage = try #require(view.textStorage)
        let text = note as NSString
        let heading = storage.attribute(.font, at: text.range(of: "Plans").location, effectiveRange: nil) as? NSFont
        #expect(heading?.fontName.contains("NewYork") == true)
        let quoted = storage.attribute(.font, at: text.range(of: "Quoted").location, effectiveRange: nil) as? NSFont
        #expect(quoted?.fontName.contains("NewYork") == true)
        let body = storage.attribute(.font, at: text.range(of: "Text").location, effectiveRange: nil) as? NSFont
        #expect(body?.fontName.contains("NewYork") == false, "body text stays the system font")
    }
}
