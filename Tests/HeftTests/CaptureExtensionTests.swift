import Foundation
import HeftCore
import Testing

/// The capture extension is a shape the build cannot check for itself: an
/// extension that is not sandboxed, or a capture intent that is also in
/// the app, both build cleanly and fail only when Spotlight is asked. Each
/// of these is a fact the runtime depends on, read from the files that
/// decide it.
@Suite("Capture extension")
struct CaptureExtensionTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func swiftFiles(in directory: String) throws -> [(name: String, text: String)] {
        let url = root.appendingPathComponent(directory)
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { ($0, try String(contentsOf: url.appendingPathComponent($0), encoding: .utf8)) }
    }

    // MARK: - Which store a process reads

    @Test("The environment names the store before the bundle does")
    func environmentOutranksBundle() {
        let suite = HeftDefaults.suiteName(
            environment: [HeftDefaults.suiteEnvironmentKey: "test.suite"],
            info: [HeftDefaults.suiteInfoKey: "bundle.suite"]
        )
        #expect(suite == "test.suite")
    }

    @Test("A bundle names the store when the environment does not")
    func bundleNamesTheStore() {
        let suite = HeftDefaults.suiteName(
            environment: [:],
            info: [HeftDefaults.suiteInfoKey: "bundle.suite"]
        )
        #expect(suite == "bundle.suite")
    }

    @Test("With neither, a process reads its own store")
    func ownStoreByDefault() {
        #expect(HeftDefaults.suiteName(environment: [:], info: [:]) == nil)
        #expect(HeftDefaults.suiteName(
            environment: [HeftDefaults.suiteEnvironmentKey: ""],
            info: [HeftDefaults.suiteInfoKey: ""]
        ) == nil)
    }

    // MARK: - The extension's declarations

    @Test("The extension reads the app's preferences, under the key the accessor looks up")
    func extensionReadsTheAppsStore() throws {
        let info = try plist("Config/HeftCapture-Info.plist")
        #expect(info[HeftDefaults.suiteInfoKey] as? String == "dev.stenglein.Heft")
        let entitlements = try plist("Config/HeftCapture.entitlements")
        let domains = entitlements["com.apple.security.temporary-exception.shared-preference.read-write"] as? [String]
        #expect(domains == ["dev.stenglein.Heft"])
    }

    @Test("The extension is an App Intents extension, and sandboxed, or macOS never launches it")
    func extensionIsSandboxedAndDeclared() throws {
        let info = try plist("Config/HeftCapture-Info.plist")
        let attributes = info["EXAppExtensionAttributes"] as? [String: Any]
        #expect(attributes?["EXExtensionPointIdentifier"] as? String == "com.apple.appintents-extension")
        let entitlements = try plist("Config/HeftCapture.entitlements")
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        let files = entitlements["com.apple.security.temporary-exception.files.absolute-path.read-write"] as? [String]
        #expect(files == ["/"], "a vault is wherever the reader keeps it")
    }

    @Test("The project embeds it where ExtensionKit looks")
    func projectEmbedsTheExtension() throws {
        let project = try text("Heft.xcodeproj/project.pbxproj")
        #expect(project.contains("productType = \"com.apple.product-type.extensionkit-extension\""))
        #expect(project.contains("dstSubfolderSpec = 16"), "Contents/Extensions, not PlugIns")
        #expect(project.contains("CODE_SIGN_ENTITLEMENTS = Config/HeftCapture.entitlements"))
    }

    // MARK: - Where the intents live

    @Test("The captures are compiled into the extension and nowhere else")
    func capturesLiveOnlyInTheExtension() throws {
        // A copy in the app would be a second place the system could run
        // one, and a running app is the place it prefers.
        let captures = ["CaptureToInboxIntent", "AddToTodaysNoteIntent"]
        let extensionSources = try swiftFiles(in: "Sources/HeftCapture").map(\.text).joined()
        for capture in captures {
            #expect(extensionSources.contains("struct \(capture): AppIntent"), Comment(rawValue: capture))
        }
        for directory in ["Sources/Heft", "Sources/Heft/Views", "Sources/HeftCore"] {
            for file in try swiftFiles(in: directory) {
                for capture in captures {
                    #expect(!file.text.contains("struct \(capture)"), "\(directory)/\(file.name) declares \(capture)")
                }
            }
        }
    }

    @Test("The extension has no windows to import")
    func extensionImportsNoUI() throws {
        for file in try swiftFiles(in: "Sources/HeftCapture") {
            #expect(!file.text.contains("import AppKit"), Comment(rawValue: file.name))
            #expect(!file.text.contains("import SwiftUI"), Comment(rawValue: file.name))
        }
    }
}
