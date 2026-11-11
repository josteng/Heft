import Foundation
import Testing
@testable import HeftCore

/// Heft 0.8 moved from `dev.stenglein.Heft` to `dev.josteng.Heft`, and a
/// reader's settings come along: copied once, never over a newer value.
struct PreferenceCarryOverTests {
    private func store() throws -> UserDefaults {
        let name = "dev.josteng.Heft.carry-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("The old settings are copied into an empty store")
    func copiesTheOldSettings() throws {
        let defaults = try store()
        let legacy: [String: Any] = ["dev.stenglein.Heft.vaultPath": "/Users/someone/Vault",
                                     "dev.stenglein.Heft.vim.enabled": true]
        #expect(HeftDefaults.carryOver(legacy, into: defaults) == 2)
        #expect(defaults.string(forKey: "dev.stenglein.Heft.vaultPath") == "/Users/someone/Vault")
        #expect(defaults.bool(forKey: "dev.stenglein.Heft.vim.enabled"))
    }

    @Test("A value already in the new store is kept")
    func keepsNewerValues() throws {
        let defaults = try store()
        defaults.set("/Users/someone/Newer", forKey: "dev.stenglein.Heft.vaultPath")
        HeftDefaults.carryOver(["dev.stenglein.Heft.vaultPath": "/Users/someone/Older"], into: defaults)
        #expect(defaults.string(forKey: "dev.stenglein.Heft.vaultPath") == "/Users/someone/Newer")
    }

    @Test("It happens once: a setting cleared afterwards stays cleared")
    func happensOnce() throws {
        let defaults = try store()
        let legacy: [String: Any] = ["dev.stenglein.Heft.vim.enabled": true]
        HeftDefaults.carryOver(legacy, into: defaults)
        defaults.removeObject(forKey: "dev.stenglein.Heft.vim.enabled")
        #expect(HeftDefaults.carryOver(legacy, into: defaults) == 0)
        #expect(defaults.object(forKey: "dev.stenglein.Heft.vim.enabled") == nil)
    }

    @Test("The extensions may read the old store to carry it over")
    func extensionsReadTheOldStore() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["HeftCapture", "HeftMacShare"] {
            let data = try Data(contentsOf: root.appendingPathComponent("Config/\(name).entitlements"))
            let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let readOnly = plist["com.apple.security.temporary-exception.shared-preference.read-only"] as? [String]
            #expect(readOnly == [HeftDefaults.legacyDomain], "\(name)")
        }
    }
}
