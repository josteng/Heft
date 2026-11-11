import Foundation

/// Where Heft keeps its preferences.
///
/// Normally `UserDefaults.standard`, which for the installed bundle is the
/// `dev.josteng.Heft` domain the app and the `heft` command share.
///
/// With `HEFT_DEFAULTS_SUITE` set in the environment it is an isolated suite
/// instead, and that is the whole point: launching the GUI at a test vault
/// otherwise writes to the real store — it rewrites `vaultPath`, which is
/// where Spotlight capture files things, and pushes a temporary folder into
/// Open Recent. Both have had to be cleaned up by hand after testing, and the
/// capture one silently aims "Add to Today's Note" at a directory that is
/// about to be deleted.
///
/// A bundle can also name the domain it reads in its Info.plist, under
/// `HeftDefaultsSuite`. That is for the capture extension, a process of its
/// own whose standard domain is its own empty one; it has to answer "which
/// vault" from the same store the app writes.
///
/// One accessor rather than `UserDefaults.standard` at fifteen call sites, so
/// the isolation cannot be half-applied: a single setting still reaching the
/// real store is enough to lose the property.
public enum HeftDefaults {
    public static let suiteEnvironmentKey = "HEFT_DEFAULTS_SUITE"
    public static let suiteInfoKey = "HeftDefaultsSuite"

    public static let shared: UserDefaults = {
        let environment = ProcessInfo.processInfo.environment
        let suite = suiteName(environment: environment, info: Bundle.main.infoDictionary ?? [:])
        let defaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        // The real store only: a test or `--sandbox` run names its own suite.
        if (environment[suiteEnvironmentKey] ?? "").isEmpty,
           (suite ?? Bundle.main.bundleIdentifier) == domain {
            carryOver(UserDefaults.standard.persistentDomain(forName: legacyDomain), into: defaults)
        }
        return defaults
    }()

    /// The app's identifier, and so its preferences' domain, from 0.8.
    public static let domain = "dev.josteng.Heft"
    /// Before 0.8 Heft was `dev.stenglein.Heft`, and its settings are still
    /// there. Whichever process reaches the new store first, the app, the
    /// `heft` command or a Spotlight capture run before the app was opened,
    /// copies them over once.
    public static let legacyDomain = "dev.stenglein.Heft"
    public static let carriedOverKey = "dev.josteng.Heft.carriedOverFromStenglein"

    /// Copies what the old store holds and the new one does not, once.
    /// Keys keep their old names, so nothing else has to know.
    @discardableResult
    public static func carryOver(_ legacy: [String: Any]?, into defaults: UserDefaults) -> Int {
        guard !defaults.bool(forKey: carriedOverKey) else { return 0 }
        var copied = 0
        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(true, forKey: carriedOverKey)
        return copied
    }

    /// The domain a process reads instead of its own, or nil for its own.
    ///
    /// The environment outranks the bundle: a test launch has to be able to
    /// isolate any process, including one that names a real domain.
    public static func suiteName(environment: [String: String], info: [String: Any]) -> String? {
        if let suite = environment[suiteEnvironmentKey], !suite.isEmpty { return suite }
        if let suite = info[suiteInfoKey] as? String, !suite.isEmpty { return suite }
        return nil
    }

    /// True when running against an isolated store, so the app can say so
    /// rather than leaving someone to wonder why their settings look reset.
    public static var isSandboxed: Bool {
        let suite = ProcessInfo.processInfo.environment[suiteEnvironmentKey]
        return !(suite ?? "").isEmpty
    }
}
