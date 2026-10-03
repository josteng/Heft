import FoundationModels

/// Whether Apple's on-device model can be used here, and why not, for the
/// settings that use it: naming chats and suggesting names. A switch for
/// something the Mac cannot do is greyed out and says why, rather than
/// offering what will quietly never happen.
enum OnDeviceModel {
    /// Nil when the model can be used; otherwise what stands in the way.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use this."
        case .unavailable(.deviceNotEligible):
            return "This Mac cannot run Apple Intelligence."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting its model ready. Try again later."
        case .unavailable:
            return "Apple Intelligence is not available on this Mac."
        }
    }
}
