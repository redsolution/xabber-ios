//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//

import Foundation
import XMPPFramework

/// Detached presentation data from XEP-SYNC's embedded `last-message`.
///
/// This is deliberately not a `MessageStorageItem`: it cannot participate in
/// timeline identity, archive coverage, unread accounting, search, or MAM
/// freshness. The `lastMessageID` check prevents a delayed projection from
/// describing a different Last Chats row revision.
struct LastChatListSyncPreviewProjection: Equatable, Sendable {
    let owner: String
    let conversationPrimary: String
    let lastMessageID: String
    let text: String
    let isSystemMessage: Bool
    let isAttachment: Bool
    let groupchatNickname: String?
    let groupchatAuthorColorKey: String?

    init(
        owner: String,
        conversationPrimary: String,
        lastMessageID: String,
        text: String,
        isSystemMessage: Bool = false,
        isAttachment: Bool = false,
        groupchatNickname: String? = nil,
        groupchatAuthorColorKey: String? = nil
    ) {
        self.owner = owner
        self.conversationPrimary = conversationPrimary
        self.lastMessageID = lastMessageID
        self.text = text
        self.isSystemMessage = isSystemMessage
        self.isAttachment = isAttachment
        self.groupchatNickname = groupchatNickname
        self.groupchatAuthorColorKey = groupchatAuthorColorKey
    }
}

enum LastChatAttachmentPreviewKind: CaseIterable, Equatable, Sendable {
    case photo
    case video
    case file
    case voice
}

enum LastChatAttachmentPreviewFormatter {
    static func kind(
        referenceKindRaw: String,
        mimeType: String,
        mediaType: String?
    ) -> LastChatAttachmentPreviewKind? {
        let referenceKind = referenceKindRaw.lowercased()
        if referenceKind == "voice" {
            return .voice
        }
        guard referenceKind == "media" else { return nil }

        let wireMediaType = mediaType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let normalizedMimeType = mimeType.lowercased()
        if wireMediaType.hasPrefix("image/") || normalizedMimeType == "image" {
            return .photo
        }
        if wireMediaType.hasPrefix("video/") || normalizedMimeType == "video" {
            return .video
        }
        return .file
    }

    static func text(
        for attachmentKinds: [LastChatAttachmentPreviewKind]
    ) -> String? {
        guard attachmentKinds.isNotEmpty else { return nil }
        return LastChatAttachmentPreviewKind.allCases.compactMap { kind in
            let count = attachmentKinds.filter { $0 == kind }.count
            return count > 0 ? localizedText(kind: kind, count: count) : nil
        }.joined(separator: ", ")
    }

    static func normalizedCaption(
        _ body: String?,
        fallbackURIs: Set<String>
    ) -> String? {
        guard let body else { return nil }
        let normalizedFallbacks = Set(fallbackURIs.compactMap { value -> String? in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isNotEmpty ? value : nil
        })
        let remainingLines = body.components(separatedBy: .newlines).filter { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isNotEmpty && !normalizedFallbacks.contains(value)
        }
        let caption = remainingLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return caption.isNotEmpty ? caption : nil
    }

    private static func localizedText(
        kind: LastChatAttachmentPreviewKind,
        count: Int
    ) -> String {
        let resource = localizationResource(for: kind)
        if count == 1 {
            return L10n.text(
                resource.singularKey,
                fallback: resource.singularFallback
            )
        }
        return L10n.plural(
            resource.countedKey,
            count: count,
            fallback: resource.countedFallback
        )
    }

    private static func localizationResource(
        for kind: LastChatAttachmentPreviewKind
    ) -> (
        singularKey: String,
        singularFallback: String,
        countedKey: String,
        countedFallback: String
    ) {
        switch kind {
        case .photo:
            return (
                "chat_list__attachment_preview__photo",
                "Photo",
                "chat_list__attachment_preview__photos_count",
                "%lld Photos"
            )
        case .video:
            return (
                "chat_list__attachment_preview__video",
                "Video",
                "chat_list__attachment_preview__videos_count",
                "%lld Videos"
            )
        case .file:
            return (
                "chat_list__attachment_preview__file",
                "File",
                "chat_list__attachment_preview__files_count",
                "%lld Files"
            )
        case .voice:
            return (
                "chat_list__attachment_preview__voice_message",
                "Voice message",
                "chat_list__attachment_preview__voice_messages_count",
                "%lld Voice messages"
            )
        }
    }
}

