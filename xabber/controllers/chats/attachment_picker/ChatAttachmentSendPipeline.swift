import Foundation

enum ChatAttachmentSendBlockReason: Equatable {
    case emptySelection
    case unpreparedDrafts
    case cloudStorageUnavailable
    case referenceBuildFailed
    case accountUnavailable
    case sendFailed
}

enum ChatAttachmentSendResult: Equatable {
    case sent(referenceCount: Int)
    case premiumRequired(owner: String)
    case cloudStorageQuotaExceeded(owner: String)
    case blocked(ChatAttachmentSendBlockReason)
}

enum ChatAttachmentSendabilityPolicy {
    static func canRequestSend(drafts: [AttachmentDraft]) -> Bool {
        guard !drafts.isEmpty else {
            return false
        }

        return drafts.allSatisfy { draft in
            if case .prepared = draft.preparationState {
                return true
            }

            if case .preparedLocation = draft.preparationState {
                return true
            }

            return false
        }
    }
}

enum ChatAttachmentInlineSendabilityPolicy {
    static func canRequestSend(drafts: [AttachmentDraft]) -> Bool {
        guard !drafts.isEmpty else {
            return false
        }

        return drafts.allSatisfy { draft in
            switch draft.preparationState {
            case .prepared, .preparedLocation:
                return true
            case .pending, .preparing, .unavailable:
                return false
            }
        }
    }
}

enum ChatAttachmentDraftUploadRequirementPolicy {
    static func requiresUpload(drafts: [AttachmentDraft]) -> Bool {
        drafts.contains { $0.requiresUpload }
    }
}

protocol ChatAttachmentCloudStorageAvailabilityProviding: AnyObject {
    func isCloudStorageAvailable(owner: String) -> Bool
}

protocol ChatAttachmentQuotaRefreshing: AnyObject {
    func refreshQuota(
        owner: String,
        reason: CloudStorageQuotaRefreshReason,
        force: Bool,
        completion: @escaping (CloudStorageQuotaRefreshResult) -> Void
    )
}

protocol ChatAttachmentQuotaAccessProviding: AnyObject {
    func currentAccess(owner: String) -> MediaUploadQuotaPolicy.Access
}

protocol ChatAttachmentMediaMessageSending: AnyObject {
    func sendMediaMessage(
        references: [MessageReferenceStorageItem],
        body: String,
        legacyBody: String,
        context: ChatAttachmentFlowContext,
        completion: @escaping (Bool) -> Void
    )
}

protocol ChatAttachmentSendCoordinating: AnyObject {
    func send(
        drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState,
        context: ChatAttachmentFlowContext,
        completion: @escaping (ChatAttachmentSendResult) -> Void
    )
}

final class ChatAttachmentSendPipeline: ChatAttachmentSendCoordinating {
    private let cloudStorageAvailabilityProvider: ChatAttachmentCloudStorageAvailabilityProviding
    private let quotaRefresher: ChatAttachmentQuotaRefreshing
    private let quotaAccessProvider: ChatAttachmentQuotaAccessProviding
    private let mediaMessageSender: ChatAttachmentMediaMessageSending
    private let referenceBuilder: ChatAttachmentReferenceBuilder

    init(
        cloudStorageAvailabilityProvider: ChatAttachmentCloudStorageAvailabilityProviding = AccountChatAttachmentCloudStorageAvailabilityProvider(),
        quotaRefresher: ChatAttachmentQuotaRefreshing = CloudStorageQuotaRefreshCoordinatorAdapter(),
        quotaAccessProvider: ChatAttachmentQuotaAccessProviding = MediaUploadQuotaAccessProvider(),
        mediaMessageSender: ChatAttachmentMediaMessageSending = AccountChatAttachmentMediaMessageSender(),
        referenceBuilder: ChatAttachmentReferenceBuilder = ChatAttachmentReferenceBuilder()
    ) {
        self.cloudStorageAvailabilityProvider = cloudStorageAvailabilityProvider
        self.quotaRefresher = quotaRefresher
        self.quotaAccessProvider = quotaAccessProvider
        self.mediaMessageSender = mediaMessageSender
        self.referenceBuilder = referenceBuilder
    }

