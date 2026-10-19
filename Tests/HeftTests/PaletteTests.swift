import AppKit
import Foundation
import HeftCore
import Testing
@testable import Heft

/// Colors ▸ Vivid / Muted, and the swatches a colour can be picked from.
@Suite("Color palette")
@MainActor
struct PaletteTests {

    @Test("A stored colour is a swatch by name, an exact hex, or nothing")
    func choices() {
        typealias Choice = AppearancePreferences.ColorChoice
        #expect(Choice(stored: "teal") == .swatch(.teal))
        #expect(Choice(stored: "#112233") == .custom("#112233"))
        #expect(Choice(stored: nil) == nil)
        #expect(Choice(stored: "not a colour") == nil)
        #expect(Choice.swatch(.red).stored == "red")
    }

    /// A vault set up now starts calm; a file from before keeps the look it
    /// had, colourful and vivid, whatever the new defaults are.
    @Test("New vaults start muted and plain; old files stay vivid")
    func defaults() throws {
        let fresh = AppearancePreferences()
        #expect(fresh.palette == .muted)
        #expect(!fresh.colorfulFormatting)
        let old = try JSONDecoder().decode(AppearancePreferences.self, from: Data("{}".utf8))
        #expect(old.palette == .vivid)
        #expect(old.colorfulFormatting)
        #expect(old == AppearancePreferences.legacy)
        #expect(AppearancePreferences.step(stored: nil, current: .legacy) == .nothing)
    }

    private func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        var out = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    @Test("Muted is the same hue, softer, in light and dark alike")
    func muted() {
        let vivid = resolved(Palette.color(.red, .vivid), dark: false)
        let lightMuted = resolved(Palette.color(.red, .muted), dark: false)
        let darkMuted = resolved(Palette.color(.red, .muted), dark: true)
        #expect(lightMuted.saturationComponent < vivid.saturationComponent)
        #expect(darkMuted.brightnessComponent > lightMuted.brightnessComponent, "lighter on a dark page")
        #expect(abs(lightMuted.redComponent - 0x94 / 255.0) < 0.01)
    }

    @Test("Code is graphite unless chosen, in either palette")
    func code() {
        #expect(Palette.code(.vivid, chosen: nil) == Palette.color(.graphite, .vivid))
        #expect(resolved(Palette.code(.muted, chosen: nil), dark: false)
                == resolved(Palette.color(.graphite, .muted), dark: false))
        #expect(Palette.code(.muted, chosen: .systemGreen) == .systemGreen)
        #expect(Palette.code(.vivid, chosen: .systemGreen) == .systemGreen)
    }

    @Test("Links follow the accent as it is when vivid, softened when muted")
    func accent() {
        #expect(Palette.followingAccent(.systemBlue, .vivid) == .systemBlue)
        let softened = resolved(Palette.followingAccent(.systemBlue, .muted), dark: false)
        #expect(softened.saturationComponent < resolved(.systemBlue, dark: false).saturationComponent)
    }

    /// `withAlphaComponent` on a dynamic colour pins it to whatever
    /// appearance is current, so the fill's alpha is in each mode's colour.
    @Test("A muted highlight keeps its light and dark colours")
    func highlight() {
        let fill = Palette.highlightFill(.yellow, .muted)
        let light = resolved(fill, dark: false)
        let dark = resolved(fill, dark: true)
        #expect(abs(light.alphaComponent - 0.18) < 0.01)
        #expect(dark.brightnessComponent > light.brightnessComponent)
    }

    @Test("A muted note hands its palette to every line, and quiets code")
    func styled() {
        let context = RenderContext(index: .empty, current: nil, vaultRoot: nil, palette: .muted)
        let source = "> [!tip] Tip\n> body\n\nRun `make`."
        let storage = NSTextStorage(string: source)
        let layout = LiveStyler.apply(to: storage, reveal: .none, context: context)
        #expect(layout.palette == .muted)
        let code = (source as NSString).range(of: "make").location
        let fill = storage.attribute(.backgroundColor, at: code, effectiveRange: nil) as? NSColor
        #expect(fill.map { resolved($0, dark: false).alphaComponent } == resolved(Palette.codeFill(.muted), dark: false).alphaComponent)
        let vivid = LiveStyler.apply(to: NSTextStorage(string: source), reveal: .none,
                                     context: RenderContext(index: .empty, current: nil, vaultRoot: nil))
        #expect(vivid.palette == .vivid)
    }
}