enum LastChatListSyncPreviewMutation: Equatable, Sendable {
    case upsert(LastChatListSyncPreviewProjection)
    case remove(conversationPrimary: String)
}

/// Account-scoped, process-resident projection store for chat-list rendering.
/// Mutations are applied in page-sized batches and produce at most one change
/// notification per owner and batch.
final class LastChatListSyncPreviewStore: @unchecked Sendable {
    static let shared = LastChatListSyncPreviewStore()
    static let didChangeNotification = Notification.Name(
        "com.xabber.last-chat-list-sync-preview.did-change"
    )
    static let changedConversationPrimariesUserInfoKey =
        "conversationPrimaries"

    private let lock = NSLock()
    private var projectionsByOwner: [
        String: [String: LastChatListSyncPreviewProjection]
    ] = [:]
    private var epochsByOwner: [String: UInt64] = [:]

    private init() {}

    func projection(
        owner: String,
        conversationPrimary: String,
        expectedLastMessageID: String
    ) -> LastChatListSyncPreviewProjection? {
        lock.lock()
        let projection = projectionsByOwner[owner]?[conversationPrimary]
        lock.unlock()
        guard projection?.owner == owner,
              projection?.conversationPrimary == conversationPrimary,
              projection?.lastMessageID == expectedLastMessageID else {
            return nil
        }
        return projection
    }

    func projectionCount(for owner: String) -> Int {
        lock.lock()
        let count = projectionsByOwner[owner]?.count ?? 0
        lock.unlock()
        return count
    }

    func preparationEpoch(for owner: String) -> UInt64 {
        lock.lock()
        let epoch = epochsByOwner[owner] ?? 0
        lock.unlock()
        return epoch
    }

    func apply(
        _ mutations: [LastChatListSyncPreviewMutation],
        for owner: String,
        expectedEpoch: UInt64? = nil
    ) {
        guard owner.isNotEmpty, mutations.isNotEmpty else { return }

        var changedPrimaries = Set<String>()
        lock.lock()
        if let expectedEpoch,
           epochsByOwner[owner, default: 0] != expectedEpoch {
            lock.unlock()
            return
        }
        var ownerProjections = projectionsByOwner[owner] ?? [:]
        mutations.forEach { mutation in
            switch mutation {
            case let .upsert(projection):
                guard projection.owner == owner,
                      projection.conversationPrimary.isNotEmpty,
                      projection.lastMessageID.isNotEmpty,
                      projection.text.isNotEmpty else {
                    return
                }
                if ownerProjections[projection.conversationPrimary] !=
                    projection {
                    ownerProjections[projection.conversationPrimary] =
                        projection
                    changedPrimaries.insert(projection.conversationPrimary)
                }
            case let .remove(conversationPrimary):
                if ownerProjections.removeValue(
                    forKey: conversationPrimary
                ) != nil {
                    changedPrimaries.insert(conversationPrimary)
                }
            }
        }
        if ownerProjections.isEmpty {
            projectionsByOwner.removeValue(forKey: owner)
        } else {
            projectionsByOwner[owner] = ownerProjections
        }
        lock.unlock()

        postChange(owner: owner, changedPrimaries: changedPrimaries)
    }

    func removeAll(for owner: String) {
        lock.lock()
        epochsByOwner[owner, default: 0] &+= 1
        let removed = projectionsByOwner.removeValue(forKey: owner)
        let changedPrimaries = Set(removed?.keys.map { $0 } ?? [])
        lock.unlock()
        postChange(owner: owner, changedPrimaries: changedPrimaries)
    }

    /// Rejects delayed page preparations without blanking already-rendered
    /// chat-list previews during reconnect. Row revision matching remains
    /// enforced by `expectedLastMessageID`.
    func invalidatePreparations(for owner: String) {
        lock.lock()
        epochsByOwner[owner, default: 0] &+= 1
        lock.unlock()
    }

