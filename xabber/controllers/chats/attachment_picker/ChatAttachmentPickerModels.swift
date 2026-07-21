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

enum ChatAttachmentPickerBlockReason: Equatable {
    case cloudStorageUnavailable
    case cloudStoragePending
}

enum ChatAttachmentPickerRoute: Equatable {
    case telegramAttachmentFlow
    case blocked(ChatAttachmentPickerBlockReason)
}

enum ChatAttachmentPickerRoutingPolicy {
    static func route(
        isTelegramAttachmentPickerEnabled: Bool?,
        availabilityState: CloudStorageAvailabilityState
    ) -> ChatAttachmentPickerRoute {
        switch availabilityState {
        case .ready:
            return .telegramAttachmentFlow
        case .discovering, .authorizing, .retryableFailure:
            return .blocked(.cloudStoragePending)
        case .unsupported:
            return .blocked(.cloudStorageUnavailable)
        }
    }

    static func route(
        isTelegramAttachmentPickerEnabled: Bool?,
        isCloudStorageAvailable: Bool
    ) -> ChatAttachmentPickerRoute {
        guard isCloudStorageAvailable else {
            return .blocked(.cloudStorageUnavailable)
        }

        return .telegramAttachmentFlow
    }
}
