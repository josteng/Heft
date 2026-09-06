import AppIntents
import ExtensionFoundation

/// The process a capture runs in, which is not the app's.
///
/// A background App Intent declared in the app still runs *inside* the app,
/// and macOS brings the app forward to run it: a minimized Heft jumped out of
/// the Dock every time a line was filed into it from Spotlight. An intent
/// compiled only into this extension can only run here, in a short-lived
/// process with no windows, so the app is left exactly as it was, or not
/// launched at all.
///
/// The extension is sandboxed because macOS refuses to launch one that is
/// not, and refuses silently: Shortcuts reports that it "couldn't communicate
/// with the app" and nothing is logged. What the sandbox would otherwise
/// keep out, the vault and the app's preferences, is let back in by the
/// entitlements beside the Info.plist.
@main
struct HeftCaptureExtension: AppIntentsExtension {}