    private func postChange(
        owner: String,
        changedPrimaries: Set<String>
    ) {
        guard changedPrimaries.isNotEmpty else { return }
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: owner,
            userInfo: [
                Self.changedConversationPrimariesUserInfoKey:
                    Array(changedPrimaries).sorted()
            ]
        )
    }
}

/// A bounded, non-persisting parser for the embedded XEP-SYNC message.
/// Unknown payloads receive a neutral label; XML or identifiers are never
/// surfaced as presentation text.
enum LastChatListSyncPreviewParser {
    private static let maximumTextLength = 4_096

    static func projection(
        owner: String,
        conversationPrimary: String,
        lastMessageID: String,
        messageElement: DDXMLElement,
        encryption: MessageEncryptionProvenance = .plaintext
    ) -> LastChatListSyncPreviewProjection? {
        guard owner.isNotEmpty,
              conversationPrimary.isNotEmpty,
              lastMessageID.isNotEmpty else {
            return nil
        }

        if encryption == .failedOMEMO || encryption == .unverifiedOMEMO ||
            (SCEReceivePolicy.hasOMEMO2(messageElement) && !encryption.isAuthenticated) {
            return LastChatListSyncPreviewProjection(
                owner: owner,
                conversationPrimary: conversationPrimary,
                lastMessageID: lastMessageID,
                text: encryption == .failedOMEMO
                    ? L10n.text("chat_list__preview__decrypt_failed", fallback: "Failed to decrypt")
                    : L10n.text("chat_list__preview__encrypted_message", fallback: "Encrypted message"),
                isSystemMessage: false,
                isAttachment: false,
                groupchatNickname: nil,
                groupchatAuthorColorKey: nil
            )
        }

        let referenceElements = (messageElement.children ?? [])
            .compactMap { $0 as? DDXMLElement }
            .filter { isReference($0) }
        let directForwardReferences = referenceElements.filter {
            isDirectForwardReference($0)
        }
        let presentationReferenceElements = referenceElements.filter {
            !isDirectForwardReference($0)
        }
        let directPayloads = messageElement.children?
            .compactMap { $0 as? DDXMLElement }
            .filter { isPresentationPayload($0) } ?? []
        let presentationRoots = directPayloads + presentationReferenceElements.flatMap {
            ($0.children ?? []).compactMap { $0 as? DDXMLElement }
                .filter { isPresentationPayload($0) }
        }
        let attachmentKinds = presentationReferenceElements.compactMap {
            attachmentKind(in: $0)
        }
        let fallbackURIs = Set(presentationReferenceElements.flatMap {
            sourceURIs(in: $0)
        })

        let hasLocation = presentationRoots.containsElement {
            SCEReceivePolicy.matches($0, name: "geoloc", namespace: "http://jabber.org/protocol/geoloc")
        }
        let hasContact = presentationRoots.containsElement {
            SCEReceivePolicy.matches($0, name: "contact", namespace: "https://xabber.com/protocol/contact-sharing")
        }
        let hasSticker = presentationRoots.containsElement {
            SCEReceivePolicy.matches($0, name: "media-type", namespace: "https://xabber.com/protocol/files") &&
                $0.stringValue?.lowercased() == "image/sticker"
        }
        let hasAttachment = hasLocation || hasContact || hasSticker ||
            attachmentKinds.isNotEmpty ||
            presentationRoots.containsElement {
                isFilePayload($0) || SCEReceivePolicy.matches(
                    $0, name: "voice-message", namespace: "https://xabber.com/protocol/voice-messages"
                )
            }
        let isSystemMessage = presentationRoots.containsElement {
            isSystemPayload($0)
        }
        let groupAuthor = isSystemMessage
            ? nil
            : groupAuthorProjection(in: messageElement)

        let wireBody = SCEReceivePolicy.children(
            of: messageElement, named: "body", xmlns: "jabber:client"
        ).first?.stringValue
        let bodyWithoutReferenceFallbacks = wireBody.map {
            $0.xmlEscaping(reverse: false).excludeFromBody(
                referenceElements,
                groupchat: nil
            )
        }
        let body = normalizedText(
            LastChatAttachmentPreviewFormatter.normalizedCaption(
                bodyWithoutReferenceFallbacks,
                fallbackURIs: fallbackURIs
            )
        )
        let text: String
        if let body {
            text = body
        } else if hasLocation {
            text = MessageStorageItem.locationDisplayText
        } else if hasContact {
            text = "Contact".localizeString(
                id: "chat_attachment_source_contact",
                arguments: []
            )
        } else if hasSticker {
            text = "Sticker".localizeString(
                id: "chat_message_sticker",
                arguments: []
            )
        } else if let attachmentText = LastChatAttachmentPreviewFormatter.text(
            for: attachmentKinds
        ) {
            text = attachmentText
        } else if directForwardReferences.count == 1 {
            text = "Forwarded message".localizeString(
                id: "chat_message_forwarded_message",
                arguments: []
            )
        } else if directForwardReferences.count > 1 {
            text = "%@ forwarded messages".localizeString(
                id: "chat_message_some_forwarded_messages",
                arguments: [String(directForwardReferences.count)]
            )
        } else if hasAttachment {
            text = "File".localizeString(
                id: "chat_message_file",
                arguments: []
            )
        } else if isSystemMessage {
            text = L10n.text(
                "chat_list__preview__system_message",
                fallback: "System message"
            )
        } else {
            text = L10n.text(
                "chat_list__preview__message",
                fallback: "Message"
            )
        }

        return LastChatListSyncPreviewProjection(
            owner: owner,
            conversationPrimary: conversationPrimary,
            lastMessageID: lastMessageID,
            text: text,
            isSystemMessage: isSystemMessage,
            isAttachment: hasAttachment,
            groupchatNickname: groupAuthor?.nickname,
            groupchatAuthorColorKey: groupAuthor?.colorKey
        )
    }

