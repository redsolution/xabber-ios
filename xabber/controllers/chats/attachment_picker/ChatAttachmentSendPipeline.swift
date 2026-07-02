import Foundation
import CocoaLumberjack

private enum ChatAttachmentMediaUploadTrace {
    static func log(_ event: String, details: [(String, Any?)] = []) {
        let renderedDetails = details.compactMap { key, value -> String? in
            guard let value else { return nil }
            return "\(key)=\(format(value))"
        }.joined(separator: " ")
        let suffix = renderedDetails.isEmpty ? "" : " \(renderedDetails)"
        DDLogDebug("MEDIA_UPLOAD_TRACE event=\(event)\(suffix)")
    }

    private static func format(_ value: Any) -> String {
        let string = String(describing: value)
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: "\\n")
        guard !string.isEmpty,
              string.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return "\"\(string)\""
        }
        return string
    }
}

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

        return drafts.allSatisfy(\.isPreparedForSend)
    }
}

enum ChatAttachmentInlineSendabilityPolicy {
    static func canRequestSend(drafts: [AttachmentDraft]) -> Bool {
        guard !drafts.isEmpty else {
            return false
        }

        return drafts.allSatisfy { draft in
            draft.isPreparedForSend
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
        requiresUpload: Bool,
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
            ChatAttachmentMediaUploadTrace.log("picker_send_blocked", details: [
                ("reason", "emptySelection"),
                ("owner", context.owner),
                ("conversationType", context.conversationType.rawValue)
            ])
            completion(.blocked(.emptySelection))
            return
        }

        guard ChatAttachmentSendabilityPolicy.canRequestSend(drafts: drafts) else {
            ChatAttachmentMediaUploadTrace.log("picker_send_blocked", details: [
                ("reason", "unpreparedDrafts"),
                ("owner", context.owner),
                ("conversationType", context.conversationType.rawValue),
                ("draftCount", drafts.count),
                ("preparedCount", drafts.filter { $0.isPreparedForSend }.count),
                ("uploadDraftCount", drafts.filter { $0.requiresUpload }.count)
            ])
            completion(.blocked(.unpreparedDrafts))
            return
        }

        let requiresUpload = ChatAttachmentDraftUploadRequirementPolicy.requiresUpload(drafts: drafts)
        if requiresUpload {
            guard cloudStorageAvailabilityProvider.isCloudStorageAvailable(owner: context.owner) else {
                ChatAttachmentMediaUploadTrace.log("picker_send_blocked", details: [
                    ("reason", "cloudStorageUnavailable"),
                    ("owner", context.owner),
                    ("conversationType", context.conversationType.rawValue),
                    ("draftCount", drafts.count),
                    ("uploadDraftCount", drafts.filter { $0.requiresUpload }.count)
                ])
                completion(.blocked(.cloudStorageUnavailable))
                return
            }

            switch quotaAccessProvider.currentAccess(owner: context.owner) {
            case .available:
                break
            case .premiumRequired:
                ChatAttachmentMediaUploadTrace.log("picker_send_blocked", details: [
                    ("reason", "quotaExceeded"),
                    ("owner", context.owner),
                    ("conversationType", context.conversationType.rawValue),
                    ("draftCount", drafts.count),
                    ("uploadDraftCount", drafts.filter { $0.requiresUpload }.count)
                ])
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
                requiresUpload: requiresUpload,
                context: context
            ) { [quotaRefresher] didSend in
                ChatAttachmentMediaUploadTrace.log("picker_send_result", details: [
                    ("owner", context.owner),
                    ("conversationType", context.conversationType.rawValue),
                    ("referenceCount", references.count),
                    ("requiresUpload", requiresUpload),
                    ("didCreateLocalRow", didSend)
                ])
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
            ChatAttachmentMediaUploadTrace.log("picker_send_handoff", details: [
                ("owner", context.owner),
                ("conversationType", context.conversationType.rawValue),
                ("draftCount", drafts.count),
                ("referenceCount", references.count),
                ("requiresUpload", requiresUpload),
                ("uploadDraftCount", drafts.filter { $0.requiresUpload }.count),
                ("forwardedCount", context.forwardedMessageIds.count)
            ])
        } catch {
            ChatAttachmentMediaUploadTrace.log("picker_send_blocked", details: [
                ("reason", "referenceBuildFailed"),
                ("owner", context.owner),
                ("conversationType", context.conversationType.rawValue),
                ("draftCount", drafts.count),
                ("errorType", String(describing: type(of: error)))
            ])
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
        requiresUpload: Bool,
        context: ChatAttachmentFlowContext,
        completion: @escaping (Bool) -> Void
    ) {
        guard let account = AccountManager.shared.find(for: context.owner) else {
            ChatAttachmentMediaUploadTrace.log("media_sender_account_missing", details: [
                ("owner", context.owner),
                ("conversationType", context.conversationType.rawValue),
                ("referenceCount", references.count),
                ("requiresUpload", requiresUpload)
            ])
            completion(false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard requiresUpload else {
                ChatAttachmentMediaUploadTrace.log("media_sender_simple_handoff", details: [
                    ("owner", context.owner),
                    ("conversationType", context.conversationType.rawValue),
                    ("referenceCount", references.count),
                    ("forwardedCount", context.forwardedMessageIds.count)
                ])
                _ = account.messages.sendSimpleMessage(
                    body,
                    to: context.jid,
                    forwarded: context.forwardedMessageIds,
                    conversationType: context.conversationType,
                    references: references
                )
                DispatchQueue.main.async {
                    completion(true)
                }
                return
            }

            ChatAttachmentMediaUploadTrace.log("media_sender_upload_handoff", details: [
                ("owner", context.owner),
                ("conversationType", context.conversationType.rawValue),
                ("referenceCount", references.count),
                ("forwardedCount", context.forwardedMessageIds.count)
            ])
            let primary = account.messages.willSendMediaMessage(
                references,
                to: context.jid,
                forwarded: context.forwardedMessageIds,
                conversationType: context.conversationType,
                body: body,
                legacyBody: legacyBody
            )
            guard let primary else {
                ChatAttachmentMediaUploadTrace.log("media_sender_local_row_failed", details: [
                    ("owner", context.owner),
                    ("conversationType", context.conversationType.rawValue),
                    ("referenceCount", references.count)
                ])
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }

            ChatAttachmentMediaUploadTrace.log("media_sender_local_row_created", details: [
                ("owner", context.owner),
                ("conversationType", context.conversationType.rawValue),
                ("messagePrimary", primary),
                ("referenceCount", references.count)
            ])
            DispatchQueue.main.async {
                completion(true)
                DispatchQueue.global(qos: .utility).async {
                    ChatAttachmentMediaUploadTrace.log("media_sender_continue_upload_scheduled", details: [
                        ("owner", context.owner),
                        ("conversationType", context.conversationType.rawValue),
                        ("messagePrimary", primary),
                        ("referenceCount", references.count)
                    ])
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
