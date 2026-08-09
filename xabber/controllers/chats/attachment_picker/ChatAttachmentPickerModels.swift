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
}

enum ChatAttachmentPickerRoute: Equatable {
    case legacyImagePicker
    case telegramAttachmentFlow
    case blocked(ChatAttachmentPickerBlockReason)
}

enum ChatAttachmentPickerRoutingPolicy {
    static func route(
        isTelegramAttachmentPickerEnabled: Bool?,
        isCloudStorageAvailable: Bool
    ) -> ChatAttachmentPickerRoute {
        guard isCloudStorageAvailable else {
            return .blocked(.cloudStorageUnavailable)
        }

        if isTelegramAttachmentPickerEnabled ?? true {
            return .telegramAttachmentFlow
        }

        return .legacyImagePicker
    }
}

enum ChatAttachmentPickerLegacyFallbackRetentionReason: Equatable {
    case productSignoffMissing
    case sendParityIncomplete
    case focusedTestsFailed
    case appBuildFailed
    case manualSmokeMissing
    case rollbackBlockerPresent
}

enum ChatAttachmentPickerLegacyFallbackDecision: Equatable {
    case retainLegacyFallback(ChatAttachmentPickerLegacyFallbackRetentionReason)
    case eligibleToRemoveLegacyFallback
}

enum ChatAttachmentPickerRolloutPolicy {
    static func decision(
        hasProductSignoffForDefaultOnRollout: Bool,
        sendParityVerified: Bool,
        focusedTestsPassed: Bool,
        appBuildPassed: Bool,
        manualSmokePassed: Bool,
        hasRollbackBlockers: Bool
    ) -> ChatAttachmentPickerLegacyFallbackDecision {
        guard hasProductSignoffForDefaultOnRollout else {
            return .retainLegacyFallback(.productSignoffMissing)
        }
        guard sendParityVerified else {
            return .retainLegacyFallback(.sendParityIncomplete)
        }
        guard focusedTestsPassed else {
            return .retainLegacyFallback(.focusedTestsFailed)
        }
        guard appBuildPassed else {
            return .retainLegacyFallback(.appBuildFailed)
        }
        guard manualSmokePassed else {
            return .retainLegacyFallback(.manualSmokeMissing)
        }
        guard !hasRollbackBlockers else {
            return .retainLegacyFallback(.rollbackBlockerPresent)
        }
        return .eligibleToRemoveLegacyFallback
    }
}