    private static func isDirectForwardReference(
        _ reference: DDXMLElement
    ) -> Bool {
        guard SCEReceivePolicy.matches(reference, name: "reference", namespace: "https://xabber.com/protocol/references"),
              reference.attributeStringValue(forName: "type") == "mutable",
              let forwarded = SCEReceivePolicy.children(
                of: reference, named: "forwarded", xmlns: "urn:xmpp:forward:0"
              ).first else { return false }
        return !SCEReceivePolicy.children(of: forwarded, named: "message", xmlns: "jabber:client").isEmpty
    }

    private static func isReference(_ element: DDXMLElement) -> Bool {
        ["https://xabber.com/protocol/references", "urn:xmpp:reference:0"].contains {
            SCEReceivePolicy.matches(element, name: "reference", namespace: $0)
        }
    }

    private static func isFilePayload(_ element: DDXMLElement) -> Bool {
        SCEReceivePolicy.matches(element, name: "file-sharing", namespace: "https://xabber.com/protocol/files") ||
            SCEReceivePolicy.matches(element, name: "file-sharing", namespace: "urn:xmpp:sfs:0") ||
            SCEReceivePolicy.matches(element, name: "media-sharing", namespace: "urn:xmpp:sims:1")
    }

    private static func isSystemPayload(_ element: DDXMLElement) -> Bool {
        let pairs = [
            ("event", "https://xabber.com/protocol/groups"),
            ("invite", "https://xabber.com/protocol/groups"),
            ("system-message", "https://xabber.com/protocol/groups"),
            ("system-message", "https://xabber.com/protocol/groups#system-message"),
            ("system-message", "https://xabber.com/protocol/system-message"),
            ("retract", "https://xabber.com/protocol/rewrite"),
            ("replace", "https://xabber.com/protocol/rewrite"),
            ("apply-to", "urn:xmpp:fasten:0")
        ]
        return pairs.contains { name, namespace in
            SCEReceivePolicy.matches(element, name: name, namespace: namespace)
        }
    }

    private static func isPresentationPayload(_ element: DDXMLElement) -> Bool {
        isFilePayload(element) || isSystemPayload(element) ||
            SCEReceivePolicy.matches(element, name: "x", namespace: "https://xabber.com/protocol/groups") ||
            SCEReceivePolicy.matches(element, name: "voice-message", namespace: "https://xabber.com/protocol/voice-messages") ||
            SCEReceivePolicy.matches(element, name: "geoloc", namespace: "http://jabber.org/protocol/geoloc") ||
            SCEReceivePolicy.matches(element, name: "contact", namespace: "https://xabber.com/protocol/contact-sharing")
    }

