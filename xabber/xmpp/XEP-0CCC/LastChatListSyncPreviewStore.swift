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
        let resource = resourceName(for: kind)
        let resourceIndex = pluralResourceIndex(count: count)
        let usesRussianCountedOne = count != 1 &&
            resourceIndex == 0 &&
            currentLanguageCode().hasPrefix("ru")
        let keySuffix = usesRussianCountedOne
            ? "item_0_counted"
            : "item_\(resourceIndex)"
        let key = "plurals.last_chat_attachment_preview__\(resource).\(keySuffix)"
        let fallback: String
        switch (kind, count == 1, usesRussianCountedOne) {
        case (.photo, _, true): fallback = "%@ Photo"
        case (.video, _, true): fallback = "%@ Video"
        case (.file, _, true): fallback = "%@ File"
        case (.voice, _, true): fallback = "%@ Voice message"
        case (.photo, true, false): fallback = "Photo"
        case (.photo, false, false): fallback = "%@ Photos"
        case (.video, true, false): fallback = "Video"
        case (.video, false, false): fallback = "%@ Videos"
        case (.file, true, false): fallback = "File"
        case (.file, false, false): fallback = "%@ Files"
        case (.voice, true, false): fallback = "Voice message"
        case (.voice, false, false): fallback = "%@ Voice messages"
        }
        return fallback.localizeString(
            id: key,
            arguments: count == 1 ? [] : [String(count)]
        )
    }

    private static func resourceName(
        for kind: LastChatAttachmentPreviewKind
    ) -> String {
        switch kind {
        case .photo: return "photos"
        case .video: return "videos"
        case .file: return "files"
        case .voice: return "voice_messages"
        }
    }

    private static func pluralResourceIndex(count: Int) -> Int {
        let language = currentLanguageCode()
        guard language.hasPrefix("ru") else {
            return count == 1 ? 0 : 1
        }
        let absoluteCount = abs(count)
        let mod100 = absoluteCount % 100
        if (11...14).contains(mod100) {
            return 3
        }
        switch absoluteCount % 10 {
        case 1: return 0
        case 2...4: return 1
        default: return 2
        }
    }

    private static func currentLanguageCode() -> String {
        let selectedLanguage = TranslationsManager.shared.currentLang ??
            Locale.current.languageCode ?? "en"
        let normalizedSelection = selectedLanguage.lowercased()
        if normalizedSelection == "ru" ||
            normalizedSelection.hasPrefix("ru-") ||
            normalizedSelection.hasPrefix("ru_") {
            return "ru"
        }
        return TranslationsManager.shared
            .prepareLanCode(language: selectedLanguage)
            .lowercased()
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
        messageElement: DDXMLElement
    ) -> LastChatListSyncPreviewProjection? {
        guard owner.isNotEmpty,
              conversationPrimary.isNotEmpty,
              lastMessageID.isNotEmpty else {
            return nil
        }

        let referenceElements = messageElement.elements(forName: "reference")
        let directForwardReferences = referenceElements.filter {
            isDirectForwardReference($0)
        }
        let presentationReferenceElements = referenceElements.filter {
            !isDirectForwardReference($0)
        }
        let presentationRoots = messageElement.children?
            .compactMap { $0 as? DDXMLElement }
            .filter {
                !isDirectForwardReference($0)
            } ?? []
        let attachmentKinds = presentationReferenceElements.compactMap {
            attachmentKind(in: $0)
        }
        let fallbackURIs = Set(presentationReferenceElements.flatMap {
            sourceURIs(in: $0)
        })

        let hasLocation = presentationRoots.containsElement {
            $0.name == "geoloc" &&
                $0.xmlns() == "http://jabber.org/protocol/geoloc"
        }
        let hasContact = presentationRoots.containsElement {
            $0.name == "contact"
        }
        let hasSticker = presentationRoots.containsElement {
            $0.name == "sticker"
        }
        let hasAttachment = hasLocation || hasContact || hasSticker ||
            attachmentKinds.isNotEmpty ||
            presentationRoots.containsElement {
                let name = $0.name?.lowercased() ?? ""
                let namespace = $0.xmlns() ?? ""
                return [
                    "file-sharing", "media-sharing", "file", "media",
                    "voice"
                ].contains(name) || [
                    "urn:xmpp:sfs:0", "urn:xmpp:sims:1"
                ].contains(namespace)
            }
        let isSystemMessage = presentationRoots.containsElement {
            let name = $0.name?.lowercased() ?? ""
            let namespace = $0.xmlns() ?? ""
            return [
                "event", "invite", "retract", "replace", "apply-to"
            ].contains(name) ||
                namespace == "https://xabber.com/protocol/groups#system-message" ||
                namespace == "https://xabber.com/protocol/system-message"
        }
        let groupAuthor = isSystemMessage
            ? nil
            : groupAuthorProjection(in: messageElement)

        let wireBody = messageElement.element(forName: "body")?.stringValue
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
            text = "System message"
        } else {
            text = "Message"
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
        reference.xmlns() == "https://xabber.com/protocol/references" &&
            reference.attributeStringValue(forName: "type") == "mutable" &&
            reference
                .element(forName: "forwarded", xmlns: "urn:xmpp:forward:0")?
                .element(forName: "message") != nil
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
        if containsElement(in: reference, matching: { element in
            let name = element.name?.lowercased() ?? ""
            let namespace = element.xmlns() ?? ""
            return name == "voice-message" || name == "voice" ||
                namespace == "https://xabber.com/protocol/voice-messages"
        }) {
            return .voice
        }

        let hasFileSharing = containsElement(in: reference) { element in
            let name = element.name?.lowercased() ?? ""
            let namespace = element.xmlns() ?? ""
            return ["file-sharing", "media-sharing"].contains(name) ||
                [
                    "https://xabber.com/protocol/files",
                    "urn:xmpp:sfs:0",
                    "urn:xmpp:sims:1"
                ].contains(namespace)
        }
        guard hasFileSharing else { return nil }
        let mediaType = firstElement(in: reference) {
            $0.name?.lowercased() == "media-type"
        }?.stringValue
        return LastChatAttachmentPreviewFormatter.kind(
            referenceKindRaw: "media",
            mimeType: "",
            mediaType: mediaType
        )
    }

    private static func sourceURIs(in root: DDXMLElement) -> [String] {
        var values: [String] = []
        if root.name?.lowercased() == "uri",
           let value = root.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           value.isNotEmpty {
            values.append(value)
        }
        root.children?.compactMap { $0 as? DDXMLElement }.forEach {
            values.append(contentsOf: sourceURIs(in: $0))
        }
        return values
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