    func send(
        drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState,
        context: ChatAttachmentFlowContext,
        completion: @escaping (ChatAttachmentSendResult) -> Void
    ) {
        guard !drafts.isEmpty else {
            completion(.blocked(.emptySelection))
            return
        }

        guard ChatAttachmentSendabilityPolicy.canRequestSend(drafts: drafts) else {
            completion(.blocked(.unpreparedDrafts))
            return
        }

        let requiresUpload = ChatAttachmentDraftUploadRequirementPolicy.requiresUpload(drafts: drafts)
        if requiresUpload {
            guard cloudStorageAvailabilityProvider.isCloudStorageAvailable(owner: context.owner) else {
                completion(.blocked(.cloudStorageUnavailable))
                return
            }

            switch quotaAccessProvider.currentAccess(owner: context.owner) {
            case .available:
                break
            case .premiumRequired:
                completion(.cloudStorageQuotaExceeded(owner: context.owner))
                return
            }
        }

        do {
            let references = try referenceBuilder.makeReferences(
                from: drafts,
                context: context
            )
            let outgoingBody = ChatAttachmentCaptionOutgoingBodyPolicy.makeOutgoingBody(
                captionState: captionState,
                conversationType: context.conversationType,
                references: references
            )
            mediaMessageSender.sendMediaMessage(
                references: references,
                body: outgoingBody.body,
                legacyBody: outgoingBody.legacyBody,
                context: context
            ) { [quotaRefresher] didSend in
                completion(didSend ? .sent(referenceCount: references.count) : .blocked(.sendFailed))
                guard didSend, requiresUpload else {
                    return
                }

                quotaRefresher.refreshQuota(
                    owner: context.owner,
                    reason: .preUploadValidation,
                    force: true
                ) { _ in }
            }
        } catch {
            completion(.blocked(.referenceBuildFailed))
        }
    }
}

final class AccountChatAttachmentCloudStorageAvailabilityProvider: ChatAttachmentCloudStorageAvailabilityProviding {
    func isCloudStorageAvailable(owner: String) -> Bool {
        AccountManager.shared.find(for: owner)?.cloudStorage.isAvailable() ?? false
    }
}

final class CloudStorageQuotaRefreshCoordinatorAdapter: ChatAttachmentQuotaRefreshing {
    func refreshQuota(
        owner: String,
        reason: CloudStorageQuotaRefreshReason,
        force: Bool,
        completion: @escaping (CloudStorageQuotaRefreshResult) -> Void
    ) {
        CloudStorageQuotaRefreshCoordinator.shared.refresh(
            owner: owner,
            reason: reason,
            force: force,
            completion: completion
        )
    }
}

final class MediaUploadQuotaAccessProvider: ChatAttachmentQuotaAccessProviding {
    func currentAccess(owner: String) -> MediaUploadQuotaPolicy.Access {
        MediaUploadQuotaPolicy.currentAccess(jid: owner)
    }
}

final class AccountChatAttachmentMediaMessageSender: ChatAttachmentMediaMessageSending {
    func sendMediaMessage(
        references: [MessageReferenceStorageItem],
        body: String,
        legacyBody: String,
        context: ChatAttachmentFlowContext,
        completion: @escaping (Bool) -> Void
    ) {
        guard let account = AccountManager.shared.find(for: context.owner) else {
            completion(false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let primary = account.messages.willSendMediaMessage(
                references,
                to: context.jid,
                forwarded: context.forwardedMessageIds,
                conversationType: context.conversationType,
                body: body,
                legacyBody: legacyBody
            )
            guard let primary else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }

            DispatchQueue.main.async {
                completion(true)
                DispatchQueue.global(qos: .utility).async {
                    account.messages.continueSendMediaMessage(primary)
                }
            }
        }
    }
}

enum ChatAttachmentUploadFailure: Equatable {
    case httpStatus(Int)
    case network
}

enum ChatAttachmentUploadFailureResolution: Equatable {
    case persistentFailedMessageRetry
}

enum ChatAttachmentUploadFailurePolicy {
    static func resolution(
        for failure: ChatAttachmentUploadFailure
    ) -> ChatAttachmentUploadFailureResolution {
        .persistentFailedMessageRetry
    }
}