    private struct GroupAuthorProjection {
        let nickname: String
        let colorKey: String
    }

    private static func groupAuthorProjection(
        in messageElement: DDXMLElement
    ) -> GroupAuthorProjection? {
        let message = XMPPMessage(from: messageElement)
        guard let user = groupchatUserElement(from: message) else {
            return nil
        }
        let memberID = normalizedText(
            user.attributeStringValue(forName: "id")
        )
        let jid = normalizedText(
            user.element(forName: "jid")?.stringValue
        )
        let nickname = normalizedText(
            user.element(forName: "nickname")?.stringValue
        ) ?? jid
        guard let nickname else {
            return nil
        }
        let colorKey = memberID ?? jid ?? nickname
        return GroupAuthorProjection(
            nickname: nickname,
            colorKey: colorKey
        )
    }

    private static func attachmentKind(
        in reference: DDXMLElement
    ) -> LastChatAttachmentPreviewKind? {
        let payloads = (reference.children ?? []).compactMap { $0 as? DDXMLElement }
        if payloads.contains(where: { element in
            SCEReceivePolicy.matches(element, name: "voice-message", namespace: "https://xabber.com/protocol/voice-messages")
        }) {
            return .voice
        }

        guard let fileSharing = payloads.first(where: isFilePayload) else { return nil }
        let mediaType = firstElement(in: fileSharing) {
            SCEReceivePolicy.matches($0, name: "media-type", namespace: "https://xabber.com/protocol/files") ||
                SCEReceivePolicy.matches($0, name: "media-type", namespace: "urn:xmpp:file:metadata:0")
        }?.stringValue
        return LastChatAttachmentPreviewFormatter.kind(
            referenceKindRaw: "media",
            mimeType: "",
            mediaType: mediaType
        )
    }

    private static func sourceURIs(in root: DDXMLElement) -> [String] {
        if isReference(root) {
            return (root.children ?? []).compactMap { $0 as? DDXMLElement }
                .flatMap { sourceURIs(in: $0) }
        }
        if SCEReceivePolicy.matches(root, name: "voice-message", namespace: "https://xabber.com/protocol/voice-messages") {
            return SCEReceivePolicy.children(of: root, named: "file-sharing", xmlns: "https://xabber.com/protocol/files")
                .flatMap { sourceURIs(in: $0) }
        }
        guard isFilePayload(root), let namespace = root.uri else { return [] }
        return SCEReceivePolicy.children(of: root, named: "sources", xmlns: namespace)
            .flatMap { SCEReceivePolicy.children(of: $0, named: "uri", xmlns: namespace) }
            .compactMap { normalizedText($0.stringValue) }
    }

    private static func firstElement(
        in root: DDXMLElement,
        matching predicate: (DDXMLElement) -> Bool
    ) -> DDXMLElement? {
        if predicate(root) {
            return root
        }
        for child in root.children?.compactMap({ $0 as? DDXMLElement }) ?? [] {
            if let match = firstElement(in: child, matching: predicate) {
                return match
            }
        }
        return nil
    }

    private static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        guard trimmed.isNotEmpty else { return nil }
        return String(trimmed.prefix(maximumTextLength))
    }

    private static func containsElement(
        in root: DDXMLElement,
        matching predicate: (DDXMLElement) -> Bool
    ) -> Bool {
        if predicate(root) {
            return true
        }
        return root.children?.compactMap { $0 as? DDXMLElement }.contains {
            containsElement(in: $0, matching: predicate)
        } ?? false
    }
}

private extension Sequence where Element == DDXMLElement {
    func containsElement(
        matching predicate: (DDXMLElement) -> Bool
    ) -> Bool {
        contains { root in
            if predicate(root) {
                return true
            }
            return root.children?
                .compactMap { $0 as? DDXMLElement }
                .containsElement(matching: predicate) ?? false
        }
    }
}
