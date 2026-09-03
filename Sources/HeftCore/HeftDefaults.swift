import Foundation

/// Where Heft keeps its preferences.
///
/// Normally `UserDefaults.standard`, which for the installed bundle is the
/// `dev.stenglein.Heft` domain the app and the `heft` command share.
///
/// With `HEFT_DEFAULTS_SUITE` set in the environment it is an isolated suite
/// instead, and that is the whole point: launching the GUI at a test vault
/// otherwise writes to the real store — it rewrites `vaultPath`, which is
/// where Spotlight capture files things, and pushes a temporary folder into
/// Open Recent. Both have had to be cleaned up by hand after testing, and the
/// capture one silently aims "Add to Today's Note" at a directory that is
/// about to be deleted.
///
/// One accessor rather than `UserDefaults.standard` at fifteen call sites, so
/// the isolation cannot be half-applied: a single setting still reaching the
/// real store is enough to lose the property.
public enum HeftDefaults {
    public static let suiteEnvironmentKey = "HEFT_DEFAULTS_SUITE"

    public static let shared: UserDefaults = {
        guard let suite = ProcessInfo.processInfo.environment[suiteEnvironmentKey],
              !suite.isEmpty,
              let defaults = UserDefaults(suiteName: suite)
        else { return .standard }
        return defaults
    }()

    /// True when running against an isolated store, so the app can say so
    /// rather than leaving someone to wonder why their settings look reset.
    public static var isSandboxed: Bool {
        let suite = ProcessInfo.processInfo.environment[suiteEnvironmentKey]
        return !(suite ?? "").isEmpty
    }
}
