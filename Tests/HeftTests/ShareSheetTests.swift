import Foundation
import HeftCore
import HeftShareShared
import Testing
import UniformTypeIdentifiers

/// What a share becomes in a note, which the phone's and the Mac's share
/// sheets both compile, and the Mac extension's declarations, which build
/// cleanly when wrong and fail only when someone shares.
@Suite("Share sheet")
struct ShareSheetTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func item(_ attachment: NSSecureCoding, type: UTType, title: String? = nil) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(item: attachment, typeIdentifier: type.identifier)]
        if let title { item.attributedContentText = NSAttributedString(string: title) }
        return item
    }

    // MARK: - Reading the items

    /// macOS hands a shared address over as its bytes, where iOS hands over
    /// a URL; a sheet that only took the latter opened empty on the Mac.
    @Test("An address handed over as bytes, as macOS does, is read")
    func addressAsData() async throws {
        let address = "https://example.com/notes/paper"
        let shared = await SharedContent.markdown(from: [
            item(Data(address.utf8) as NSData, type: .url, title: "A paper"),
        ])
        #expect(shared.url?.absoluteString == address)
        #expect(shared.text == "[A paper](\(address))")
        #expect(shared.title == "A paper")
    }

    @Test("An address handed over as a URL, as iOS does, is read")
    func addressAsURL() async throws {
        let address = try #require(URL(string: "https://example.com/notes/paper"))
        let shared = await SharedContent.markdown(from: [item(address as NSURL, type: .url)])
        #expect(shared.url == address)
        #expect(shared.text == address.absoluteString, "no title: the bare address, looked up later")
        #expect(shared.title == nil)
    }

    @Test("Text handed over as bytes is read")
    func textAsData() async {
        let shared = await SharedContent.markdown(from: [
            item(Data("  a quoted line \n".utf8) as NSData, type: .plainText),
        ])
        #expect(shared.text == "a quoted line")
        #expect(shared.url == nil)
    }

    // MARK: - Retitling

    @Test("A title replaces the link's text and leaves the comment around it")
    func retitleKeepsComment() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let text = "read later: [Old [title]](https://example.com/a) for the talk"
        #expect(SharedContent.retitled(text, url: url, title: "New")
                == "read later: [New](https://example.com/a) for the talk")
    }

    @Test("A bare address becomes a link, and a rewritten text becomes the link")
    func retitleBareAndRewritten() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(SharedContent.retitled("see https://example.com/a", url: url, title: "Page [1]")
                == "see [Page (1)](https://example.com/a)")
        #expect(SharedContent.retitled("nothing of it left", url: url, title: "Page")
                == "[Page](https://example.com/a)")
    }

    // MARK: - The settings the Mac sheet honours

    @Test("Both link-title switches are on until turned off")
    func linkTitleSwitches() throws {
        let suite = "dev.stenglein.Heft.tests.linkTitles.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LinkTitlePreference.pageTitles(in: defaults))
        #expect(LinkTitlePreference.shortTitles(in: defaults))
        defaults.set(false, forKey: LinkTitlePreference.pageTitlesKey)
        #expect(!LinkTitlePreference.pageTitles(in: defaults))
        #expect(LinkTitlePreference.shortTitles(in: defaults))
        defaults.set(false, forKey: LinkTitlePreference.shortTitlesKey)
        #expect(!LinkTitlePreference.shortTitles(in: defaults))
    }

    // MARK: - The Mac extension's declarations

    @Test("The Mac extension is a share service that reads the app's preferences")
    func macExtensionDeclared() throws {
        let info = try plist("Config/HeftMacShare-Info.plist")
        let ext = try #require(info["NSExtension"] as? [String: Any])
        #expect(ext["NSExtensionPointIdentifier"] as? String == "com.apple.share-services")
        #expect(info[HeftDefaults.suiteInfoKey] as? String == "dev.stenglein.Heft")
    }

    @Test("The Mac extension is sandboxed, reaches any vault, and may load a page")
    func macExtensionEntitlements() throws {
        let entitlements = try plist("Config/HeftMacShare.entitlements")
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        let files = entitlements["com.apple.security.temporary-exception.files.absolute-path.read-write"] as? [String]
        #expect(files == ["/"], "a vault is wherever the reader keeps it")
        let domains = entitlements["com.apple.security.temporary-exception.shared-preference.read-write"] as? [String]
        #expect(domains == ["dev.stenglein.Heft"])
        #expect(entitlements["com.apple.security.network.client"] as? Bool == true, "the page title")
    }

    @Test("The Mac app embeds the extension in PlugIns, and both sheets share one reader")
    func projectEmbedsMacExtension() throws {
        let project = try String(contentsOf: root.appendingPathComponent("Heft.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        let app = try #require(project.range(of: "090000000000000000000001 /* Heft */ = {"))
        let appTarget = project[app.upperBound...].prefix { $0 != "}" }
        #expect(appTarget.contains("110000000000000000000003 /* Embed Foundation Extensions */"))
        let phase = try #require(project.range(of: "110000000000000000000003 /* Embed Foundation Extensions */ = {"))
        let phaseBody = project[phase.upperBound...].prefix(400)
        #expect(phaseBody.contains("dstSubfolderSpec = 13;"), "Contents/PlugIns")
        #expect(phaseBody.contains("HeftMacShare.appex"))
        for target in ["090000000000000000000009 /* HeftShare */ = {", "090000000000000000000010 /* HeftMacShare */ = {"] {
            let start = try #require(project.range(of: target), Comment(rawValue: target))
            let groups = project[start.upperBound...].prefix(1200)
            #expect(groups.contains("/* HeftShareShared */"), Comment(rawValue: target))
        }
    }
}
