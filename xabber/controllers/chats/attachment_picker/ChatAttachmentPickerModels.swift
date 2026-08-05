import Foundation

enum ChatAttachmentSource: Hashable {
    case gallery
    case file
    case geolocation
    case contact
}

enum ChatAttachmentFlowError: Error, Equatable {
    case missingPresenter
    case presentationFailed
    case sendBlocked(ChatAttachmentSendBlockReason)
}

struct ChatAttachmentPickerEntryPlan: Equatable {
    let presentsPicker: Bool
    let resumesAvailability: Bool

    static func make(
        isTelegramAttachmentPickerEnabled: Bool?,
        availabilityState: CloudStorageAvailabilityState
    ) -> ChatAttachmentPickerEntryPlan {
        _ = isTelegramAttachmentPickerEnabled

        let resumesAvailability: Bool
        switch availabilityState {
        case .ready:
            resumesAvailability = false
        case .discovering, .authorizing, .retryableFailure:
            resumesAvailability = true
        case .unsupported:
            resumesAvailability = false
        }

        return ChatAttachmentPickerEntryPlan(
            presentsPicker: true,
            resumesAvailability: resumesAvailability
        )
    }
}
