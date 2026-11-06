import Foundation

/// How reviewing a proposal ends: whether the note it changed opens, to see
/// the accepted change in place. On unless turned off, on each device.
public enum ReviewPreference {
    public static let opensAcceptedNoteKey = "dev.stenglein.Heft.review.opensAcceptedNote"

    public static var opensAcceptedNote: Bool {
        get { HeftDefaults.shared.object(forKey: opensAcceptedNoteKey) as? Bool ?? true }
        set { HeftDefaults.shared.set(newValue, forKey: opensAcceptedNoteKey) }
    }
}
