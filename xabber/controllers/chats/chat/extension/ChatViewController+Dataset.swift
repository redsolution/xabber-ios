//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import CoreLocation
import UIKit
import RealmSwift
import RxSwift
import RxCocoa
import RxRealm
import DeepDiff
import CocoaLumberjack
import MaterialComponents.MDCPalettes
import XMPPFramework

private enum ChatVisibleMentionReadMutationError: Error {
    case permitRevokedBeforeFirstPersistentMutation
}

struct ChatDatasourceSnapshot {
    static let empty = ChatDatasourceSnapshot(
        items: [],
        primaryIndex: [:],
        archivedIdIndex: [:],
        hasDuplicatePrimaries: false,
        hasDuplicateArchivedIds: false
    )

    let items: [ChatViewController.Datasource]
    let primaryIndex: [String: Int]
    let archivedIdIndex: [String: Int]
    let hasDuplicatePrimaries: Bool
    let hasDuplicateArchivedIds: Bool

    var hasDuplicateKeys: Bool {
        hasDuplicatePrimaries || hasDuplicateArchivedIds
    }

    init(items: [ChatViewController.Datasource]) {
        self.items = items
        var primaryIndex: [String: Int] = [:]
        var archivedIdIndex: [String: Int] = [:]
        var duplicatePrimaryCount = 0
        var duplicateArchivedIdCount = 0

        for (offset, item) in items.enumerated() {
            if primaryIndex.updateValue(offset, forKey: item.primary) != nil {
                duplicatePrimaryCount += 1
            }

            guard let archivedId = item.archivedId, archivedId.isNotEmpty else { continue }

            if archivedIdIndex.updateValue(offset, forKey: archivedId) != nil {
                duplicateArchivedIdCount += 1
            }
        }

        self.primaryIndex = primaryIndex
        self.archivedIdIndex = archivedIdIndex
        self.hasDuplicatePrimaries = duplicatePrimaryCount > 0
        self.hasDuplicateArchivedIds = duplicateArchivedIdCount > 0

        if duplicatePrimaryCount > 0 || duplicateArchivedIdCount > 0 {
            DDLogWarn(
                "ChatDatasourceSnapshot detected duplicate keys. primary duplicates: \(duplicatePrimaryCount); archivedId duplicates: \(duplicateArchivedIdCount)"
            )
        }
    }

    init(
        items: [ChatViewController.Datasource],
        primaryIndex: [String: Int],
        archivedIdIndex: [String: Int],
        hasDuplicatePrimaries: Bool,
        hasDuplicateArchivedIds: Bool
    ) {
        self.items = items
        self.primaryIndex = primaryIndex
        self.archivedIdIndex = archivedIdIndex
        self.hasDuplicatePrimaries = hasDuplicatePrimaries
        self.hasDuplicateArchivedIds = hasDuplicateArchivedIds
    }
}

struct SavedMessageAuthorProfile {
    let jid: String
    let displayName: String
    let avatarUrl: String?
}

struct SavedMessageDisplayPolicy {
    struct Presentation {
        let isSavedMessage: Bool
        let isSavedForward: Bool
        let isDirectSavedNote: Bool
        let displayAuthorJid: String
        let displayAuthorName: String
        let displayAvatarSource: String?
        let displayOutgoing: Bool
        let visibleBody: String
        let visibleReferences: [MessageReferenceStorageItem]
        let visibleForwards: [MessageForwardsInlineStorageItem]
        let visibleDate: Date
        let groupchatAuthorRole: String
        let groupchatAuthorId: String
        let groupchatAuthorNickname: String
        let groupchatAuthorBadge: String
        let isDeleted: Bool
        let deleteState: MessageStorageItem.DeleteState
        let authorColorKey: String
    }

    static func presentation(
        for item: MessageStorageItem,
        currentUserJid: String,
        currentUserName: String? = nil,
        authorProfileLookup: ((String, String) -> SavedMessageAuthorProfile?)? = nil
    ) -> Presentation {
        let resolvedAuthorProfile = authorProfileLookup ?? defaultAuthorProfile
        let isSavedMessage = item.conversationType == .saved
        let isSavedForward = isSavedMessage && item.isSavedForward
        let isDeleted = item.isDeleted || item.deleteState == .autoDeleted
        let references = isDeleted ? [] : item.references.toArray()
        let visibleForwards = isDeleted ? [] : item.inlineForwards.toArray()
        let directAuthorName = nonEmpty(currentUserName) ?? currentUserJid

        guard isSavedMessage else {
            let authorJid = item.outgoing ? currentUserJid : item.opponent
            let fallbackName = item.outgoing ? directAuthorName : authorJid
            let groupName = MessageStorageItem.getGroupchatAuthorNickname(references)
            let groupJid = MessageStorageItem.groupchatMessageAuthorJid(references)
            let groupId = MessageStorageItem.groupchatMessageAuthorId(references)
            return Presentation(
                isSavedMessage: false,
                isSavedForward: false,
                isDirectSavedNote: false,
                displayAuthorJid: nonEmpty(groupJid) ?? authorJid,
                displayAuthorName: nonEmpty(groupName) ?? fallbackName,
                displayAvatarSource: avatarSource(from: references),
                displayOutgoing: item.outgoing,
                visibleBody: isDeleted ? "" : item.bodyForAttachmentRendering,
                visibleReferences: references,
                visibleForwards: visibleForwards,
                visibleDate: item.date,
                groupchatAuthorRole: item.groupchatMetadata?["role"] as? String ?? "member",
                groupchatAuthorId: nonEmpty(item.groupchatAuthorId) ?? nonEmpty(groupId) ?? "",
                groupchatAuthorNickname: nonEmpty(item.groupchatAuthorNickname) ?? nonEmpty(groupName) ?? "",
                groupchatAuthorBadge: nonEmpty(item.groupchatAuthorBadge) ?? "",
                isDeleted: isDeleted,
                deleteState: item.deleteState,
                authorColorKey: nonEmpty(groupId) ?? nonEmpty(groupJid) ?? authorJid
            )
        }

        if isSavedForward {
            let groupName = MessageStorageItem.getGroupchatAuthorNickname(references)
            let groupJid = MessageStorageItem.groupchatMessageAuthorJid(references)
            let groupId = MessageStorageItem.groupchatMessageAuthorId(references)
            let authorJid = nonEmpty(groupJid)
                ?? nonEmpty(item.savedForwardAuthorJid)
                ?? currentUserJid
            let authorProfile = resolvedAuthorProfile(authorJid, currentUserJid)
            let groupDisplayName = displayNameCandidate(groupName, authorJid: authorJid)
            let authorName = groupDisplayName
                ?? authorProfile?.displayName
                ?? preparedJid(authorJid)
            let authorRole = nonEmpty(item.groupchatMetadata?["role"] as? String)
                ?? "member"
            let authorAvatarSource = avatarSource(from: references)
                ?? authorProfile?.avatarUrl
            return Presentation(
                isSavedMessage: true,
                isSavedForward: true,
                isDirectSavedNote: false,
                displayAuthorJid: authorProfile?.jid ?? authorJid,
                displayAuthorName: authorName,
                displayAvatarSource: authorAvatarSource,
                displayOutgoing: isSameBareJid(authorJid, currentUserJid),
                visibleBody: isDeleted ? "" : item.bodyForAttachmentRendering,
                visibleReferences: references,
                visibleForwards: visibleForwards,
                visibleDate: item.sentDate,
                groupchatAuthorRole: authorRole,
                groupchatAuthorId: nonEmpty(groupId) ?? "",
                groupchatAuthorNickname: authorName,
                groupchatAuthorBadge: nonEmpty(item.groupchatAuthorBadge) ?? "",
                isDeleted: isDeleted,
                deleteState: item.deleteState,
                authorColorKey: nonEmpty(groupId) ?? nonEmpty(groupJid) ?? authorJid
            )
        }

        return Presentation(
            isSavedMessage: true,
            isSavedForward: false,
            isDirectSavedNote: true,
            displayAuthorJid: currentUserJid,
            displayAuthorName: directAuthorName,
            displayAvatarSource: nil,
            displayOutgoing: true,
            visibleBody: isDeleted ? "" : item.bodyForAttachmentRendering,
            visibleReferences: references,
            visibleForwards: visibleForwards,
            visibleDate: item.date,
            groupchatAuthorRole: "member",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isDeleted: isDeleted,
            deleteState: item.deleteState,
            authorColorKey: currentUserJid
        )
    }

    static func attributedAuthor(for presentation: Presentation) -> NSAttributedString? {
        guard presentation.displayAuthorName.isNotEmpty else { return nil }
        return NSAttributedString(string: presentation.displayAuthorName, attributes: [
            .font: UIFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: ChatViewController.getUsernamePalette(for: presentation.authorColorKey).tint500
        ])
    }

    static func attributedBody(
        for presentation: Presentation,
        attributes: [NSAttributedString.Key: Any],
        searchedText: String? = nil,
        searchedTextColor: UIColor? = nil
    ) -> NSAttributedString {
        let mentionColor = AccountColorManager.shared
            .palette(for: presentation.displayAuthorJid)
            .tint700
        let references = presentation.visibleReferences.compactMap { reference -> ChatAttributedBodyReference? in
            guard !reference.isLocallyHiddenByReport,
                  reference.kind == .markup || reference.kind == .mention else {
                return nil
            }
            return ChatAttributedBodyReference(
                storageReference: reference,
                mentionColor: mentionColor
            )
        }
        return ChatAttributedBodyFormatter.format(
            body: presentation.visibleBody,
            references: references,
            attributes: attributes,
            searchedText: searchedText,
            searchedTextColor: searchedTextColor
        )
    }

    private static func avatarSource(from references: [MessageReferenceStorageItem]) -> String? {
        nonEmpty(references.first(where: { $0.kind == .groupchat })?.metadata?["avatar_uri"] as? String)
    }

    private static func defaultAuthorProfile(jid: String, owner: String) -> SavedMessageAuthorProfile? {
        let bareJid = normalizedBareJid(jid)
        guard bareJid.isNotEmpty,
              let realm = try? WRealm.safe(),
              let roster = realm.object(
                ofType: RosterStorageItem.self,
                forPrimaryKey: RosterStorageItem.genPrimary(jid: bareJid, owner: owner)
              ) else {
            return nil
        }

        return SavedMessageAuthorProfile(
            jid: bareJid,
            displayName: roster.displayName,
            avatarUrl: nonEmpty(roster.avatarMinUrl) ?? nonEmpty(roster.avatarMaxUrl) ?? nonEmpty(roster.oldschoolAvatarKey)
        )
    }

    private static func displayNameCandidate(_ value: String?, authorJid: String) -> String? {
        guard let value = nonEmpty(value),
              !isJidLikeDisplayName(value, authorJid: authorJid) else {
            return nil
        }
        return value
    }

    private static func isJidLikeDisplayName(_ value: String, authorJid: String) -> Bool {
        if isSameBareJid(value, authorJid) {
            return true
        }
        return value.contains("@") && XMPPJID(string: value) != nil
    }

    private static func preparedJid(_ value: String) -> String {
        JidManager.shared.prepareJid(jid: value)
    }

    private static func isSameBareJid(_ lhs: String, _ rhs: String) -> Bool {
        normalizedBareJid(lhs).caseInsensitiveCompare(normalizedBareJid(rhs)) == .orderedSame
    }

    private static func normalizedBareJid(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return XMPPJID(string: trimmed)?.bare ?? trimmed
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }
        return value
    }
}

final class ChatContactAvatarURLResolver {
    static let shared = ChatContactAvatarURLResolver { owner, jid in
        do {
            let realm = try WRealm.safe()
            return realm.object(
                ofType: RosterStorageItem.self,
                forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)
            )?.avatarUrl
        } catch {
            return nil
        }
    }

    private let lookup: (String, String) -> String?

    init(lookup: @escaping (String, String) -> String?) {
        self.lookup = lookup
    }

    func resolve(owner: String, jid: String) -> String? {
        guard !Thread.isMainThread, owner.isNotEmpty, jid.isNotEmpty else { return nil }
        return lookup(owner, jid)
    }
}

struct ChatMessageReferenceSnapshot {
    let primary: String
    let owner: String
    let jid: String
    let messageId: String
    let kindRaw: String
    let mimeType: String
    let begin: Int
    let end: Int
    let url: String?
    let downloadURLRaw: String?
    let localFileURLRaw: String?
    let decodedURLRaw: String?
    let videoPreviewURLRaw: String?
    let wireThumbnailURLRaw: String?
    let sizeInPx: CGSize?
    let sizeInBytesRaw: Int
    let filename: String?
    let name: String?
    let duration: Int?
    let isDownloaded: Bool
    let isSensitive: Bool
    let isSensitiveChecked: Bool
    let isLocallyHiddenByReport: Bool
    let metadata: [String: Any]?
    let meteringLevels: [Float]
    let resolvedContactEntity: MessageContactEntityKind?
    let resolvedContactAvatarURL: String?

    var kind: MessageReferenceStorageItem.Kind {
        MessageReferenceStorageItem.Kind(rawValue: kindRaw) ?? .none
    }

    var range: NSRange {
        NSRange(location: begin, length: max(0, end - begin))
    }

    var downloadUrl: URL? {
        Self.encodedURL(from: downloadURLRaw)
    }

    var localFileUrl: URL? {
        Self.encodedURL(from: localFileURLRaw)
    }

    var decodedUrl: URL? {
        Self.encodedURL(from: decodedURLRaw)
    }

    var videoPreviewUrl: URL? {
        guard let videoPreviewURLRaw else { return nil }
        return MessageReferenceURLPolicy.url(from: videoPreviewURLRaw)
    }

    var wireThumbnailUrl: URL? {
        Self.verifiedTimelineThumbnailURL(from: wireThumbnailURLRaw)
    }

    var displayFileName: String {
        Self.nonEmpty(name) ?? Self.nonEmpty(filename) ?? "file"
    }

    init(_ reference: MessageReferenceStorageItem) {
        let metadata = reference.metadata
        let kind = reference.kind
        let contactJid = Self.contactJid(metadata: metadata, url: reference.url)

        self.primary = reference.primary
        self.owner = reference.owner
        self.jid = reference.jid
        self.messageId = reference.messageId
        self.kindRaw = reference.kind_
        self.mimeType = reference.mimeType
        self.begin = reference.begin
        self.end = reference.end
        self.url = reference.url
        self.downloadURLRaw = [MessageReferenceStorageItem.Kind.geoloc, .contact].contains(kind) ? nil : reference.url
        self.localFileURLRaw = metadata?["localFileUri"] as? String
        self.decodedURLRaw = metadata?["decodedUrl"] as? String
        self.videoPreviewURLRaw = metadata?["thumbnail"] as? String
        self.wireThumbnailURLRaw = Self.timelineThumbnailURLRaw(
            reference: reference,
            metadata: metadata
        )
        if let height = metadata?["height"] as? Int,
           let width = metadata?["width"] as? Int,
           height > 0,
           width > 0 {
            self.sizeInPx = CGSize(width: width, height: height)
        } else {
            self.sizeInPx = nil
        }
        self.sizeInBytesRaw = metadata?["size"] as? Int ?? 0
        self.filename = metadata?["filename"] as? String
        self.name = metadata?["name"] as? String
        if let duration = metadata?["duration"] as? Int {
            self.duration = duration
        } else if let duration = metadata?["duration"] as? String {
            self.duration = Int(duration)
        } else {
            self.duration = nil
        }
        self.isDownloaded = reference.isDownloaded
        self.isSensitive = reference.isSensitive
        self.isSensitiveChecked = reference.isSensitiveChecked
        self.isLocallyHiddenByReport = reference.isLocallyHiddenByReport
        self.metadata = metadata
        if let metersString = metadata?["pcm"] as? String {
            self.meteringLevels = metersString.split(separator: " ").compactMap { Float($0) }
        } else {
            self.meteringLevels = []
        }
        if kind == .contact,
           let contactJid {
            self.resolvedContactEntity = MessageContactEntityKind.resolved(
                metadata: metadata,
                owner: reference.owner,
                jid: contactJid
            )
            self.resolvedContactAvatarURL = Self.nonEmpty(metadata?["avatar_url"] as? String)
                ?? Self.nonEmpty(
                    ChatContactAvatarURLResolver.shared.resolve(
                        owner: reference.owner,
                        jid: contactJid
                    )
                )
        } else {
            self.resolvedContactEntity = nil
            self.resolvedContactAvatarURL = nil
        }
    }

    private static func encodedURL(from raw: String?) -> URL? {
        MessageReferenceURLPolicy.url(from: raw)
    }

    private static func timelineThumbnailURLRaw(
        reference: MessageReferenceStorageItem,
        metadata: [String: Any]?
    ) -> String? {
        if let metadataURL = verifiedTimelineThumbnailURL(
            from: metadata?["thumbnail-uri"] as? String
        ) {
            return metadataURL.absoluteString
        }

        if let pending = reference.pendingMediaAttachment?
            .timelineThumbnailDataURLRaw {
            return pending
        }

        guard reference.kind == .media,
              let realm = reference.realm,
              let source = nonEmpty(reference.url),
              let messagePrimary = nonEmpty(reference.messageId) else {
            return nil
        }
        let attachmentPrimary = MessageMediaAttachmentStorageItem.genPrimary(
            jid: reference.jid,
            owner: reference.owner,
            url: source,
            messagePrimary: messagePrimary
        )
        return realm.object(
            ofType: MessageMediaAttachmentStorageItem.self,
            forPrimaryKey: attachmentPrimary
        )?.timelineThumbnailDataURLRaw
    }

    private static func verifiedTimelineThumbnailURL(
        from rawValue: String?
    ) -> URL? {
        if let dataURL = MessageMediaThumbnailDataURLPolicy.url(from: rawValue) {
            return dataURL
        }
        guard let url = MessageReferenceURLPolicy.url(from: rawValue),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isNotEmpty == true else {
            return nil
        }
        return url
    }

    private static func contactJid(metadata: [String: Any]?, url: String?) -> String? {
        if let value = metadata?["contact_jid"] as? String,
           value.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return url?
            .replacingOccurrences(of: "xmpp:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else { return nil }
        return value
    }
}

struct ChatForwardSnapshotLimits: Equatable {
    static let `default` = ChatForwardSnapshotLimits(
        maxDepth: 8,
        maxNodes: 256,
        maxBytes: 256 * 1_024
    )

    let maxDepth: Int
    let maxNodes: Int
    let maxBytes: Int

    init(maxDepth: Int, maxNodes: Int, maxBytes: Int) {
        self.maxDepth = max(0, maxDepth)
        self.maxNodes = max(1, maxNodes)
        self.maxBytes = max(1, maxBytes)
    }
}

struct ChatMessageForwardSnapshot {
    let primary: String
    let messageId: String
    let owner: String
    let opponent: String
    let jid: String
    let parentId: String
    let body: String
    let forwardJid: String
    let forwardNickname: String
    let authorName: String
    let isOutgoing: Bool
    let originalDate: Date?
    let references: [ChatMessageReferenceSnapshot]
    let subforwards: [ChatMessageForwardSnapshot]
    let isTruncated: Bool
    let truncationReason: String?

    var containsTruncatedContent: Bool {
        isTruncated || subforwards.contains(where: \.containsTruncatedContent)
    }

    var nodeCount: Int {
        1 + subforwards.reduce(0) { $0 + $1.nodeCount }
    }

    var maximumObservedDepth: Int {
        guard let childDepth = subforwards.map(\.maximumObservedDepth).max() else {
            return 0
        }
        return 1 + childDepth
    }

    init(
        _ forward: MessageForwardsInlineStorageItem,
        limits: ChatForwardSnapshotLimits = .default
    ) {
        var state = BuildState(limits: limits)
        self = Self.build(forward, depth: 0, path: [], state: &state)
    }

    private init(
        primary: String,
        messageId: String,
        owner: String,
        opponent: String,
        jid: String,
        parentId: String,
        body: String,
        forwardJid: String,
        forwardNickname: String,
        authorName: String,
        isOutgoing: Bool,
        originalDate: Date?,
        references: [ChatMessageReferenceSnapshot],
        subforwards: [ChatMessageForwardSnapshot],
        isTruncated: Bool,
        truncationReason: String?
    ) {
        self.primary = primary
        self.messageId = messageId
        self.owner = owner
        self.opponent = opponent
        self.jid = jid
        self.parentId = parentId
        self.body = body
        self.forwardJid = forwardJid
        self.forwardNickname = forwardNickname
        self.authorName = authorName
        self.isOutgoing = isOutgoing
        self.originalDate = originalDate
        self.references = references
        self.subforwards = subforwards
        self.isTruncated = isTruncated
        self.truncationReason = truncationReason
    }

    private struct BuildState {
        let limits: ChatForwardSnapshotLimits
        var nodes = 0
        var bytes = 0
    }

    private static func build(
        _ forward: MessageForwardsInlineStorageItem,
        depth: Int,
        path: Set<String>,
        state: inout BuildState
    ) -> ChatMessageForwardSnapshot {
        let identity = forward.primary.isNotEmpty
            ? "primary:\(forward.primary)"
            : "object:\(ObjectIdentifier(forward).hashValue)"
        if path.contains(identity) {
            return placeholder(forward, reason: "cycle")
        }
        guard depth <= state.limits.maxDepth else {
            return placeholder(forward, reason: "depth limit")
        }
        guard state.nodes < state.limits.maxNodes else {
            return placeholder(forward, reason: "node limit")
        }

        let scalarBytes = estimatedScalarBytes(forward)
        guard state.bytes + scalarBytes <= state.limits.maxBytes else {
            return placeholder(forward, reason: "byte limit")
        }
        state.nodes += 1
        state.bytes += scalarBytes

        var didTruncateReferences = false
        var references: [ChatMessageReferenceSnapshot] = []
        references.reserveCapacity(min(forward.references.count, 32))
        for reference in forward.references {
            let referenceBytes = estimatedReferenceBytes(reference)
            guard state.bytes + referenceBytes <= state.limits.maxBytes else {
                didTruncateReferences = true
                break
            }
            state.bytes += referenceBytes
            references.append(ChatMessageReferenceSnapshot(reference))
        }

        var nextPath = path
        nextPath.insert(identity)
        var children: [ChatMessageForwardSnapshot] = []
        let didTruncateDepth = depth >= state.limits.maxDepth && forward.subforwards.isNotEmpty
        var didTruncateChildren = false
        var childTruncationReason: String?
        if !didTruncateDepth {
            children.reserveCapacity(min(forward.subforwards.count, state.limits.maxNodes - state.nodes))
            for child in forward.subforwards {
                if state.nodes >= state.limits.maxNodes || state.bytes >= state.limits.maxBytes {
                    didTruncateChildren = true
                    childTruncationReason = state.nodes >= state.limits.maxNodes ? "node limit" : "byte limit"
                    break
                }
                children.append(build(child, depth: depth + 1, path: nextPath, state: &state))
            }
        }

        let truncationReason = didTruncateReferences
            ? "byte limit"
            : (didTruncateDepth ? "depth limit" : childTruncationReason)
        let displayBody: String
        if let truncationReason {
            let separator = forward.body.isEmpty ? "" : "\n"
            displayBody = "\(forward.body)\(separator)[Forward content unavailable: \(truncationReason)]"
        } else {
            displayBody = forward.body
        }
        return ChatMessageForwardSnapshot(
            primary: forward.primary,
            messageId: forward.messageId,
            owner: forward.owner,
            opponent: forward.opponent,
            jid: forward.jid,
            parentId: forward.parentId,
            body: displayBody,
            forwardJid: forward.forwardJid,
            forwardNickname: forward.forwardNickname,
            authorName: forward.tryToLoadNickname(),
            isOutgoing: forward.isOutgoing,
            originalDate: forward.originalDate,
            references: references,
            subforwards: children,
            isTruncated: didTruncateReferences || didTruncateDepth || didTruncateChildren,
            truncationReason: truncationReason
        )
    }

    private static func placeholder(
        _ forward: MessageForwardsInlineStorageItem,
        reason: String
    ) -> ChatMessageForwardSnapshot {
        ChatMessageForwardSnapshot(
            primary: forward.primary,
            messageId: forward.messageId,
            owner: forward.owner,
            opponent: forward.opponent,
            jid: forward.jid,
            parentId: forward.parentId,
            body: "[Forward content unavailable: \(reason)]",
            forwardJid: forward.forwardJid,
            forwardNickname: forward.forwardNickname,
            authorName: forward.forwardNickname.isNotEmpty ? forward.forwardNickname : forward.forwardJid,
            isOutgoing: forward.isOutgoing,
            originalDate: forward.originalDate,
            references: [],
            subforwards: [],
            isTruncated: true,
            truncationReason: reason
        )
    }

    private static func estimatedScalarBytes(_ forward: MessageForwardsInlineStorageItem) -> Int {
        [
            forward.primary,
            forward.messageId,
            forward.owner,
            forward.opponent,
            forward.jid,
            forward.parentId,
            forward.body,
            forward.forwardJid,
            forward.forwardNickname
        ].reduce(0) { $0 + $1.utf8.count }
    }

    private static func estimatedReferenceBytes(_ reference: MessageReferenceStorageItem) -> Int {
        reference.primary.utf8.count +
        reference.owner.utf8.count +
        reference.jid.utf8.count +
        reference.messageId.utf8.count +
        reference.kind_.utf8.count +
        reference.mimeType.utf8.count +
        (reference.url?.utf8.count ?? 0) +
        reference.metadata_.utf8.count
    }

}

struct ChatMessageDisplaySnapshot {
    struct Presentation {
        let isSavedMessage: Bool
        let isSavedForward: Bool
        let isDirectSavedNote: Bool
        let displayAuthorJid: String
        let displayAuthorName: String
        let displayAvatarSource: String?
        let displayOutgoing: Bool
        let visibleBody: String
        let visibleReferences: [ChatMessageReferenceSnapshot]
        let visibleForwards: [ChatMessageForwardSnapshot]
        let visibleReferencesRevision: String
        let visibleForwardsRevision: String
        let visibleDate: Date
        let groupchatAuthorRole: String
        let groupchatAuthorId: String
        let groupchatAuthorNickname: String
        let groupchatAuthorBadge: String
        let isDeleted: Bool
        let deleteState: MessageStorageItem.DeleteState
        let authorColorKey: String
    }

    let primary: String
    let owner: String
    let opponent: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let outgoing: Bool
    let messageId: String
    let displayAs: MessageStorageItem.MessageDisplayType
    let body: String
    let legacyBody: String
    let bodyForAttachmentRendering: String
    let localReportPlaceholderText: String?
    let date: Date
    let sentDate: Date
    let editDate: Date?
    let afterburnInterval: Double
    let burnDate: Double
    let deleteState: MessageStorageItem.DeleteState
    let isDeleted: Bool
    let isLocallyHiddenByReport: Bool
    let messageWarningText: String?
    let groupchatAuthorId: String?
    let groupchatAuthorNickname: String?
    let groupchatAuthorBadge: String?
    let groupchatMetadata: [String: Any]?
    let isHasAttachedMessages: Bool
    let presentation: Presentation

    init(item: MessageStorageItem, presentation: SavedMessageDisplayPolicy.Presentation) {
        self.primary = item.primary
        self.owner = item.owner
        self.opponent = item.opponent
        self.conversationType = item.conversationType
        self.outgoing = item.outgoing
        self.messageId = item.messageId
        self.displayAs = item.displayAs
        self.body = item.body
        self.legacyBody = item.legacyBody
        self.bodyForAttachmentRendering = item.bodyForAttachmentRendering
        self.localReportPlaceholderText = item.localReportPlaceholderText
        self.date = item.date
        self.sentDate = item.sentDate
        self.editDate = item.editDate
        self.afterburnInterval = item.afterburnInterval
        self.burnDate = item.burnDate
        self.deleteState = item.deleteState
        self.isDeleted = item.isDeleted
        self.isLocallyHiddenByReport = item.isLocallyHiddenByReport
        self.messageWarningText = item.messageWarningText
        self.groupchatAuthorId = item.groupchatAuthorId
        self.groupchatAuthorNickname = item.groupchatAuthorNickname
        self.groupchatAuthorBadge = item.groupchatAuthorBadge
        self.groupchatMetadata = item.groupchatMetadata
        self.isHasAttachedMessages = item.isHasAttachedMessages
        let visibleReferences = presentation.visibleReferences.map(ChatMessageReferenceSnapshot.init)
        let visibleForwards = presentation.visibleForwards.map { ChatMessageForwardSnapshot($0) }
        self.presentation = Presentation(
            isSavedMessage: presentation.isSavedMessage,
            isSavedForward: presentation.isSavedForward,
            isDirectSavedNote: presentation.isDirectSavedNote,
            displayAuthorJid: presentation.displayAuthorJid,
            displayAuthorName: presentation.displayAuthorName,
            displayAvatarSource: presentation.displayAvatarSource,
            displayOutgoing: presentation.displayOutgoing,
            visibleBody: presentation.visibleBody,
            visibleReferences: visibleReferences,
            visibleForwards: visibleForwards,
            visibleReferencesRevision: Self.referenceRevision(visibleReferences),
            visibleForwardsRevision: Self.forwardRevision(visibleForwards),
            visibleDate: presentation.visibleDate,
            groupchatAuthorRole: presentation.groupchatAuthorRole,
            groupchatAuthorId: presentation.groupchatAuthorId,
            groupchatAuthorNickname: presentation.groupchatAuthorNickname,
            groupchatAuthorBadge: presentation.groupchatAuthorBadge,
            isDeleted: presentation.isDeleted,
            deleteState: presentation.deleteState,
            authorColorKey: presentation.authorColorKey
        )
    }

    func forwardDisplayRevision(
        revealedSensitiveMediaPrimaries: Set<String>,
        context: ChatDisplayModelCacheContext
    ) -> String {
        var hasher = ChatDisplayModelRevisionHasher()
        hasher.combine(presentation.visibleForwards.count)
        hasher.combine(presentation.visibleForwardsRevision)
        func combineRevealedTargets(_ forward: ChatMessageForwardSnapshot) {
            forward.references
                .filter { revealedSensitiveMediaPrimaries.contains($0.primary) }
                .map(\.primary)
                .sorted()
                .forEach { hasher.combine($0) }
            forward.subforwards.forEach(combineRevealedTargets)
        }
        presentation.visibleForwards.forEach(combineRevealedTargets)
        hasher.combine(context.searchText)
        hasher.combine(context.localeIdentifier)
        hasher.combine(context.contentSizeCategory)
        hasher.combine(context.bodyFontName)
        hasher.combine(Double(context.bodyFontPointSize))
        hasher.combine(context.interfaceStyleRawValue)
        return hasher.revision
    }

    func statePresentation(
        currentUserJid: String,
        state: MessageStorageItem.MessageSendingState,
        archivedId: String
    ) -> SavedMessageStatePolicy.Presentation {
        guard conversationType == .saved else {
            return SavedMessageStatePolicy.Presentation(
                effectiveState: state,
                showsDeliveryIndicator: outgoing,
                shouldSendDisplayedMarker: conversationType != .saved
            )
        }

        let authoredByCurrentUser = presentation.isDirectSavedNote || Self.isSameBareJid(presentation.displayAuthorJid, currentUserJid)
        let hasProof = archivedId.isNotEmpty ||
            state == .none ||
            state == .sended ||
            state == .deliver ||
            state == .read
        if !authoredByCurrentUser && hasProof {
            return SavedMessageStatePolicy.Presentation(
                effectiveState: .none,
                showsDeliveryIndicator: false,
                shouldSendDisplayedMarker: false
            )
        }

        let effectiveState: MessageStorageItem.MessageSendingState = hasProof
            ? .read
            : (state == .notSended || state == .none ? .sending : state)
        return SavedMessageStatePolicy.Presentation(
            effectiveState: effectiveState,
            showsDeliveryIndicator: authoredByCurrentUser || [.sending, .uploading, .notSended].contains(effectiveState),
            shouldSendDisplayedMarker: false
        )
    }

    func attributedAuthor() -> NSAttributedString? {
        guard presentation.displayAuthorName.isNotEmpty else { return nil }
        return NSAttributedString(string: presentation.displayAuthorName, attributes: [
            .font: UIFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: ChatViewController.getUsernamePalette(for: presentation.authorColorKey).tint500
        ])
    }

    private static func referenceRevision(_ references: [ChatMessageReferenceSnapshot]) -> String {
        var hasher = ChatDisplayModelRevisionHasher()
        hasher.combine(references.count)
        references.forEach { combineReference($0, into: &hasher) }
        return hasher.revision
    }

    private static func forwardRevision(_ forwards: [ChatMessageForwardSnapshot]) -> String {
        var hasher = ChatDisplayModelRevisionHasher()
        hasher.combine(forwards.count)
        forwards.forEach { combineForward($0, into: &hasher) }
        return hasher.revision
    }

    func attributedBody(
        attributes: [NSAttributedString.Key: Any],
        searchedText: String? = nil,
        searchedTextColor: UIColor? = nil
    ) -> NSAttributedString {
        if presentation.isSavedMessage || presentation.visibleBody != body {
            return Self.attributedBody(
                body: presentation.visibleBody,
                references: presentation.visibleReferences,
                authorJid: presentation.displayAuthorJid,
                attributes: attributes,
                searchedText: searchedText,
                searchedTextColor: searchedTextColor,
                skipsHiddenReferences: true
            )
        }
        if let localReportPlaceholderText {
            let string = NSMutableAttributedString(string: localReportPlaceholderText)
            string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
            string.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: NSRange(location: 0, length: string.length))
            string.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body).italic(), range: NSRange(location: 0, length: string.length))
            return string
        }
        return Self.attributedBody(
            body: body,
            references: presentation.visibleReferences,
            authorJid: owner,
            attributes: attributes,
            searchedText: searchedText,
            searchedTextColor: searchedTextColor,
            skipsHiddenReferences: true
        )
    }

    static func attributedForwardBody(
        body: String,
        references: [ChatMessageReferenceSnapshot],
        attributes: [NSAttributedString.Key: Any],
        authorJid: String,
        searchedText: String? = nil,
        searchedTextColor: UIColor? = nil
    ) -> NSAttributedString {
        attributedBody(
            body: body,
            references: references,
            authorJid: authorJid,
            attributes: attributes,
            searchedText: searchedText,
            searchedTextColor: searchedTextColor,
            skipsHiddenReferences: false
        )
    }

    private static func attributedBody(
        body: String,
        references: [ChatMessageReferenceSnapshot],
        authorJid: String,
        attributes: [NSAttributedString.Key: Any],
        searchedText: String?,
        searchedTextColor: UIColor?,
        skipsHiddenReferences: Bool
    ) -> NSAttributedString {
        let mentionColor = AccountColorManager.shared.palette(for: authorJid).tint700
        let formattedReferences = references.compactMap { reference -> ChatAttributedBodyReference? in
            guard (!skipsHiddenReferences || !reference.isLocallyHiddenByReport),
                  reference.kind == .markup || reference.kind == .mention else {
                return nil
            }
            switch reference.kind {
            case .mention:
                return .mention(
                    begin: reference.begin,
                    end: reference.end,
                    destination: reference.metadata?["uri"] as? String ?? reference.url,
                    color: mentionColor
                )
            case .markup:
                return .markup(
                    begin: reference.begin,
                    end: reference.end,
                    styles: reference.metadata?["styles"] as? [String] ?? [],
                    destination: reference.metadata?["uri"] as? String ?? reference.url
                )
            default:
                return nil
            }
        }
        return ChatAttributedBodyFormatter.format(
            body: body,
            references: formattedReferences,
            attributes: attributes,
            searchedText: searchedText,
            searchedTextColor: searchedTextColor
        )
    }

    private static func combineReference(
        _ reference: ChatMessageReferenceSnapshot,
        into hasher: inout ChatDisplayModelRevisionHasher
    ) {
        hasher.combine(reference.primary)
        hasher.combine(reference.owner)
        hasher.combine(reference.jid)
        hasher.combine(reference.kindRaw)
        hasher.combine(reference.mimeType)
        hasher.combine(reference.begin)
        hasher.combine(reference.end)
        hasher.combine(reference.url)
        hasher.combine(reference.downloadUrl?.absoluteString)
        hasher.combine(reference.localFileUrl?.absoluteString)
        hasher.combine(reference.decodedUrl?.absoluteString)
        hasher.combine(reference.videoPreviewUrl?.absoluteString)
        hasher.combine(reference.wireThumbnailUrl?.absoluteString)
        hasher.combine(reference.sizeInPx.map { Double($0.width) })
        hasher.combine(reference.sizeInPx.map { Double($0.height) })
        hasher.combine(reference.sizeInBytesRaw)
        hasher.combine(reference.filename)
        hasher.combine(reference.name)
        hasher.combine(String(describing: reference.duration))
        hasher.combine(reference.isDownloaded)
        hasher.combine(reference.isSensitive)
        hasher.combine(reference.isSensitiveChecked)
        hasher.combine(reference.isLocallyHiddenByReport)
        combineMetadata(reference.metadata, into: &hasher)
        hasher.combine(reference.meteringLevels.count)
        reference.meteringLevels.forEach { hasher.combine(Double($0)) }
    }

    private static func combineForward(
        _ forward: ChatMessageForwardSnapshot,
        into hasher: inout ChatDisplayModelRevisionHasher
    ) {
        hasher.combine(forward.primary)
        hasher.combine(forward.messageId)
        hasher.combine(forward.owner)
        hasher.combine(forward.opponent)
        hasher.combine(forward.jid)
        hasher.combine(forward.parentId)
        hasher.combine(forward.body)
        hasher.combine(forward.forwardJid)
        hasher.combine(forward.forwardNickname)
        hasher.combine(forward.isOutgoing)
        hasher.combine(forward.originalDate?.timeIntervalSinceReferenceDate)
        hasher.combine(forward.references.count)
        forward.references.forEach { combineReference($0, into: &hasher) }
        hasher.combine(forward.subforwards.count)
        forward.subforwards.forEach { combineForward($0, into: &hasher) }
    }

    private static func combineMetadata(
        _ metadata: [String: Any]?,
        into hasher: inout ChatDisplayModelRevisionHasher
    ) {
        guard let metadata else {
            hasher.combine("metadata:nil")
            return
        }
        hasher.combine(metadata.count)
        for key in metadata.keys.sorted() {
            hasher.combine(key)
            combineMetadataValue(metadata[key], into: &hasher)
        }
    }

    private static func combineMetadataValue(
        _ value: Any?,
        into hasher: inout ChatDisplayModelRevisionHasher
    ) {
        switch value {
        case let value as String:
            hasher.combine(value)
        case let value as Bool:
            hasher.combine(value)
        case let value as Int:
            hasher.combine(value)
        case let value as Int64:
            hasher.combine(UInt64(bitPattern: value))
        case let value as Double:
            hasher.combine(value)
        case let value as Float:
            hasher.combine(Double(value))
        case let value as [String]:
            hasher.combine(value.count)
            value.forEach { hasher.combine($0) }
        case let value as [String: String]:
            hasher.combine(value.count)
            for key in value.keys.sorted() {
                hasher.combine(key)
                hasher.combine(value[key])
            }
        case let value as [String: Any]:
            combineMetadata(value, into: &hasher)
        case let value as [Any]:
            hasher.combine(value.count)
            value.forEach { combineMetadataValue($0, into: &hasher) }
        case .none:
            hasher.combine("nil")
        default:
            hasher.combine(String(describing: value))
        }
    }

    private static func isSameBareJid(_ lhs: String, _ rhs: String) -> Bool {
        normalizedBareJid(lhs).caseInsensitiveCompare(normalizedBareJid(rhs)) == .orderedSame
    }

    private static func normalizedBareJid(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return XMPPJID(string: trimmed)?.bare ?? trimmed
    }
}

struct ChatDisplayModelCacheContext: Hashable {
    let searchText: String?
    let localeIdentifier: String
    let contentSizeCategory: String
    let bodyFontName: String
    let bodyFontPointSize: CGFloat
    let interfaceStyleRawValue: Int

    static func current(searchText: String?, traitCollection: UITraitCollection) -> ChatDisplayModelCacheContext {
        let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        return ChatDisplayModelCacheContext(
            searchText: searchText?.isEmpty == true ? nil : searchText,
            localeIdentifier: Locale.current.identifier,
            contentSizeCategory: traitCollection.preferredContentSizeCategory.rawValue,
            bodyFontName: bodyFont.fontName,
            bodyFontPointSize: bodyFont.pointSize,
            interfaceStyleRawValue: traitCollection.userInterfaceStyle.rawValue
        )
    }
}

enum ChatDatasourceMappingPurpose {
    case timeline
}

struct ChatDatasourceMappingContext {
    let owner: String
    let jid: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let ownerSender: Sender
    let opponentSender: Sender
    let purpose: ChatDatasourceMappingPurpose
    var searchText: String?
    var inSearchMode: Bool
    var displayCacheContext: ChatDisplayModelCacheContext
    let bodyTextAttributes: [NSAttributedString.Key: Any]
    let systemTextAttributes: [NSAttributedString.Key: Any]
    let dateSeparatorAttributes: [NSAttributedString.Key: Any]
    let timeMarkerAttributes: [NSAttributedString.Key: Any]
    let searchHighlightColor: UIColor
    let avatarVerticalPosition: String
    let canPinMessages: Bool
    var revealedSensitiveMediaPrimaries: Set<String>
    let layoutContext: ChatMessageLayoutContext
    let layoutReuseSnapshot: ChatMessageLayoutSnapshot
    let layoutCacheCapacity: Int
    let layoutOperationCounter: ChatMessageLayoutOperationCounter?
}

enum ChatLayoutViewportRestoration: Equatable {
    case none
    case bottom
    case message(ChatHistoryPageAnchor)
}

struct ChatPendingWidthTransitionLayoutRemap {
    let generation: Int
    let targetViewSize: CGSize
    let targetLayoutWidth: CGFloat
    let viewportRestoration: ChatLayoutViewportRestoration
    let items: [ChatViewController.Datasource]
    let mappingContext: ChatDatasourceMappingContext
    let preparedLayouts: ChatMessageLayoutSnapshot
    let completion: (() -> Void)?
}

struct ChatWidthTransitionLayoutFinalizationGate {
    struct Receipt: Equatable {
        let generation: Int
        let targetViewSize: CGSize
        let targetLayoutWidth: CGFloat
    }

    let generation: Int
    let targetViewSize: CGSize
    let targetLayoutWidth: CGFloat
    private var collectionUpdateCompleted = false
    private var caTransactionCompleted = false
    private var targetLayoutObserved = false
    private var didComplete = false

    init(
        generation: Int,
        targetViewSize: CGSize,
        targetLayoutWidth: CGFloat
    ) {
        self.generation = generation
        self.targetViewSize = targetViewSize
        self.targetLayoutWidth = targetLayoutWidth
    }

    mutating func recordCollectionUpdateCompletion(
        generation candidate: Int,
        didFinish: Bool
    ) -> Bool {
        guard candidate == generation,
              didFinish,
              !collectionUpdateCompleted else {
            return false
        }
        collectionUpdateCompleted = true
        return true
    }

    mutating func recordCATransactionCompletion(
        generation candidate: Int
    ) -> Bool {
        guard candidate == generation,
              !caTransactionCompleted else {
            return false
        }
        caTransactionCompleted = true
        return true
    }

    mutating func recordLayoutObservation(
        generation candidate: Int,
        targetGeometryReady: Bool,
        targetCacheReady: Bool,
        targetContentSizeReady: Bool,
        semanticViewportReady: Bool
    ) -> Bool {
        guard candidate == generation else { return false }
        targetLayoutObserved =
            targetGeometryReady &&
            targetCacheReady &&
            targetContentSizeReady &&
            semanticViewportReady
        return true
    }

    mutating func completeIfReady() -> Receipt? {
        guard !didComplete,
              collectionUpdateCompleted,
              caTransactionCompleted,
              targetLayoutObserved else {
            return nil
        }
        didComplete = true
        return Receipt(
            generation: generation,
            targetViewSize: targetViewSize,
            targetLayoutWidth: targetLayoutWidth
        )
    }
}

struct ChatPendingWidthTransitionLayoutFinalization {
    var gate: ChatWidthTransitionLayoutFinalizationGate
    let viewportRestoration: ChatLayoutViewportRestoration
    let firstItemPrimary: String?
    let completion: (() -> Void)?
}

struct ChatWidthTransitionSourceGeometry {
    let contentHeight: CGFloat
    let contentOffsetY: CGFloat
}

enum ChatWidthTransitionCellHeightDeltaPolicy {
    static func delta(
        items: [ChatViewController.Datasource],
        previousLayouts: ChatMessageLayoutSnapshot,
        preparedLayouts: ChatMessageLayoutSnapshot,
        stoppingBefore primary: String? = nil
    ) -> CGFloat? {
        var result: CGFloat = 0
        var didReachStop = primary == nil
        for item in items {
            if item.primary == primary {
                didReachStop = true
                break
            }
            guard let previous = previousLayouts.layout(
                forPrimary: item.primary
            ),
                  let prepared = preparedLayouts.layout(
                    forPrimary: item.primary
                  ) else {
                return nil
            }
            result += prepared.cellSize.height - previous.cellSize.height
        }
        return didReachStop ? result : nil
    }
}

struct ChatWidthTransitionLayoutAdjustments: Equatable {
    let targetBoundsY: CGFloat
    let postBoundsMetricsY: CGFloat
}

enum ChatWidthTransitionTargetContentOffset: Equatable {
    case bottom
    case message(
        indexPath: IndexPath,
        viewportRelativeMinY: CGFloat
    )
}

enum ChatWidthTransitionLayoutAdjustmentPolicy {
    static func adjustments(
        viewportRestoration: ChatLayoutViewportRestoration,
        totalHeightDelta: CGFloat,
        precedingAnchorHeightDelta: CGFloat?
    ) -> ChatWidthTransitionLayoutAdjustments {
        switch viewportRestoration {
        case .none:
            return ChatWidthTransitionLayoutAdjustments(
                targetBoundsY: 0,
                postBoundsMetricsY: 0
            )
        case .bottom:
            return ChatWidthTransitionLayoutAdjustments(
                targetBoundsY: totalHeightDelta,
                // When target metrics arrive after the bounds transition,
                // UICollectionView already owns live-tail preservation from
                // the source cache. Adding the full height delta again moves
                // the viewport into history.
                postBoundsMetricsY: 0
            )
        case .message:
            let precedingDelta = precedingAnchorHeightDelta ?? 0
            return ChatWidthTransitionLayoutAdjustments(
                targetBoundsY: precedingDelta,
                // A late metrics invalidation already asks UIKit to preserve
                // its native visible row. Adding the cell-height delta here
                // cancels that proposal. The documented layout target-offset
                // callback resolves the exact requested row instead.
                postBoundsMetricsY: 0
            )
        }
    }
}

enum ChatWidthTransitionCommitReadinessPolicy {
    static func isReady(
        targetViewSize: CGSize,
        targetLayoutWidth: CGFloat,
        viewBounds: CGRect,
        collectionBounds: CGRect,
        sectionInsets: UIEdgeInsets,
        tolerance: CGFloat = 1
    ) -> Bool {
        guard abs(viewBounds.width - targetViewSize.width) <= tolerance,
              abs(viewBounds.height - targetViewSize.height) <= tolerance,
              abs(collectionBounds.width - targetViewSize.width) <= tolerance,
              abs(collectionBounds.height - targetViewSize.height) <= tolerance else {
            return false
        }
        let availableLayoutWidth = max(
            1,
            collectionBounds.width - sectionInsets.horizontal
        )
        return abs(availableLayoutWidth - targetLayoutWidth) <= tolerance
    }
}

enum ChatWidthTransitionBoundsAdjustmentPolicy {
    static func adjustmentY(
        viewportRestoration: ChatLayoutViewportRestoration,
        sourceGeometry: ChatWidthTransitionSourceGeometry,
        targetViewportHeight: CGFloat,
        contentInsets: UIEdgeInsets
    ) -> CGFloat {
        switch viewportRestoration {
        case .none, .message:
            // UIKit's default bounds-height adjustment changes the visible
            // item-relative position before target layouts arrive. Keeping
            // the source offset lets the later metrics invalidation preserve
            // the correct semantic anchor through its cell-height deltas.
            return 0
        case .bottom:
            let targetOffsetY =
                ChatBottomScrollAlignmentPolicy.targetContentOffsetY(
                    targetMaxY: sourceGeometry.contentHeight,
                    contentHeight: sourceGeometry.contentHeight,
                    viewportHeight: targetViewportHeight,
                    contentInsets: contentInsets
                )
            return targetOffsetY - sourceGeometry.contentOffsetY
        }
    }
}

struct ChatSkeletonDescriptor {
    let primary: String
    let messageId: String
    let text: NSAttributedString
    let sentDate: Date
    let outgoing: Bool
}

enum ChatSkeletonTemplate {
    private static let wordBank = [
        "message", "history", "loading", "conversation", "preview", "secure", "contact", "reply"
    ]
    private static let wordCounts = [
        3, 7, 5, 11, 4, 8, 6, 9, 5, 12,
        4, 7, 10, 6, 8, 3, 11, 5, 9, 7,
        4, 10, 6, 8, 5, 12, 3, 9, 7, 5
    ]
    private static let referenceDate = Date(timeIntervalSince1970: 978_307_200)

    static let descriptors: [ChatSkeletonDescriptor] = wordCounts.enumerated().map { index, count in
        let words = (0..<count).map { wordBank[(index + $0) % wordBank.count] }
        return ChatSkeletonDescriptor(
            primary: "chat-skeleton-\(index)",
            messageId: "chat-skeleton-message-\(index)",
            text: NSAttributedString(string: words.joined(separator: " ")),
            sentDate: referenceDate.addingTimeInterval(TimeInterval(index * 60)),
            outgoing: index.isMultiple(of: 3)
        )
    }
}

struct ChatDatasourceMappingResult {
    let datasource: [ChatViewController.Datasource]
    let editedMessagePrimariesNeedingLayoutInvalidation: [String]
    let layoutSnapshot: ChatMessageLayoutSnapshot
    var wasCancelled: Bool = false
}

enum ChatDateSeparatorPresentationPolicy {
    /// Synthetic section rows carry no delivery/read lifecycle. Keeping this
    /// invariant prevents a read-through mutation of the first real message
    /// from fabricating a visual change on its date separator.
    static let isRead = true
}

private struct ChatDatasourceMappingDateFormatters {
    let sectionDateFormatter: DateFormatter
    let attachmentTimeFormatter: DateFormatter

    init() {
        self.sectionDateFormatter = ChatViewController.makeSectionsDateFormatter()
        self.attachmentTimeFormatter = ChatViewController.makeAttachmentTimeFormatter()
    }
}

struct ChatDisplayModelCacheKey: Hashable {
    let messagePrimary: String
    let displayRevision: String
    let context: ChatDisplayModelCacheContext
}

struct ChatMappedReferenceAttachments {
    static let empty = ChatMappedReferenceAttachments(
        images: [],
        videos: [],
        locations: [],
        contacts: [],
        audio: [],
        files: []
    )

    let images: [ImageAttachment]
    let videos: [VideoAttachment]
    let locations: [LocationAttachment]
    let contacts: [ContactAttachment]
    let audio: [AudioAttachment]
    let files: [FileAttachment]
}

final class ChatLazyForwardDisplayModel {
    let signature: String
    private let lock = NSLock()
    private var resolvedAttachments: [MessageAttachment]?
    private var builder: (() -> [MessageAttachment])?

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolvedAttachments != nil
    }

    var attachments: [MessageAttachment] {
        lock.lock()
        if let resolvedAttachments {
            lock.unlock()
            return resolvedAttachments
        }
        guard let builder else {
            lock.unlock()
            return []
        }
        lock.unlock()

        let builtAttachments = builder()

        lock.lock()
        if let resolvedAttachments {
            lock.unlock()
            return resolvedAttachments
        }
        resolvedAttachments = builtAttachments
        self.builder = nil
        lock.unlock()
        return builtAttachments
    }

    init(signature: String, builder: @escaping () -> [MessageAttachment]) {
        self.signature = signature
        self.builder = builder
    }

    static func eager(_ attachments: [MessageAttachment], signature: String = "eager") -> ChatLazyForwardDisplayModel {
        let model = ChatLazyForwardDisplayModel(signature: signature) { attachments }
        model.resolvedAttachments = attachments
        model.builder = nil
        return model
    }
}

final class ChatCachedDisplayModel {
    let displaySnapshot: ChatMessageDisplaySnapshot?
    let kind: MessageKind
    let mappedReferences: ChatMappedReferenceAttachments
    let lazyForwards: ChatLazyForwardDisplayModel
    let isDownloaded: Bool
    let timeMarkerText: NSAttributedString

    var forwards: [MessageAttachment] {
        lazyForwards.attachments
    }

    var bodyText: String {
        switch kind {
        case .attributedText(let text),
                .system(let text),
                .initial(let text),
                .skeleton(let text),
                .date(let text),
                .unread(let text):
            return text.string
        case .emoji(let text):
            return text
        case .sticker(let attachment):
            return attachment.primary
        case .call(let attachment):
            return attachment.primary
        }
    }

    var bodyFontPointSize: CGFloat? {
        switch kind {
        case .attributedText(let text),
                .system(let text),
                .initial(let text),
                .skeleton(let text),
                .date(let text),
                .unread(let text):
            guard text.length > 0 else { return nil }
            return (text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize
        case .emoji, .sticker, .call:
            return nil
        }
    }

    init(
        displaySnapshot: ChatMessageDisplaySnapshot? = nil,
        kind: MessageKind,
        mappedReferences: ChatMappedReferenceAttachments,
        lazyForwards: ChatLazyForwardDisplayModel,
        isDownloaded: Bool,
        timeMarkerText: NSAttributedString
    ) {
        self.displaySnapshot = displaySnapshot
        self.kind = kind
        self.mappedReferences = mappedReferences
        self.lazyForwards = lazyForwards
        self.isDownloaded = isDownloaded
        self.timeMarkerText = timeMarkerText
    }
}

final class ChatDisplayModelCache {
    struct Statistics: Equatable {
        let hits: Int
        let misses: Int
        let stores: Int
        let evictions: Int
        let entryCount: Int
        let linearRecencyScanSteps: Int

        var performanceSnapshot: ChatPerformanceMetricSnapshot {
            ChatPerformanceMetricSnapshot(
                phase: .displayModelCache,
                counters: [
                    "hits": hits,
                    "misses": misses,
                    "stores": stores,
                    "evictions": evictions,
                    "entryCount": entryCount,
                    "linearRecencyScanSteps": linearRecencyScanSteps
                ]
            )
        }
    }

    private final class Entry {
        let key: ChatDisplayModelCacheKey
        let model: ChatCachedDisplayModel
        weak var previous: Entry?
        var next: Entry?

        init(key: ChatDisplayModelCacheKey, model: ChatCachedDisplayModel) {
            self.key = key
            self.model = model
        }
    }

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [ChatDisplayModelCacheKey: Entry] = [:]
    private var leastRecent: Entry?
    private var mostRecent: Entry?
    private var hitCount: Int = 0
    private var missCount: Int = 0
    private var storeCount: Int = 0
    private var evictionCount: Int = 0
    private var invalidationGeneration: UInt64 = 0

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            hits: hitCount,
            misses: missCount,
            stores: storeCount,
            evictions: evictionCount,
            entryCount: entries.count,
            linearRecencyScanSteps: 0
        )
    }

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    func model(
        for key: ChatDisplayModelCacheKey,
        build: () -> ChatCachedDisplayModel
    ) -> ChatCachedDisplayModel {
        ChatPerformanceSignposts.measure(.displayModelCache) {
            lock.lock()
            if let cached = entries[key] {
                hitCount += 1
                markRecentlyUsed(cached)
                lock.unlock()
                return cached.model
            }
            missCount += 1
            let buildGeneration = invalidationGeneration
            lock.unlock()

            let built = build()
            guard capacity > 0 else {
                return built
            }

            lock.lock()
            guard buildGeneration == invalidationGeneration else {
                lock.unlock()
                return built
            }
            if let cached = entries[key] {
                hitCount += 1
                markRecentlyUsed(cached)
                lock.unlock()
                return cached.model
            }
            let entry = Entry(key: key, model: built)
            entries[key] = entry
            appendAsMostRecent(entry)
            storeCount += 1
            evictIfNeeded()
            lock.unlock()
            return built
        }
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        leastRecent = nil
        mostRecent = nil
        invalidationGeneration &+= 1
        lock.unlock()
    }

    private func markRecentlyUsed(_ entry: Entry) {
        guard mostRecent !== entry else { return }
        unlink(entry)
        appendAsMostRecent(entry)
    }

    private func evictIfNeeded() {
        while entries.count > capacity,
              let oldest = leastRecent {
            unlink(oldest)
            entries.removeValue(forKey: oldest.key)
            evictionCount += 1
        }
    }

    private func unlink(_ entry: Entry) {
        let previous = entry.previous
        let next = entry.next
        previous?.next = next
        next?.previous = previous
        if leastRecent === entry {
            leastRecent = next
        }
        if mostRecent === entry {
            mostRecent = previous
        }
        entry.previous = nil
        entry.next = nil
    }

    private func appendAsMostRecent(_ entry: Entry) {
        entry.previous = mostRecent
        entry.next = nil
        mostRecent?.next = entry
        mostRecent = entry
        if leastRecent == nil {
            leastRecent = entry
        }
    }
}

private struct ChatDisplayModelRevisionHasher {
    private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    private(set) var value: UInt64 = ChatDisplayModelRevisionHasher.offsetBasis

    var revision: String {
        String(value, radix: 16)
    }

    mutating func combine(_ value: String?) {
        guard let value else {
            combineByte(0xff)
            return
        }
        for byte in value.utf8 {
            combineByte(byte)
        }
        combineByte(0xfe)
    }

    mutating func combine(_ value: Bool) {
        combineByte(value ? 1 : 0)
    }

    mutating func combine(_ value: Int) {
        combine(UInt64(bitPattern: Int64(value)))
    }

    mutating func combine(_ value: Double?) {
        guard let value else {
            combineByte(0xfd)
            return
        }
        combine(value.bitPattern)
    }

    mutating func combine(_ value: UInt64) {
        combineByte(UInt8(truncatingIfNeeded: value))
        combineByte(UInt8(truncatingIfNeeded: value >> 8))
        combineByte(UInt8(truncatingIfNeeded: value >> 16))
        combineByte(UInt8(truncatingIfNeeded: value >> 24))
        combineByte(UInt8(truncatingIfNeeded: value >> 32))
        combineByte(UInt8(truncatingIfNeeded: value >> 40))
        combineByte(UInt8(truncatingIfNeeded: value >> 48))
        combineByte(UInt8(truncatingIfNeeded: value >> 56))
    }

    private mutating func combineByte(_ byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* ChatDisplayModelRevisionHasher.prime
    }
}

struct ChatMessageRichStorageRevision: Hashable {
    let rawValue: String

    static func capture(
        _ item: MessageStorageItem,
        revealedSensitiveMediaPrimaries: Set<String>,
        forwardLimits: ChatForwardSnapshotLimits = .default
    ) -> ChatMessageRichStorageRevision {
        var hasher = ChatDisplayModelRevisionHasher()
        hasher.combine(item.primary)
        hasher.combine(item.messageId)
        hasher.combine(item.owner)
        hasher.combine(item.opponent)
        hasher.combine(item.conversationType_)
        hasher.combine(item.outgoing)
        hasher.combine(item.messageType)
        hasher.combine(item.body)
        hasher.combine(item.legacyBody)
        hasher.combine(item.date.timeIntervalSinceReferenceDate)
        hasher.combine(item.sentDate.timeIntervalSinceReferenceDate)
        hasher.combine(item.editDate?.timeIntervalSinceReferenceDate)
        hasher.combine(item.afterburnInterval)
        hasher.combine(item.burnDate)
        hasher.combine(item.deleteState_)
        hasher.combine(item.isDeleted)
        hasher.combine(item.isLocallyHiddenByReport)
        hasher.combine(item.localReportState)
        hasher.combine(item.systemMetadata_)
        hasher.combine(item.isSavedForward)
        hasher.combine(item.savedForwardAuthorJid)

        hasher.combine(item.references.count)
        for reference in item.references {
            combineReference(
                reference,
                revealedSensitiveMediaPrimaries: revealedSensitiveMediaPrimaries,
                into: &hasher
            )
        }

        var traversal = ForwardRevisionTraversal(limits: forwardLimits)
        hasher.combine(item.inlineForwards.count)
        for forward in item.inlineForwards {
            guard traversal.nodes < traversal.limits.maxNodes,
                  traversal.bytes < traversal.limits.maxBytes else {
                hasher.combine("forward-root:budget-limit")
                break
            }
            combineForward(
                forward,
                depth: 0,
                path: [],
                revealedSensitiveMediaPrimaries: revealedSensitiveMediaPrimaries,
                traversal: &traversal,
                into: &hasher
            )
        }
        return ChatMessageRichStorageRevision(rawValue: hasher.revision)
    }

    private struct ForwardRevisionTraversal {
        let limits: ChatForwardSnapshotLimits
        var nodes = 0
        var bytes = 0
    }

    private static func combineReference(
        _ reference: MessageReferenceStorageItem,
        revealedSensitiveMediaPrimaries: Set<String>,
        into hasher: inout ChatDisplayModelRevisionHasher
    ) {
        hasher.combine(reference.primary)
        hasher.combine(reference.messageId)
        hasher.combine(reference.owner)
        hasher.combine(reference.jid)
        hasher.combine(reference.kind_)
        hasher.combine(reference.mimeType)
        hasher.combine(reference.begin)
        hasher.combine(reference.end)
        hasher.combine(reference.url)
        hasher.combine(reference.metadata_)
        hasher.combine(reference.isDownloaded)
        hasher.combine(reference.isSensitive)
        hasher.combine(reference.isSensitiveChecked)
        hasher.combine(reference.isLocallyHiddenByReport)
        hasher.combine(revealedSensitiveMediaPrimaries.contains(reference.primary))
    }

    private static func combineForward(
        _ forward: MessageForwardsInlineStorageItem,
        depth: Int,
        path: Set<String>,
        revealedSensitiveMediaPrimaries: Set<String>,
        traversal: inout ForwardRevisionTraversal,
        into hasher: inout ChatDisplayModelRevisionHasher
    ) {
        let identity = forward.primary.isNotEmpty
            ? "primary:\(forward.primary)"
            : "object:\(ObjectIdentifier(forward).hashValue)"
        guard !path.contains(identity) else {
            hasher.combine("forward:cycle")
            return
        }
        guard depth <= traversal.limits.maxDepth else {
            hasher.combine("forward:depth-limit")
            return
        }
        guard traversal.nodes < traversal.limits.maxNodes else {
            hasher.combine("forward:node-limit")
            return
        }
        let scalarBytes = forward.primary.utf8.count +
            forward.messageId.utf8.count +
            forward.parentId.utf8.count +
            forward.body.utf8.count +
            forward.forwardJid.utf8.count +
            forward.forwardNickname.utf8.count
        guard traversal.bytes + scalarBytes <= traversal.limits.maxBytes else {
            hasher.combine("forward:byte-limit")
            return
        }
        traversal.nodes += 1
        traversal.bytes += scalarBytes

        hasher.combine(forward.primary)
        hasher.combine(forward.messageId)
        hasher.combine(forward.owner)
        hasher.combine(forward.opponent)
        hasher.combine(forward.jid)
        hasher.combine(forward.parentId)
        hasher.combine(forward.body)
        hasher.combine(forward.forwardJid)
        hasher.combine(forward.forwardNickname)
        hasher.combine(forward.isOutgoing)
        hasher.combine(forward.originalDate?.timeIntervalSinceReferenceDate)
        hasher.combine(forward.references.count)
        for reference in forward.references {
            let referenceBytes = reference.primary.utf8.count + reference.metadata_.utf8.count
            guard traversal.bytes + referenceBytes <= traversal.limits.maxBytes else {
                hasher.combine("forward-reference:byte-limit")
                break
            }
            traversal.bytes += referenceBytes
            combineReference(
                reference,
                revealedSensitiveMediaPrimaries: revealedSensitiveMediaPrimaries,
                into: &hasher
            )
        }
        var nextPath = path
        nextPath.insert(identity)
        hasher.combine(forward.subforwards.count)
        guard depth < traversal.limits.maxDepth else {
            if forward.subforwards.isNotEmpty {
                hasher.combine("forward:depth-limit")
            }
            return
        }
        for child in forward.subforwards {
            guard traversal.nodes < traversal.limits.maxNodes,
                  traversal.bytes < traversal.limits.maxBytes else {
                hasher.combine("forward-child:budget-limit")
                break
            }
            combineForward(
                child,
                depth: depth + 1,
                path: nextPath,
                revealedSensitiveMediaPrimaries: revealedSensitiveMediaPrimaries,
                traversal: &traversal,
                into: &hasher
            )
        }
    }
}

struct ChatMessageChromeStorageRevision: Hashable {
    let rawValue: String

    static func capture(_ item: MessageStorageItem) -> ChatMessageChromeStorageRevision {
        var hasher = ChatDisplayModelRevisionHasher()
        hasher.combine(item.primary)
        hasher.combine(item.state_)
        hasher.combine(item.isRead)
        hasher.combine(item.messageError)
        hasher.combine(item.messageErrorCode)
        hasher.combine(item.errorMetadata_)
        hasher.combine(item.archivedId)
        hasher.combine(item.queryIds)
        return ChatMessageChromeStorageRevision(rawValue: hasher.revision)
    }
}

final class ChatDatasetMappingCancellationToken {
    struct Statistics: Equatable {
        let rowsProcessed: Int
        let rowsProcessedAfterCancellation: Int
    }

    let generation: Int
    private let cancellationCheckInterval: Int
    private let lock = NSLock()
    private var cancelled = false
    private var rowsProcessed = 0
    private var rowsProcessedAtCancellation: Int?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            rowsProcessed: rowsProcessed,
            rowsProcessedAfterCancellation: rowsProcessedAtCancellation.map {
                max(0, rowsProcessed - $0)
            } ?? 0
        )
    }

    init(generation: Int, cancellationCheckInterval: Int) {
        self.generation = generation
        self.cancellationCheckInterval = max(1, cancellationCheckInterval)
    }

    func cancel() {
        lock.lock()
        if !cancelled {
            cancelled = true
            rowsProcessedAtCancellation = rowsProcessed
        }
        lock.unlock()
    }

    func shouldProcessNextRow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled && rowsProcessed.isMultiple(of: cancellationCheckInterval) {
            return false
        }
        rowsProcessed += 1
        return true
    }
}

final class ChatDatasetMappingJobCoordinator {
    private let cancellationCheckInterval: Int
    private let lock = NSLock()
    private var current: ChatDatasetMappingCancellationToken?

    init(cancellationCheckInterval: Int = 16) {
        self.cancellationCheckInterval = max(1, cancellationCheckInterval)
    }

    func begin(generation: Int) -> ChatDatasetMappingCancellationToken {
        let token = ChatDatasetMappingCancellationToken(
            generation: generation,
            cancellationCheckInterval: cancellationCheckInterval
        )
        lock.lock()
        let obsolete = current
        current = token
        lock.unlock()
        obsolete?.cancel()
        return token
    }

    func cancelAll() {
        lock.lock()
        let token = current
        current = nil
        lock.unlock()
        token?.cancel()
    }

    var ownedJobCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return current == nil ? 0 : 1
    }
}

enum ChatDatasetMappingQueueFactory {
    static func make(label: String) -> DispatchQueue {
        DispatchQueue(
            label: label,
            qos: .userInitiated,
            attributes: .concurrent,
            autoreleaseFrequency: .workItem,
            target: nil
        )
    }
}

struct ChatDatasetWindow: Equatable {
    static let empty = ChatDatasetWindow(minIndex: 0, maxIndex: 0)

    let minIndex: Int
    let maxIndex: Int

    var isEmpty: Bool {
        maxIndex <= minIndex
    }

    var count: Int {
        max(0, maxIndex - minIndex)
    }
}

struct ChatTimelineBoundary: Equatable {
    let primary: String
    let archivedId: String?
    let messageId: String?
    let date: Date

    init(
        primary: String,
        archivedId: String?,
        messageId: String?,
        date: Date
    ) {
        self.primary = primary
        self.archivedId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archivedId)
        self.messageId = messageId?.isNotEmpty == true ? messageId : nil
        self.date = date
    }

    init(message: MessageStorageItem) {
        self.init(
            primary: message.primary,
            archivedId: message.archivedId,
            messageId: message.messageId,
            date: message.date
        )
    }
}

struct ChatTimelineAnchor: Equatable {
    let primary: String?
    let archivedId: String?
    let messageId: String?
    let date: Date?

    init(
        primary: String?,
        archivedId: String?,
        messageId: String?,
        date: Date?
    ) {
        self.primary = primary?.isNotEmpty == true ? primary : nil
        self.archivedId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archivedId)
        self.messageId = messageId?.isNotEmpty == true ? messageId : nil
        self.date = date
    }
}

struct ChatTimelinePositionKey: Comparable, Equatable {
    let date: Date
    let orderKey: MessageHistoryOrderKey

    init(primary: String, archivedId: String?, messageId: String?, date: Date) {
        self.date = date
        self.orderKey = MessageHistoryOrderKey(
            primary: primary,
            archivedId: archivedId,
            messageId: messageId,
            date: date
        )
    }

    init(message: MessageStorageItem) {
        self.init(
            primary: message.primary,
            archivedId: message.archivedId,
            messageId: message.messageId,
            date: message.date
        )
    }

    init(boundary: ChatTimelineBoundary) {
        self.init(
            primary: boundary.primary,
            archivedId: boundary.archivedId,
            messageId: boundary.messageId,
            date: boundary.date
        )
    }

    static func < (lhs: ChatTimelinePositionKey, rhs: ChatTimelinePositionKey) -> Bool {
        lhs.orderKey < rhs.orderKey
    }
}

enum ChatTimelineMessageIdentity {
    static func keys(for item: MessageStorageItem) -> [String] {
        var keys: [String] = []
        if let archivedId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(item.archivedId) {
            keys.append("archive:\(archivedId)")
        }
        if item.messageId.isNotEmpty {
            keys.append("message:\(item.messageId)")
        }
        if item.primary.isNotEmpty {
            keys.append("primary:\(item.primary)")
        }
        return keys
    }
}

enum ChatTimelineOrdering {
    static func chronological(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        items.sorted {
            ChatTimelinePositionKey(message: $0) < ChatTimelinePositionKey(message: $1)
        }
    }

    static func deduplicatedChronological(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        var seen = Set<String>()
        return chronological(items).filter { item in
            let keys = ChatTimelineMessageIdentity.keys(for: item)
            guard keys.contains(where: { seen.contains($0) }) == false else {
                return false
            }
            seen.formUnion(keys)
            return true
        }
    }
}

protocol ChatTimelinePageProviding {
    func latest(limit: Int) -> [MessageStorageItem]
    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem]
    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem]
    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem]
    func message(primary: String?, archivedId: String?, messageId: String?) -> MessageStorageItem?
    func searchMessage(anchor: ChatMessageAnchorRef) -> MessageStorageItem?
    func searchMessageResolution(anchor: ChatMessageAnchorRef) -> ChatTimelineSearchMessageResolution
    func items(primaryKeys: [String]) -> [MessageStorageItem]
}

extension ChatTimelinePageProviding {
    func searchMessage(anchor: ChatMessageAnchorRef) -> MessageStorageItem? {
        message(
            primary: anchor.messagePrimary,
            archivedId: anchor.archivedId,
            messageId: anchor.messageId
        )
    }

    func searchMessageResolution(
        anchor: ChatMessageAnchorRef
    ) -> ChatTimelineSearchMessageResolution {
        searchMessage(anchor: anchor).map(ChatTimelineSearchMessageResolution.found)
            ?? .failed(.targetMissing)
    }
}

enum ChatBoundedTimelineWindowPolicy {
    static let targetPageMultiplier = ChatPerformanceResourceBudgets.timelineTargetPageMultiplier
    static let hardPageMultiplier = ChatPerformanceResourceBudgets.timelineHardPageMultiplier

    static func targetLimit(pageSize: Int) -> Int {
        max(1, pageSize) * targetPageMultiplier
    }

    static func hardLimit(pageSize: Int) -> Int {
        max(1, pageSize) * hardPageMultiplier
    }

    static func trimmedItems<T>(
        _ items: [T],
        direction: ChatHistoryPageDirection?,
        pageSize: Int
    ) -> [T] {
        let limit = direction == nil ? targetLimit(pageSize: pageSize) : hardLimit(pageSize: pageSize)
        guard items.count > limit else {
            return items
        }

        switch direction {
        case .older:
            return Array(items.prefix(limit))
        case .newer, .none:
            return Array(items.suffix(limit))
        }
    }

    static func normalizedWindow(
        requestedWindow: ChatDatasetWindow,
        itemCount: Int,
        direction: ChatHistoryPageDirection?
    ) -> ChatDatasetWindow {
        guard itemCount > 0 else {
            return .empty
        }

        switch direction {
        case .older:
            return ChatDatasetWindow(
                minIndex: requestedWindow.minIndex,
                maxIndex: requestedWindow.minIndex + itemCount
            )
        case .newer, .none:
            return ChatDatasetWindow(
                minIndex: max(0, requestedWindow.maxIndex - itemCount),
                maxIndex: requestedWindow.maxIndex
            )
        }
    }
}

final class ChatLocalHistoryPageProviderDiagnostics {
    struct Record: Equatable {
        let operation: String
        let candidateCount: Int
        let wasOnMainThread: Bool
    }

    private let lock = NSLock()
    private var storedRecords: [Record] = []
    private var storedFullScanCount = 0
    private var storedCountQueryCount = 0
    private var storedOffsetQueryCount = 0
    private var storedExpansionCount = 0
    private var storedFullSameDateBucketMaterializationCount = 0

    var records: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return storedRecords
    }

    var fullScanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFullScanCount
    }

    var queryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRecords.count
    }

    var mainThreadQueryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRecords.lazy.filter(\.wasOnMainThread).count
    }

    var countQueryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCountQueryCount
    }

    var offsetQueryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedOffsetQueryCount
    }

    var expansionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedExpansionCount
    }

    var fullSameDateBucketMaterializationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFullSameDateBucketMaterializationCount
    }

    var maxCandidateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRecords.map(\.candidateCount).max() ?? 0
    }

    var performanceSnapshot: ChatPerformanceMetricSnapshot {
        lock.lock()
        let recordCount = storedRecords.count
        let mainThreadQueryCount = storedRecords.lazy.filter(\.wasOnMainThread).count
        let fullScanCount = storedFullScanCount
        let countQueryCount = storedCountQueryCount
        let offsetQueryCount = storedOffsetQueryCount
        let expansionCount = storedExpansionCount
        let fullSameDateBucketMaterializationCount = storedFullSameDateBucketMaterializationCount
        let maxCandidateCount = storedRecords.map(\.candidateCount).max() ?? 0
        lock.unlock()
        return ChatPerformanceMetricSnapshot(
            phase: .localHistoryQuery,
            counters: [
                "recordCount": recordCount,
                "mainThreadQueryCount": mainThreadQueryCount,
                "fullScanCount": fullScanCount,
                "countQueryCount": countQueryCount,
                "offsetQueryCount": offsetQueryCount,
                "expansionCount": expansionCount,
                "fullSameDateBucketMaterializationCount": fullSameDateBucketMaterializationCount,
                "maxCandidateCount": maxCandidateCount
            ]
        )
    }

    func record(operation: String, candidateCount: Int) {
        lock.lock()
        storedRecords.append(Record(
            operation: operation,
            candidateCount: candidateCount,
            wasOnMainThread: Thread.isMainThread
        ))
        lock.unlock()
    }

    func recordFullScan() {
        lock.lock()
        storedFullScanCount += 1
        lock.unlock()
    }
}

struct ChatUnreadMentionBulkLookupRequest: Equatable {
    let notificationPrimary: String
    let archivedId: String?
    let messageId: String?
}

struct ChatUnreadMentionBulkCandidate: Equatable {
    let primary: String
    let archivedId: String?
    let messageId: String?
}

/// Immutable, bounded input for the one-operation group-mention lookup.
/// The plan contains only indexed identifiers from the at-most-one-page
/// notification batch; total conversation history size is deliberately absent.
struct ChatUnreadMentionBulkQueryPlan: Equatable {
    let requests: [ChatUnreadMentionBulkLookupRequest]
    let archivedIds: [String]
    let messageIds: [String]
    let candidateLimit: Int

    init(
        requests: [ChatUnreadMentionBulkLookupRequest],
        limit: Int
    ) {
        let boundedLimit = min(
            max(0, limit),
            ArchivePageSizing.initial
        )
        let boundedRequests = Array(requests.prefix(boundedLimit)).map { request in
            ChatUnreadMentionBulkLookupRequest(
                notificationPrimary: request.notificationPrimary,
                archivedId: RegularChatArchiveSyncStateStorageItem
                    .normalizedArchiveId(request.archivedId),
                messageId: request.messageId?.isNotEmpty == true
                    ? request.messageId
                    : nil
            )
        }
        self.requests = boundedRequests
        self.archivedIds = Array(Set(boundedRequests.compactMap(\.archivedId))).sorted()
        self.messageIds = Array(Set(boundedRequests.compactMap(\.messageId))).sorted()
        self.candidateLimit = boundedLimit
    }
}

enum ChatUnreadMentionBulkResolutionPolicy {
    /// Duplicate archived/message identifiers resolve to the stable lowest
    /// primary. Sorting here as well as in the Realm query keeps the result
    /// deterministic for every provider implementation and insertion order.
    static func resolve<Candidates: Sequence>(
        plan: ChatUnreadMentionBulkQueryPlan,
        candidates: Candidates
    ) -> [String: String] where Candidates.Element == ChatUnreadMentionBulkCandidate {
        var primaryByArchivedId: [String: String] = [:]
        var primaryByMessageId: [String: String] = [:]
        for candidate in candidates.sorted(by: { $0.primary < $1.primary }) {
            if let archivedId = RegularChatArchiveSyncStateStorageItem
                .normalizedArchiveId(candidate.archivedId),
               primaryByArchivedId[archivedId] == nil {
                primaryByArchivedId[archivedId] = candidate.primary
            }
            if let messageId = candidate.messageId,
               messageId.isNotEmpty,
               primaryByMessageId[messageId] == nil {
                primaryByMessageId[messageId] = candidate.primary
            }
        }

        var result: [String: String] = [:]
        result.reserveCapacity(plan.requests.count)
        for request in plan.requests where request.notificationPrimary.isNotEmpty {
            let archivedPrimary = request.archivedId.flatMap {
                primaryByArchivedId[$0]
            }
            let messagePrimary = request.messageId.flatMap {
                primaryByMessageId[$0]
            }
            if let primary = archivedPrimary ?? messagePrimary {
                result[request.notificationPrimary] = primary
            }
        }
        return result
    }
}

final class ChatLocalHistoryPageProvider: ChatTimelinePageProviding {
    /// A fixed oversampling budget absorbs normal live/MAM duplicate rows without
    /// turning a page request into count/offset or exponentially growing queries.
    private static let candidateMultiplier = 4

    private let realm: Realm
    private let owner: String
    private let jid: String
    private let conversationType: ClientSynchronizationManager.ConversationType
    private let diagnostics: ChatLocalHistoryPageProviderDiagnostics?
    private let isCancelled: () -> Bool

    init(
        realm: Realm,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        diagnostics: ChatLocalHistoryPageProviderDiagnostics? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) {
        self.realm = realm
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
        self.diagnostics = diagnostics
        self.isCancelled = isCancelled
    }

    func latest(limit: Int) -> [MessageStorageItem] {
        guard limit > 0 else { return [] }
        if let candidates = linkedCandidates(
            startingAt: linkedIndexState()?.newestMessagePrimary,
            direction: .previous,
            requestedLimit: limit
        ) {
            diagnostics?.record(operation: "latest", candidateCount: candidates.count)
            return Array(Self.deduplicatedChronologicalItems(candidates).suffix(limit))
        }
        return boundedCandidateWindow(
            operation: "latest",
            scoped: baseQuery(),
            sortDescriptors: Self.sortDescriptors(ascending: false),
            requestedLimit: limit
        ) { candidates in
            Array(Self.deduplicatedChronologicalItems(candidates).suffix(limit))
        }
    }

    /// Initial presentation has a stricter materialization budget than
    /// interactive paging. It consumes one exact chronological tail window;
    /// duplicate repair can happen on later pages without making the first
    /// visible frame inspect up to `candidateMultiplier * limit` rows.
    func initialLatestWindow(limit: Int) -> [MessageStorageItem] {
        let boundedLimit = min(
            max(0, limit),
            ArchivePageSizing.initial
        )
        guard boundedLimit > 0 else { return [] }
        return ChatPerformanceSignposts.measure(.localHistoryQuery) {
            guard !isCancelled() else { return [] }
            let candidates = Array(
                baseQuery()
                    .sorted(by: Self.sortDescriptors(ascending: false))
                    .prefix(boundedLimit)
            )
            guard !isCancelled() else { return [] }
            diagnostics?.record(
                operation: "latestWindow",
                candidateCount: candidates.count
            )
            return Array(
                Self.deduplicatedChronologicalItems(candidates)
                    .suffix(boundedLimit)
            )
        }
    }

    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        guard limit > 0 else { return [] }
        if let anchor = linkedMessage(primary: boundary.primary),
           let candidates = linkedCandidates(
                startingAt: anchor.historyPreviousMessagePrimary,
                direction: .previous,
                requestedLimit: limit
           ) {
            diagnostics?.record(operation: "older", candidateCount: candidates.count)
            return Array(Self.deduplicatedChronologicalItems(candidates).suffix(limit))
        }
        let scoped = baseQuery()
            .filter(Self.cursorPredicate(before: boundary))
        return boundedCandidateWindow(
            operation: "older",
            scoped: scoped,
            sortDescriptors: Self.sortDescriptors(ascending: false),
            requestedLimit: limit
        ) { candidates in
            Array(Self.deduplicatedChronologicalItems(candidates).suffix(limit))
        }
    }

    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        guard limit > 0 else { return [] }
        if let anchor = linkedMessage(primary: boundary.primary),
           let candidates = linkedCandidates(
                startingAt: anchor.historyNextMessagePrimary,
                direction: .next,
                requestedLimit: limit
           ) {
            diagnostics?.record(operation: "newer", candidateCount: candidates.count)
            return Array(Self.deduplicatedChronologicalItems(candidates).prefix(limit))
        }
        let scoped = baseQuery()
            .filter(Self.cursorPredicate(after: boundary))
        return boundedCandidateWindow(
            operation: "newer",
            scoped: scoped,
            sortDescriptors: Self.sortDescriptors(ascending: true),
            requestedLimit: limit
        ) { candidates in
            Array(Self.deduplicatedChronologicalItems(candidates).prefix(limit))
        }
    }

    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem] {
        guard anchor.owner == owner,
              anchor.opponent == jid,
              anchor.conversationType == conversationType,
              !anchor.isDeleted else {
            return []
        }

        let boundary = ChatTimelineBoundary(message: anchor)
        let olderItems = older(before: boundary, limit: max(0, before))
        let newerItems = newer(after: boundary, limit: max(0, after))
        let items = olderItems + [anchor] + newerItems
        let deduplicated = Self.deduplicatedChronologicalItems(items)
        guard deduplicated.contains(where: { $0.primary == anchor.primary }) else {
            return []
        }
        return deduplicated
    }

    func message(
        primary: String?,
        archivedId: String?,
        messageId: String?
    ) -> MessageStorageItem? {
        ChatPerformanceSignposts.measure(.localHistoryQuery) {
            let result = resolvedMessage(
                primary: primary,
                archivedId: archivedId,
                messageId: messageId
            )
            diagnostics?.record(
                operation: "message",
                candidateCount: result == nil ? 0 : 1
            )
            return result
        }
    }

    /// Resolves the complete bounded unread-mention batch in one typed history
    /// operation. Notification order and archived-id-before-message-id
    /// precedence are applied in memory; no per-notification provider lookup is
    /// permitted on the initial-frame route.
    func unreadMentionMessagePrimaries(
        for notifications: [NotificationStorageItem],
        limit: Int
    ) -> [String: String] {
        let boundedLimit = min(
            max(0, limit),
            ArchivePageSizing.initial
        )
        return ChatPerformanceSignposts.measure(.localHistoryQuery) {
            guard boundedLimit > 0, !isCancelled() else {
                diagnostics?.record(operation: "unread", candidateCount: 0)
                return [:]
            }
            let boundedNotifications = Array(notifications.prefix(boundedLimit))
            let plan = ChatUnreadMentionBulkQueryPlan(
                requests: boundedNotifications.map {
                    ChatUnreadMentionBulkLookupRequest(
                        notificationPrimary: $0.primary,
                        archivedId: $0.sourceArchivedId,
                        messageId: $0.sourceMessageId
                    )
                },
                limit: boundedLimit
            )
            let candidates: [MessageStorageItem]
            if plan.archivedIds.isEmpty && plan.messageIds.isEmpty {
                candidates = []
            } else {
                candidates = Array(
                    baseQuery()
                        .filter(
                            "archivedId IN %@ OR messageId IN %@",
                            plan.archivedIds,
                            plan.messageIds
                        )
                        .sorted(byKeyPath: "primary", ascending: true)
                        .prefix(boundedLimit)
                )
            }
            guard !isCancelled() else { return [:] }
            let result = ChatUnreadMentionBulkResolutionPolicy.resolve(
                plan: plan,
                candidates: candidates.map {
                    ChatUnreadMentionBulkCandidate(
                        primary: $0.primary,
                        archivedId: $0.archivedId,
                        messageId: $0.messageId
                    )
                }
            )
            diagnostics?.record(
                operation: "unread",
                candidateCount: max(
                    boundedNotifications.isEmpty ? 0 : 1,
                    max(boundedNotifications.count, candidates.count)
                )
            )
            return result
        }
    }

    private func resolvedMessage(
        primary: String?,
        archivedId: String?,
        messageId: String?
    ) -> MessageStorageItem? {
        guard !isCancelled() else { return nil }
        if let primary,
           primary.isNotEmpty,
           let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
           item.owner == owner,
           item.opponent == jid,
           item.conversationType == conversationType,
           !item.isDeleted {
            return item
        }

        let scoped = baseQuery()
        if let archivedId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archivedId),
           let item = scoped.filter("archivedId == %@", archivedId).first {
            return item
        }

        if let messageId,
           messageId.isNotEmpty,
           let item = scoped.filter("messageId == %@", messageId).first {
            return item
        }

        return nil
    }

    func searchMessage(anchor: ChatMessageAnchorRef) -> MessageStorageItem? {
        searchMessageResolution(anchor: anchor).message
    }

    func searchMessageResolution(
        anchor: ChatMessageAnchorRef
    ) -> ChatTimelineSearchMessageResolution {
        guard !isCancelled() else { return .failed(.superseded) }

        if let primary = anchor.messagePrimary,
           primary.isNotEmpty,
           let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
           item.owner == owner,
           item.opponent == jid,
           item.conversationType == conversationType {
            diagnostics?.record(operation: "search-primary", candidateCount: 1)
            return item.isDeleted ? .failed(.targetDeleted) : .found(item)
        }

        let scoped = baseQuery()
        var deferredFailure: ChatAnchorTransactionFailure?
        if let archivedId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(anchor.archivedId) {
            let candidates = Array(scoped.filter("archivedId == %@", archivedId).prefix(2))
            diagnostics?.record(operation: "search-archive", candidateCount: candidates.count)
            if candidates.count == 1 {
                return .found(candidates[0])
            }
            if candidates.count > 1 {
                deferredFailure = .ambiguous(candidateCount: candidates.count)
            }
        }

        if let messageId = anchor.messageId,
           messageId.isNotEmpty {
            let materializationLimit = anchor.authorId?.isNotEmpty == true
                ? LastChatsSearchLocalResolver.defaultFallbackCandidateLimit + 1
                : 2
            let materialized = Array(
                scoped
                    .filter("messageId == %@", messageId)
                    .sorted(byKeyPath: "historyPositionOrdinal", ascending: false)
                    .prefix(materializationLimit)
            )
            diagnostics?.record(operation: "search-message-id", candidateCount: materialized.count)
            if anchor.authorId?.isNotEmpty == true,
               materialized.count > LastChatsSearchLocalResolver.defaultFallbackCandidateLimit {
                return .failed(.candidateLimitExceeded(
                    limit: LastChatsSearchLocalResolver.defaultFallbackCandidateLimit
                ))
            }
            let candidates = materialized.filter {
                anchor.authorId?.isNotEmpty != true || $0.groupchatAuthorId == anchor.authorId
            }
            if candidates.count == 1 {
                return .found(candidates[0])
            }
            if candidates.count > 1 {
                deferredFailure = .ambiguous(candidateCount: candidates.count)
            }
        }

        guard let sourceDate = anchor.sourceDate,
              let fingerprint = LastChatsSearchFingerprint.normalize(anchor.bodyFingerprint) else {
            return .failed(deferredFailure ?? .targetMissing)
        }
        let fallbackLimit = LastChatsSearchLocalResolver.defaultFallbackCandidateLimit
        let candidates = Array(
            scoped
                .filter(
                    "date >= %@ AND date <= %@",
                    sourceDate.addingTimeInterval(-LastChatsSearchLocalResolver.dateTolerance),
                    sourceDate.addingTimeInterval(LastChatsSearchLocalResolver.dateTolerance)
                )
                .sorted(byKeyPath: "historyPositionOrdinal", ascending: false)
                .prefix(fallbackLimit + 1)
        )
        diagnostics?.record(operation: "search-fingerprint-date", candidateCount: candidates.count)
        guard candidates.count <= fallbackLimit else {
            return .failed(.candidateLimitExceeded(limit: fallbackLimit))
        }
        let matches = candidates.filter {
            (anchor.authorId?.isNotEmpty != true || $0.groupchatAuthorId == anchor.authorId)
                && LastChatsSearchFingerprint.normalize($0.displayedBody()) == fingerprint
        }
        if matches.count == 1, let match = matches.first {
            return .found(match)
        }
        if matches.count > 1 {
            return .failed(.ambiguous(candidateCount: matches.count))
        }
        return .failed(deferredFailure ?? .targetMissing)
    }

    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem? {
        guard let boundaryDate = ChatInitialPositionPolicy.archiveDate(from: boundaryArchivedId) else {
            return nil
        }

        let boundary = ChatTimelineBoundary(
            primary: boundaryArchivedId,
            archivedId: boundaryArchivedId,
            messageId: nil,
            date: boundaryDate
        )
        return boundedCandidateWindow(
            operation: "firstIncoming",
            scoped: baseQuery()
                .filter(Self.cursorPredicate(after: boundary))
                .filter("outgoing == false"),
            sortDescriptors: Self.sortDescriptors(ascending: true),
            requestedLimit: 1
        ) { candidates in
            Array(Self.deduplicatedChronologicalItems(candidates).prefix(1))
        }.first
    }

    func items(primaryKeys: [String]) -> [MessageStorageItem] {
        guard primaryKeys.isNotEmpty, !isCancelled() else { return [] }
        let results = realm.objects(MessageStorageItem.self)
            .filter("primary IN %@", primaryKeys)
        let byPrimary = Dictionary(uniqueKeysWithValues: results.map { ($0.primary, $0) })
        return primaryKeys.compactMap { byPrimary[$0] }
    }

    private func baseQuery() -> Results<MessageStorageItem> {
        realm.objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@",
                owner,
                jid,
                conversationType.rawValue
            )
    }

    private enum LinkedDirection {
        case previous
        case next
    }

    private func linkedIndexState() -> ChatLocalHistoryIndexStorageItem? {
        guard !isCancelled(),
              let state = ChatLocalHistoryLinkedIndex.state(
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                in: realm
              ),
              state.version == ChatLocalHistoryIndexStorageItem.currentVersion else {
            return nil
        }
        return state
    }

    private func linkedMessage(primary: String) -> MessageStorageItem? {
        guard linkedIndexState() != nil,
              let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
              message.owner == owner,
              message.opponent == jid,
              message.conversationType == conversationType,
              message.historyLinkedIndexVersion == ChatLocalHistoryIndexStorageItem.currentVersion else {
            return nil
        }
        return message
    }

    private func linkedCandidates(
        startingAt initialPrimary: String?,
        direction: LinkedDirection,
        requestedLimit: Int
    ) -> [MessageStorageItem]? {
        guard linkedIndexState() != nil else { return nil }
        return ChatPerformanceSignposts.measure(.localHistoryQuery) { () -> [MessageStorageItem]? in
            guard !isCancelled() else { return [] }
            let traversalLimit = max(requestedLimit, requestedLimit * Self.candidateMultiplier)
            var currentPrimary = initialPrimary
            var visitedPrimaries = Set<String>()
            var candidates: [MessageStorageItem] = []
            candidates.reserveCapacity(min(traversalLimit, requestedLimit))

            while let primary = currentPrimary, visitedPrimaries.count < traversalLimit {
                guard visitedPrimaries.insert(primary).inserted,
                      let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
                      message.owner == owner,
                      message.opponent == jid,
                      message.conversationType == conversationType,
                      message.historyLinkedIndexVersion == ChatLocalHistoryIndexStorageItem.currentVersion else {
                    return nil
                }
                currentPrimary = direction == .previous
                    ? message.historyPreviousMessagePrimary
                    : message.historyNextMessagePrimary
                if !message.isDeleted {
                    candidates.append(message)
                }
                if isCancelled() { return [] }
            }
            return candidates
        }
    }

    private func boundedCandidateWindow(
        operation: String,
        scoped: Results<MessageStorageItem>,
        sortDescriptors: [RealmSwift.SortDescriptor],
        requestedLimit: Int,
        transform: ([MessageStorageItem]) -> [MessageStorageItem]
    ) -> [MessageStorageItem] {
        ChatPerformanceSignposts.measure(.localHistoryQuery) {
            guard !isCancelled() else { return [] }
            let candidateLimit = max(requestedLimit, requestedLimit * Self.candidateMultiplier)
            let candidates = Array(scoped.sorted(by: sortDescriptors).prefix(candidateLimit))
            guard !isCancelled() else { return [] }
            diagnostics?.record(operation: operation, candidateCount: candidates.count)
            return transform(candidates)
        }
    }

    private static func sortDescriptors(ascending: Bool) -> [RealmSwift.SortDescriptor] {
        [
            RealmSwift.SortDescriptor(keyPath: "historyPositionOrdinal", ascending: ascending)
        ]
    }

    private static func cursorPredicate(before boundary: ChatTimelineBoundary) -> NSPredicate {
        let position = MessageHistoryPositionComponents.make(
            primary: boundary.primary,
            archivedId: boundary.archivedId,
            messageId: boundary.messageId,
            date: boundary.date
        )
        return NSPredicate(
            format: "historyPositionOrdinal < %@",
            NSNumber(value: position.ordinal)
        )
    }

    private static func cursorPredicate(after boundary: ChatTimelineBoundary) -> NSPredicate {
        let position = MessageHistoryPositionComponents.make(
            primary: boundary.primary,
            archivedId: boundary.archivedId,
            messageId: boundary.messageId,
            date: boundary.date
        )
        return NSPredicate(
            format: "historyPositionOrdinal > %@",
            NSNumber(value: position.ordinal)
        )
    }

    private static func deduplicatedChronologicalItems(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        ChatTimelineOrdering.deduplicatedChronological(items)
    }
}

enum ChatHistoryPageDirection: Equatable {
    case older
    case newer
}

enum ChatScrollMotionState: String, Equatable {
    case resting
    case dragging
    case decelerating
    case tracking

    var isMoving: Bool {
        self != .resting
    }
}

enum ChatHistoryLoadingOverlayPolicy {
    static let isOverlayUserInteractionEnabled = false
    static let shouldDisableCollectionInteraction = false
}

struct ChatTimelineConversationKey: Equatable, @unchecked Sendable {
    let owner: String
    let jid: String
    let conversationType: ClientSynchronizationManager.ConversationType

    static let empty = ChatTimelineConversationKey(
        owner: "",
        jid: "",
        conversationType: .regular
    )
}

enum ChatVirtualSegment: Equatable {
    case unknownOlder
    case loadedRange(oldestArchiveId: String?, newestArchiveId: String?)
    case unknownNewer
    case liveTail
}

struct ChatTimelineAnchorRestoreCommand: Equatable {
    let primary: String
    let archivedId: String?
    let viewportOffset: CGFloat
}

struct ChatVirtualTimelineState: Equatable {
    static let empty = ChatVirtualTimelineState(
        conversationKey: .empty,
        segments: [],
        oldest: nil,
        newest: nil,
        residentPrimaryKeys: [],
        residentArchivedIds: [],
        isResidentAtLiveTail: true
    )

    let conversationKey: ChatTimelineConversationKey
    let segments: [ChatVirtualSegment]
    let oldest: ChatTimelineBoundary?
    let newest: ChatTimelineBoundary?
    let residentPrimaryKeys: [String]
    let residentArchivedIds: [String]
    let isResidentAtLiveTail: Bool

    var isEmpty: Bool {
        residentPrimaryKeys.isEmpty
    }

    static func empty(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ChatVirtualTimelineState {
        ChatVirtualTimelineState(
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: conversationType
            ),
            segments: [],
            oldest: nil,
            newest: nil,
            residentPrimaryKeys: [],
            residentArchivedIds: [],
            isResidentAtLiveTail: true
        )
    }

    func normalized(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ChatVirtualTimelineState {
        let key = ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        guard conversationKey == key else {
            return .empty(owner: owner, jid: jid, conversationType: conversationType)
        }
        return self
    }

}

struct ChatTimelineSnapshot {
    let items: [MessageStorageItem]
    let state: ChatVirtualTimelineState
    let anchorRestore: ChatTimelineAnchorRestoreCommand?

    init(
        items: [MessageStorageItem],
        state: ChatVirtualTimelineState,
        anchorRestore: ChatTimelineAnchorRestoreCommand?
    ) {
        self.items = items
        self.state = state
        self.anchorRestore = anchorRestore
    }
}

typealias ChatHistoryPageAnchor = ChatViewportAnchor

struct ChatHistoryPagingBoundaryContext: Equatable {
    let firstRealSection: Int?
    let lastRealSection: Int?
    let visibleRealSections: [Int]

    var isEntireRealRangeVisible: Bool {
        guard let firstRealSection,
              let lastRealSection else {
            return false
        }
        return visibleRealSections.contains(firstRealSection) &&
            visibleRealSections.contains(lastRealSection)
    }
}

enum ChatDatasourceApplyCategory: String {
    case `default`
    case olderAnchorReload
    case tailAppendBottomPinned
}

enum ChatHistoryPageAnchorRestorePhase: String {
    case none
    case applyTransaction
}

struct ChatHistoryPageApplyPlan: Equatable {
    let keepOffset: Bool
    let restorePhase: ChatHistoryPageAnchorRestorePhase
    let applyCategory: ChatDatasourceApplyCategory

    var shouldRestoreAnchor: Bool {
        restorePhase != .none
    }
}

enum ChatHistoryPageApplyPolicy {
    static func keepOffset(direction: ChatHistoryPageDirection) -> Bool {
        switch direction {
        case .older:
            return true
        case .newer:
            return false
        }
    }

    static func plan(
        direction: ChatHistoryPageDirection,
        hasCapturedAnchor: Bool
    ) -> ChatHistoryPageApplyPlan {
        switch direction {
        case .older where hasCapturedAnchor:
            return ChatHistoryPageApplyPlan(
                keepOffset: false,
                restorePhase: .applyTransaction,
                applyCategory: .olderAnchorReload
            )
        case .older:
            return ChatHistoryPageApplyPlan(
                keepOffset: true,
                restorePhase: .none,
                applyCategory: .default
            )
        case .newer:
            return ChatHistoryPageApplyPlan(
                keepOffset: false,
                restorePhase: hasCapturedAnchor ? .applyTransaction : .none,
                applyCategory: .default
            )
        }
    }
}

enum ChatHistoryPageAnchorCapturePolicy {
    static func shouldCaptureNewerAnchor(
        isNearBottom: Bool,
        isResidentAtLiveTail: Bool
    ) -> Bool {
        guard isNearBottom else {
            return true
        }

        return !isResidentAtLiveTail
    }
}

enum ChatHistoryPageAnchorRestorePolicy {
    static func targetContentOffsetY(
        anchorMinY: CGFloat,
        viewportRelativeMinY: CGFloat,
        minContentOffsetY: CGFloat,
        maxContentOffsetY: CGFloat
    ) -> CGFloat {
        min(max(anchorMinY - viewportRelativeMinY, minContentOffsetY), maxContentOffsetY)
    }
}

private struct ChatHistoryPageAnchorRestoreDiagnostics {
    var sectionFound = false
    var attributesFound = false
    var restored = false
    var targetOffsetY: CGFloat?
}

enum ChatDatasourceApplyGenerationPolicy {
    static func shouldApply(requestGeneration: Int, currentGeneration: Int) -> Bool {
        requestGeneration == currentGeneration
    }
}

enum ChatUnreadMentionNavigatorMode: Equatable {
    case hidden
    case indicator
}

struct ChatUnreadMentionItem: Equatable {
    let notificationPrimary: String?
    let messagePrimary: String?
    let archivedId: String?
    let messageId: String?
    let chatPrimary: String
    let authorId: String?
    let date: Date
    let targetMemberId: String?
    let groupchatJid: String
}

/// Value-only UI projection. General unread totals and sampling diagnostics do
/// not affect the mention navigator, so their changes must not schedule
/// redundant main-thread presentation work.
struct ChatUnreadMentionPresentationMetadata: Equatable {
    let mentions: [ChatUnreadMentionItem]
    let latestUnreadMentionArchivedId: String?

    init(_ metadata: ChatTimelineUnreadMetadata) {
        self.mentions = metadata.mentions
        self.latestUnreadMentionArchivedId =
            metadata.latestUnreadMentionArchivedId
    }
}

enum ChatUnreadMentionPresentationTrackingPolicy {
    static func trackedProjection(
        authoritative metadata: ChatTimelineUnreadMetadata,
        appliedMentions: [ChatUnreadMentionItem]
    ) -> ChatUnreadMentionPresentationMetadata? {
        let projection = ChatUnreadMentionPresentationMetadata(metadata)
        if projection.mentions == appliedMentions {
            return projection
        }
        guard projection.mentions.isEmpty,
              let latestUnreadMentionArchivedId =
                projection.latestUnreadMentionArchivedId,
              appliedMentions.count == 1,
              let fallback = appliedMentions.first,
              fallback.notificationPrimary == nil,
              fallback.archivedId == latestUnreadMentionArchivedId else {
            // A fallback without a matching authoritative hint is
            // provisional. Leaving it untracked ensures the next observer
            // frame can clear or replace it even when the raw mention list
            // itself remains empty.
            return nil
        }
        return projection
    }
}

enum ChatUnreadMentionPresentationCommitPolicy {
    static func nextTrackedProjection(
        previous: ChatUnreadMentionPresentationMetadata?,
        authoritative metadata: ChatTimelineUnreadMetadata,
        appliedMentions: [ChatUnreadMentionItem],
        didApplyNavigatorState: Bool
    ) -> ChatUnreadMentionPresentationMetadata? {
        guard didApplyNavigatorState else { return previous }
        return ChatUnreadMentionPresentationTrackingPolicy.trackedProjection(
            authoritative: metadata,
            appliedMentions: appliedMentions
        )
    }
}

struct ChatUnreadMentionNavigationTarget: Equatable {
    let notificationPrimary: String?
    let messagePrimary: String?
    let archivedId: String?
    let messageId: String?
    let authorId: String?
    let date: Date
    let observerIndex: Int?
}

struct ChatUnreadMentionNavigationRequest: Equatable {
    let target: ChatUnreadMentionNavigationTarget
    let direction: ChatViewController.ChatDirection
}

struct ChatUnreadMentionsState: Equatable {
    static let empty = ChatUnreadMentionsState(
        items: [],
        unreadCount: 0,
        visibleUnreadNotificationPrimaries: Set(),
        currentTarget: nil,
        jumpTarget: nil,
        mode: .hidden
    )

    let items: [ChatUnreadMentionItem]
    let unreadCount: Int
    let visibleUnreadNotificationPrimaries: Set<String>
    let currentTarget: ChatUnreadMentionNavigationTarget?
    let jumpTarget: ChatUnreadMentionNavigationTarget?
    let mode: ChatUnreadMentionNavigatorMode

    var hasUnreadMentions: Bool {
        unreadCount > 0
    }
}

enum ChatUnreadMentionMatcher {
    static func unreadMentionItem(
        from notification: NotificationStorageItem,
        resolveMessagePrimary: (NotificationStorageItem) -> String?,
        chatPrimary: String,
        currentMemberId: String?,
        groupchatJid: String
    ) -> ChatUnreadMentionItem? {
        guard notification.isMentionNotification,
              !notification.isRead,
              notification.sourceChatJid == groupchatJid,
              notification.sourceConversationType == nil || notification.sourceConversationType == .group,
              notification.mentionLinkStatus != .invalidated,
              notification.mentionLinkStatus != .missing else {
            return nil
        }

        let archivedId = notification.sourceArchivedId?.isNotEmpty == true ? notification.sourceArchivedId : nil
        let messageId = notification.sourceMessageId?.isNotEmpty == true ? notification.sourceMessageId : nil

        guard archivedId != nil || messageId != nil else {
            return nil
        }

        let targetMemberId = notification.mentionTargetUserId ?? currentMemberId

        if let authorId = notification.sourceSenderId,
           authorId.isNotEmpty,
           let targetMemberId,
           targetMemberId.isNotEmpty,
           authorId == targetMemberId {
            return nil
        }

        return ChatUnreadMentionItem(
            notificationPrimary: notification.primary,
            messagePrimary: resolveMessagePrimary(notification),
            archivedId: archivedId,
            messageId: messageId,
            chatPrimary: chatPrimary,
            authorId: notification.sourceSenderId,
            date: notification.sourceMessageDate ?? notification.date,
            targetMemberId: targetMemberId,
            groupchatJid: groupchatJid
        )
    }
}

enum ChatUnreadMentionIndexPolicy {
    static func rebuild<Notifications: Sequence>(
        from notifications: Notifications,
        resolveMessagePrimary: (NotificationStorageItem) -> String?,
        chatPrimary: String,
        currentMemberId: String?,
        groupchatJid: String
    ) -> [ChatUnreadMentionItem] where Notifications.Element == NotificationStorageItem {
        var seenKeys: Set<String> = []
        return notifications.compactMap {
            ChatUnreadMentionMatcher.unreadMentionItem(
                from: $0,
                resolveMessagePrimary: resolveMessagePrimary,
                chatPrimary: chatPrimary,
                currentMemberId: currentMemberId,
                groupchatJid: groupchatJid
            )
        }.filter {
            let key = $0.archivedId ?? $0.messageId ?? $0.notificationPrimary ?? $0.chatPrimary
            return seenKeys.insert(key).inserted
        }
    }
}

enum ChatUnreadMentionFallbackPolicy {
    static func fallbackItem(
        mentionId: String?,
        chatPrimary: String,
        currentMemberId: String?,
        groupchatJid: String,
        date: Date
    ) -> ChatUnreadMentionItem? {
        guard let mentionId,
              mentionId.isNotEmpty else {
            return nil
        }

        return ChatUnreadMentionItem(
            notificationPrimary: nil,
            messagePrimary: nil,
            archivedId: mentionId,
            messageId: nil,
            chatPrimary: chatPrimary,
            authorId: nil,
            date: date,
            targetMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )
    }
}

enum ChatUnreadMentionPresentationItemsPolicy {
    static func items(
        metadata: ChatTimelineUnreadMetadata,
        chatPrimary: String,
        groupchatJid: String
    ) -> [ChatUnreadMentionItem] {
        guard metadata.mentions.isEmpty else {
            return metadata.mentions
        }
        return ChatUnreadMentionFallbackPolicy.fallbackItem(
            mentionId: metadata.latestUnreadMentionArchivedId,
            chatPrimary: chatPrimary,
            currentMemberId: nil,
            groupchatJid: groupchatJid,
            date: Date(timeIntervalSince1970: 0)
        ).map { [$0] } ?? []
    }
}

enum ChatUnreadMentionPresentationReconciliationDecision: Equatable {
    case unchanged
    case apply(
        metadata: ChatUnreadMentionPresentationMetadata,
        items: [ChatUnreadMentionItem]
    )
}

enum ChatUnreadMentionPresentationReconciliationPolicy {
    static func decision(
        lastApplied: ChatUnreadMentionPresentationMetadata?,
        metadata: ChatTimelineUnreadMetadata,
        chatPrimary: String,
        groupchatJid: String
    ) -> ChatUnreadMentionPresentationReconciliationDecision {
        let next = ChatUnreadMentionPresentationMetadata(metadata)
        guard next != lastApplied else { return .unchanged }
        return .apply(
            metadata: next,
            items: ChatUnreadMentionPresentationItemsPolicy.items(
                metadata: metadata,
                chatPrimary: chatPrimary,
                groupchatJid: groupchatJid
            )
        )
    }
}

enum ChatUnreadMentionBadgeClaimPolicy {
    static func shouldClearClaim(
        claimedNotificationPrimary: String?,
        nextJumpNotificationPrimary: String?
    ) -> Bool {
        guard let claimedNotificationPrimary else { return false }
        return nextJumpNotificationPrimary != claimedNotificationPrimary
    }
}

enum ChatUnreadMentionNavigationPolicy {
    private static func order(_ lhs: ChatUnreadMentionNavigationTarget, _ rhs: ChatUnreadMentionNavigationTarget) -> Bool {
        if let leftIndex = lhs.observerIndex,
           let rightIndex = rhs.observerIndex,
           leftIndex != rightIndex {
            return leftIndex > rightIndex
        }

        if lhs.date != rhs.date {
            return lhs.date > rhs.date
        }

        let leftKey = lhs.archivedId ?? lhs.messageId ?? lhs.notificationPrimary ?? ""
        let rightKey = rhs.archivedId ?? rhs.messageId ?? rhs.notificationPrimary ?? ""
        return leftKey < rightKey
    }

    static func resolveState(
        items: [ChatUnreadMentionItem],
        residentPrimaryPositions: [String: Int],
        visiblePrimaries: Set<String>,
        preferredArchivedId: String? = nil,
        selectedNotificationPrimary: String? = nil
    ) -> ChatUnreadMentionsState {
        let targets = items
            .compactMap { item -> ChatUnreadMentionNavigationTarget? in
                return ChatUnreadMentionNavigationTarget(
                    notificationPrimary: item.notificationPrimary,
                    messagePrimary: item.messagePrimary,
                    archivedId: item.archivedId,
                    messageId: item.messageId,
                    authorId: item.authorId,
                    date: item.date,
                    observerIndex: item.messagePrimary.flatMap { residentPrimaryPositions[$0] }
                )
            }
            .sorted(by: order)

        guard !targets.isEmpty else {
            return .empty
        }

        let visibleUnreadNotificationPrimaries = Set<String>(targets.compactMap { target in
            guard let messagePrimary = target.messagePrimary,
                  visiblePrimaries.contains(messagePrimary) else {
                return nil
            }
            return target.notificationPrimary
        })

        let preferredHintTarget = preferredArchivedId.flatMap { archivedId in
            targets.first(where: { $0.archivedId == archivedId })
        }

        let selectedTarget = selectedNotificationPrimary.flatMap { notificationPrimary in
            targets.first(where: { $0.notificationPrimary == notificationPrimary })
        }

        let visibleTarget = targets.first(where: { target in
            guard let messagePrimary = target.messagePrimary else {
                return false
            }
            return visiblePrimaries.contains(messagePrimary)
        })

        let currentTarget = selectedTarget ?? visibleTarget ?? preferredHintTarget ?? targets.first
        let jumpTarget: ChatUnreadMentionNavigationTarget?

        if let visibleTarget,
           let visibleIndex = targets.firstIndex(where: { $0.notificationPrimary == visibleTarget.notificationPrimary }),
           (visibleIndex + 1) < targets.count {
            jumpTarget = targets[visibleIndex + 1]
        } else {
            jumpTarget = currentTarget
        }

        let mode: ChatUnreadMentionNavigatorMode = .indicator

        return ChatUnreadMentionsState(
            items: items,
            unreadCount: targets.count,
            visibleUnreadNotificationPrimaries: visibleUnreadNotificationPrimaries,
            currentTarget: currentTarget,
            jumpTarget: jumpTarget,
            mode: mode
        )
    }
}

/// Retains notification-owned mention authority independently from the
/// ordinary read state and current viewport of its linked message. Exact
/// meaningful visibility remains the coordinator's admission boundary.
enum ChatUnreadMentionReadCandidateRetentionPolicy {
    static func notificationPrimariesToRetain(
        items: [ChatUnreadMentionItem]
    ) -> Set<String> {
        Set(items.compactMap { item in
            guard let notificationPrimary = item.notificationPrimary,
                  notificationPrimary.isNotEmpty,
                  item.messagePrimary?.isNotEmpty == true else {
                return nil
            }
            return notificationPrimary
        })
    }
}

enum ChatUnreadMentionFloatingControlPolicy {
    static func shouldShowNavigator(
        conversationType: ClientSynchronizationManager.ConversationType,
        unreadCount: Int,
        isSearchMode: Bool
    ) -> Bool {
        conversationType == .group && unreadCount > 0 && !isSearchMode
    }

    static func shouldShowScrollDownButton(
        requested: Bool,
        navigatorVisible _: Bool
    ) -> Bool {
        requested
    }
}

enum ChatDatasourceApplyMode {
    case fullReload(keepOffset: Bool = false)
    case windowReload(keepOffset: Bool = false)
    case targetedDiff
}

enum ChatDatasourcePresentationCommitMode: Equatable {
    case standard
    case atomicInitialFrame
}

enum ChatDatasourcePresentationOwner: Equatable {
    case archiveEngine
}

enum ChatDatasourcePresentationTransactionContext {
    private static let tokenKey = "com.xabber.chat.initial-frame-visual-transaction"

    static var currentToken: String? {
        CATransaction.value(forKey: tokenKey) as? String
    }

    static func install(token: String) {
        CATransaction.setValue(token, forKey: tokenKey)
    }
}

struct ChatReloadInvalidationPlan {
    let mode: ChatDatasourceApplyMode
    let animated: Bool
    let invalidateLayout: Bool
    let suppressDefaultBottomScroll: Bool
}

enum ChatReloadInvalidationPolicy {
    static func sensitiveMediaRevealPlan() -> ChatReloadInvalidationPlan {
        ChatReloadInvalidationPlan(
            mode: .targetedDiff,
            animated: false,
            invalidateLayout: false,
            suppressDefaultBottomScroll: true
        )
    }
}

enum ChatBottomAlignmentTarget: Equatable {
    case newestRealMessage
    case message(ChatMessageAnchorRef)
}

enum ChatBottomAlignmentTargetPolicy {
    static func indexPath(
        for target: ChatBottomAlignmentTarget,
        in items: [ChatViewController.Datasource]
    ) -> IndexPath? {
        guard let section = section(for: target, in: items) else {
            return nil
        }
        return IndexPath(item: 0, section: section)
    }

    static func section(
        for target: ChatBottomAlignmentTarget,
        in items: [ChatViewController.Datasource]
    ) -> Int? {
        switch target {
        case .newestRealMessage:
            return newestRealMessageSection(in: items)
        case .message(let anchor):
            return ChatLoadedMessageNavigationPolicy.index(in: items, for: anchor)
        }
    }

    private static func newestRealMessageSection(
        in items: [ChatViewController.Datasource]
    ) -> Int? {
        items
            .enumerated()
            .reversed()
            .first { _, item in
                isRealMessage(item)
            }?
            .offset
    }

    private static func isRealMessage(_ item: ChatViewController.Datasource) -> Bool {
        guard !item.isFakeMessage else {
            return false
        }

        switch item.kind {
        case .date(_), .unread(_), .initial(_), .skeleton(_):
            return false
        default:
            return true
        }
    }
}

struct ChatOutgoingAutoScrollRequest: Equatable {
    let id: UUID
    let previousNewestPrimary: String?

    init(
        previousNewestPrimary: String?,
        id: UUID = UUID()
    ) {
        self.id = id
        self.previousNewestPrimary = previousNewestPrimary
    }
}

enum ChatOutgoingAutoScrollDecision: Equatable {
    case notHandled
    case useDefaultAndClear
    case handledNoScroll
    case scroll(IndexPath)

    var consumesPendingRequest: Bool {
        switch self {
        case .useDefaultAndClear, .handledNoScroll, .scroll:
            return true
        case .notHandled:
            return false
        }
    }
}

enum ChatOutgoingAutoScrollPolicy {
    static func newestRealMessage(
        in items: [ChatViewController.Datasource]
    ) -> (index: Int, item: ChatViewController.Datasource)? {
        items
            .enumerated()
            .reversed()
            .first { !$0.element.isFakeMessage }
            .map { (index: $0.offset, item: $0.element) }
    }

    static func didInsertLocalOutgoingRow(
        request: ChatOutgoingAutoScrollRequest?,
        items: [ChatViewController.Datasource]
    ) -> Bool {
        guard let request,
              let newest = newestRealMessage(in: items),
              newest.item.primary != request.previousNewestPrimary else {
            return false
        }

        return newest.item.isOutgoing
    }

    static func decision(
        request: ChatOutgoingAutoScrollRequest?,
        items: [ChatViewController.Datasource],
        isAnchorNavigationActive: Bool
    ) -> ChatOutgoingAutoScrollDecision {
        guard let request else {
            return .notHandled
        }
        guard !isAnchorNavigationActive else {
            return .handledNoScroll
        }
        guard let newest = newestRealMessage(in: items) else {
            return .notHandled
        }
        guard newest.item.primary != request.previousNewestPrimary else {
            return .notHandled
        }
        guard newest.item.isOutgoing else {
            return .useDefaultAndClear
        }

        let newestIndexPath = IndexPath(item: 0, section: newest.index)
        return .scroll(newestIndexPath)
    }
}

enum ChatOutgoingAutoScrollApplyPolicy {
    static func shouldUseImmediateReload(
        outgoingAutoScrollDecision: ChatOutgoingAutoScrollDecision
    ) -> Bool {
        switch outgoingAutoScrollDecision {
        case .scroll:
            // A batch insertion updates the collection's content height before
            // bottom alignment is committed. UIKit can then expose the new row
            // under the composer for one or more frames. Reload, layout and
            // bottom alignment are kept in the same non-animated transaction.
            return true
        case .notHandled, .useDefaultAndClear, .handledNoScroll:
            return false
        }
    }

    static func shouldAnimateStructuralApply(
        requestedAnimated: Bool,
        outgoingAutoScrollDecision: ChatOutgoingAutoScrollDecision
    ) -> Bool {
        guard requestedAnimated else {
            return false
        }

        switch outgoingAutoScrollDecision {
        case .scroll:
            return false
        case .notHandled, .useDefaultAndClear, .handledNoScroll:
            return true
        }
    }
}

enum ChatTailAppendBottomPinPolicy {
    static func isPureTailAppend(
        old: ChatDatasourceSnapshot,
        new: ChatDatasourceSnapshot
    ) -> Bool {
        guard !old.items.isEmpty,
              new.items.count > old.items.count,
              !old.hasDuplicateKeys,
              !new.hasDuplicateKeys else {
            return false
        }

        for index in old.items.indices {
            let oldItem = old.items[index]
            let newItem = new.items[index]
            guard oldItem.primary == newItem.primary,
                  ChatViewController.Datasource.compareContent(oldItem, newItem) else {
                return false
            }
        }

        return new.items.dropFirst(old.items.count).contains { !$0.isFakeMessage }
    }

    static func shouldPinBottom(
        old: ChatDatasourceSnapshot,
        new: ChatDatasourceSnapshot,
        wasNearBottom: Bool,
        isResidentAtLiveTail: Bool = true,
        isDefaultBottomScrollDeferred: Bool,
        suppressDefaultBottomScroll: Bool,
        containsOnlyFakeMessages: Bool,
        outgoingAutoScrollDecision: ChatOutgoingAutoScrollDecision
    ) -> Bool {
        guard wasNearBottom,
              isResidentAtLiveTail,
              !isDefaultBottomScrollDeferred,
              !suppressDefaultBottomScroll,
              !containsOnlyFakeMessages else {
            return false
        }

        switch outgoingAutoScrollDecision {
        case .notHandled, .useDefaultAndClear:
            return isPureTailAppend(old: old, new: new)
        case .scroll, .handledNoScroll:
            return false
        }
    }

    static func bottomDistance(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        contentInsets: UIEdgeInsets,
        contentOffsetY: CGFloat
    ) -> CGFloat {
        max(0, contentHeight + contentInsets.bottom - viewportHeight - contentOffsetY)
    }
}

struct ChatDatasetApplyPlan {
    let window: ChatDatasetWindow
    let mode: ChatDatasourceApplyMode
    let invalidateLayout: Bool
}

struct ChatMessageContentUpdate: Equatable {
    let primary: String
    let indexPath: IndexPath
}

enum ChatMessageUpdateClassification: Equatable {
    case contentOnly
    case layout
}

struct ChatMessageLayoutSignature: Equatable {
    enum CellKind: Equatable {
        case text
        case system
        case sticker
        case initial
    }

    enum MessageKindKey: Equatable {
        case attributedText
        case emoji
        case sticker(String)
        case call(String)
        case system
        case initial
        case skeleton
        case date
        case unread
    }

    let cellKind: CellKind
    let messageKindKey: MessageKindKey
    let isOutgoing: Bool
    let withAuthor: Bool
    let withAvatar: Bool
    let reservesAvatarSpace: Bool
    let tailed: Bool
    let hasIndicator: Bool
    let messageWarningText: String?
    let images: [String]
    let videos: [String]
    let locations: [String]
    let contacts: [String]
    let files: [String]
    let audios: [String]
    let forwards: [ForwardSignature]

    struct ForwardSignature: Equatable {
        let primary: String
        let isOutgoing: Bool
        let images: [String]
        let videos: [String]
        let locations: [String]
        let contacts: [String]
        let files: [String]
        let audios: [String]
        let subforwards: [ForwardSignature]

        init(_ attachment: MessageAttachment) {
            self.primary = attachment.primary
            self.isOutgoing = attachment.outgoing
            self.images = attachment.images.map(\.primary)
            self.videos = attachment.videos.map(\.primary)
            self.locations = attachment.locations.map(\.primary)
            self.contacts = attachment.contacts.map(\.primary)
            self.files = attachment.files.map(\.primary)
            self.audios = attachment.audios.map(\.primary)
            self.subforwards = attachment.subforwards.map(ForwardSignature.init)
        }
    }

    init(_ message: ChatViewController.Datasource) {
        self.cellKind = Self.cellKind(for: message.kind)
        self.messageKindKey = Self.messageKindKey(for: message.kind)
        self.isOutgoing = message.isOutgoing
        self.withAuthor = message.withAuthor
        self.withAvatar = message.withAvatar
        self.reservesAvatarSpace = message.reservesAvatarSpace
        self.tailed = message.tailed
        self.hasIndicator = message.indicator != .none
        self.messageWarningText = message.messageWarningText
        self.images = message.images.map(\.primary)
        self.videos = message.videos.map(\.primary)
        self.locations = message.locations.map(\.primary)
        self.contacts = message.contacts.map(\.primary)
        self.files = message.files.map(\.primary)
        self.audios = message.audios.map(\.primary)
        self.forwards = message.forwards.map(ForwardSignature.init)
    }

    private static func cellKind(for kind: MessageKind) -> CellKind {
        switch kind {
        case .attributedText, .emoji, .skeleton:
            return .text
        case .system, .date, .unread, .call:
            return .system
        case .sticker:
            return .sticker
        case .initial:
            return .initial
        }
    }

    private static func messageKindKey(for kind: MessageKind) -> MessageKindKey {
        switch kind {
        case .attributedText:
            return .attributedText
        case .emoji:
            return .emoji
        case .sticker(let attachment):
            return .sticker(attachment.primary)
        case .call(let attachment):
            return .call(attachment.primary)
        case .system:
            return .system
        case .initial:
            return .initial
        case .skeleton:
            return .skeleton
        case .date:
            return .date
        case .unread:
            return .unread
        }
    }
}

struct ChatDiffContentSignature: Equatable, CustomStringConvertible {
    let kind: ChatMessageKindContentSignature
    let timeMarkerText: String
    let attachments: ChatAttachmentContentSignature

    var description: String {
        "ChatDiffContentSignature(kind:\(kind),timeLength:\(timeMarkerText.count),attachments:\(attachments))"
    }
}

struct ChatAttributedTextContentSignature: Equatable, CustomStringConvertible {
    struct Run: Equatable {
        let location: Int
        let length: Int
        let fontName: String?
        let fontPointSize: CGFloat?
        let fontTraitsRawValue: UInt32?
        let linkDestination: String?
    }

    let text: String
    let runs: [Run]

    init(_ attributedText: NSAttributedString) {
        self.text = attributedText.string
        var runs: [Run] = []
        let fullRange = NSRange(location: 0, length: attributedText.length)
        if fullRange.length > 0 {
            attributedText.enumerateAttributes(in: fullRange) { attributes, range, _ in
                let font = attributes[.font] as? UIFont
                runs.append(Run(
                    location: range.location,
                    length: range.length,
                    fontName: font?.fontName,
                    fontPointSize: font?.pointSize,
                    fontTraitsRawValue: font?.fontDescriptor.symbolicTraits.rawValue,
                    linkDestination: Self.linkDestination(from: attributes[.link])
                ))
            }
        }
        self.runs = runs
    }

    var description: String {
        "attributed(length:\(text.count),runs:\(runs.count))"
    }

    private static func linkDestination(from value: Any?) -> String? {
        switch value {
        case let value as URL:
            return value.absoluteString
        case let value as NSURL:
            return (value as URL).absoluteString
        case let value as String:
            return value
        default:
            return nil
        }
    }
}

enum ChatMessageKindContentSignature: Equatable, CustomStringConvertible {
    case attributedText(ChatAttributedTextContentSignature)
    case emoji(String)
    case sticker(ChatImageAttachmentSignature)
    case call(primary: String, incoming: Bool, missed: Bool)
    case system(String)
    case initial(String)
    case skeleton(String)
    case date(String)
    case unread(String)

    var description: String {
        switch self {
        case .attributedText(let signature):
            return signature.description
        case .emoji(let text):
            return "emoji(length:\(text.count))"
        case .sticker(let signature):
            return "sticker(\(signature))"
        case .call(let primary, let incoming, let missed):
            return "call(primary:\(primary),incoming:\(incoming),missed:\(missed))"
        case .system(let text):
            return "system(length:\(text.count))"
        case .initial(let text):
            return "initial(length:\(text.count))"
        case .skeleton(let text):
            return "skeleton(length:\(text.count))"
        case .date(let text):
            return "date(length:\(text.count))"
        case .unread(let text):
            return "unread(length:\(text.count))"
        }
    }
}

struct ChatAttachmentContentSignature: Equatable, CustomStringConvertible {
    let images: [ChatImageAttachmentSignature]
    let videos: [ChatVideoAttachmentSignature]
    let locations: [ChatLocationAttachmentSignature]
    let contacts: [ChatContactAttachmentSignature]
    let files: [ChatFileAttachmentSignature]
    let audios: [ChatAudioAttachmentSignature]
    let forwards: [ChatForwardAttachmentSignature]

    var description: String {
        [
            "images:\(images.count)",
            "videos:\(videos.count)",
            "locations:\(locations.count)",
            "contacts:\(contacts.count)",
            "files:\(files.count)",
            "audios:\(audios)",
            "forwards:\(forwards.count)"
        ].joined(separator: ",")
    }
}

struct ChatImageAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let url: URL?
    let previewUrl: URL?
    let size: CGSize
    let isSensitive: Bool
    let isSensitiveRevealed: Bool

    init(_ attachment: ImageAttachment) {
        self.primary = attachment.primary
        self.url = attachment.url
        self.previewUrl = attachment.previewUrl
        self.size = attachment.size
        self.isSensitive = attachment.isSensitive
        self.isSensitiveRevealed = attachment.isSensitiveRevealed
    }

    var description: String {
        "image(primary:\(primary),url:\(url?.absoluteString ?? ""),preview:\(previewUrl?.absoluteString ?? ""),size:\(size),sensitive:\(isSensitive),revealed:\(isSensitiveRevealed))"
    }
}

struct ChatVideoAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let url: URL?
    let size: CGSize
    let previewUrl: URL?
    let duration: Double
    let downloaded: Bool
    let isSensitive: Bool
    let isSensitiveRevealed: Bool

    init(_ attachment: VideoAttachment) {
        self.primary = attachment.primary
        self.url = attachment.url
        self.size = attachment.size
        self.previewUrl = attachment.previewUrl
        self.duration = attachment.duration
        self.downloaded = attachment.downloaded
        self.isSensitive = attachment.isSensitive
        self.isSensitiveRevealed = attachment.isSensitiveRevealed
    }

    var description: String {
        "video(primary:\(primary),duration:\(duration),downloaded:\(downloaded))"
    }
}

struct ChatLocationAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees
    let address: String?
    let geoURI: String
    let snapshotURL: URL?

    init(_ attachment: LocationAttachment) {
        self.primary = attachment.primary
        self.latitude = attachment.coordinate.latitude
        self.longitude = attachment.coordinate.longitude
        self.address = attachment.address
        self.geoURI = attachment.geoURI
        self.snapshotURL = attachment.snapshotURL
    }

    var description: String {
        "location(primary:\(primary),lat:\(latitude),lon:\(longitude))"
    }
}

struct ChatContactAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let owner: String
    let jid: String
    let entity: MessageContactEntityKind
    let title: String
    let nickname: String?
    let given: String?
    let family: String?
    let avatarURL: String?
    let avatarMetadata: [String: String]

    init(_ attachment: ContactAttachment) {
        self.primary = attachment.primary
        self.owner = attachment.owner
        self.jid = attachment.jid
        self.entity = attachment.entity
        self.title = attachment.title
        self.nickname = attachment.nickname
        self.given = attachment.given
        self.family = attachment.family
        self.avatarURL = attachment.avatarURL
        self.avatarMetadata = attachment.avatarMetadata
    }

    var description: String {
        "contact(primary:\(primary),jid:\(jid),entity:\(entity.rawValue),metadata:\(avatarMetadata.count))"
    }
}

struct ChatFileAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let url: URL?
    let size: Double
    let name: String
    let presentationRevision: String
    let downloaded: Bool

    init(_ attachment: FileAttachment) {
        self.primary = attachment.primary
        self.url = attachment.url
        self.size = attachment.size
        self.name = attachment.name
        self.presentationRevision = attachment.presentation.revision
        self.downloaded = attachment.downloaded
    }

    var description: String {
        "file(primary:\(primary),name:\(name),size:\(size),downloaded:\(downloaded))"
    }

    func equalsPresentation(of other: ChatFileAttachmentSignature) -> Bool {
        primary == other.primary &&
            url == other.url &&
            size == other.size &&
            name == other.name &&
            presentationRevision == other.presentationRevision
    }
}

struct ChatAudioAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let url: URL?
    let size: Double
    let name: String
    let duration: Double
    let downloaded: Bool
    let pcm: ChatVoicePCMSignature

    init(_ attachment: AudioAttachment) {
        self.primary = attachment.primary
        self.url = attachment.url
        self.size = attachment.size
        self.name = attachment.name
        self.duration = attachment.duration
        self.downloaded = attachment.downloaded
        self.pcm = ChatVoicePCMSignature(attachment.pcm)
    }

    var description: String {
        "audio(primary:\(primary),duration:\(duration),downloaded:\(downloaded),pcm:\(pcm))"
    }
}

struct ChatForwardAttachmentSignature: Equatable, CustomStringConvertible {
    let primary: String
    let author: String
    let jid: String
    let outgoing: Bool
    let textMessage: ChatAttributedTextContentSignature
    let timeMarker: String
    let attachments: ChatAttachmentContentSignature

    var description: String {
        "forward(primary:\(primary),outgoing:\(outgoing),textLength:\(textMessage.text.count),attachments:\(attachments))"
    }
}

private extension ChatAttachmentContentSignature {
    func differsOnlyInFileTransferState(from other: ChatAttachmentContentSignature) -> Bool {
        self != other && equalsExcludingFileTransferState(other)
    }

    func equalsExcludingFileTransferState(_ other: ChatAttachmentContentSignature) -> Bool {
        images == other.images &&
            videos == other.videos &&
            locations == other.locations &&
            contacts == other.contacts &&
            audios == other.audios &&
            files.count == other.files.count &&
            zip(files, other.files).allSatisfy { $0.equalsPresentation(of: $1) } &&
            forwards.count == other.forwards.count &&
            zip(forwards, other.forwards).allSatisfy { lhs, rhs in
                lhs.primary == rhs.primary &&
                    lhs.author == rhs.author &&
                    lhs.jid == rhs.jid &&
                    lhs.outgoing == rhs.outgoing &&
                    lhs.textMessage == rhs.textMessage &&
                    lhs.timeMarker == rhs.timeMarker &&
                    lhs.attachments.equalsExcludingFileTransferState(rhs.attachments)
            }
    }
}

struct ChatVoicePCMSignature: Equatable, CustomStringConvertible {
    let count: Int
    let hash: UInt64

    init(_ pcm: [Float]) {
        var hasher = ChatStableSignatureHasher()
        for value in pcm {
            hasher.combine(value.bitPattern)
        }
        self.count = pcm.count
        self.hash = hasher.value
    }

    var description: String {
        "count:\(count),hash:\(String(hash, radix: 16))"
    }
}

private struct ChatStableSignatureHasher {
    private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    private(set) var value: UInt64 = ChatStableSignatureHasher.offsetBasis

    mutating func combine(_ value: UInt32) {
        combine(UInt8(truncatingIfNeeded: value))
        combine(UInt8(truncatingIfNeeded: value >> 8))
        combine(UInt8(truncatingIfNeeded: value >> 16))
        combine(UInt8(truncatingIfNeeded: value >> 24))
    }

    private mutating func combine(_ byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* ChatStableSignatureHasher.prime
    }
}

private final class ChatDiffSignatureBuilder {
    private var textCache: [ObjectIdentifier: String] = [:]
    private var attributedTextCache: [ObjectIdentifier: ChatAttributedTextContentSignature] = [:]
    private var imageCache: [ObjectIdentifier: ChatImageAttachmentSignature] = [:]
    private var videoCache: [ObjectIdentifier: ChatVideoAttachmentSignature] = [:]
    private var locationCache: [ObjectIdentifier: ChatLocationAttachmentSignature] = [:]
    private var contactCache: [ObjectIdentifier: ChatContactAttachmentSignature] = [:]
    private var fileCache: [ObjectIdentifier: ChatFileAttachmentSignature] = [:]
    private var audioCache: [ObjectIdentifier: ChatAudioAttachmentSignature] = [:]
    private var forwardCache: [ObjectIdentifier: ChatForwardAttachmentSignature] = [:]

    func contentSignature(for message: ChatViewController.Datasource) -> ChatDiffContentSignature {
        ChatDiffContentSignature(
            kind: kindSignature(message.kind),
            timeMarkerText: textString(message.timeMarkerText),
            attachments: attachmentSignature(
                images: message.images,
                videos: message.videos,
                locations: message.locations,
                contacts: message.contacts,
                files: message.files,
                audios: message.audios,
                forwards: message.forwards
            )
        )
    }

    private func kindSignature(_ kind: MessageKind) -> ChatMessageKindContentSignature {
        switch kind {
        case .attributedText(let text):
            return .attributedText(attributedTextSignature(text))
        case .emoji(let text):
            return .emoji(text)
        case .sticker(let attachment):
            return .sticker(imageSignature(attachment))
        case .call(let attachment):
            return .call(
                primary: attachment.primary,
                incoming: attachment.incoming,
                missed: attachment.missed
            )
        case .system(let text):
            return .system(textString(text))
        case .initial(let text):
            return .initial(textString(text))
        case .skeleton(let text):
            return .skeleton(textString(text))
        case .date(let text):
            return .date(textString(text))
        case .unread(let text):
            return .unread(textString(text))
        }
    }

    private func attachmentSignature(
        images: [ImageAttachment],
        videos: [VideoAttachment],
        locations: [LocationAttachment],
        contacts: [ContactAttachment],
        files: [FileAttachment],
        audios: [AudioAttachment],
        forwards: [MessageAttachment]
    ) -> ChatAttachmentContentSignature {
        ChatAttachmentContentSignature(
            images: images.map(imageSignature(_:)),
            videos: videos.map(videoSignature(_:)),
            locations: locations.map(locationSignature(_:)),
            contacts: contacts.map(contactSignature(_:)),
            files: files.map(fileSignature(_:)),
            audios: audios.map(audioSignature(_:)),
            forwards: forwards.map(forwardSignature(_:))
        )
    }

    private func textString(_ text: NSAttributedString?) -> String {
        guard let text else { return "" }
        let key = ObjectIdentifier(text)
        if let cached = textCache[key] {
            return cached
        }
        let value = text.string
        textCache[key] = value
        return value
    }

    private func attributedTextSignature(
        _ text: NSAttributedString?
    ) -> ChatAttributedTextContentSignature {
        guard let text else {
            return ChatAttributedTextContentSignature(NSAttributedString(string: ""))
        }
        let key = ObjectIdentifier(text)
        if let cached = attributedTextCache[key] {
            return cached
        }
        let value = ChatAttributedTextContentSignature(text)
        attributedTextCache[key] = value
        return value
    }

    private func imageSignature(_ attachment: ImageAttachment) -> ChatImageAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = imageCache[key] {
            return cached
        }
        let signature = ChatImageAttachmentSignature(attachment)
        imageCache[key] = signature
        return signature
    }

    private func videoSignature(_ attachment: VideoAttachment) -> ChatVideoAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = videoCache[key] {
            return cached
        }
        let signature = ChatVideoAttachmentSignature(attachment)
        videoCache[key] = signature
        return signature
    }

    private func locationSignature(_ attachment: LocationAttachment) -> ChatLocationAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = locationCache[key] {
            return cached
        }
        let signature = ChatLocationAttachmentSignature(attachment)
        locationCache[key] = signature
        return signature
    }

    private func contactSignature(_ attachment: ContactAttachment) -> ChatContactAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = contactCache[key] {
            return cached
        }
        let signature = ChatContactAttachmentSignature(attachment)
        contactCache[key] = signature
        return signature
    }

    private func fileSignature(_ attachment: FileAttachment) -> ChatFileAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = fileCache[key] {
            return cached
        }
        let signature = ChatFileAttachmentSignature(attachment)
        fileCache[key] = signature
        return signature
    }

    private func audioSignature(_ attachment: AudioAttachment) -> ChatAudioAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = audioCache[key] {
            return cached
        }
        let signature = ChatAudioAttachmentSignature(attachment)
        audioCache[key] = signature
        return signature
    }

    private func forwardSignature(_ attachment: MessageAttachment) -> ChatForwardAttachmentSignature {
        let key = ObjectIdentifier(attachment)
        if let cached = forwardCache[key] {
            return cached
        }
        let signature = ChatForwardAttachmentSignature(
            primary: attachment.primary,
            author: attachment.author,
            jid: attachment.jid,
            outgoing: attachment.outgoing,
            textMessage: attributedTextSignature(attachment.textMessage),
            timeMarker: textString(attachment.timeMarker),
            attachments: attachmentSignature(
                images: attachment.images,
                videos: attachment.videos,
                locations: attachment.locations,
                contacts: attachment.contacts,
                files: attachment.files,
                audios: attachment.audios,
                forwards: attachment.subforwards
            )
        )
        forwardCache[key] = signature
        return signature
    }
}

enum ChatMessageUpdatePolicy {
    private static let sizeTolerance: CGFloat = 0.5

    static func shouldUseReloadFallback(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> Bool {
        old.hasDuplicateKeys || new.hasDuplicateKeys
    }

    static func classify(
        old oldMessage: ChatViewController.Datasource,
        new newMessage: ChatViewController.Datasource,
        oldSize: CGSize?,
        newSize: CGSize?
    ) -> ChatMessageUpdateClassification {
        guard ChatDatasourceStableIdentity.matches(oldMessage, newMessage) else {
            return .layout
        }
        guard ChatMessageLayoutSignature(oldMessage) == ChatMessageLayoutSignature(newMessage) else {
            return .layout
        }
        guard let oldSize, let newSize, sizesAreEqual(oldSize, newSize) else {
            return .layout
        }
        return .contentOnly
    }

    static func changeMask(
        old oldMessage: ChatViewController.Datasource,
        new newMessage: ChatViewController.Datasource,
        oldSize: CGSize?,
        newSize: CGSize?
    ) -> ChatMessageChangeMask {
        let oldSignature = contentSignature(for: oldMessage)
        let newSignature = contentSignature(for: newMessage)
        var mask: ChatMessageChangeMask = []

        if oldMessage.primary != newMessage.primary ||
            oldMessage.state != newMessage.state ||
            oldMessage.indicator != newMessage.indicator ||
            oldMessage.error != newMessage.error ||
            oldMessage.errorType != newMessage.errorType ||
            oldMessage.isRead != newMessage.isRead ||
            oldMessage.archivedId != newMessage.archivedId ||
            oldMessage.queryIds != newMessage.queryIds ||
            oldMessage.messageWarningText != newMessage.messageWarningText ||
            oldMessage.editDate != newMessage.editDate ||
            oldSignature.timeMarkerText != newSignature.timeMarkerText ||
            ChatViewController.Datasource.iconForMetadata(for: oldMessage.errorMetadata) !=
                ChatViewController.Datasource.iconForMetadata(for: newMessage.errorMetadata) {
            mask.insert(.chrome)
        }
        if oldSignature.kind != newSignature.kind {
            mask.insert(.text)
        }
        if oldSignature.attachments != newSignature.attachments {
            if oldSignature.attachments.differsOnlyInFileTransferState(
                from: newSignature.attachments
            ) {
                mask.insert(.fileTransferState)
            } else {
                mask.insert(.attachments)
            }
        }
        if oldMessage.avatarUrl != newMessage.avatarUrl ||
            oldMessage.withAvatar != newMessage.withAvatar ||
            oldMessage.reservesAvatarSpace != newMessage.reservesAvatarSpace ||
            oldMessage.groupchatAuthorId != newMessage.groupchatAuthorId ||
            oldMessage.groupchatAuthorNickname != newMessage.groupchatAuthorNickname ||
            oldMessage.groupchatAuthorBadge != newMessage.groupchatAuthorBadge ||
            oldMessage.attributedAuthor?.string != newMessage.attributedAuthor?.string {
            mask.insert(.avatar)
        }
        if ChatMessageLayoutSignature(oldMessage) != ChatMessageLayoutSignature(newMessage) ||
            !equalOptionalSizes(oldSize, newSize) {
            mask.insert(.layout)
        }
        if mask.isEmpty && shouldUpdateContent(old: oldMessage, new: newMessage) {
            mask.insert(.chrome)
        }
        return mask
    }

    static func shouldUpdateContent(
        old oldMessage: ChatViewController.Datasource,
        new newMessage: ChatViewController.Datasource
    ) -> Bool {
        let signatureBuilder = ChatDiffSignatureBuilder()
        return !ChatViewController.Datasource.compareContent(oldMessage, newMessage) ||
        signatureBuilder.contentSignature(for: oldMessage) != signatureBuilder.contentSignature(for: newMessage)
    }

    static func contentSignature(for message: ChatViewController.Datasource) -> ChatDiffContentSignature {
        ChatDiffSignatureBuilder().contentSignature(for: message)
    }

    private static func sizesAreEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= sizeTolerance &&
        abs(lhs.height - rhs.height) <= sizeTolerance
    }

    private static func equalOptionalSizes(_ lhs: CGSize?, _ rhs: CGSize?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return sizesAreEqual(lhs, rhs)
        case (nil, nil):
            return true
        case (.some, .none), (.none, .some):
            return false
        }
    }
}

struct ChatObserverModelOnlyAssimilationRoute {
    let isObserverCurrentRoute: Bool
    let isTargetedDiff: Bool
    let invalidatesLayout: Bool
    let hasBoundaryPlaceholder: Bool
    let usesDefaultApplyCategory: Bool
    let hasPendingOutgoingAutoScroll: Bool
    let hasExplicitSearchOrAnchorMutation: Bool

    var isEligible: Bool {
        isObserverCurrentRoute &&
            isTargetedDiff &&
            !invalidatesLayout &&
            !hasBoundaryPlaceholder &&
            usesDefaultApplyCategory &&
            !hasPendingOutgoingAutoScroll &&
            !hasExplicitSearchOrAnchorMutation
    }
}

enum ChatObserverModelOnlyAssimilationDecision: Equatable {
    case exactNoOp
    case incomingReadOnly(changedPrimaries: Set<String>)
    case requiresUIKitApply
}

enum ChatObserverModelOnlyAssimilationPolicy {
    static func decision(
        current: ChatDatasourceSnapshot,
        mapped: ChatDatasourceSnapshot,
        currentLayout: @escaping (String) -> ChatMessageLayout?,
        mappedLayout: @escaping (String) -> ChatMessageLayout?,
        route: ChatObserverModelOnlyAssimilationRoute
    ) -> ChatObserverModelOnlyAssimilationDecision {
        guard route.isEligible,
              !current.items.isEmpty,
              current.items.count == mapped.items.count,
              !current.hasDuplicateKeys,
              !mapped.hasDuplicateKeys else {
            return .requiresUIKitApply
        }

        var changedPrimaries = Set<String>()
        for (old, new) in zip(current.items, mapped.items) {
            guard old.primary == new.primary,
                  old.diffId == new.diffId,
                  old.messageId == new.messageId,
                  old.archivedId == new.archivedId,
                  old.queryIds == new.queryIds else {
                return .requiresUIKitApply
            }

            if rowsAreExactlyEqual(old, new) {
                continue
            }
            guard isIncomingReadOnlyTransition(old: old, new: new),
                  let oldLayout = currentLayout(old.primary),
                  let newLayout = mappedLayout(new.primary),
                  oldLayout == newLayout else {
                return .requiresUIKitApply
            }
            changedPrimaries.insert(new.primary)
        }

        let diff = ChatDatasourceCoordinator.diff(
            old: current,
            new: mapped,
            oldSizeProvider: { currentLayout($0.primary)?.cellSize },
            newSizeProvider: { mappedLayout($0.primary)?.cellSize }
        )
        guard diff.inserts.isEmpty,
              diff.deletes.isEmpty,
              diff.moves.isEmpty,
              diff.reloads.isEmpty else {
            return .requiresUIKitApply
        }

        guard !changedPrimaries.isEmpty else {
            return diff.isEmpty ? .exactNoOp : .requiresUIKitApply
        }

        let contentOnlyPrimaries = Set(
            diff.contentOnlyUpdates.map(\.primary)
        )
        guard diff.contentOnlyUpdates.count == changedPrimaries.count,
              contentOnlyPrimaries == changedPrimaries,
              Set(diff.changeMasksByPrimary.keys) == changedPrimaries,
              diff.changeMasksByPrimary.values.allSatisfy({
                  $0 == [.chrome]
              }) else {
            return .requiresUIKitApply
        }
        return .incomingReadOnly(changedPrimaries: changedPrimaries)
    }

    private static func isIncomingReadOnlyTransition(
        old: ChatViewController.Datasource,
        new: ChatViewController.Datasource
    ) -> Bool {
        guard !old.isFakeMessage,
              !new.isFakeMessage,
              !old.outgoing,
              !new.outgoing,
              !old.isOutgoing,
              !new.isOutgoing,
              old.state == .deliver,
              !old.isRead,
              new.state == .read,
              new.isRead,
              old.indicator == .none,
              new.indicator == .none else {
            return false
        }
        var normalized = new
        normalized.state = old.state
        normalized.isRead = old.isRead
        return rowsAreExactlyEqual(old, normalized)
    }

    private static func rowsAreExactlyEqual(
        _ lhs: ChatViewController.Datasource,
        _ rhs: ChatViewController.Datasource
    ) -> Bool {
        lhs.primary == rhs.primary &&
            lhs.jid == rhs.jid &&
            lhs.owner == rhs.owner &&
            lhs.outgoing == rhs.outgoing &&
            lhs.sender.id == rhs.sender.id &&
            lhs.sender.displayName == rhs.sender.displayName &&
            lhs.messageId == rhs.messageId &&
            lhs.sentDate == rhs.sentDate &&
            lhs.editDate == rhs.editDate &&
            messageKindsAreExactlyEqual(lhs.kind, rhs.kind) &&
            lhs.withAuthor == rhs.withAuthor &&
            lhs.withAvatar == rhs.withAvatar &&
            lhs.reservesAvatarSpace == rhs.reservesAvatarSpace &&
            lhs.error == rhs.error &&
            lhs.errorType == rhs.errorType &&
            lhs.canPinMessage == rhs.canPinMessage &&
            lhs.canEditMessage == rhs.canEditMessage &&
            lhs.canDeleteMessage == rhs.canDeleteMessage &&
            lhs.isOutgoing == rhs.isOutgoing &&
            lhs.isEdited == rhs.isEdited &&
            lhs.groupchatAuthorRole == rhs.groupchatAuthorRole &&
            lhs.groupchatAuthorId == rhs.groupchatAuthorId &&
            lhs.groupchatAuthorNickname == rhs.groupchatAuthorNickname &&
            lhs.groupchatAuthorBadge == rhs.groupchatAuthorBadge &&
            lhs.isHasAttachedMessages == rhs.isHasAttachedMessages &&
            lhs.isDownloaded == rhs.isDownloaded &&
            lhs.state == rhs.state &&
            lhs.searchString == rhs.searchString &&
            metadataIsExactlyEqual(lhs.errorMetadata, rhs.errorMetadata) &&
            lhs.messageWarningText == rhs.messageWarningText &&
            lhs.burnDate == rhs.burnDate &&
            lhs.afterburnInterval == rhs.afterburnInterval &&
            lhs.archivedId == rhs.archivedId &&
            lhs.queryIds == rhs.queryIds &&
            lhs.isRead == rhs.isRead &&
            lhs.selectedSearchResultId == rhs.selectedSearchResultId &&
            lhs.isHadHistoryGap == rhs.isHadHistoryGap &&
            lhs.tailed == rhs.tailed &&
            lhs.isFakeMessage == rhs.isFakeMessage &&
            ChatMessageUpdatePolicy.contentSignature(for: lhs) ==
                ChatMessageUpdatePolicy.contentSignature(for: rhs) &&
            forwardAttributedStringsAreExactlyEqual(
                lhs.forwards,
                rhs.forwards
            ) &&
            lhs.timeMarkerText.isEqual(to: rhs.timeMarkerText) &&
            attributedStringsAreExactlyEqual(
                lhs.attributedAuthor,
                rhs.attributedAuthor
            ) &&
            lhs.indicator == rhs.indicator &&
            lhs.avatarUrl == rhs.avatarUrl
    }

    private static func messageKindsAreExactlyEqual(
        _ lhs: MessageKind,
        _ rhs: MessageKind
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.attributedText(lhs), .attributedText(rhs)):
            return lhs.isEqual(to: rhs)
        case let (.emoji(lhs), .emoji(rhs)):
            return lhs == rhs
        case let (.sticker(lhs), .sticker(rhs)):
            return ChatImageAttachmentSignature(lhs) ==
                ChatImageAttachmentSignature(rhs)
        case let (.call(lhs), .call(rhs)):
            return lhs.primary == rhs.primary &&
                lhs.incoming == rhs.incoming &&
                lhs.missed == rhs.missed
        case let (.system(lhs), .system(rhs)):
            return lhs.isEqual(to: rhs)
        case let (.initial(lhs), .initial(rhs)):
            return lhs.isEqual(to: rhs)
        case let (.skeleton(lhs), .skeleton(rhs)):
            return lhs.isEqual(to: rhs)
        case let (.date(lhs), .date(rhs)):
            return lhs.isEqual(to: rhs)
        case let (.unread(lhs), .unread(rhs)):
            return lhs.isEqual(to: rhs)
        default:
            return false
        }
    }

    private static func forwardAttributedStringsAreExactlyEqual(
        _ lhs: [MessageAttachment],
        _ rhs: [MessageAttachment]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { lhsForward, rhsForward in
            attributedStringsAreExactlyEqual(
                lhsForward.textMessage,
                rhsForward.textMessage
            ) &&
                lhsForward.timeMarker.isEqual(to: rhsForward.timeMarker) &&
                forwardAttributedStringsAreExactlyEqual(
                    lhsForward.subforwards,
                    rhsForward.subforwards
                )
        }
    }

    private static func attributedStringsAreExactlyEqual(
        _ lhs: NSAttributedString?,
        _ rhs: NSAttributedString?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.isEqual(to: rhs)
        case (.some, nil), (nil, .some):
            return false
        }
    }

    private static func metadataIsExactlyEqual(
        _ lhs: [String: Any]?,
        _ rhs: [String: Any]?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return NSDictionary(dictionary: lhs).isEqual(to: rhs)
        case (.some, nil), (nil, .some):
            return false
        }
    }
}

#if DEBUG || CHAT_PERFORMANCE_LAB
enum ChatObserverModelOnlyAssimilationRejectionReason: String, Equatable {
    case routeIsNotObserverCurrent
    case routeIsNotTargetedDiff
    case routeInvalidatesLayout
    case routeHasBoundaryPlaceholder
    case routeUsesNonDefaultApplyCategory
    case routeHasPendingOutgoingAutoScroll
    case routeHasExplicitSearchOrAnchorMutation
    case currentDatasourceIsEmpty
    case itemCountMismatch
    case currentDatasourceHasDuplicateKeys
    case mappedDatasourceHasDuplicateKeys
    case stableIdentityMismatch
    case changedRowIsNotIncomingReadOnly
    case currentLayoutMissing
    case mappedLayoutMissing
    case layoutChanged
    case structuralDiff
    case reloadDiff
    case exactRowsProducedNonemptyDiff
    case contentOnlyUpdateCountMismatch
    case contentOnlyPrimaryMismatch
    case changeMaskPrimaryMismatch
    case changeMaskIsNotChromeOnly
    case unclassified
}

extension ChatObserverModelOnlyAssimilationPolicy {
    /// DEBUG-only mirror of the production guard order. It never participates
    /// in the decision and exists solely to make a rejected real observer
    /// frame causally attributable in focused tests.
    static func rejectionReasonForTesting(
        current: ChatDatasourceSnapshot,
        mapped: ChatDatasourceSnapshot,
        currentLayout: @escaping (String) -> ChatMessageLayout?,
        mappedLayout: @escaping (String) -> ChatMessageLayout?,
        route: ChatObserverModelOnlyAssimilationRoute,
        decision: ChatObserverModelOnlyAssimilationDecision
    ) -> ChatObserverModelOnlyAssimilationRejectionReason? {
        guard decision == .requiresUIKitApply else { return nil }
        guard route.isObserverCurrentRoute else {
            return .routeIsNotObserverCurrent
        }
        guard route.isTargetedDiff else {
            return .routeIsNotTargetedDiff
        }
        guard !route.invalidatesLayout else {
            return .routeInvalidatesLayout
        }
        guard !route.hasBoundaryPlaceholder else {
            return .routeHasBoundaryPlaceholder
        }
        guard route.usesDefaultApplyCategory else {
            return .routeUsesNonDefaultApplyCategory
        }
        guard !route.hasPendingOutgoingAutoScroll else {
            return .routeHasPendingOutgoingAutoScroll
        }
        guard !route.hasExplicitSearchOrAnchorMutation else {
            return .routeHasExplicitSearchOrAnchorMutation
        }
        guard !current.items.isEmpty else {
            return .currentDatasourceIsEmpty
        }
        guard current.items.count == mapped.items.count else {
            return .itemCountMismatch
        }
        guard !current.hasDuplicateKeys else {
            return .currentDatasourceHasDuplicateKeys
        }
        guard !mapped.hasDuplicateKeys else {
            return .mappedDatasourceHasDuplicateKeys
        }

        var changedPrimaries = Set<String>()
        for (old, new) in zip(current.items, mapped.items) {
            guard old.primary == new.primary,
                  old.diffId == new.diffId,
                  old.messageId == new.messageId,
                  old.archivedId == new.archivedId,
                  old.queryIds == new.queryIds else {
                return .stableIdentityMismatch
            }
            if rowsAreExactlyEqual(old, new) {
                continue
            }
            guard isIncomingReadOnlyTransition(old: old, new: new) else {
                return .changedRowIsNotIncomingReadOnly
            }
            guard let oldLayout = currentLayout(old.primary) else {
                return .currentLayoutMissing
            }
            guard let newLayout = mappedLayout(new.primary) else {
                return .mappedLayoutMissing
            }
            guard oldLayout == newLayout else {
                return .layoutChanged
            }
            changedPrimaries.insert(new.primary)
        }

        let diff = ChatDatasourceCoordinator.diff(
            old: current,
            new: mapped,
            oldSizeProvider: { currentLayout($0.primary)?.cellSize },
            newSizeProvider: { mappedLayout($0.primary)?.cellSize }
        )
        guard diff.inserts.isEmpty,
              diff.deletes.isEmpty,
              diff.moves.isEmpty else {
            return .structuralDiff
        }
        guard diff.reloads.isEmpty else {
            return .reloadDiff
        }
        guard !changedPrimaries.isEmpty else {
            return diff.isEmpty ? .unclassified : .exactRowsProducedNonemptyDiff
        }
        guard diff.contentOnlyUpdates.count == changedPrimaries.count else {
            return .contentOnlyUpdateCountMismatch
        }
        guard Set(diff.contentOnlyUpdates.map(\.primary)) == changedPrimaries else {
            return .contentOnlyPrimaryMismatch
        }
        guard Set(diff.changeMasksByPrimary.keys) == changedPrimaries else {
            return .changeMaskPrimaryMismatch
        }
        guard diff.changeMasksByPrimary.values.allSatisfy({
            $0 == [.chrome]
        }) else {
            return .changeMaskIsNotChromeOnly
        }
        return .unclassified
    }
}
#endif

struct ChatDatasourceCoordinator {
    struct DiffResult {
        let inserts: IndexSet
        let deletes: IndexSet
        let reloads: [IndexPath]
        let contentOnlyUpdates: [ChatMessageContentUpdate]
        let moves: [(from: IndexPath, to: IndexPath)]
        let changeMasksByPrimary: [String: ChatMessageChangeMask]

        var isEmpty: Bool {
            inserts.isEmpty && deletes.isEmpty && reloads.isEmpty && contentOnlyUpdates.isEmpty && moves.isEmpty
        }

        var hasCollectionUpdates: Bool {
            !inserts.isEmpty || !deletes.isEmpty || !reloads.isEmpty || !moves.isEmpty
        }
    }

    static func makeSnapshot(items: [ChatViewController.Datasource]) -> ChatDatasourceSnapshot {
        ChatDatasourceSnapshot(items: items)
    }

    static func diff(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> DiffResult {
        diff(old: old, new: new, oldSizeProvider: nil, newSizeProvider: nil)
    }

    static func diff(
        old: ChatDatasourceSnapshot,
        new: ChatDatasourceSnapshot,
        oldSizeProvider: ((ChatViewController.Datasource) -> CGSize?)?,
        newSizeProvider: ((ChatViewController.Datasource) -> CGSize?)?
    ) -> DiffResult {
        let changes = DeepDiff.diff(old: old.items, new: new.items)
        let inserts = IndexSet(changes.compactMap { $0.insert?.index })
        let deletes = IndexSet(changes.compactMap { $0.delete?.index })
        let moves = changes.compactMap { change -> (from: IndexPath, to: IndexPath)? in
            guard let move = change.move else { return nil }
            return (IndexPath(row: 0, section: move.fromIndex), IndexPath(row: 0, section: move.toIndex))
        }

        var contentOnlyUpdates: [ChatMessageContentUpdate] = []
        var reloads: [IndexPath] = []
        var changeMasksByPrimary: [String: ChatMessageChangeMask] = [:]
        var handledSections = Set<Int>()

        changes.compactMap(\.replace).forEach { replace in
            handledSections.insert(replace.index)
        }

        let commonCount = min(old.items.count, new.items.count)
        for index in 0..<commonCount {
            guard !deletes.contains(index), !inserts.contains(index) else { continue }
            let oldItem = old.items[index]
            let newItem = new.items[index]
            guard ChatDatasourceStableIdentity.matches(oldItem, newItem) else { continue }
            guard handledSections.contains(index) ||
                    ChatMessageUpdatePolicy.shouldUpdateContent(old: oldItem, new: newItem) else {
                continue
            }

            let indexPath = IndexPath(row: 0, section: index)
            let oldSize = oldSizeProvider?(oldItem)
            let newSize = newSizeProvider?(newItem)
            changeMasksByPrimary[newItem.primary] = ChatMessageUpdatePolicy.changeMask(
                old: oldItem,
                new: newItem,
                oldSize: oldSize,
                newSize: newSize
            )
            let classification = ChatMessageUpdatePolicy.classify(
                old: oldItem,
                new: newItem,
                oldSize: oldSize,
                newSize: newSize
            )
            switch classification {
            case .contentOnly:
                contentOnlyUpdates.append(ChatMessageContentUpdate(primary: newItem.primary, indexPath: indexPath))
            case .layout:
                reloads.append(indexPath)
            }
        }

        return DiffResult(
            inserts: inserts,
            deletes: deletes,
            reloads: reloads,
            contentOnlyUpdates: contentOnlyUpdates,
            moves: moves,
            changeMasksByPrimary: changeMasksByPrimary
        )
    }

    static func compatibleForTargetedApply(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> Bool {
        guard !old.items.isEmpty else { return false }
        guard old.items.count == new.items.count else { return false }
        guard !old.hasDuplicateKeys, !new.hasDuplicateKeys else { return false }
        return zip(old.items, new.items).allSatisfy { $0.primary == $1.primary }
    }

    static func supportsTargetedApply(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> Bool {
        !old.items.isEmpty && !ChatMessageUpdatePolicy.shouldUseReloadFallback(old: old, new: new)
    }
}

struct ChatDatasetCoordinator {
    let pageSize: Int

    func clamp(_ window: ChatDatasetWindow, totalCount: Int) -> ChatDatasetWindow {
        guard totalCount > 0 else { return .empty }

        var minIndex = max(0, window.minIndex)
        var maxIndex = min(totalCount, max(minIndex, window.maxIndex))

        if maxIndex == minIndex {
            maxIndex = min(totalCount, minIndex + pageSize)
            minIndex = max(0, maxIndex - pageSize)
        }

        return ChatDatasetWindow(minIndex: minIndex, maxIndex: maxIndex)
    }

    func initialWindow(totalCount: Int) -> ChatDatasetWindow {
        clamp(ChatDatasetWindow(minIndex: totalCount - pageSize, maxIndex: totalCount), totalCount: totalCount)
    }

    func replacementWindow(around index: Int, totalCount: Int) -> ChatDatasetWindow {
        let halfPage = pageSize / 2
        return clamp(ChatDatasetWindow(minIndex: index - halfPage, maxIndex: index + halfPage), totalCount: totalCount)
    }

    func nextWindow(from current: ChatDatasetWindow, direction: ChatHistoryPageDirection) -> ChatDatasetWindow {
        switch direction {
        case .newer:
            return ChatDatasetWindow(minIndex: current.minIndex, maxIndex: current.maxIndex + pageSize)
        case .older:
            return ChatDatasetWindow(minIndex: current.minIndex - pageSize, maxIndex: current.maxIndex)
        }
    }

}

extension ChatViewController {
    internal var chatTimelineConversationKey: ChatTimelineConversationKey {
        ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
    }

    fileprivate static func makeAttachmentTimeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    fileprivate static func makeSectionsDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }

    internal func captureDatasourceMappingContext(
        layoutWidthOverride: CGFloat? = nil,
        purpose: ChatDatasourceMappingPurpose = .timeline
    ) -> ChatDatasourceMappingContext {
        let traitCollection = self.traitCollection
        let flowLayout = self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout
        let layoutWidth = [
            layoutWidthOverride,
            flowLayout?.itemWidth,
            self.messagesCollectionView.bounds.width,
            self.view.bounds.width
        ]
            .compactMap { $0 }
            .first { $0.isFinite && $0 > 1 } ?? 1
        let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        let captionFont = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection)
        let bodyColor = UIColor.label.resolvedColor(with: traitCollection)
        let searchHighlightColor = ChatSearchHighlightStyle
            .telegram(for: traitCollection)
            .backgroundColor
        let timeMarkerColor = UIColor(red: 158.0 / 255.0, green: 158.0 / 255.0, blue: 158.0 / 255.0, alpha: 1)
        let searchText = self.searchTextObserver.value

        return ChatDatasourceMappingContext(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType,
            ownerSender: self.ownerSender,
            opponentSender: self.opponentSender,
            purpose: purpose,
            searchText: searchText,
            inSearchMode: self.inSearchMode.value,
            displayCacheContext: ChatDisplayModelCacheContext.current(
                searchText: searchText,
                traitCollection: traitCollection
            ),
            bodyTextAttributes: [
                .foregroundColor: bodyColor,
                .font: bodyFont
            ],
            systemTextAttributes: [
                .font: captionFont.italic(),
                .foregroundColor: UIColor.white
            ],
            dateSeparatorAttributes: [
                .font: captionFont,
                .foregroundColor: UIColor.white
            ],
            timeMarkerAttributes: [
                .foregroundColor: timeMarkerColor,
                .font: UIFont.systemFont(ofSize: 10, weight: .regular)
            ],
            searchHighlightColor: searchHighlightColor,
            avatarVerticalPosition: self.avatarVerticalPosition,
            canPinMessages: self.canonicalGroupProjectionState?.canPinMessages == true,
            revealedSensitiveMediaPrimaries: self.revealedSensitiveMediaPrimaries,
            layoutContext: ChatMessageLayoutContext(
                width: layoutWidth,
                contentSizeCategory: traitCollection.preferredContentSizeCategory.rawValue,
                localeIdentifier: Locale.current.identifier,
                interfaceStyleRawValue: traitCollection.userInterfaceStyle.rawValue,
                messageStyle: self.messageCorner.rawValue,
                cornerRadius: self.cornerRadius,
                avatarMode: self.avatarVerticalPosition
            ),
            layoutReuseSnapshot: flowLayout?.cache.reuseSnapshot() ?? .empty,
            layoutCacheCapacity: flowLayout?.cache.capacity ?? ChatPerformanceResourceBudgets.layoutCount,
            layoutOperationCounter: flowLayout?.cache.operationCounter
        )
    }

    /// Builds the deterministic opening placeholder entirely from immutable
    /// presentation values. It neither reads Realm nor owns any archive work.
    private func makeArchiveEngineOpeningSkeletonMappingResult()
        -> ChatDatasourceMappingResult {
        let context = captureDatasourceMappingContext()
        let items = ChatSkeletonTemplate.descriptors.map { descriptor in
            let text = NSMutableAttributedString(
                attributedString: descriptor.text
            )
            text.addAttributes(
                context.bodyTextAttributes,
                range: NSRange(location: 0, length: text.length)
            )
            return Datasource(
                primary: descriptor.primary,
                jid: context.jid,
                owner: context.owner,
                outgoing: descriptor.outgoing,
                sender: context.opponentSender,
                messageId: descriptor.messageId,
                sentDate: descriptor.sentDate,
                editDate: nil,
                kind: .skeleton(text),
                withAuthor: false,
                withAvatar: false,
                error: false,
                errorType: "",
                canPinMessage: false,
                canEditMessage: false,
                canDeleteMessage: false,
                forwards: [],
                isOutgoing: descriptor.outgoing,
                isEdited: false,
                groupchatAuthorRole: "",
                groupchatAuthorId: "",
                groupchatAuthorNickname: "",
                groupchatAuthorBadge: "",
                isHasAttachedMessages: false,
                isDownloaded: true,
                state: .read,
                searchString: nil,
                errorMetadata: [:],
                burnDate: -1,
                afterburnInterval: -1,
                isRead: true,
                isFakeMessage: true,
                images: [],
                videos: [],
                files: [],
                audios: [],
                timeMarkerText: NSAttributedString(),
                indicator: .none
            )
        }
        let layouts = ChatMessageLayoutPrewarmer.prewarm(
            items: items,
            context: context.layoutContext,
            reuse: context.layoutReuseSnapshot,
            capacity: context.layoutCacheCapacity,
            operationCounter: context.layoutOperationCounter
        )
        return ChatDatasourceMappingResult(
            datasource: items,
            editedMessagePrimariesNeedingLayoutInvalidation: [],
            layoutSnapshot: layouts
        )
    }

    /// Commits the exact 30-row engine-native skeleton as one synchronous
    /// UIKit transaction. Callers may submit archive work only after this
    /// method returns successfully.
    @discardableResult
    internal func commitArchiveEngineOpeningSkeletonSynchronously() -> Bool {
        assert(Thread.isMainThread, "Opening skeleton commits are main-owned")
        let expectedPrimaries = ChatSkeletonTemplate.descriptors.map(\.primary)
        let alreadyCommitted =
            datasource.map(\.primary) == expectedPrimaries &&
            datasource.count == ChatSkeletonTemplate.descriptors.count &&
            datasource.allSatisfy { item in
                guard item.isFakeMessage else { return false }
                if case .skeleton = item.kind { return true }
                return false
            } &&
            datasourceSnapshot.items.map(\.primary) == expectedPrimaries &&
            messagesCollectionView.numberOfSections == expectedPrimaries.count
        if alreadyCommitted {
            setShouldShowInitialMessage(false)
            return true
        }

        view.setNeedsLayout()
        view.layoutIfNeeded()
        messagesCollectionView.setNeedsLayout()
        messagesCollectionView.layoutIfNeeded()
        let mapping = makeArchiveEngineOpeningSkeletonMappingResult()
        var transactionCommitted = false
        applyChatDatasource(
            mapping.datasource,
            mode: .fullReload(keepOffset: false),
            animated: false,
            invalidateLayout: false,
            preparedLayouts: mapping.layoutSnapshot,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
            presentationCommitMode: .atomicInitialFrame,
            transactionCompletion: { result in
                if case .committed = result {
                    transactionCommitted = true
                }
            }
        )
        let didCommitExpectedRows =
            transactionCommitted &&
            datasource.map(\.primary) == expectedPrimaries &&
            datasourceSnapshot.items.map(\.primary) == expectedPrimaries &&
            messagesCollectionView.numberOfSections == expectedPrimaries.count
        if didCommitExpectedRows {
            setShouldShowInitialMessage(false)
            ChatArchiveDebugTrace.log(
                "archiveEngineOpeningSkeletonCommitted",
                [("count", expectedPrimaries.count)]
            )
        }
        return didCommitExpectedRows
    }

    internal func prepareAndApplyCurrentDatasourceLayouts(
        layoutWidthOverride: CGFloat? = nil,
        viewportRestoration: ChatLayoutViewportRestoration? = nil,
        completion: (() -> Void)? = nil
    ) {
        cancelPendingWidthTransitionLayoutRemap()
        widthTransitionLayoutSnapshotsByContext.removeAll(
            keepingCapacity: true
        )
        guard isViewLoaded else {
            completion?()
            return
        }
        let capturedViewportRestoration = viewportRestoration ?? captureLayoutViewportRestoration()
        layoutPreparationGeneration += 1
        let generation = layoutPreparationGeneration
        let items = datasource
        let context = captureDatasourceMappingContext(
            layoutWidthOverride: layoutWidthOverride
        )
        datasetMappingQueue.async { [weak self] in
            let preparedLayouts = ChatMessageLayoutPrewarmer.prewarm(
                items: items,
                context: context.layoutContext,
                reuse: context.layoutReuseSnapshot,
                capacity: context.layoutCacheCapacity,
                operationCounter: context.layoutOperationCounter
            )
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.layoutPreparationGeneration else { return }
                let stillRepresentsCurrentDatasource = self.datasource.count == items.count &&
                    zip(self.datasource, items).allSatisfy { current, captured in
                        ChatMessageLayoutKey(
                            message: current,
                            context: context.layoutContext
                        ) == ChatMessageLayoutKey(
                            message: captured,
                            context: context.layoutContext
                        )
                    }
                guard stillRepresentsCurrentDatasource else {
                    self.prepareAndApplyCurrentDatasourceLayouts(
                        layoutWidthOverride: layoutWidthOverride,
                        viewportRestoration: capturedViewportRestoration,
                        completion: completion
                    )
                    return
                }
                self.rememberWidthTransitionLayoutSnapshot(
                    preparedLayouts,
                    context: context.layoutContext,
                    items: items
                )
                let restoreAnchor: ChatHistoryPageAnchor?
                let forceBottomAlignmentTarget: ChatBottomAlignmentTarget?
                let keepOffset: Bool
                switch capturedViewportRestoration {
                case .none:
                    restoreAnchor = nil
                    forceBottomAlignmentTarget = nil
                    keepOffset = true
                case .bottom:
                    restoreAnchor = nil
                    forceBottomAlignmentTarget = .newestRealMessage
                    keepOffset = false
                case .message(let anchor):
                    restoreAnchor = anchor
                    forceBottomAlignmentTarget = nil
                    keepOffset = false
                }
                self.applyChatDatasource(
                    items,
                    mode: .fullReload(keepOffset: keepOffset),
                    animated: false,
                    invalidateLayout: true,
                    preparedLayouts: preparedLayouts,
                    suppressDefaultBottomScroll: true,
                    forceBottomAlignmentTarget: forceBottomAlignmentTarget,
                    anchorRestorePhase: restoreAnchor == nil ? .none : .applyTransaction,
                    anchorPrimary: restoreAnchor?.primary,
                    restoreAnchor: restoreAnchor,
                    presentationOwner: .archiveEngine,
                    completion: completion
                )
            }
        }
    }

    /// Prewarms width-specific message layouts without publishing the same
    /// datasource again. Semantic viewport ownership is staged into UIKit's
    /// natural target-bounds invalidation before background preparation can
    /// finish. The prepared cache is then activated either in that same pass
    /// or in a later metrics-only invalidation, so neither path needs a
    /// datasource transaction or `setContentOffset` correction.
    internal func prepareAndInstallCurrentDatasourceLayoutsForWidthTransition(
        targetViewSize: CGSize,
        layoutWidthOverride: CGFloat,
        completion: (() -> Void)? = nil
    ) {
        guard isViewLoaded, datasource.isNotEmpty else {
            cancelPendingWidthTransitionLayoutRemap()
            completion?()
            return
        }
        cancelPendingWidthTransitionLayoutRemap()
        let viewportRestoration = captureLayoutViewportRestoration()
        guard let flowLayout = messagesCollectionView.collectionViewLayout as?
                MessagesCollectionViewFlowLayout else {
            completion?()
            return
        }
        let sourceGeometry = captureWidthTransitionSourceGeometry()
        layoutPreparationGeneration += 1
        let generation = layoutPreparationGeneration
        activeWidthTransitionLayoutTargetSize = targetViewSize
        activeWidthTransitionLayoutGeneration = generation
        let items = datasource
        let mappingContext = captureDatasourceMappingContext(
            layoutWidthOverride: layoutWidthOverride
        )
        let targetLayoutWidth =
            mappingContext.layoutContext.normalizedWidth
        flowLayout.stageWidthTransitionBoundsAdjustment(
            targetLayoutWidth: targetLayoutWidth,
            contentOffsetAdjustmentY:
                ChatWidthTransitionBoundsAdjustmentPolicy.adjustmentY(
                    viewportRestoration: viewportRestoration,
                    sourceGeometry: sourceGeometry,
                    targetViewportHeight: targetViewSize.height,
                    contentInsets: messagesCollectionView.contentInset
                )
        )
        let previousLayouts = mappingContext.layoutReuseSnapshot
        if let first = items.first,
           let sourceContext = previousLayouts.key(
            forPrimary: first.primary
           )?.context {
            rememberWidthTransitionLayoutSnapshot(
                previousLayouts,
                context: sourceContext,
                items: items
            )
        }
        if let retainedTargetLayouts = retainedWidthTransitionLayoutSnapshot(
            context: mappingContext.layoutContext,
            items: items
        ) {
            guard let layoutContentOffsetAdjustments =
                widthTransitionLayoutContentOffsetAdjustments(
                    viewportRestoration: viewportRestoration,
                    items: items,
                    previousLayouts: previousLayouts,
                    preparedLayouts: retainedTargetLayouts
                ) else {
                assertionFailure(
                    "Retained width-transition layouts must cover the semantic viewport"
                )
                cancelPendingWidthTransitionLayoutRemap()
                completion?()
                return
            }
            pendingWidthTransitionLayoutRemap =
                ChatPendingWidthTransitionLayoutRemap(
                    generation: generation,
                    targetViewSize: targetViewSize,
                    targetLayoutWidth: targetLayoutWidth,
                    viewportRestoration: viewportRestoration,
                    items: items,
                    mappingContext: mappingContext,
                    preparedLayouts: retainedTargetLayouts,
                    completion: completion
                )
            flowLayout.stageWidthTransitionLayout(
                retainedTargetLayouts,
                targetLayoutWidth: targetLayoutWidth,
                targetBoundsContentOffsetAdjustmentY:
                    layoutContentOffsetAdjustments.targetBoundsY,
                postBoundsMetricsContentOffsetAdjustmentY:
                    layoutContentOffsetAdjustments.postBoundsMetricsY,
                targetContentOffset:
                    widthTransitionTargetContentOffset(
                        viewportRestoration: viewportRestoration,
                        items: items
                    )
            )
            commitPendingWidthTransitionLayoutRemapIfReady()
            return
        }
        datasetMappingQueue.async { [weak self] in
            let preparedLayouts = ChatMessageLayoutPrewarmer.prewarm(
                items: items,
                context: mappingContext.layoutContext,
                reuse: previousLayouts,
                capacity: mappingContext.layoutCacheCapacity,
                operationCounter: mappingContext.layoutOperationCounter
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard generation == self.layoutPreparationGeneration else {
                    self.cancelWidthTransitionLayoutRemapIfOwned(
                        by: generation
                    )
                    return
                }
                guard self.activeWidthTransitionLayoutGeneration == generation,
                      self.activeWidthTransitionLayoutTargetSize ==
                        targetViewSize else {
                    return
                }
                let stillRepresentsCurrentDatasource =
                    self.datasource.count == items.count &&
                    zip(self.datasource, items).allSatisfy { current, captured in
                        ChatMessageLayoutKey(
                            message: current,
                            context: mappingContext.layoutContext
                        ) == ChatMessageLayoutKey(
                            message: captured,
                            context: mappingContext.layoutContext
                        )
                    }
                guard stillRepresentsCurrentDatasource else {
                    self.prepareAndInstallCurrentDatasourceLayoutsForWidthTransition(
                        targetViewSize: targetViewSize,
                        layoutWidthOverride: layoutWidthOverride,
                        completion: completion
                    )
                    return
                }
                self.rememberWidthTransitionLayoutSnapshot(
                    preparedLayouts,
                    context: mappingContext.layoutContext,
                    items: items
                )
                guard let layoutContentOffsetAdjustments =
                    self.widthTransitionLayoutContentOffsetAdjustments(
                        viewportRestoration: viewportRestoration,
                        items: items,
                        previousLayouts: previousLayouts,
                        preparedLayouts: preparedLayouts
                    ) else {
                    assertionFailure(
                        "Prepared width-transition layouts must cover the semantic viewport"
                    )
                    self.cancelPendingWidthTransitionLayoutRemap()
                    completion?()
                    return
                }
                self.pendingWidthTransitionLayoutRemap =
                    ChatPendingWidthTransitionLayoutRemap(
                        generation: generation,
                        targetViewSize: targetViewSize,
                        targetLayoutWidth:
                            mappingContext.layoutContext.normalizedWidth,
                        viewportRestoration: viewportRestoration,
                        items: items,
                        mappingContext: mappingContext,
                        preparedLayouts: preparedLayouts,
                        completion: completion
                    )
                (self.messagesCollectionView.collectionViewLayout as?
                    MessagesCollectionViewFlowLayout)?
                    .stageWidthTransitionLayout(
                        preparedLayouts,
                        targetLayoutWidth:
                            mappingContext.layoutContext.normalizedWidth,
                        targetBoundsContentOffsetAdjustmentY:
                            layoutContentOffsetAdjustments.targetBoundsY,
                        postBoundsMetricsContentOffsetAdjustmentY:
                            layoutContentOffsetAdjustments.postBoundsMetricsY,
                        targetContentOffset:
                            self.widthTransitionTargetContentOffset(
                                viewportRestoration:
                                    viewportRestoration,
                                items: items
                            )
                    )
                self.commitPendingWidthTransitionLayoutRemapIfReady()
            }
        }
    }

    /// Called both when background preparation returns and from
    /// `viewDidLayoutSubviews`. The latter closes the race where layout
    /// preparation finishes before UIKit has installed the target bounds.
    internal func commitPendingWidthTransitionLayoutRemapIfReady() {
        guard let pending = pendingWidthTransitionLayoutRemap else {
            return
        }
        guard pending.generation == layoutPreparationGeneration else {
            cancelWidthTransitionLayoutRemapIfOwned(by: pending.generation)
            return
        }
        guard activeWidthTransitionLayoutGeneration == pending.generation,
              activeWidthTransitionLayoutTargetSize == pending.targetViewSize,
              let flowLayout = messagesCollectionView.collectionViewLayout as?
                MessagesCollectionViewFlowLayout,
              ChatWidthTransitionCommitReadinessPolicy.isReady(
                targetViewSize: pending.targetViewSize,
                targetLayoutWidth: pending.targetLayoutWidth,
                viewBounds: view.bounds,
                collectionBounds: messagesCollectionView.bounds,
                sectionInsets: flowLayout.sectionInset
              ) else {
            return
        }
        let stillRepresentsCurrentDatasource =
            datasource.count == pending.items.count &&
            zip(datasource, pending.items).allSatisfy { current, captured in
                ChatMessageLayoutKey(
                    message: current,
                    context: pending.mappingContext.layoutContext
                ) == ChatMessageLayoutKey(
                    message: captured,
                    context: pending.mappingContext.layoutContext
                )
            }
        guard stillRepresentsCurrentDatasource else {
            assertionFailure(
                "Width-transition layouts must retain complete datasource and viewport geometry"
            )
            cancelPendingWidthTransitionLayoutRemap()
            pending.completion?()
            return
        }

        pendingWidthTransitionLayoutRemap = nil
        pendingWidthTransitionLayoutFinalization =
            ChatPendingWidthTransitionLayoutFinalization(
                gate: ChatWidthTransitionLayoutFinalizationGate(
                    generation: pending.generation,
                    targetViewSize: pending.targetViewSize,
                    targetLayoutWidth: pending.targetLayoutWidth
                ),
                viewportRestoration: pending.viewportRestoration,
                firstItemPrimary: pending.items.first?.primary,
                completion: pending.completion
            )
        let invalidationContext = flowLayout.invalidationContext(
            forBoundsChange: messagesCollectionView.bounds
        )
        if let flowInvalidationContext = invalidationContext as?
            UICollectionViewFlowLayoutInvalidationContext {
            flowInvalidationContext.invalidateFlowLayoutDelegateMetrics = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            let complete: () -> Void = {
                self?.recordWidthTransitionCATransactionCompletion(
                    generation: pending.generation
                )
            }
            if Thread.isMainThread {
                complete()
            } else {
                DispatchQueue.main.async(execute: complete)
            }
        }
        var commitMode: ChatWidthTransitionInvalidationCommitMode = .direct
        UIView.performWithoutAnimation {
            flowLayout.cache.install(pending.preparedLayouts)
            commitMode = flowLayout.commitStagedWidthTransitionInvalidation(
                invalidationContext,
                completion: { [weak self] didFinish in
                    self?.recordWidthTransitionCollectionUpdateCompletion(
                        generation: pending.generation,
                        didFinish: didFinish
                    )
                }
            )
            messagesCollectionView.layoutIfNeeded()
        }
        if commitMode == .direct {
            recordWidthTransitionCollectionUpdateCompletion(
                generation: pending.generation,
                didFinish: true
            )
        }
        CATransaction.commit()
    }

    internal func cancelPendingWidthTransitionLayoutRemap() {
        let committedCompletion =
            pendingWidthTransitionLayoutFinalization?.completion
        pendingWidthTransitionLayoutFinalization = nil
        retireWidthTransitionLayoutOwnership()
        committedCompletion?()
    }

    private func retireWidthTransitionLayoutOwnership() {
        (messagesCollectionView.collectionViewLayout as?
            MessagesCollectionViewFlowLayout)?
            .discardStagedWidthTransitionLayout()
        pendingWidthTransitionLayoutRemap = nil
        activeWidthTransitionLayoutTargetSize = nil
        activeWidthTransitionLayoutGeneration = nil
    }

    private func recordWidthTransitionCollectionUpdateCompletion(
        generation: Int,
        didFinish: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var pending = pendingWidthTransitionLayoutFinalization,
              pending.gate.generation == generation else {
            return
        }
        guard didFinish else {
            let completion = pending.completion
            pendingWidthTransitionLayoutFinalization = nil
            retireWidthTransitionLayoutOwnership()
            completion?()
            return
        }
        guard pending.gate.recordCollectionUpdateCompletion(
            generation: generation,
            didFinish: true
        ) else {
            return
        }
        pendingWidthTransitionLayoutFinalization = pending
        finalizeWidthTransitionLayoutIfReady()
    }

    private func recordWidthTransitionCATransactionCompletion(
        generation: Int
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var pending = pendingWidthTransitionLayoutFinalization,
              pending.gate.recordCATransactionCompletion(
                generation: generation
              ) else {
            return
        }
        pendingWidthTransitionLayoutFinalization = pending
        finalizeWidthTransitionLayoutIfReady()
    }

    internal func recordWidthTransitionLayoutFinalizationObservationIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var pending = pendingWidthTransitionLayoutFinalization,
              let proof = widthTransitionLayoutFinalizationProof(
                for: pending
              ) else {
            return
        }
        _ = pending.gate.recordLayoutObservation(
            generation: pending.gate.generation,
            targetGeometryReady: proof.targetGeometryReady,
            targetCacheReady: proof.targetCacheReady,
            targetContentSizeReady: proof.targetContentSizeReady,
            semanticViewportReady: proof.semanticViewportReady
        )
        pendingWidthTransitionLayoutFinalization = pending
        finalizeWidthTransitionLayoutIfReady()
    }

    private func widthTransitionLayoutFinalizationProof(
        for pending: ChatPendingWidthTransitionLayoutFinalization
    ) -> (
        targetGeometryReady: Bool,
        targetCacheReady: Bool,
        targetContentSizeReady: Bool,
        semanticViewportReady: Bool
    )? {
        guard let flowLayout = messagesCollectionView.collectionViewLayout as?
            MessagesCollectionViewFlowLayout else {
            return nil
        }
        let targetGeometryReady =
            ChatWidthTransitionCommitReadinessPolicy.isReady(
                targetViewSize: pending.gate.targetViewSize,
                targetLayoutWidth: pending.gate.targetLayoutWidth,
                viewBounds: view.bounds,
                collectionBounds: messagesCollectionView.bounds,
                sectionInsets: flowLayout.sectionInset
            )
        let targetCacheReady: Bool
        if let primary = pending.firstItemPrimary,
           let installedWidth = flowLayout.cache.reuseSnapshot().key(
                forPrimary: primary
           )?.context.normalizedWidth {
            targetCacheReady = abs(
                installedWidth - pending.gate.targetLayoutWidth
            ) <= 1
        } else {
            targetCacheReady = false
        }
        let contentSize = messagesCollectionView.contentSize
        let targetContentSizeReady =
            contentSize.width.isFinite &&
            contentSize.height.isFinite &&
            contentSize.height >= 0 &&
            abs(
                contentSize.width - messagesCollectionView.bounds.width
            ) <= 1
        return (
            targetGeometryReady: targetGeometryReady,
            targetCacheReady: targetCacheReady,
            targetContentSizeReady: targetContentSizeReady,
            semanticViewportReady:
                isWidthTransitionSemanticViewportReady(
                    pending.viewportRestoration
                )
        )
    }

    private func isWidthTransitionSemanticViewportReady(
        _ viewportRestoration: ChatLayoutViewportRestoration
    ) -> Bool {
        switch viewportRestoration {
        case .none:
            return true
        case .bottom:
            return ChatTailAppendBottomPinPolicy.bottomDistance(
                contentHeight: messagesCollectionView.contentSize.height,
                viewportHeight: messagesCollectionView.bounds.height,
                contentInsets: messagesCollectionView.contentInset,
                contentOffsetY: messagesCollectionView.contentOffset.y
            ) <= 0.5
        case .message(let anchor):
            guard let section = datasource.firstIndex(where: {
                $0.primary == anchor.primary
            }),
                  let attributes = messagesCollectionView
                    .layoutAttributesForItem(
                        at: IndexPath(item: 0, section: section)
                    ) else {
                return false
            }
            let viewportRelativeMinY = attributes.frame.minY -
                messagesCollectionView.contentOffset.y
            let displayScale = view.window?.screen.scale ?? UIScreen.main.scale
            return abs(
                viewportRelativeMinY - anchor.viewportRelativeMinY
            ) <= 1 / max(displayScale, 1)
        }
    }

    private func finalizeWidthTransitionLayoutIfReady() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var pending = pendingWidthTransitionLayoutFinalization,
              let proof = widthTransitionLayoutFinalizationProof(
                for: pending
              ) else {
            return
        }
        _ = pending.gate.recordLayoutObservation(
            generation: pending.gate.generation,
            targetGeometryReady: proof.targetGeometryReady,
            targetCacheReady: proof.targetCacheReady,
            targetContentSizeReady: proof.targetContentSizeReady,
            semanticViewportReady: proof.semanticViewportReady
        )
        guard let receipt = pending.gate.completeIfReady() else {
            pendingWidthTransitionLayoutFinalization = pending
            return
        }
        let completion = pending.completion
        pendingWidthTransitionLayoutFinalization = nil
        retireWidthTransitionLayoutOwnership()
#if DEBUG || CHAT_PERFORMANCE_LAB
        performanceFixtureWidthTransitionLayoutCommitHandler?(
            receipt.generation,
            receipt.targetViewSize
        )
#endif
        completion?()
    }

    private func cancelWidthTransitionLayoutRemapIfOwned(
        by generation: Int
    ) {
        guard activeWidthTransitionLayoutGeneration == generation else {
            return
        }
        cancelPendingWidthTransitionLayoutRemap()
    }

    private func captureWidthTransitionSourceGeometry()
        -> ChatWidthTransitionSourceGeometry {
        return ChatWidthTransitionSourceGeometry(
            contentHeight: messagesCollectionView.contentSize.height,
            contentOffsetY: messagesCollectionView.contentOffset.y
        )
    }

    private func widthTransitionLayoutContentOffsetAdjustments(
        viewportRestoration: ChatLayoutViewportRestoration,
        items: [Datasource],
        previousLayouts: ChatMessageLayoutSnapshot,
        preparedLayouts: ChatMessageLayoutSnapshot
    ) -> ChatWidthTransitionLayoutAdjustments? {
        guard let totalHeightDelta =
            ChatWidthTransitionCellHeightDeltaPolicy.delta(
                items: items,
                previousLayouts: previousLayouts,
                preparedLayouts: preparedLayouts
            ) else {
            return nil
        }
        let precedingAnchorHeightDelta: CGFloat?
        if case .message(let anchor) = viewportRestoration {
            guard let delta = ChatWidthTransitionCellHeightDeltaPolicy.delta(
                items: items,
                previousLayouts: previousLayouts,
                preparedLayouts: preparedLayouts,
                stoppingBefore: anchor.primary
            ) else {
                return nil
            }
            precedingAnchorHeightDelta = delta
        } else {
            precedingAnchorHeightDelta = nil
        }
        return ChatWidthTransitionLayoutAdjustmentPolicy.adjustments(
            viewportRestoration: viewportRestoration,
            totalHeightDelta: totalHeightDelta,
            precedingAnchorHeightDelta: precedingAnchorHeightDelta
        )
    }

    private func widthTransitionTargetContentOffset(
        viewportRestoration: ChatLayoutViewportRestoration,
        items: [Datasource]
    ) -> ChatWidthTransitionTargetContentOffset? {
        switch viewportRestoration {
        case .none:
            return nil
        case .bottom:
            return .bottom
        case .message(let anchor):
            guard let section = items.firstIndex(where: {
                $0.primary == anchor.primary
            }) else {
                return nil
            }
            return .message(
                indexPath: IndexPath(item: 0, section: section),
                viewportRelativeMinY: anchor.viewportRelativeMinY
            )
        }
    }

    private func rememberWidthTransitionLayoutSnapshot(
        _ snapshot: ChatMessageLayoutSnapshot,
        context: ChatMessageLayoutContext,
        items: [Datasource]
    ) {
        guard let key = widthTransitionLayoutSnapshotKey(
            context: context,
            items: items
        ),
              items.allSatisfy({ item in
                snapshot.key(forPrimary: item.primary) ==
                    ChatMessageLayoutKey(message: item, context: context)
              }) else {
            return
        }
        widthTransitionLayoutSnapshotsByContext[key] = snapshot
    }

    private func retainedWidthTransitionLayoutSnapshot(
        context: ChatMessageLayoutContext,
        items: [Datasource]
    ) -> ChatMessageLayoutSnapshot? {
        guard let key = widthTransitionLayoutSnapshotKey(
            context: context,
            items: items
        ),
              let snapshot = widthTransitionLayoutSnapshotsByContext[key],
              items.allSatisfy({ item in
                snapshot.key(forPrimary: item.primary) ==
                    ChatMessageLayoutKey(message: item, context: context)
              }) else {
            return nil
        }
        return snapshot
    }

    private func widthTransitionLayoutSnapshotKey(
        context: ChatMessageLayoutContext,
        items: [Datasource]
    ) -> ChatMessageLayoutContext? {
        guard let first = items.first else { return nil }
        return ChatMessageLayoutKey(
            message: first,
            context: context
        ).context
    }

    private func captureLayoutViewportRestoration() -> ChatLayoutViewportRestoration {
        guard !datasource.isEmpty else {
            return .none
        }
        if isNearBottom() {
            return .bottom
        }
        if let anchor = capturePagingAnchorIfNeeded(direction: .older) {
            return .message(anchor)
        }
        return .none
    }

    internal func requestOutgoingAutoScrollAfterDatasourceUpdate() {
        self.pendingOutgoingAutoScrollRequest = ChatOutgoingAutoScrollRequest(
            previousNewestPrimary: ChatOutgoingAutoScrollPolicy
                .newestRealMessage(in: self.datasource)?
                .item
                .primary
        )
    }

    private func pendingOutgoingAutoScrollDecision(
        items: [Datasource]
    ) -> (
        request: ChatOutgoingAutoScrollRequest?,
        decision: ChatOutgoingAutoScrollDecision
    ) {
        let request = self.pendingOutgoingAutoScrollRequest
        let isAnchorNavigationActive = ChatInitialScrollPolicy.shouldDeferDefaultScroll(
            hasPendingAnchorRequest: self.pendingOpenMessageRequest != nil,
            isAnchorNavigationInFlight: self.isMessageAnchorNavigationInFlight
        )
        let decision = ChatOutgoingAutoScrollPolicy.decision(
            request: request,
            items: items,
            isAnchorNavigationActive: isAnchorNavigationActive
        )
        self.finishSendToLocalRowSignpostIfNeeded(request: request, items: items)
        return (request, decision)
    }

    internal static func mapReferenceAttachments(
        _ references: [MessageReferenceStorageItem],
        revealedSensitiveMediaPrimaries: Set<String> = Set<String>()
    ) -> (images: [ImageAttachment], videos: [VideoAttachment], locations: [LocationAttachment], contacts: [ContactAttachment], audio: [AudioAttachment], files: [FileAttachment]) {
        mapReferenceAttachments(
            references.map(ChatMessageReferenceSnapshot.init),
            revealedSensitiveMediaPrimaries: revealedSensitiveMediaPrimaries
        )
    }

    private static func mapReferenceAttachments(
        _ references: [ChatMessageReferenceSnapshot],
        revealedSensitiveMediaPrimaries: Set<String> = Set<String>()
    ) -> (images: [ImageAttachment], videos: [VideoAttachment], locations: [LocationAttachment], contacts: [ContactAttachment], audio: [AudioAttachment], files: [FileAttachment]) {
        var images: [ImageAttachment] = []
        var videos: [VideoAttachment] = []
        var locations: [LocationAttachment] = []
        var contacts: [ContactAttachment] = []
        var audio: [AudioAttachment] = []
        var files: [FileAttachment] = []

        references.filter { !$0.isLocallyHiddenByReport }.forEach { item in
            if item.kind == .geoloc {
                if let location = Self.locationAttachment(for: item) {
                    locations.append(location)
                }
                return
            }
            if item.kind == .contact {
                if let contact = Self.contactAttachment(for: item) {
                    contacts.append(contact)
                }
                return
            }

            let mediaType = SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(
                kind: item.kind,
                mimeType: item.mimeType,
                mediaType: item.metadata?["media-type"] as? String
            )
            switch mediaType {
            case .image:
                images.append(ImageAttachment(
                    primary: item.primary,
                    url: Self.imageSourceURL(for: item),
                    previewUrl: item.wireThumbnailUrl,
                    size: item.sizeInPx ?? CGSize(square: 128),
                    isSensitive: item.isSensitive,
                    isSensitiveRevealed: revealedSensitiveMediaPrimaries.contains(item.primary)
                ))
            case .video:
                videos.append(VideoAttachment(
                    primary: item.primary,
                    url: item.downloadUrl,
                    size: item.sizeInPx ?? CGSize(square: 128),
                    previewUrl: item.wireThumbnailUrl ?? item.videoPreviewUrl,
                    duration: 0,
                    downloaded: item.isDownloaded,
                    isSensitive: item.isSensitive,
                    isSensitiveRevealed: revealedSensitiveMediaPrimaries.contains(item.primary)
                ))
            case .unsupported:
                if item.kindRaw == "voice" {
                    audio.append(AudioAttachment(primary: item.primary, url: item.decodedUrl, size: 10, name: "name", duration: Double(item.duration ?? 0), downloaded: item.isDownloaded, pcm: item.meteringLevels))
                } else if item.kind == .media && MimeIcon(item.mimeType).value != .audio && item.kindRaw != "groupchat" {
                    files.append(FileAttachment(
                        primary: item.primary,
                        url: item.downloadUrl,
                        size: Double(item.sizeInBytesRaw),
                        name: item.displayFileName,
                        mimeType: item.mimeType,
                        downloaded: item.isDownloaded
                    ))
                }
            }
        }

        return (images, videos, locations, contacts, audio, files)
    }

    private static func imageSourceURL(for reference: ChatMessageReferenceSnapshot) -> URL? {
        if let downloadUrl = reference.downloadUrl {
            return downloadUrl
        }
        if let localFileUrl = reference.localFileUrl,
           localFileUrl.isFileURL {
            return localFileUrl
        }
        return nil
    }

    internal static func stickerAttachment(
        from references: [ChatMessageReferenceSnapshot]
    ) -> ImageAttachment? {
        guard let reference = references.first(where: {
            !$0.isLocallyHiddenByReport &&
                SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(
                    kind: $0.kind,
                    mimeType: $0.mimeType,
                    mediaType: $0.metadata?["media-type"] as? String
                ) == .image
        }), let url = imageSourceURL(for: reference) else {
            return nil
        }
        return ImageAttachment(
            primary: reference.primary,
            url: url,
            previewUrl: reference.wireThumbnailUrl,
            size: reference.sizeInPx ?? CGSize(square: 128),
            isSensitive: reference.isSensitive
        )
    }

    private static func locationAttachment(for reference: ChatMessageReferenceSnapshot) -> LocationAttachment? {
        guard let metadata = reference.metadata,
              let latitude = geolocCoordinateValue(metadata["lat"]),
              let longitude = geolocCoordinateValue(metadata["lon"]),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude),
              latitude.isFinite,
              longitude.isFinite else {
            return nil
        }

        let snapshotURL = (metadata["local-snapshot-url"] as? String)
            .flatMap(URL.init(string:))
        let geoURI = metadata["uri"] as? String ?? reference.url ?? "geo:\(latitude),\(longitude)"

        return LocationAttachment(
            primary: reference.primary,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            address: metadata["text"] as? String,
            geoURI: geoURI,
            snapshotURL: snapshotURL
        )
    }

    private static func contactAttachment(for reference: ChatMessageReferenceSnapshot) -> ContactAttachment? {
        guard let metadata = reference.metadata else {
            return nil
        }

        let jid = Self.contactNonEmpty(metadata["contact_jid"] as? String)
            ?? Self.contactNonEmpty(reference.url?.replacingOccurrences(of: "xmpp:", with: ""))
        guard let jid else {
            return nil
        }

        let nickname = Self.contactNonEmpty(metadata["nickname"] as? String)
        let given = Self.contactNonEmpty(metadata["given"] as? String)
        let family = Self.contactNonEmpty(metadata["family"] as? String)
        let entity = reference.resolvedContactEntity ?? MessageContactEntityKind.resolved(metadata: metadata, owner: reference.owner, jid: jid)
        let title = contactDisplayTitle(
            displayTitle: Self.contactNonEmpty(metadata["display_title"] as? String),
            nickname: nickname,
            given: given,
            family: family,
            jid: jid
        )
        let avatarMetadata = metadata.compactMapValues { $0 as? String }
            .filter { $0.key.hasPrefix("avatar_") }

        return ContactAttachment(
            primary: reference.primary,
            owner: reference.owner,
            jid: jid,
            entity: entity,
            title: title,
            nickname: nickname,
            given: given,
            family: family,
            avatarURL: reference.resolvedContactAvatarURL,
            avatarMetadata: avatarMetadata
        )
    }

    private static func contactDisplayTitle(
        displayTitle: String?,
        nickname: String?,
        given: String?,
        family: String?,
        jid: String
    ) -> String {
        if let displayTitle = Self.contactNonEmpty(displayTitle) {
            return displayTitle
        }
        if let nickname = Self.contactNonEmpty(nickname) {
            return nickname
        }
        let fullName = [Self.contactNonEmpty(given), Self.contactNonEmpty(family)]
            .compactMap { $0 }
            .joined(separator: " ")
        if let fullName = Self.contactNonEmpty(fullName) {
            return fullName
        }
        return jid
    }

    private static func contactNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }
        return value
    }

    private static func geolocCoordinateValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Float {
            return Double(value)
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    private static func mappedReferenceAttachments(
        _ references: [ChatMessageReferenceSnapshot],
        revealedSensitiveMediaPrimaries: Set<String>
    ) -> ChatMappedReferenceAttachments {
        let mapped = Self.mapReferenceAttachments(
            references,
            revealedSensitiveMediaPrimaries: revealedSensitiveMediaPrimaries
        )
        return ChatMappedReferenceAttachments(
            images: mapped.images,
            videos: mapped.videos,
            locations: mapped.locations,
            contacts: mapped.contacts,
            audio: mapped.audio,
            files: mapped.files
        )
    }

    internal func willUpdateFloatingDate() {
        self.updateFloatingDateObserverSignal.accept(true)
    }

    internal func updateFloatingDate(_ update: ChatScrollFloatingDateUpdate) {
        guard !self.showSkeletonObserver.value,
              update.residentRowCount >= 5 else {
            self.pinnedDateView.isHidden = true
            return
        }
        let frame = CGRect(
            origin: CGPoint(x: 0, y: 0),
            size: CGSize(width: self.view.bounds.width, height: 34)
        )
        let text = NSAttributedString(
            string: sectionsDateFormatter.string(from: update.date),
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .caption1),
                .foregroundColor: UIColor.white,
            ]
        )
        self.pinnedDateView.isHidden = false
        self.pinnedDateView.frame = frame
        self.pinnedDateView.configure(text)
    }

    internal func updateFloatingDate() {
        let visible = self.scrollResidentMetadata.capture(
            indexPaths: self.messagesCollectionView.indexPathsForVisibleItems
        )
        guard !self.showSkeletonObserver.value,
              let top = visible.rows.first(where: { !$0.isFakeMessage }) else {
            self.pinnedDateView.isHidden = true
            return
        }
        self.updateFloatingDate(
            ChatScrollFloatingDateUpdate(
                section: top.section,
                date: top.sentDate,
                residentRowCount: visible.residentRowCount
            )
        )
    }

    internal func mapAttachment(_ attachment: MessageForwardsInlineStorageItem) -> MessageAttachment {
        mapAttachment(
            ChatMessageForwardSnapshot(attachment),
            context: captureDatasourceMappingContext(),
            formatters: ChatDatasourceMappingDateFormatters()
        )
    }

    private func mapAttachment(
        _ attachment: ChatMessageForwardSnapshot,
        context: ChatDatasourceMappingContext,
        formatters: ChatDatasourceMappingDateFormatters
    ) -> MessageAttachment {
        let mappedReferences = Self.mapReferenceAttachments(
            attachment.references,
            revealedSensitiveMediaPrimaries: context.revealedSensitiveMediaPrimaries
        )
        let timeString = attachment.originalDate.map(formatters.attachmentTimeFormatter.string(from:)) ?? ""
        let timeMarkerString = NSAttributedString(
            string: timeString,
            attributes: context.timeMarkerAttributes
        )
        return MessageAttachment(
            primary: attachment.primary,
            author: attachment.authorName,
            jid: attachment.forwardJid,
            outgoing: attachment.isOutgoing,
            textMessage: ChatMessageDisplaySnapshot.attributedForwardBody(
                body: attachment.body,
                references: attachment.references,
                attributes: context.bodyTextAttributes,
                authorJid: attachment.forwardJid,
                searchedText: context.searchText,
                searchedTextColor: context.searchHighlightColor
            ),
            images: mappedReferences.images,
            videos: mappedReferences.videos,
            locations: mappedReferences.locations,
            contacts: mappedReferences.contacts,
            files: mappedReferences.files,
            audios: mappedReferences.audio,
            timeMarker: timeMarkerString,
            subforwards: attachment.subforwards.compactMap {
                return mapAttachment($0, context: context, formatters: formatters)
            }
        )
    }

    private func cachedDisplayModel(
        for item: MessageStorageItem,
        context: ChatDatasourceMappingContext,
        formatters: ChatDatasourceMappingDateFormatters
    ) -> ChatCachedDisplayModel {
        let richRevision = ChatMessageRichStorageRevision.capture(
            item,
            revealedSensitiveMediaPrimaries: context.revealedSensitiveMediaPrimaries
        )
        let key = ChatDisplayModelCacheKey(
            messagePrimary: item.primary,
            displayRevision: richRevision.rawValue,
            context: context.displayCacheContext
        )
        return displayModelCache.model(for: key) {
            let presentation = SavedMessageDisplayPolicy.presentation(
                for: item,
                currentUserJid: context.owner,
                currentUserName: context.ownerSender.displayName
            )
            let snapshot = ChatMessageDisplaySnapshot(item: item, presentation: presentation)
            let kind = self.displayKind(
                for: snapshot,
                context: context
            )
            let mappedReferences = Self.mappedReferenceAttachments(
                snapshot.presentation.visibleReferences,
                revealedSensitiveMediaPrimaries: context.revealedSensitiveMediaPrimaries
            )
            let forwardSignature = snapshot.forwardDisplayRevision(
                revealedSensitiveMediaPrimaries: context.revealedSensitiveMediaPrimaries,
                context: context.displayCacheContext
            )
            let visibleForwards = snapshot.presentation.visibleForwards
            let lazyForwards = ChatLazyForwardDisplayModel(signature: forwardSignature) { [weak self] in
                guard let self else { return [] }
                return visibleForwards.compactMap {
                    self.mapAttachment($0, context: context, formatters: formatters)
                }
            }
            let timeMarkerString = self.timeMarkerText(
                for: snapshot,
                context: context,
                formatters: formatters
            )
            return ChatCachedDisplayModel(
                displaySnapshot: snapshot,
                kind: kind,
                mappedReferences: mappedReferences,
                lazyForwards: lazyForwards,
                isDownloaded: snapshot.presentation.visibleReferences.contains(where: \.isDownloaded),
                timeMarkerText: timeMarkerString
            )
        }
    }

    private func displayKind(
        for snapshot: ChatMessageDisplaySnapshot,
        context: ChatDatasourceMappingContext
    ) -> MessageKind {
        switch snapshot.displayAs {
        case .text:
            return .attributedText(
                snapshot.attributedBody(
                    attributes: context.bodyTextAttributes,
                    searchedText: context.searchText,
                    searchedTextColor: context.searchHighlightColor
                )
            )
        case .call:
            return .call(CallAttachment(
                primary: snapshot.primary,
                incoming: !snapshot.presentation.displayOutgoing,
                missed: snapshot.presentation.visibleReferences.first?.metadata?["callState"] as? String == "missed"
            ))
        case .system:
            return .system(
                NSAttributedString(
                    string: snapshot.presentation.visibleBody,
                    attributes: context.systemTextAttributes
                )
            )
        case .sticker:
            guard let attachment = Self.stickerAttachment(
                from: snapshot.presentation.visibleReferences
            ) else {
                return .attributedText(NSAttributedString())
            }
            return .sticker(attachment)
        }
    }

    private func timeMarkerText(
        for snapshot: ChatMessageDisplaySnapshot,
        context: ChatDatasourceMappingContext,
        formatters: ChatDatasourceMappingDateFormatters
    ) -> NSAttributedString {
        var timeString = formatters.attachmentTimeFormatter.string(from: snapshot.presentation.visibleDate)
        if snapshot.afterburnInterval > 0 {
            timeString = "\(timeString) ⦁ \(snapshot.afterburnInterval.prettyMinuteFormatedString)"
        }
        if snapshot.editDate != nil {
            timeString = "\(timeString) (edited)"
        }
        return NSAttributedString(
            string: timeString,
            attributes: context.timeMarkerAttributes
        )
    }

    internal func applyChatDatasource(
        _ items: [Datasource],
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        preparedLayouts: ChatMessageLayoutSnapshot? = nil,
        suppressDefaultBottomScroll: Bool = false,
        forceBottomAlignmentTarget: ChatBottomAlignmentTarget? = nil,
        applyCategory: ChatDatasourceApplyCategory = .default,
        anchorRestorePhase: ChatHistoryPageAnchorRestorePhase = .none,
        anchorPrimary: String? = nil,
        restoreAnchor: ChatHistoryPageAnchor? = nil,
        presentationOwner: ChatDatasourcePresentationOwner,
        presentationCommitMode: ChatDatasourcePresentationCommitMode = .standard,
        transactionCommitAuthorization: (() -> Bool)? = nil,
        transactionCompletion: ((ChatViewportTransactionResult) -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        _ = presentationOwner
        var datasourceApplySignpost = ChatPerformanceSignposts.begin(.datasourceApply)
        let applyStartedAt = Date()
        let applyConversationKey = self.chatTimelineConversationKey
        if presentationCommitMode == .atomicInitialFrame {
            // Revoke every request admitted against the pre-transaction
            // presentation. UIKit can enqueue another one during reload/layout;
            // the committed receipt revokes that generation separately below.
            self.scrollWorkScheduler.cancel()
        }
        let modeDescription: String
        switch mode {
        case .fullReload(let keepOffset):
            modeDescription = "fullReload(keepOffset:\(keepOffset))"
        case .windowReload(let keepOffset):
            modeDescription = "windowReload(keepOffset:\(keepOffset))"
        case .targetedDiff:
            modeDescription = "targetedDiff"
        }
        let oldContentOffset = self.messagesCollectionView.contentOffset
        let oldContentSize = self.messagesCollectionView.contentSize
        let oldContentInsets = self.messagesCollectionView.contentInset
        let oldVerticalScrollIndicatorInsets =
            self.messagesCollectionView.verticalScrollIndicatorInsets
        let oldHorizontalScrollIndicatorInsets =
            self.messagesCollectionView.horizontalScrollIndicatorInsets
        let oldBottomDistance = ChatTailAppendBottomPinPolicy.bottomDistance(
            contentHeight: oldContentSize.height,
            viewportHeight: self.messagesCollectionView.bounds.height,
            contentInsets: oldContentInsets,
            contentOffsetY: oldContentOffset.y
        )
        let oldFirstArchivedId = self.datasource.first?.archivedId
        let oldLastArchivedId = self.datasource.last?.archivedId
        let newSnapshot = ChatDatasourceCoordinator.makeSnapshot(items: items)
        let previousDatasource = self.datasource
        let previousSnapshot = datasourceSnapshot
        let flowLayout = self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout
        let previousLayoutSnapshot = flowLayout?.cache.reuseSnapshot() ?? .empty
        let nextLayoutSnapshot = preparedLayouts ?? previousLayoutSnapshot
        let targetedDiff: ChatDatasourceCoordinator.DiffResult?
        if case .targetedDiff = mode,
           !previousSnapshot.items.isEmpty,
           ChatDatasourceCoordinator.supportsTargetedApply(old: previousSnapshot, new: newSnapshot) {
            targetedDiff = ChatPerformanceSignposts.measure(.datasourceDiff) {
                ChatDatasourceCoordinator.diff(
                    old: previousSnapshot,
                    new: newSnapshot,
                    oldSizeProvider: { previousLayoutSnapshot.layout(forPrimary: $0.primary)?.cellSize },
                    newSizeProvider: { nextLayoutSnapshot.layout(forPrimary: $0.primary)?.cellSize }
                )
            }
        } else {
            targetedDiff = nil
        }
        self.scrollFrameOperationCounter.record(.datasourceApplies)
        self.scrollFrameOperationCounter.record(.structuralInserts, by: targetedDiff?.inserts.count ?? 0)
        self.scrollFrameOperationCounter.record(.structuralDeletes, by: targetedDiff?.deletes.count ?? 0)
        self.scrollFrameOperationCounter.record(.structuralMoves, by: targetedDiff?.moves.count ?? 0)
        let containsOnlyFakeMessages = !items.isEmpty && items.allSatisfy(\.isFakeMessage)
        let containsRealMessages = items.contains { !$0.isFakeMessage }
        let wasNearBottom = self.isNearBottom()
        let isResidentAtLiveTail = self.virtualTimelineState.isResidentAtLiveTail
        var retainedRestoreAnchor: ChatHistoryPageAnchor?
        if restoreAnchor == nil,
           let retainedAnchor = self.retainedMessageAnchor,
           let nextItem = items.first(where: { $0.primary == retainedAnchor.primary }) {
            switch ChatRetainedMessageAnchorPolicy.resolve(
                anchor: retainedAnchor,
                nextPrimary: nextItem.primary,
                nextArchivedId: nextItem.archivedId,
                nextDisplayRevision: self.anchorDisplayRevision(for: nextItem),
                isUserInteracting: self.messagesCollectionView.isTracking ||
                    self.messagesCollectionView.isDragging ||
                    self.messagesCollectionView.isDecelerating
            ) {
            case .retain(let nextAnchor):
                self.retainedMessageAnchor = nextAnchor
                retainedRestoreAnchor = ChatHistoryPageAnchor(
                    primary: nextAnchor.primary,
                    viewportRelativeMinY: nextAnchor.viewportRelativeMinY
                )
            case .drop:
                self.retainedMessageAnchor = nil
            }
        }
        let effectiveRestoreAnchor = restoreAnchor ?? retainedRestoreAnchor
        let effectiveAnchorRestorePhase: ChatHistoryPageAnchorRestorePhase = retainedRestoreAnchor == nil
            ? anchorRestorePhase
            : .applyTransaction
        let effectiveAnchorPrimary = anchorPrimary ?? effectiveRestoreAnchor?.primary
        let shouldRestoreAnchor = effectiveAnchorRestorePhase != .none && effectiveRestoreAnchor != nil
        let shouldRestoreAnchorInApplyTransaction = effectiveAnchorRestorePhase == .applyTransaction && effectiveRestoreAnchor != nil
        let isDefaultBottomScrollDeferred = ChatInitialScrollPolicy.shouldDeferDefaultScroll(
            hasPendingAnchorRequest: self.pendingOpenMessageRequest != nil,
            isAnchorNavigationInFlight: self.isMessageAnchorNavigationInFlight
        )
        let shouldAutoScrollToBottom = !suppressDefaultBottomScroll
            && !shouldRestoreAnchor
            && forceBottomAlignmentTarget == nil
            && wasNearBottom
            && (previousSnapshot.items.isEmpty || isResidentAtLiveTail)
            && !isDefaultBottomScrollDeferred
            && !containsOnlyFakeMessages
        let requestedAnimatedApply = animated && !(
            previousSnapshot.items.isEmpty && !newSnapshot.items.isEmpty
        )
        let requestedStructuralAnimation = ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
            requestedAnimated: requestedAnimatedApply,
            isTransitionActive: self.isNavigationTransitionActive,
            isPreparingFirstFrame: false
        )
        let outgoingAutoScrollEvaluation = self.pendingOutgoingAutoScrollDecision(
            items: items
        )
        let outgoingAutoScrollRequest = outgoingAutoScrollEvaluation.request
        let outgoingAutoScrollDecision = outgoingAutoScrollEvaluation.decision
        let shouldTailAppendBottomPin = !shouldRestoreAnchor
            && ChatTailAppendBottomPinPolicy.shouldPinBottom(
                old: previousSnapshot,
                new: newSnapshot,
                wasNearBottom: wasNearBottom,
                isResidentAtLiveTail: isResidentAtLiveTail,
                isDefaultBottomScrollDeferred: isDefaultBottomScrollDeferred,
                suppressDefaultBottomScroll: suppressDefaultBottomScroll,
                containsOnlyFakeMessages: containsOnlyFakeMessages,
                outgoingAutoScrollDecision: outgoingAutoScrollDecision
            )
        let insertedItems = targetedDiff?.inserts.compactMap { section in
            items.indices.contains(section) ? items[section] : nil
        } ?? []
        let incrementalViewportDecision = ChatIncrementalViewportPolicy.decision(
            insertedItems: insertedItems,
            wasNearBottom: wasNearBottom,
            isResidentAtLiveTail: isResidentAtLiveTail
        )
        let effectiveApplyCategory: ChatDatasourceApplyCategory = shouldTailAppendBottomPin
            ? .tailAppendBottomPinned
            : applyCategory
        let shouldAnimateApply = !shouldTailAppendBottomPin && ChatOutgoingAutoScrollApplyPolicy.shouldAnimateStructuralApply(
            requestedAnimated: requestedStructuralAnimation,
            outgoingAutoScrollDecision: outgoingAutoScrollDecision
        )
        let modeKeepsOffset: Bool
        switch mode {
        case .fullReload(let keepOffset), .windowReload(let keepOffset):
            modeKeepsOffset = keepOffset
        case .targetedDiff:
            modeKeepsOffset = false
        }
        let outgoingRequestsScroll: Bool
        if case .scroll = outgoingAutoScrollDecision {
            outgoingRequestsScroll = true
        } else {
            outgoingRequestsScroll = false
        }
        let hasExplicitAnchor = shouldRestoreAnchorInApplyTransaction && effectiveRestoreAnchor != nil
        let needsAutomaticAnchor = !hasExplicitAnchor &&
            forceBottomAlignmentTarget == nil &&
            !shouldTailAppendBottomPin &&
            !shouldAutoScrollToBottom &&
            !outgoingRequestsScroll &&
            (modeKeepsOffset || (targetedDiff?.hasCollectionUpdates == true && !wasNearBottom))
        let automaticAnchor = needsAutomaticAnchor
            ? self.capturePagingAnchorIfNeeded(direction: .older)
            : nil
        let effectiveViewportAnchor = hasExplicitAnchor ? effectiveRestoreAnchor : automaticAnchor
        let anchorStrategy: ChatViewportAnchorStrategy
        if outgoingRequestsScroll {
            // A send is an explicit viewport command. The generic store
            // observation anchor describes the pre-insert frame and must not
            // hide the newly persisted outgoing row below the composer.
            anchorStrategy = .bottom
        } else if let effectiveViewportAnchor {
            anchorStrategy = .message(effectiveViewportAnchor)
        } else if forceBottomAlignmentTarget != nil ||
                    shouldTailAppendBottomPin ||
                    shouldAutoScrollToBottom {
            anchorStrategy = .bottom
        } else if modeKeepsOffset {
            anchorStrategy = .preserveContentOffset(oldContentOffset.y)
        } else {
            anchorStrategy = .none
        }
        let isUserInteractingWithTimeline =
            self.messagesCollectionView.isTracking ||
            self.messagesCollectionView.isDragging ||
            self.messagesCollectionView.isDecelerating
        let atomicTailAppendTarget: ChatCollectionUpdateTargetContentOffset?
        if targetedDiff?.hasCollectionUpdates == true,
           !shouldAnimateApply,
           !shouldRestoreAnchor,
           forceBottomAlignmentTarget == nil,
           effectiveViewportAnchor == nil,
           self.activeWidthTransitionLayoutTargetSize == nil,
           ChatTailAppendBottomPinPolicy.isPureTailAppend(
               old: previousSnapshot,
               new: newSnapshot
           ) {
            switch outgoingAutoScrollDecision {
            case .scroll(let indexPath):
                atomicTailAppendTarget = .message(indexPath)
            case .notHandled, .useDefaultAndClear:
                atomicTailAppendTarget = shouldTailAppendBottomPin &&
                    !isUserInteractingWithTimeline
                    ? .bottom
                    : nil
            case .handledNoScroll:
                atomicTailAppendTarget = nil
            }
        } else {
            atomicTailAppendTarget = nil
        }
        var contentChanges: ChatViewportContentChanges = []
        switch mode {
        case .fullReload, .windowReload:
            contentChanges.insert(.reload)
        case .targetedDiff:
            if targetedDiff == nil {
                contentChanges.insert(.reload)
            }
            if targetedDiff?.hasCollectionUpdates == true {
                contentChanges.insert(.structural)
            }
            if targetedDiff?.contentOnlyUpdates.isEmpty == false {
                contentChanges.insert(.contentOnly)
            }
        }
        var layoutChanges: ChatViewportLayoutChanges = []
        if invalidateLayout {
            layoutChanges.insert(.invalidateLayout)
        }
        if targetedDiff?.reloads.isEmpty == false {
            layoutChanges.insert(.reconfigureItems)
        }
        let viewportSnapshotDiff = ChatViewportSnapshotDiff(
            oldItemCount: previousSnapshot.items.count,
            newItemCount: newSnapshot.items.count,
            insertedItemCount: targetedDiff?.inserts.count
                ?? max(0, newSnapshot.items.count - previousSnapshot.items.count),
            deletedItemCount: targetedDiff?.deletes.count
                ?? max(0, previousSnapshot.items.count - newSnapshot.items.count),
            movedItemCount: targetedDiff?.moves.count ?? 0,
            reloadedItemCount: targetedDiff?.reloads.count ?? 0,
            contentOnlyItemCount: targetedDiff?.contentOnlyUpdates.count ?? 0
        )
        var completedViewportTransactionResult: ChatViewportTransactionResult?
        let viewportTransaction = ChatViewportTransaction(
            snapshotDiff: viewportSnapshotDiff,
            contentChanges: contentChanges,
            layoutChanges: layoutChanges,
            initialInsets: oldContentInsets,
            anchorStrategy: anchorStrategy,
            completion: { result in
                completedViewportTransactionResult = result
                guard presentationCommitMode == .standard else {
                    return
                }
                transactionCompletion?(result)
            }
        )
        if self.messagesCollectionView.isTracking ||
            self.messagesCollectionView.isDragging ||
            self.messagesCollectionView.isDecelerating {
            viewportTransaction.markUserInteractionDetected()
        }
        let forceBottomAlignmentDescription = forceBottomAlignmentTarget.map { String(describing: $0) } ?? "-"
        ChatArchiveDebugTrace.log("chatDatasourceApplyStart", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("mode", modeDescription),
            ("applyCategory", effectiveApplyCategory.rawValue),
            ("anchorRestorePhase", anchorRestorePhase.rawValue),
            ("anchorPrimary", effectiveAnchorPrimary ?? "-"),
            ("oldCount", self.datasource.count),
            ("newCount", items.count),
            ("oldFirstArchivedId", oldFirstArchivedId ?? "-"),
            ("newFirstArchivedId", items.first?.archivedId ?? "-"),
            ("oldLastArchivedId", oldLastArchivedId ?? "-"),
            ("newLastArchivedId", items.last?.archivedId ?? "-"),
            ("animated", animated),
            ("structuralAnimated", shouldAnimateApply),
            ("invalidateLayout", invalidateLayout),
            ("forceBottomAlignmentTarget", forceBottomAlignmentDescription),
            ("oldOffsetY", Int(oldContentOffset.y)),
            ("oldContentHeight", Int(oldContentSize.height)),
            ("oldBottomDistance", Int(oldBottomDistance))
        ])
        var didFinish = false
        var pendingLogicalCommit: (() -> Void)?
        let finish: () -> Void = {
            guard !didFinish else { return }
            didFinish = true
            let finishStartedAt = Date()
            let layoutStartedAt = Date()
            ChatPerformanceSignposts.measure(.layoutApply) {
                if layoutChanges.contains(.invalidateLayout) {
                    self.messagesCollectionView.collectionViewLayout.invalidateLayout()
                }
                _ = viewportTransaction.performForcedLayout {
                    self.messagesCollectionView.layoutIfNeeded()
                }
            }
            let layoutMs = ChatArchiveDebugTrace.milliseconds(since: layoutStartedAt)
            let insetsStartedAt = Date()
            self.updateChatCollectionInsets()
            viewportTransaction.recordFinalInsets(self.messagesCollectionView.contentInset)
            let insetsMs = ChatArchiveDebugTrace.milliseconds(since: insetsStartedAt)
            var transactionFailure: ChatViewportTransactionFailure?
            var anchorError: CGFloat?
            var bottomAlignmentError: CGFloat?
            var alignmentTargetDescription = "none"
            var forcedBottomAlignmentApplied = false
            var resolvedBottomTargetIndexPath: IndexPath?
            var usedPrependViewportFallback = false
            switch anchorStrategy {
            case .message(let anchor):
                alignmentTargetDescription = "anchor"
                guard let section = self.datasourceSnapshot.primaryIndex[anchor.primary] else {
                    transactionFailure = .targetMissing(primary: anchor.primary)
                    break
                }
                let indexPath = IndexPath(item: 0, section: section)
                let minOffsetY = -self.messagesCollectionView.adjustedContentInset.top
                let maxOffsetY = max(
                    minOffsetY,
                    self.messagesCollectionView.contentSize.height -
                        self.messagesCollectionView.bounds.height +
                        self.messagesCollectionView.adjustedContentInset.bottom
                )
                let frame = self.messagesCollectionView.layoutAttributesForItem(at: indexPath)?.frame
                    ?? self.messagesCollectionView.cellForItem(at: indexPath)?.frame
                let targetOffsetY: CGFloat
                if let frame {
                    targetOffsetY = ChatViewportTransactionTargetPolicy.targetContentOffsetY(
                        anchor: anchor,
                        resolvedAnchorMinY: frame.minY,
                        minimumContentOffsetY: minOffsetY,
                        maximumContentOffsetY: maxOffsetY
                    )
                } else if ChatPrependViewportFallbackPolicy.isEligible(
                    previousPrimaryIDs: previousSnapshot.items.map(\.primary),
                    nextPrimaryIDs: newSnapshot.items.map(\.primary),
                    anchorPrimary: anchor.primary
                ) {
                    usedPrependViewportFallback = true
                    targetOffsetY = ChatPrependViewportFallbackPolicy.targetContentOffsetY(
                        previousContentOffsetY: oldContentOffset.y,
                        previousContentHeight: oldContentSize.height,
                        nextContentHeight: self.messagesCollectionView.contentSize.height,
                        minimumContentOffsetY: minOffsetY,
                        maximumContentOffsetY: maxOffsetY
                    )
                } else {
                    transactionFailure = .targetMissing(primary: anchor.primary)
                    break
                }
                _ = viewportTransaction.performProgrammaticOffsetMutation(
                    currentOffsetY: self.messagesCollectionView.contentOffset.y,
                    targetOffsetY: targetOffsetY,
                    isAutomatic: automaticAnchor != nil
                ) { targetOffsetY in
                    self.messagesCollectionView.setContentOffset(
                        CGPoint(x: self.messagesCollectionView.contentOffset.x, y: targetOffsetY),
                        animated: false
                    )
                }
                if let frame {
                    anchorError = abs(
                        frame.minY -
                            self.messagesCollectionView.contentOffset.y -
                            anchor.viewportRelativeMinY
                    )
                } else {
                    anchorError = abs(
                        self.messagesCollectionView.contentOffset.y - targetOffsetY
                    )
                }
            case .preserveContentOffset(let requestedOffsetY):
                alignmentTargetDescription = "preservedOffset"
                let minOffsetY = -self.messagesCollectionView.adjustedContentInset.top
                let maxOffsetY = max(
                    minOffsetY,
                    self.messagesCollectionView.contentSize.height -
                        self.messagesCollectionView.bounds.height +
                        self.messagesCollectionView.adjustedContentInset.bottom
                )
                let decision = ChatViewportTransactionTargetPolicy.preservedContentOffsetDecision(
                    requestedOffsetY: requestedOffsetY,
                    minimumContentOffsetY: minOffsetY,
                    maximumContentOffsetY: maxOffsetY
                )
                _ = viewportTransaction.performProgrammaticOffsetMutation(
                    currentOffsetY: self.messagesCollectionView.contentOffset.y,
                    targetOffsetY: decision.targetOffsetY,
                    isAutomatic: !decision.isSafetyClamp
                ) { targetOffsetY in
                    self.messagesCollectionView.setContentOffset(
                        CGPoint(x: self.messagesCollectionView.contentOffset.x, y: targetOffsetY),
                        animated: false
                    )
                }
            case .bottom:
                alignmentTargetDescription = forceBottomAlignmentTarget == nil
                    ? "bottom"
                    : forceBottomAlignmentDescription
                var targetIndexPath: IndexPath?
                var missingTargetPrimary: String?
                if let forceBottomAlignmentTarget {
                    targetIndexPath = ChatBottomAlignmentTargetPolicy.indexPath(
                        for: forceBottomAlignmentTarget,
                        in: self.datasource
                    )
                    if targetIndexPath == nil {
                        switch forceBottomAlignmentTarget {
                        case .message(let anchor):
                            missingTargetPrimary = anchor.messagePrimary
                                ?? anchor.archivedId
                                ?? anchor.messageId
                                ?? "message-anchor"
                        case .newestRealMessage:
                            missingTargetPrimary = "newest-real-message"
                        }
                    }
                } else if case .scroll(let requestedIndexPath) = outgoingAutoScrollDecision {
                    guard requestedIndexPath.section >= 0,
                          requestedIndexPath.section < self.datasource.count else {
                        transactionFailure = .targetMissing(primary: "section-\(requestedIndexPath.section)")
                        break
                    }
                    targetIndexPath = requestedIndexPath
                }
                if let missingTargetPrimary {
                    transactionFailure = .targetMissing(primary: missingTargetPrimary)
                    break
                }
                resolvedBottomTargetIndexPath = targetIndexPath
                let targetMaxY = targetIndexPath.flatMap {
                    self.messagesCollectionView.layoutAttributesForItem(at: $0)?.frame.maxY
                        ?? self.messagesCollectionView.cellForItem(at: $0)?.frame.maxY
                } ?? self.messagesCollectionView.contentSize.height
                let targetOffsetY = ChatBottomScrollAlignmentPolicy.targetContentOffsetY(
                    targetMaxY: targetMaxY,
                    contentHeight: self.messagesCollectionView.contentSize.height,
                    viewportHeight: self.messagesCollectionView.bounds.height,
                    contentInsets: self.messagesCollectionView.contentInset
                )
                let isExplicitBottomTarget = forceBottomAlignmentTarget != nil || outgoingRequestsScroll
                forcedBottomAlignmentApplied = viewportTransaction.performProgrammaticOffsetMutation(
                    currentOffsetY: self.messagesCollectionView.contentOffset.y,
                    targetOffsetY: targetOffsetY,
                    isAutomatic: !isExplicitBottomTarget
                ) { targetOffsetY in
                    self.messagesCollectionView.setContentOffset(
                        CGPoint(x: self.messagesCollectionView.contentOffset.x, y: targetOffsetY),
                        animated: shouldAnimateApply && !isExplicitBottomTarget
                    )
                }
                bottomAlignmentError = abs(
                    self.messagesCollectionView.contentOffset.y - targetOffsetY
                )
            case .none:
                break
            }
            if presentationCommitMode == .atomicInitialFrame {
                self.messagesCollectionView.setNeedsLayout()
            }
            self.messagesCollectionView.layoutIfNeeded()
            if presentationCommitMode == .atomicInitialFrame,
               transactionFailure == nil {
                switch anchorStrategy {
                case .message(let anchor):
                    if usedPrependViewportFallback {
                        let minOffsetY =
                            -self.messagesCollectionView.adjustedContentInset.top
                        let maxOffsetY = max(
                            minOffsetY,
                            self.messagesCollectionView.contentSize.height -
                                self.messagesCollectionView.bounds.height +
                                self.messagesCollectionView.adjustedContentInset.bottom
                        )
                        let finalTargetOffsetY =
                            ChatPrependViewportFallbackPolicy.targetContentOffsetY(
                                previousContentOffsetY: oldContentOffset.y,
                                previousContentHeight: oldContentSize.height,
                                nextContentHeight: self.messagesCollectionView.contentSize.height,
                                minimumContentOffsetY: minOffsetY,
                                maximumContentOffsetY: maxOffsetY
                            )
                        let didCorrect = viewportTransaction.performFinalAlignmentCorrection(
                            currentOffsetY: self.messagesCollectionView.contentOffset.y,
                            targetOffsetY: finalTargetOffsetY,
                            tolerance: 1
                        ) { targetOffsetY in
                            self.messagesCollectionView.setContentOffset(
                                CGPoint(
                                    x: self.messagesCollectionView.contentOffset.x,
                                    y: targetOffsetY
                                ),
                                animated: false
                            )
                        }
                        if didCorrect {
                            self.messagesCollectionView.setNeedsLayout()
                            self.messagesCollectionView.layoutIfNeeded()
                        }
                        anchorError = abs(
                            self.messagesCollectionView.contentOffset.y - finalTargetOffsetY
                        )
                        if let anchorError, anchorError > 1 {
                            transactionFailure = .alignmentUnresolved(
                                target: "anchor",
                                error: anchorError
                            )
                        }
                        break
                    }
                    let resolveAnchorTargetOffsetY: () -> CGFloat? = {
                        guard let section = self.datasourceSnapshot.primaryIndex[anchor.primary] else {
                            return nil
                        }
                        let indexPath = IndexPath(item: 0, section: section)
                        guard let frame =
                                self.messagesCollectionView.layoutAttributesForItem(
                                    at: indexPath
                                )?.frame
                                ?? self.messagesCollectionView.cellForItem(
                                    at: indexPath
                                )?.frame else {
                            return nil
                        }
                        let minOffsetY =
                            -self.messagesCollectionView.adjustedContentInset.top
                        let maxOffsetY = max(
                            minOffsetY,
                            self.messagesCollectionView.contentSize.height -
                                self.messagesCollectionView.bounds.height +
                                self.messagesCollectionView.adjustedContentInset.bottom
                        )
                        return ChatViewportTransactionTargetPolicy.targetContentOffsetY(
                            anchor: anchor,
                            resolvedAnchorMinY: frame.minY,
                            minimumContentOffsetY: minOffsetY,
                            maximumContentOffsetY: maxOffsetY
                        )
                    }
                    if let resolvedTargetOffsetY = resolveAnchorTargetOffsetY() {
                        let didCorrect = viewportTransaction.performFinalAlignmentCorrection(
                            currentOffsetY: self.messagesCollectionView.contentOffset.y,
                            targetOffsetY: resolvedTargetOffsetY,
                            tolerance: 1
                        ) { targetOffsetY in
                            self.messagesCollectionView.setContentOffset(
                                CGPoint(
                                    x: self.messagesCollectionView.contentOffset.x,
                                    y: targetOffsetY
                                ),
                                animated: false
                            )
                        }
                        if didCorrect {
                            self.messagesCollectionView.setNeedsLayout()
                            self.messagesCollectionView.layoutIfNeeded()
                        }
                        if let finalTargetOffsetY = resolveAnchorTargetOffsetY() {
                            anchorError = abs(
                                self.messagesCollectionView.contentOffset.y -
                                    finalTargetOffsetY
                            )
                        } else {
                            transactionFailure = .targetMissing(primary: anchor.primary)
                        }
                    } else {
                        transactionFailure = .targetMissing(primary: anchor.primary)
                    }
                    if let anchorError, anchorError > 1 {
                        transactionFailure = .alignmentUnresolved(
                            target: "anchor",
                            error: anchorError
                        )
                    }
                case .bottom:
                    let resolveBottomTargetOffsetY: () -> CGFloat? = {
                        let targetMaxY: CGFloat
                        if let resolvedBottomTargetIndexPath {
                            guard let resolvedTargetMaxY =
                                    self.messagesCollectionView.layoutAttributesForItem(
                                        at: resolvedBottomTargetIndexPath
                                    )?.frame.maxY
                                    ?? self.messagesCollectionView.cellForItem(
                                        at: resolvedBottomTargetIndexPath
                                    )?.frame.maxY else {
                                return nil
                            }
                            targetMaxY = resolvedTargetMaxY
                        } else {
                            targetMaxY = self.messagesCollectionView.contentSize.height
                        }
                        return ChatBottomScrollAlignmentPolicy.targetContentOffsetY(
                            targetMaxY: targetMaxY,
                            contentHeight: self.messagesCollectionView.contentSize.height,
                            viewportHeight: self.messagesCollectionView.bounds.height,
                            contentInsets: self.messagesCollectionView.contentInset
                        )
                    }
                    if let finalTargetOffsetY = resolveBottomTargetOffsetY() {
                        let didCorrect = viewportTransaction.performFinalAlignmentCorrection(
                            currentOffsetY: self.messagesCollectionView.contentOffset.y,
                            targetOffsetY: finalTargetOffsetY,
                            tolerance: 0.5
                        ) { targetOffsetY in
                            self.messagesCollectionView.setContentOffset(
                                CGPoint(
                                    x: self.messagesCollectionView.contentOffset.x,
                                    y: targetOffsetY
                                ),
                                animated: false
                            )
                        }
                        if didCorrect {
                            self.messagesCollectionView.setNeedsLayout()
                            self.messagesCollectionView.layoutIfNeeded()
                        }
                        if let resolvedFinalTargetOffsetY =
                                resolveBottomTargetOffsetY() {
                            bottomAlignmentError = abs(
                                self.messagesCollectionView.contentOffset.y -
                                    resolvedFinalTargetOffsetY
                            )
                        } else {
                            transactionFailure = .targetMissing(
                                primary: alignmentTargetDescription
                            )
                        }
                    } else {
                        transactionFailure = .targetMissing(
                            primary: alignmentTargetDescription
                        )
                    }
                    if transactionFailure == nil,
                       let bottomAlignmentError,
                       bottomAlignmentError > 0.5 {
                        transactionFailure = .alignmentUnresolved(
                            target: alignmentTargetDescription,
                            error: bottomAlignmentError
                        )
                    }
                case .none, .preserveContentOffset:
                    break
                }
            }
            if presentationCommitMode == .atomicInitialFrame,
               transactionFailure == nil,
               transactionCommitAuthorization?() == false {
                transactionFailure = .superseded
            }
            if presentationCommitMode == .atomicInitialFrame,
               transactionFailure != nil {
                self.datasource = previousDatasource
                self.datasourceSnapshot = previousSnapshot
                flowLayout?.cache.install(previousLayoutSnapshot)
                self.messagesCollectionView.contentInset = oldContentInsets
                self.messagesCollectionView.verticalScrollIndicatorInsets =
                    oldVerticalScrollIndicatorInsets
                self.messagesCollectionView.horizontalScrollIndicatorInsets =
                    oldHorizontalScrollIndicatorInsets
                self.scrollFrameOperationCounter.record(.reloads)
                self.messagesCollectionView.reloadData()
                self.messagesCollectionView.layoutIfNeeded()
                self.messagesCollectionView.setContentOffset(
                    oldContentOffset,
                    animated: false
                )
                self.messagesCollectionView.layoutIfNeeded()
            }
            let logicalCommit: () -> Void = {
            let completionStartedAt = Date()
            let transactionCommitted: Bool
            if let transactionFailure {
                transactionCommitted = false
                _ = viewportTransaction.fail(transactionFailure)
            } else {
                transactionCommitted = true
                _ = viewportTransaction.commit(anchorError: anchorError)
            }
            if transactionCommitted,
               outgoingAutoScrollDecision.consumesPendingRequest,
               let outgoingAutoScrollRequest,
               self.pendingOutgoingAutoScrollRequest?.id ==
                    outgoingAutoScrollRequest.id {
                // A superseded/failed UIKit attempt cannot acknowledge the
                // user's send. Identity guarding also prevents an older apply
                // from consuming a newer rapid-send request.
                self.pendingOutgoingAutoScrollRequest = nil
            }
            let didCommitCurrentConversationContent = transactionCommitted &&
                containsRealMessages &&
                applyConversationKey == self.chatTimelineConversationKey &&
                self.datasourceSnapshot.items.map(\.primary) == newSnapshot.items.map(\.primary)
            if didCommitCurrentConversationContent {
                self.setShouldShowInitialMessage(false)
            }
            let completionMs = ChatArchiveDebugTrace.milliseconds(since: completionStartedAt)
            if transactionCommitted || presentationCommitMode == .standard {
                self.refreshUnreadMentionsNavigatorState()
                self.updateVisibleVoiceMessageQueue()
            }
            if case .preserveViewport(let showNewMessageBadge) = incrementalViewportDecision,
               showNewMessageBadge,
               !self.shouldShowScrollDownButton.value {
                self.shouldShowScrollDownButton.accept(true)
            }
            let applyDurationMs = ChatArchiveDebugTrace.milliseconds(since: applyStartedAt)
            let realMessageCount = self.chatOpenTimingRealMessageCount(in: items)
            self.recordChatOpenTimingFirstMessagesPreparedIfNeeded(
                reason: "chatDatasourceApplyFinish",
                modeDescription: modeDescription,
                appliedItemCount: items.count,
                realMessageCount: realMessageCount,
                applyStartedAt: applyStartedAt,
                applyDurationMs: applyDurationMs,
                layoutMs: layoutMs,
                animated: shouldAnimateApply,
                invalidateLayout: invalidateLayout
            )
            self.scheduleChatOpenTimingFirstMessagesVisibleCheck(
                reason: "chatDatasourceApplyFinish",
                modeDescription: modeDescription
            )
            let newContentOffset = self.messagesCollectionView.contentOffset
            let newContentSize = self.messagesCollectionView.contentSize
            let newContentInsets = self.messagesCollectionView.contentInset
            let newBottomDistance = ChatTailAppendBottomPinPolicy.bottomDistance(
                contentHeight: newContentSize.height,
                viewportHeight: self.messagesCollectionView.bounds.height,
                contentInsets: newContentInsets,
                contentOffsetY: newContentOffset.y
            )
            ChatArchiveDebugTrace.log("chatDatasourceApplyFinish", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("mode", modeDescription),
                ("applyCategory", effectiveApplyCategory.rawValue),
                ("anchorRestorePhase", anchorRestorePhase.rawValue),
                ("anchorPrimary", effectiveAnchorPrimary ?? "-"),
                ("anchorError", Int(anchorError ?? 0)),
                ("transactionCommitted", transactionCommitted),
                ("transactionFailure", transactionFailure.map { String(describing: $0) } ?? "-"),
                ("count", self.datasource.count),
                ("firstArchivedId", self.datasource.first?.archivedId ?? "-"),
                ("lastArchivedId", self.datasource.last?.archivedId ?? "-"),
                ("layoutMs", layoutMs),
                ("insetsMs", insetsMs),
                ("completionMs", completionMs),
                ("finishMs", ChatArchiveDebugTrace.milliseconds(since: finishStartedAt)),
                ("durationMs", applyDurationMs),
                ("oldOffsetY", Int(oldContentOffset.y)),
                ("newOffsetY", Int(newContentOffset.y)),
                ("oldContentHeight", Int(oldContentSize.height)),
                ("newContentHeight", Int(newContentSize.height)),
                ("oldBottomDistance", Int(oldBottomDistance)),
                ("newBottomDistance", Int(newBottomDistance)),
                ("autoScrollToBottom", shouldAutoScrollToBottom),
                ("tailAppendBottomPinned", shouldTailAppendBottomPin),
                ("suppressDefaultBottomScroll", suppressDefaultBottomScroll),
                ("forceBottomAlignmentTarget", forceBottomAlignmentDescription),
                ("forcedBottomAlignmentApplied", forcedBottomAlignmentApplied),
                ("outgoingAutoScroll", "\(outgoingAutoScrollDecision)")
            ])
            datasourceApplySignpost.end()
            if presentationCommitMode == .standard,
               let completedViewportTransactionResult,
               case .committed = completedViewportTransactionResult {
                completion?()
            }
            if presentationCommitMode == .atomicInitialFrame,
               let completedViewportTransactionResult {
                transactionCompletion?(completedViewportTransactionResult)
                let remainsAuthorizedAfterTerminal =
                    transactionCommitAuthorization?() != false
                if case .committed = completedViewportTransactionResult,
                   remainsAuthorizedAfterTerminal {
                    // Publish the winning UIKit receipt before deriving any
                    // viewport work from it. Read-boundary resampling may
                    // legitimately advance the timeline session generation;
                    // doing that first would make the already-committed
                    // archive frame look superseded to its completion owner.
                    completion?()
                    if didCommitCurrentConversationContent {
                        self.enqueuePostAtomicInitialFrameReceiptScrollWorkResample()
                    } else {
                        self.scrollWorkScheduler.cancel()
                    }
                }
            }
            }
            if presentationCommitMode == .atomicInitialFrame {
                pendingLogicalCommit = logicalCommit
            } else {
                logicalCommit()
            }
        }

        let runWithoutAnimation: (@escaping () -> Void) -> Void = { updates in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            UIView.performWithoutAnimation {
                updates()
            }
            CATransaction.commit()
        }

        let runAtomicInitialFrameVisualCommit: (@escaping () -> Void) -> Void = { updates in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ChatDatasourcePresentationTransactionContext.install(token: UUID().uuidString)
            UIView.performWithoutAnimation {
                updates()
            }
            CATransaction.commit()
            let logicalCommit = pendingLogicalCommit
            pendingLogicalCommit = nil
            logicalCommit?()
        }

        let applyNonStructuralUpdates: () -> Void = {
            guard let targetedDiff else { return }
            if !targetedDiff.reloads.isEmpty {
                self.messagesCollectionView.reconfigureItems(at: targetedDiff.reloads)
            }
            targetedDiff.contentOnlyUpdates.forEach { update in
                self.updateVisibleMessageContent(
                    primary: update.primary,
                    changeMask: targetedDiff.changeMasksByPrimary[update.primary] ?? .all
                )
            }
        }

        if presentationCommitMode == .atomicInitialFrame {
            let preflightFailure: ChatViewportTransactionFailure?
            switch anchorStrategy {
            case .message(let anchor):
                preflightFailure = newSnapshot.primaryIndex[anchor.primary] == nil
                    ? .targetMissing(primary: anchor.primary)
                    : nil
            case .bottom:
                if let forceBottomAlignmentTarget,
                   ChatBottomAlignmentTargetPolicy.indexPath(
                    for: forceBottomAlignmentTarget,
                    in: items
                   ) == nil {
                    let missingPrimary: String
                    switch forceBottomAlignmentTarget {
                    case .message(let anchor):
                        missingPrimary = anchor.messagePrimary
                            ?? anchor.archivedId
                            ?? anchor.messageId
                            ?? "message-anchor"
                    case .newestRealMessage:
                        missingPrimary = "newest-real-message"
                    }
                    preflightFailure = .targetMissing(primary: missingPrimary)
                } else {
                    preflightFailure = nil
                }
            case .none, .preserveContentOffset:
                preflightFailure = nil
            }
            if let preflightFailure {
                _ = viewportTransaction.fail(preflightFailure)
                datasourceApplySignpost.end()
                if let completedViewportTransactionResult {
                    transactionCompletion?(completedViewportTransactionResult)
                }
                return
            }
        }

        if presentationCommitMode == .atomicInitialFrame {
            runAtomicInitialFrameVisualCommit {
                if let preparedLayouts {
                    flowLayout?.cache.install(preparedLayouts)
                }
                self.datasource = items
                self.datasourceSnapshot = newSnapshot
                let reloadStartedAt = Date()
                self.scrollFrameOperationCounter.record(.reloads)
                self.messagesCollectionView.reloadData()
                ChatArchiveDebugTrace.log("chatDatasourceReload", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("mode", modeDescription),
                    ("keepOffset", modeKeepsOffset),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: reloadStartedAt)),
                    ("count", items.count)
                ])
                finish()
            }
            return
        }

        if let preparedLayouts {
            flowLayout?.cache.install(preparedLayouts)
        }

        switch mode {
        case .fullReload, .windowReload:
            self.datasource = items
            self.datasourceSnapshot = newSnapshot
            let updates = {
                let reloadStartedAt = Date()
                self.scrollFrameOperationCounter.record(.reloads)
                self.messagesCollectionView.reloadData()
                ChatArchiveDebugTrace.log("chatDatasourceReload", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("mode", modeDescription),
                    ("keepOffset", modeKeepsOffset),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: reloadStartedAt)),
                    ("count", items.count)
                ])
            }
            if shouldAnimateApply {
                updates()
            } else {
                runWithoutAnimation(updates)
            }
            finish()
        case .targetedDiff:
            self.datasource = items
            self.datasourceSnapshot = newSnapshot
            guard let targetedDiff else {
                let reload = {
                    self.scrollFrameOperationCounter.record(.reloads)
                    self.messagesCollectionView.reloadData()
                }
                shouldAnimateApply ? reload() : runWithoutAnimation(reload)
                finish()
                return
            }
            if ChatOutgoingAutoScrollApplyPolicy.shouldUseImmediateReload(outgoingAutoScrollDecision: outgoingAutoScrollDecision) {
                runWithoutAnimation {
                    self.scrollFrameOperationCounter.record(.reloads)
                    self.messagesCollectionView.reloadData()
                }
                finish()
                return
            }
            guard !targetedDiff.isEmpty else {
                ChatArchiveDebugTrace.log("chatDatasourceTargetedDiffEmpty", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("count", items.count)
                ])
                finish()
                return
            }
            guard targetedDiff.hasCollectionUpdates else {
                ChatArchiveDebugTrace.log("chatDatasourceTargetedDiffContentOnly", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("reloads", targetedDiff.reloads.count),
                    ("contentOnly", targetedDiff.contentOnlyUpdates.count)
                ])
                runWithoutAnimation(applyNonStructuralUpdates)
                finish()
                return
            }
            let applyStructuralUpdates = {
                let batchStartedAt = Date()
                let didStageAtomicTailAppendTarget = atomicTailAppendTarget.flatMap {
                    flowLayout?.stageCollectionUpdateTargetContentOffset($0)
                } ?? false
                let batchUpdates = {
                    if !targetedDiff.deletes.isEmpty {
                        self.messagesCollectionView.deleteSections(targetedDiff.deletes)
                    }
                    if !targetedDiff.inserts.isEmpty {
                        self.messagesCollectionView.insertSections(targetedDiff.inserts)
                    }
                    targetedDiff.moves.forEach {
                        self.messagesCollectionView.moveSection($0.from.section, toSection: $0.to.section)
                    }
                }
                self.isChatDatasourceStructuralTransactionActive = true
                self.messagesCollectionView.performBatchUpdates(batchUpdates, completion: { _ in
                    if didStageAtomicTailAppendTarget {
                        flowLayout?.discardStagedCollectionUpdateTargetContentOffset()
                    }
                    ChatArchiveDebugTrace.log("chatDatasourceBatchUpdatesFinish", [
                        ("owner", self.owner),
                        ("jid", self.jid),
                        ("conversationType", self.conversationType.rawValue),
                        ("durationMs", ChatArchiveDebugTrace.milliseconds(since: batchStartedAt)),
                        ("deletes", targetedDiff.deletes.count),
                        ("inserts", targetedDiff.inserts.count),
                        ("moves", targetedDiff.moves.count)
                    ])
                    runWithoutAnimation(applyNonStructuralUpdates)
                    finish()
                    self.finishChatDatasourceStructuralTransaction()
                })
            }
            shouldAnimateApply ? applyStructuralUpdates() : runWithoutAnimation(applyStructuralUpdates)
        }
    }

    /// Re-samples the geometry that became observable with an accepted atomic
    /// first-frame receipt. Offset bookkeeping and boundary paging are omitted:
    /// this pass refreshes only state derived from the committed viewport.
    internal func enqueuePostAtomicInitialFrameReceiptScrollWorkResample() {
        assert(Thread.isMainThread, "Post-receipt viewport resampling is main-owned")
        self.synchronizeReadVisibleGeometryEpoch(scheduleStableRetry: false)
        let visibleIndexPaths = self.messagesCollectionView
            .indexPathsForVisibleItems
            .sorted {
                if $0.section != $1.section {
                    return $0.section < $1.section
                }
                return $0.item < $1.item
            }
        let visibleMetadata = self.scrollResidentMetadata.capture(
            indexPaths: visibleIndexPaths
        )
        let meaningfullyVisibleReadPrimaries =
            self.meaningfullyVisibleRealMessagePrimariesForRead(
                indexPaths: visibleIndexPaths
            )
        let scrollView = self.messagesCollectionView
        self.scrollWorkScheduler.executeIsolatedReceiptWork(ChatScrollWorkRequest(
            contentOffsetY: scrollView.contentOffset.y,
            gestureTranslationY:
                scrollView.panGestureRecognizer.translation(in: scrollView).y,
            isUserScrolling:
                scrollView.isTracking ||
                scrollView.isDragging ||
                scrollView.isDecelerating,
            visibleIndexPaths: visibleIndexPaths,
            visibleMetadata: visibleMetadata,
            meaningfullyVisibleReadPrimaries: meaningfullyVisibleReadPrimaries,
            work: [
                .updateFloatingDate,
                .advanceReadBoundary,
                .updateVoiceQueue
            ],
            isPostAtomicInitialFrameReceiptResample: true
        ))
    }

    /// The structural batch terminal is also a stable-presentation receipt for
    /// read-visible candidates revoked by geometry while the batch was active.
    internal func finishChatDatasourceStructuralTransaction() {
        self.isChatDatasourceStructuralTransactionActive = false
        if self.pendingOpenMessageRequest != nil {
            self.performPendingOpenMessageRequestIfNeeded()
        }
        self.drainTimelinePresentationLanesAfterAnchorTerminal()
        self.scheduleReadVisibleStableLayoutRetryIfNeeded()
    }

    @discardableResult
    internal func updateVisibleMessageContent(
        primary: String,
        changeMask: ChatMessageChangeMask = .all
    ) -> Bool {
        guard let section = datasourceSnapshot.primaryIndex[primary],
              let item = self.datasourceItem(atSection: section) else {
            return false
        }

        let indexPath = IndexPath(row: 0, section: section)
        guard let cell = messagesCollectionView.cellForItem(at: indexPath) as? MessageCollectionViewCell else {
            return false
        }

        ChatMessageCellUpdatePlan(changeMask: changeMask).operations.forEach {
            self.scrollFrameOperationCounter.record($0)
        }
        UIView.performWithoutAnimation {
            cell.reconfigureContent(
                with: item,
                at: indexPath,
                and: messagesCollectionView,
                changeMask: changeMask
            )
            cell.setNeedsLayout()
        }
        return true
    }

    internal var datasetCoordinator: ChatDatasetCoordinator {
        ChatDatasetCoordinator(pageSize: self.datasourcePageSize)
    }

    internal func syncCurrentPage(with window: ChatDatasetWindow) {
        self.residentDatasetWindow = window
    }

    internal func visibleWindow() -> ChatDatasetWindow {
        self.residentDatasetWindow
    }

    private func messageWindowSliceForMapping(
        _ window: ChatDatasetWindow,
        currentWindow _: ChatDatasetWindow,
        timelineSnapshot: ChatTimelineSessionSnapshot? = nil
    ) -> (window: ChatDatasetWindow, items: [MessageStorageItem]) {
        guard let snapshot = timelineSnapshot ?? self.timelineSession?.snapshot else {
            return (.empty, [])
        }
        let lowerBound = min(max(0, window.minIndex), snapshot.items.count)
        let upperBound = min(max(lowerBound, window.maxIndex), snapshot.items.count)
        let items = Array(snapshot.items[lowerBound..<upperBound])
        return (
            ChatDatasetWindow(minIndex: 0, maxIndex: items.count),
            items
        )
    }

    internal func sliceForWindow(_ window: ChatDatasetWindow) -> [MessageStorageItem] {
        let mapped = self.messageWindowSliceForMapping(
            window,
            currentWindow: self.visibleWindow()
        )
        return mapped.items
    }

    private func deduplicatedChronologicalItems(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        var seen = Set<String>()
        return items
            .enumerated()
            .sorted {
                if $0.element.date == $1.element.date {
                    return $0.offset < $1.offset
                }
                return $0.element.date < $1.element.date
            }
            .map { $0.element }
            .filter { item in
                seen.insert(item.primary).inserted
            }
    }

    internal func setArchiveLoading(_ isLoading: Bool) {
        self.performOnMain {
            if isLoading {
                self.messageLoadingActivityIndicator.startAnimating()
                self.view.bringSubviewToFront(self.messageLoadingActivityIndicator)
            } else {
                self.messageLoadingActivityIndicator.stopAnimating()
            }
            self.messageLoadingActivityIndicator.isHidden = !isLoading
        }
    }

    internal func currentGroupchatMemberId(in realm: Realm? = nil) -> String? {
        let resolve: (Realm) -> String? = { realm in
            guard self.conversationType == .group else {
                return nil
            }

            return MentionNotificationSync.currentGroupMemberId(
                owner: self.owner,
                groupchatJid: self.jid,
                in: realm
            )
        }

        if let realm {
            return resolve(realm)
        }

        do {
            return resolve(try WRealm.safe())
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    internal func unreadMentionHintArchivedId() -> String? {
        do {
            let realm = try WRealm.safe()
            return realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            )?.mentionId
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    internal func visibleRealMessagePrimaries() -> Set<String> {
        Set(
            self.messagesCollectionView.indexPathsForVisibleItems.compactMap {
                guard let item = self.datasourceItem(at: $0) else {
                    return nil
                }
                return item.isFakeMessage ? nil : item.primary
            }
        )
    }

    internal func rebuildUnreadMentionItems() {
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.unreadMentionRebuildObserverForTests?()
#endif
        guard self.conversationType == .group,
              let timelineSession = self.timelineSession else {
            self.unreadMentionItems = []
            self.lastAppliedUnreadMentionPresentationMetadata = nil
            self.unreadMentionsState = .empty
            self.currentUnreadMentionNotificationPrimary = nil
            self.claimedUnreadMentionBadgeNotificationPrimary = nil
            return
        }

        let unreadSnapshot = timelineSession.snapshot
        let unreadMetadata = unreadSnapshot.unreadMetadata
        self.unreadMentionItems = unreadMetadata.mentions
        guard self.unreadMentionItems.isEmpty else { return }

        do {
#if DEBUG || CHAT_PERFORMANCE_LAB
            self.unreadMentionFallbackRealmQueryObserverForTests?()
#endif
            let realm = try WRealm.safe()
            let currentMemberId = self.currentGroupchatMemberId(in: realm)
            let chatPrimary = LastChatsStorageItem.genPrimary(
                jid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType
            )
            if let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: chatPrimary),
               let fallbackItem = ChatUnreadMentionFallbackPolicy.fallbackItem(
                mentionId: chat.mentionId,
                chatPrimary: chatPrimary,
                currentMemberId: currentMemberId,
                groupchatJid: self.jid,
                date: chat.messageDate == Date(timeIntervalSince1970: 0) ? Date() : chat.messageDate
               ) {
                self.unreadMentionItems = [fallbackItem]
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            self.unreadMentionItems = []
            self.unreadMentionsState = .empty
            self.currentUnreadMentionNotificationPrimary = nil
        }
    }

    @discardableResult
    internal func installUnreadMentionPresentationMetadataIfNeeded(
        _ metadata: ChatTimelineUnreadMetadata
    ) -> ChatUnreadMentionPresentationMetadata? {
        guard self.conversationType == .group else { return nil }
        let decision =
            ChatUnreadMentionPresentationReconciliationPolicy.decision(
                lastApplied:
                    self.lastAppliedUnreadMentionPresentationMetadata,
                metadata: metadata,
                chatPrimary: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                ),
                groupchatJid: self.jid
            )
        guard case .apply(let next, let items) = decision else {
            return nil
        }
        self.unreadMentionItems = items
        return next
    }

    @discardableResult
    internal func reconcileUnreadMentionPresentationMetadataIfNeeded(
        _ metadata: ChatTimelineUnreadMetadata,
        animated: Bool
    ) -> Bool {
        guard let next = self.installUnreadMentionPresentationMetadataIfNeeded(
            metadata
        ) else {
            return false
        }
        self.applyUnreadMentionsNavigatorState(
            animated: animated,
            preferredArchivedId: next.latestUnreadMentionArchivedId
        )
        self.commitUnreadMentionPresentationMetadata(
            authoritative: metadata
        )
        return true
    }

    internal func refreshUnreadMentionsNavigatorState(animated: Bool = false) {
        self.applyUnreadMentionsNavigatorState(
            animated: animated,
            preferredArchivedId: self.unreadMentionHintArchivedId()
        )
        guard self.conversationType == .group,
              let metadata = self.timelineSession?.snapshot.unreadMetadata else {
            self.lastAppliedUnreadMentionPresentationMetadata = nil
            return
        }
        self.commitUnreadMentionPresentationMetadata(
            authoritative: metadata
        )
    }

    private func commitUnreadMentionPresentationMetadata(
        authoritative metadata: ChatTimelineUnreadMetadata
    ) {
        self.lastAppliedUnreadMentionPresentationMetadata =
            ChatUnreadMentionPresentationCommitPolicy.nextTrackedProjection(
                previous:
                    self.lastAppliedUnreadMentionPresentationMetadata,
                authoritative: metadata,
                appliedMentions: self.unreadMentionItems,
                didApplyNavigatorState: true
            )
    }

    private func applyUnreadMentionsNavigatorState(
        animated: Bool,
        preferredArchivedId: String?
    ) {
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.unreadMentionNavigatorRefreshObserverForTests?()
#endif
        guard !self.showSkeletonObserver.value else {
            self.unreadMentionsState = .empty
            self.currentUnreadMentionNotificationPrimary = nil
            self.scheduleVisibleUnreadMentionReconciliation(notificationPrimaries: [])
            if self.shouldShowUnreadMentionsNavigator.value {
                self.shouldShowUnreadMentionsNavigator.accept(false)
            } else {
                self.updateUnreadMentionsNavigatorFrame(animated: animated)
                self.updateScrollDownButtonFrame(animated: animated)
            }
            return
        }

        let state = ChatUnreadMentionNavigationPolicy.resolveState(
            items: self.unreadMentionItems,
            residentPrimaryPositions: self.timelineSession?.snapshot.residentIndex.primaryIndexByID ?? [:],
            visiblePrimaries: self.visibleRealMessagePrimaries(),
            preferredArchivedId: preferredArchivedId,
            selectedNotificationPrimary: self.currentUnreadMentionNotificationPrimary
        )
        if ChatUnreadMentionBadgeClaimPolicy.shouldClearClaim(
            claimedNotificationPrimary:
                self.claimedUnreadMentionBadgeNotificationPrimary,
            nextJumpNotificationPrimary:
                state.jumpTarget?.notificationPrimary
        ) {
            self.claimedUnreadMentionBadgeNotificationPrimary = nil
        }
        self.unreadMentionsState = state
        self.currentUnreadMentionNotificationPrimary = state.currentTarget?.notificationPrimary
        self.unreadMentionsNavigatorView.update(
            mode: state.mode,
            unreadCount: state.unreadCount,
            accentColor: self.accountPallete.tint500
        )
        // The unread notification owns this candidate. Keep it pending while
        // its linked row is offscreen (including after ordinary read-last has
        // marked that row read); the coordinator alone admits the exact row
        // once it is meaningfully visible in the active presentation.
        self.scheduleVisibleUnreadMentionReconciliation(
            notificationPrimaries:
                ChatUnreadMentionReadCandidateRetentionPolicy
                    .notificationPrimariesToRetain(items: state.items)
        )

        let shouldShowNavigator = ChatUnreadMentionFloatingControlPolicy.shouldShowNavigator(
            conversationType: self.conversationType,
            unreadCount: state.unreadCount,
            isSearchMode: self.inSearchMode.value
        )

        if self.shouldShowUnreadMentionsNavigator.value != shouldShowNavigator {
            self.shouldShowUnreadMentionsNavigator.accept(shouldShowNavigator)
        } else {
            self.updateUnreadMentionsNavigatorFrame(animated: animated)
            self.updateScrollDownButtonFrame(animated: animated)
        }
    }

    internal func scheduleVisibleUnreadMentionReconciliation(
        notificationPrimaries: Set<String>,
        positionedMessagePrimary: String? = nil
    ) {
        self.visibleUnreadMentionReconciliationWorkItem?.cancel()
        self.visibleUnreadMentionReconciliationWorkItem = nil
        self.readVisibleStableLayoutRetryWorkItem?.cancel()
        self.readVisibleStableLayoutRetryWorkItem = nil

        let candidates = notificationPrimaries.compactMap { notificationPrimary ->
            ChatPendingMentionReadCandidate? in
            let messagePrimary = positionedMessagePrimary ??
                self.unreadMentionItems.first(where: {
                    $0.notificationPrimary == notificationPrimary
                })?.messagePrimary
            guard let messagePrimary else {
                return nil
            }
            return ChatPendingMentionReadCandidate(
                notificationPrimary: notificationPrimary,
                messagePrimary: messagePrimary
            )
        }
        self.readVisiblePresentationCoordinator.enqueue(candidates)
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.visibleMentionReadScheduledForTests?(candidates.count)
#endif
        guard self.readVisiblePresentationCoordinator.pendingCandidateCount > 0 else {
            return
        }

        self.schedulePendingVisibleUnreadMentionReconciliation(after: 0.25)
    }

    internal func retryPendingVisibleUnreadMentionReconciliation() {
        guard self.readVisiblePresentationCoordinator.pendingCandidateCount > 0 else {
            return
        }
        self.schedulePendingVisibleUnreadMentionReconciliation(after: 0)
    }

    private func schedulePendingVisibleUnreadMentionReconciliation(
        after delay: TimeInterval
    ) {
        self.visibleUnreadMentionReconciliationWorkItem?.cancel()
        self.readVisibleStableLayoutRetryWorkItem?.cancel()
        self.readVisibleStableLayoutRetryWorkItem = nil
        let expectedGeneration = self.readVisiblePresentationCoordinator.generation

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.readVisiblePresentationCoordinator.generation == expectedGeneration else {
                return
            }
            self.visibleUnreadMentionReconciliationWorkItem = nil
            self.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        }
        self.visibleUnreadMentionReconciliationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    internal func flushPendingVisibleUnreadMentionReconciliationIfPossible() {
        guard self.readVisiblePresentationCoordinator.hasPresentationReceipt else {
            return
        }
        self.synchronizeReadVisibleGeometryEpoch(scheduleStableRetry: false)
        let rowPresentationIdentities =
            self.meaningfullyVisibleRealMessagePresentationIdentitiesForRead()
        guard let flush = self.readVisiblePresentationCoordinator.takeFlush(
            snapshot: self.readVisiblePresentationSnapshot(),
            visibleMessagePrimaries: Set(rowPresentationIdentities.keys),
            rowPresentationIdentityByMessagePrimary: rowPresentationIdentities,
            candidateAdmission: { _ in true }
        ) else {
            return
        }
        self.markVisibleUnreadMentionNotificationsRead(flush)
    }

    private func markVisibleUnreadMentionNotificationsRead(
        _ flush: ChatPendingMentionReadFlush
    ) {
        let notificationPrimaries = flush.notificationPrimaries
        guard notificationPrimaries.isNotEmpty else {
            _ = self.readVisiblePresentationCoordinator.complete(
                flush: flush,
                succeeded: true
            )
            return
        }

        let owner = self.owner
        let jid = self.jid

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }
            var succeeded = false
            var didChangeReadState = false
            do {
                let realm = try WRealm.safe()
                var messagePrimariesToMarkRead: Set<String> = []
                let notificationsToMarkRead = flush.candidates.compactMap { candidate ->
                    NotificationStorageItem? in
                    guard let notification = realm.object(
                            ofType: NotificationStorageItem.self,
                            forPrimaryKey: candidate.notificationPrimary
                          ),
                          notification.owner == owner,
                          !notification.isRead,
                          notification.isMentionNotification,
                          notification.sourceChatJid == jid,
                          notification.sourceConversationType == nil ||
                            notification.sourceConversationType == .group else {
                        return nil
                    }
                    return notification
                }

#if DEBUG || CHAT_PERFORMANCE_LAB
                self.visibleMentionReadCommitBarrierForTests?()
#endif
                let claimAdmission: (
                    geometryIsCurrent: Bool,
                    permitClaimed: Bool
                ) = {
                    let admitOnMain = { () -> (
                        geometryIsCurrent: Bool,
                        permitClaimed: Bool
                    ) in
                        guard self.canClaimMentionReadMutationPermit(
                            for: flush
                        ) else {
                            _ = self.readVisiblePresentationCoordinator
                                .invalidateUnstartedFlushesForGeometryChange()
                            return (false, false)
                        }
                        return (
                            true,
                            self.readVisiblePresentationCoordinator
                                .claimCurrentMutationPermit(for: flush)
                        )
                    }
                    if Thread.isMainThread {
                        return admitOnMain()
                    }
                    return DispatchQueue.main.sync(execute: admitOnMain)
                }()
                guard claimAdmission.geometryIsCurrent,
                      claimAdmission.permitClaimed else {
#if DEBUG || CHAT_PERFORMANCE_LAB
                    self.visibleMentionReadTerminalForTests?(false)
#endif
                    return
                }

#if DEBUG || CHAT_PERFORMANCE_LAB
                self.visibleMentionReadPostClaimBarrierForTests?()
#endif

                if !notificationsToMarkRead.isEmpty {
                    try realm.write {
                        let currentNotificationsToMarkRead =
                            notificationsToMarkRead.filter { notification in
                                !notification.isInvalidated &&
                                notification.owner == owner &&
                                !notification.isRead &&
                                notification.isMentionNotification &&
                                notification.sourceChatJid == jid &&
                                (notification.sourceConversationType == nil ||
                                    notification.sourceConversationType == .group)
                            }
                        guard let firstNotification =
                                currentNotificationsToMarkRead.first else {
                            return
                        }
                        guard self.readVisiblePresentationCoordinator
                            .performFirstPersistentMutationIfPermitted(
                                for: flush,
                                { firstNotification.isRead = true }
                            ) else {
                            throw ChatVisibleMentionReadMutationError
                                .permitRevokedBeforeFirstPersistentMutation
                        }
                        didChangeReadState = true

#if DEBUG || CHAT_PERFORMANCE_LAB
                        self.visibleMentionReadAfterFirstPersistentMutationBarrierForTests?()
#endif

                        let result = MentionNotificationSync.reconcile(
                            notification: firstNotification,
                            in: realm
                        )
                        if let messagePrimary = result.linkedMessagePrimaryToMarkRead,
                           messagePrimary.isNotEmpty {
                            messagePrimariesToMarkRead.insert(messagePrimary)
                        }

                        currentNotificationsToMarkRead.dropFirst().forEach { notification in
                            notification.isRead = true
                            let result = MentionNotificationSync.reconcile(
                                notification: notification,
                                in: realm
                            )
                            if let messagePrimary = result.linkedMessagePrimaryToMarkRead,
                               messagePrimary.isNotEmpty {
                                messagePrimariesToMarkRead.insert(messagePrimary)
                            }
                        }

                        MentionNotificationSync.refreshLastChatMentionIds(
                            owner: owner,
                            groupchatJids: [jid],
                            in: realm
                        )
                    }
                }
                succeeded = true

                if didChangeReadState {
                    messagePrimariesToMarkRead.forEach {
#if DEBUG || CHAT_PERFORMANCE_LAB
                        self.visibleMentionReadMessageWillExecuteForTests?($0)
#endif
                        AccountManager.shared.find(for: owner)?
                            .messages.readMessage($0, last: false)
                    }
                }
            } catch ChatVisibleMentionReadMutationError
                .permitRevokedBeforeFirstPersistentMutation {
#if DEBUG || CHAT_PERFORMANCE_LAB
                self.visibleMentionReadTerminalForTests?(false)
#endif
                return
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                let acceptedForCurrentPresentation =
                    self.readVisiblePresentationCoordinator.complete(
                        flush: flush,
                        succeeded: succeeded
                    )
                guard acceptedForCurrentPresentation else {
                    if !succeeded,
                       self.readVisiblePresentationCoordinator.hasPresentationReceipt,
                       self.readVisiblePresentationCoordinator.pendingCandidateCount > 0 {
#if DEBUG || CHAT_PERFORMANCE_LAB
                        self.visibleMentionReadRetryForTests?()
#endif
                        self.schedulePendingVisibleUnreadMentionReconciliation(
                            after: 0.5
                        )
                    }
#if DEBUG || CHAT_PERFORMANCE_LAB
                    self.visibleMentionReadTerminalForTests?(
                        succeeded && didChangeReadState
                    )
#endif
                    return
                }
                if succeeded && didChangeReadState {
#if DEBUG || CHAT_PERFORMANCE_LAB
                    self.visibleMentionReadUIRefreshForTests?()
#endif
                    self.rebuildUnreadMentionItems()
                    self.refreshUnreadMentionsNavigatorState(animated: true)
                } else if !succeeded {
#if DEBUG || CHAT_PERFORMANCE_LAB
                    self.visibleMentionReadRetryForTests?()
#endif
                    self.schedulePendingVisibleUnreadMentionReconciliation(
                        after: 0.5
                    )
                }
#if DEBUG || CHAT_PERFORMANCE_LAB
                self.visibleMentionReadTerminalForTests?(succeeded)
#endif
            }
        }
    }

    internal func pagingBoundaryContext(visibleSections: [Int]) -> ChatHistoryPagingBoundaryContext {
        self.scrollResidentMetadata.boundaryContext(visibleSections: visibleSections)
    }

    /// Captures the first or last visible real row for an atomic engine apply.
    internal func capturePagingAnchorIfNeeded(direction: ChatHistoryPageDirection) -> ChatHistoryPageAnchor? {
        let candidateSections = self.messagesCollectionView
            .indexPathsForVisibleItems
            .compactMap(\.section)
            .sorted()
            .filter {
                guard let item = self.datasourceItem(atSection: $0) else {
                    return false
                }
                return !item.isFakeMessage
            }

        let anchorSection: Int?
        switch direction {
        case .older:
            anchorSection = candidateSections.min()
        case .newer:
            let normalizedState = self.virtualTimelineState.normalized(
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            let shouldCapture = ChatHistoryPageAnchorCapturePolicy.shouldCaptureNewerAnchor(
                isNearBottom: self.isNearBottom(),
                isResidentAtLiveTail: normalizedState.isResidentAtLiveTail
            )
            anchorSection = shouldCapture ? candidateSections.max() : nil
        }

        guard let section = anchorSection else {
            return nil
        }

        let indexPath = IndexPath(item: 0, section: section)
        let attributes = self.messagesCollectionView.layoutAttributesForItem(at: indexPath)
        let frame = attributes?.frame ?? self.messagesCollectionView.cellForItem(at: indexPath)?.frame

        guard let frame else {
            return nil
        }

        guard let item = self.datasourceItem(atSection: section) else {
            return nil
        }

        return ChatHistoryPageAnchor(
            primary: item.primary,
            viewportRelativeMinY: frame.minY - self.messagesCollectionView.contentOffset.y
        )
    }

    private func restorePagingAnchorAndCollectDiagnostics(_ anchor: ChatHistoryPageAnchor) -> ChatHistoryPageAnchorRestoreDiagnostics {
        var diagnostics = ChatHistoryPageAnchorRestoreDiagnostics()
        guard let section = self.datasourceSnapshot.primaryIndex[anchor.primary] else {
            return diagnostics
        }
        diagnostics.sectionFound = true

        let indexPath = IndexPath(item: 0, section: section)
        self.messagesCollectionView.layoutIfNeeded()

        let attributes = self.messagesCollectionView.layoutAttributesForItem(at: indexPath)
        let frame = attributes?.frame ?? self.messagesCollectionView.cellForItem(at: indexPath)?.frame
        diagnostics.attributesFound = frame != nil

        guard let frame else {
            return diagnostics
        }

        let minOffsetY = -self.messagesCollectionView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            self.messagesCollectionView.contentSize.height -
            self.messagesCollectionView.bounds.height +
            self.messagesCollectionView.adjustedContentInset.bottom
        )
        let targetY = ChatHistoryPageAnchorRestorePolicy.targetContentOffsetY(
            anchorMinY: frame.minY,
            viewportRelativeMinY: anchor.viewportRelativeMinY,
            minContentOffsetY: minOffsetY,
            maxContentOffsetY: maxOffsetY
        )
        diagnostics.targetOffsetY = targetY

        self.messagesCollectionView.setContentOffset(
            CGPoint(
                x: self.messagesCollectionView.contentOffset.x,
                y: targetY
            ),
            animated: false
        )
        diagnostics.restored = true
        return diagnostics
    }

    internal func restorePagingAnchor(_ anchor: ChatHistoryPageAnchor) {
        let diagnostics = self.restorePagingAnchorAndCollectDiagnostics(anchor)
        ChatArchiveDebugTrace.log("chatDatasourceAnchorRestore", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("phase", ChatHistoryPageAnchorRestorePhase.applyTransaction.rawValue),
            ("anchorPrimary", anchor.primary),
            ("sectionFound", diagnostics.sectionFound),
            ("attributesFound", diagnostics.attributesFound),
            ("restored", diagnostics.restored),
            ("targetOffsetY", Int(diagnostics.targetOffsetY ?? self.messagesCollectionView.contentOffset.y)),
            ("finalOffsetY", Int(self.messagesCollectionView.contentOffset.y)),
            ("contentHeight", Int(self.messagesCollectionView.contentSize.height)),
            ("insetTop", Int(self.messagesCollectionView.adjustedContentInset.top)),
            ("insetBottom", Int(self.messagesCollectionView.adjustedContentInset.bottom))
        ])
    }

    private func invalidateEditedMessageLayoutCache(primaries: [String]) {
        guard primaries.isNotEmpty,
              let layout = self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout else {
            return
        }
        primaries.forEach {
            layout.invalidateLastMessageCachedSize(primary: $0)
        }
    }

    private static func messageIndicator(
        for state: MessageStorageItem.MessageSendingState,
        showsDeliveryIndicator: Bool
    ) -> IndicatorType {
        guard showsDeliveryIndicator else {
            return .none
        }

        switch state {
        case .sended:
            return .sended
        case .deliver:
            return .received
        case .read:
            return .read
        case .error:
            return .error
        case .none:
            return .none
        case .notSended:
            return .error
        case .sending, .uploading:
            return .sending
        }
    }

    /// Compatibility helper for focused mapping tests. Production mapping paths
    /// capture the context on main and execute the result, including layout
    /// prewarming, on `datasetMappingQueue`.
    internal final func mapDataset(dataset: Array<MessageStorageItem>) -> [Datasource] {
        mapDataset(
            dataset: dataset,
            context: captureDatasourceMappingContext()
        ).datasource
    }

    internal final func beginDatasetMappingJob() -> (
        generation: Int,
        token: ChatDatasetMappingCancellationToken
    ) {
        self.datasetMappingGeneration += 1
        self.collectionPrefetchCoordinator.cancelAll()
        let generation = self.datasetMappingGeneration
        return (
            generation,
            self.datasetMappingJobCoordinator.begin(generation: generation)
        )
    }

    internal final func beginDatasetMappingJobForTesting() -> ChatDatasetMappingCancellationToken {
        beginDatasetMappingJob().token
    }

    internal final func cancelDatasetMappingJobs() {
        self.datasetMappingGeneration += 1
        self.datasetMappingJobCoordinator.cancelAll()
    }

    internal final func mapDataset(
        dataset: Array<MessageStorageItem>,
        context: ChatDatasourceMappingContext,
        cancellationToken: ChatDatasetMappingCancellationToken? = nil,
        performanceTraceContext: ChatOpenPerformanceTraceContext? = nil
    ) -> ChatDatasourceMappingResult {
        var mapSignpost = ChatPerformanceSignposts.begin(
            .mapDataset,
            context: performanceTraceContext
        )
        defer {
            mapSignpost.end()
        }
        let formatters = ChatDatasourceMappingDateFormatters()

        var out: [Datasource] = []
        var editedMessagePrimariesNeedingLayoutInvalidation: [String] = []

        func appendDateSeparatorIfNeeded(before item: MessageStorageItem, at offset: Int) {
            guard offset == 0 || self.isDateChange(from: dataset[offset - 1].sentDate, to: item.sentDate) else {
                return
            }
            let kind: MessageKind = .date(
                NSAttributedString(
                    string: formatters.sectionDateFormatter.string(from: item.sentDate),
                    attributes: context.dateSeparatorAttributes
                )
            )
            out.append(Datasource(
                primary: "\(item.primary) date changed",
                jid: context.jid,
                owner: context.owner,
                outgoing: item.outgoing,
                sender: item.outgoing ? context.ownerSender : context.opponentSender,
                messageId: item.messageId,
                sentDate: item.date,
                editDate: nil,
                kind: kind,
                withAuthor: false,
                withAvatar: false,
                error: item.state == .error,
                errorType: "",
                canPinMessage: false,
                canEditMessage: false,
                canDeleteMessage: false,
                forwards: [],
                isOutgoing: item.outgoing,
                isEdited: false,
                groupchatAuthorRole: "",
                groupchatAuthorId: "",
                groupchatAuthorNickname: "",
                groupchatAuthorBadge: "",
                isHasAttachedMessages: false,
                isDownloaded: true,
                state: .none,
                searchString:  "",
                errorMetadata: nil,
                burnDate: 0,
                afterburnInterval: 0,
                archivedId: "\(item.archivedId) date changed",
                queryIds: "\(item.queryIds ?? "") date changed",
                isRead: ChatDateSeparatorPresentationPolicy.isRead,
                selectedSearchResultId: nil,
                isHadHistoryGap: false,
                isFakeMessage: true,
                images: [],
                videos: [],
                files: [],
                audios: [],
                timeMarkerText: NSAttributedString(),
                indicator: .none,
                avatarUrl: nil
            ))
        }

        var displayModelPassCache: [String: ChatCachedDisplayModel] = [:]
        func displayModel(for item: MessageStorageItem) -> ChatCachedDisplayModel {
            if let cached = displayModelPassCache[item.primary] {
                return cached
            }
            let model = self.cachedDisplayModel(
                for: item,
                context: context,
                formatters: formatters
            )
            displayModelPassCache[item.primary] = model
            return model
        }

        func displaySnapshot(for item: MessageStorageItem) -> ChatMessageDisplaySnapshot {
            guard let snapshot = displayModel(for: item).displaySnapshot else {
                preconditionFailure("Production display cache entries must carry their immutable rich snapshot")
            }
            return snapshot
        }

        func nonEmptyGroupAuthorValue(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  value.isNotEmpty else {
                return nil
            }
            return value
        }

        func groupAuthorKey(for snapshot: ChatMessageDisplaySnapshot) -> String {
            if let authorId = nonEmptyGroupAuthorValue(snapshot.presentation.groupchatAuthorId) {
                return "id:\(authorId)"
            }
            if let authorJid = nonEmptyGroupAuthorValue(snapshot.groupchatMetadata?["jid"] as? String) {
                return "jid:\(authorJid.lowercased())"
            }
            if let nickname = nonEmptyGroupAuthorValue(snapshot.presentation.groupchatAuthorNickname) {
                return "nickname:\(nickname)"
            }
            return "unknown:\(snapshot.primary)"
        }

        func isSameIncomingGroupAuthor(
            _ lhs: ChatMessageDisplaySnapshot,
            _ rhs: ChatMessageDisplaySnapshot
        ) -> Bool {
            guard !lhs.presentation.displayOutgoing,
                  !rhs.presentation.displayOutgoing else {
                return false
            }
            return groupAuthorKey(for: lhs) == groupAuthorKey(for: rhs)
        }

        for (offset, item) in dataset.enumerated() {
            guard cancellationToken?.shouldProcessNextRow() ?? true else { break }
            appendDateSeparatorIfNeeded(before: item, at: offset)
//            let references = Array(item.references.toArray().compactMap { $0.loadModel() })
//            let inlineForwards = Array(item.inlineForwards.sorted(byKeyPath: "originalDate", ascending: true).toArray().compactMap { $0.loadModel() })

            let cachedDisplayModel = displayModel(for: item)
            guard let snapshot = cachedDisplayModel.displaySnapshot else {
                continue
            }
            let presentation = snapshot.presentation
            let displaySender = presentation.isSavedMessage
                ? Sender(id: presentation.displayAuthorJid, displayName: presentation.displayAuthorName)
                : (snapshot.outgoing ? context.ownerSender : context.opponentSender)
            let kind = cachedDisplayModel.kind
            let isDownloaded = cachedDisplayModel.isDownloaded

            var withAuthor: Bool = false
            var withAvatar: Bool = false
            var reservesAvatarSpace: Bool = false
            var tailed: Bool = true
            let date = presentation.visibleDate
            let prevMessage = offset - 1
            let nextMessage = offset + 1

            if context.avatarVerticalPosition == "top" {
                if prevMessage >= 0 {
                    let prevItem = dataset[prevMessage]
                    let prevSnapshot = displaySnapshot(for: prevItem)
                    let prevPresentation = prevSnapshot.presentation
                    if context.conversationType == .group {
                        tailed = !isSameIncomingGroupAuthor(prevSnapshot, snapshot)

                    } else {
                        tailed = !(presentation.displayOutgoing == prevPresentation.displayOutgoing)
                    }
                    if isDateChange(from: presentation.visibleDate, to: prevPresentation.visibleDate) {
                        tailed = true
                    }
                }
            }
            if prevMessage >= 0 {
                let prevItem = dataset[prevMessage]
                let prevSnapshot = displaySnapshot(for: prevItem)
                let prevPresentation = prevSnapshot.presentation
                if context.conversationType == .group {
                    withAuthor = !isSameIncomingGroupAuthor(prevSnapshot, snapshot)
                    if isDateChange(from: presentation.visibleDate, to: prevPresentation.visibleDate) {
                        withAuthor = true
                    }
                }
            } else if context.conversationType == .group {
                withAuthor = true
            }

            if nextMessage < dataset.count {
                let nextItem = dataset[nextMessage]
                let nextSnapshot = displaySnapshot(for: nextItem)
                let nextPresentation = nextSnapshot.presentation

                if context.conversationType == .group {
                    let isSameNextAuthor = isSameIncomingGroupAuthor(snapshot, nextSnapshot)
                    withAvatar = !isSameNextAuthor
                    if context.avatarVerticalPosition == "bottom" {
                        tailed = !isSameNextAuthor
                    }
                    if isDateChange(from: presentation.visibleDate, to: nextPresentation.visibleDate) {
                        withAvatar = true
                        if context.avatarVerticalPosition == "bottom" {
                            tailed = true
                        }
                    }
                } else if context.avatarVerticalPosition == "bottom" {
                    tailed = !(presentation.displayOutgoing == nextPresentation.displayOutgoing)
                    if isDateChange(from: presentation.visibleDate, to: nextPresentation.visibleDate) {
                        tailed = true
                    }
                }
            } else if context.conversationType == .group {
                withAvatar = true
            }
            var attributedAuthor: NSAttributedString? = nil
            if presentation.isSavedForward {
                withAuthor = !presentation.displayOutgoing
                withAvatar = !presentation.displayOutgoing
                attributedAuthor = withAuthor ? snapshot.attributedAuthor() : nil
            } else if withAuthor && !presentation.displayOutgoing {
                attributedAuthor = snapshot.attributedAuthor()
            }

            if snapshot.editDate != nil {
                editedMessagePrimariesNeedingLayoutInvalidation.append(snapshot.primary)
            }
            var searchString: String? = nil

            if context.inSearchMode,
               snapshot.displayAs == .text,
               let str = context.searchText,
               str.isNotEmpty,
               ChatAttributedBodyFormatter.containsMatch(
                    in: presentation.visibleBody,
                    query: str
               ) {
                searchString = str
            }


            let mappedReferences = cachedDisplayModel.mappedReferences
            let forwards = cachedDisplayModel.forwards
            let statePresentation = snapshot.statePresentation(
                currentUserJid: context.owner,
                state: item.state,
                archivedId: item.archivedId
            )
            let effectiveState = statePresentation.effectiveState
            let indicator = Self.messageIndicator(
                for: effectiveState,
                showsDeliveryIndicator: statePresentation.showsDeliveryIndicator
            )
            let timeMarkerString = cachedDisplayModel.timeMarkerText
            if presentation.displayOutgoing {
                withAuthor = false
                if presentation.isSavedMessage || context.conversationType == .group {
                    withAvatar = false
                }
            }
            reservesAvatarSpace = withAvatar
            if context.conversationType == .group {
                reservesAvatarSpace = !presentation.displayOutgoing
            }
            out.append(Datasource(
                primary: snapshot.primary,
                jid: context.jid,
                owner: context.owner,
                outgoing: presentation.displayOutgoing,
                sender: displaySender,
                messageId: snapshot.messageId,
                sentDate: date,
                editDate: snapshot.editDate,
                kind: kind,
                withAuthor: withAuthor,
                withAvatar: withAvatar,
                reservesAvatarSpace: reservesAvatarSpace,
                error: effectiveState == .error,
                errorType: item.messageError ?? "",
                canPinMessage: [.system, .sticker].contains(snapshot.displayAs) ? false : context.canPinMessages,
                canEditMessage: item.archivedId.isNotEmpty ? snapshot.displayAs == .text && presentation.displayOutgoing : false,
                canDeleteMessage: [MessageStorageItem.MessageSendingState.deliver, MessageStorageItem.MessageSendingState.read].contains(effectiveState),
                forwards: forwards,
                isOutgoing: presentation.displayOutgoing,
                isEdited: snapshot.editDate != nil,
                groupchatAuthorRole: presentation.groupchatAuthorRole,
                groupchatAuthorId: presentation.groupchatAuthorId,
                groupchatAuthorNickname: presentation.groupchatAuthorNickname,
                groupchatAuthorBadge: presentation.groupchatAuthorBadge,
                isHasAttachedMessages: snapshot.isHasAttachedMessages,
                isDownloaded: isDownloaded,
                state: snapshot.displayAs == .call ? .none : effectiveState,
                searchString:  searchString,
                errorMetadata: item.errorMetadata,
                messageWarningText: snapshot.messageWarningText,
                burnDate: snapshot.burnDate,
                afterburnInterval: snapshot.afterburnInterval,
                archivedId: item.archivedId,
                queryIds: item.queryIds,
                isRead: item.isRead,
                selectedSearchResultId: nil,//item.archivedId == self.selectedSearchResultId ? self.selectedSearchResultId : nil,
                isHadHistoryGap: false,
                tailed: tailed,
                images: mappedReferences.images,
                videos: mappedReferences.videos,
                locations: mappedReferences.locations,
                contacts: mappedReferences.contacts,
                files: mappedReferences.files,
                audios: mappedReferences.audio,
                timeMarkerText: timeMarkerString,
                indicator: indicator,
                avatarUrl: withAvatar ? presentation.displayAvatarSource : nil,
                attributedAuthor: attributedAuthor
            ))
        }
        if cancellationToken?.isCancelled == true {
            return ChatDatasourceMappingResult(
                datasource: out,
                editedMessagePrimariesNeedingLayoutInvalidation: editedMessagePrimariesNeedingLayoutInvalidation,
                layoutSnapshot: context.layoutReuseSnapshot,
                wasCancelled: true
            )
        }
        let layoutSnapshot = ChatMessageLayoutPrewarmer.prewarm(
            items: out,
            context: context.layoutContext,
            reuse: context.layoutReuseSnapshot,
            capacity: context.layoutCacheCapacity,
            operationCounter: context.layoutOperationCounter,
            shouldContinue: { cancellationToken?.isCancelled != true }
        )
        if cancellationToken?.isCancelled == true {
            return ChatDatasourceMappingResult(
                datasource: out,
                editedMessagePrimariesNeedingLayoutInvalidation: editedMessagePrimariesNeedingLayoutInvalidation,
                layoutSnapshot: context.layoutReuseSnapshot,
                wasCancelled: true
            )
        }
        return ChatDatasourceMappingResult(
            datasource: out,
            editedMessagePrimariesNeedingLayoutInvalidation: editedMessagePrimariesNeedingLayoutInvalidation,
            layoutSnapshot: layoutSnapshot
        )
    }

    private final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexSet {
        let inserts = IndexSet(changes.compactMap({ return $0.insert?.index }))
        let deletes = IndexSet(changes.compactMap({ return $0.delete?.index }))
        let replaces = IndexSet(changes.compactMap({ return $0.replace?.index }))
        let moves = changes.compactMap({ $0.move }).map({
          (
            from: IndexPath(item: 0, section: $0.fromIndex),
            to: IndexPath(item: 0, section: $0.toIndex)
          )
        })

        return ChangesWithIndexSet(
            inserts: inserts,
            deletes: deletes,
            replaces: replaces,
            moves: moves
        )
    }

    internal func currentScrollMotionState() -> ChatScrollMotionState {
        if self.messagesCollectionView.isDecelerating {
            return .decelerating
        }
        if self.messagesCollectionView.isDragging {
            return .dragging
        }
        if self.messagesCollectionView.isTracking {
            return .tracking
        }
        return .resting
    }

    internal final func loadInitialDatasource(
        performPendingOpenMessageRequest: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        _ = performPendingOpenMessageRequest
        self.startArchiveEnginePresentationIfNeeded()
        completion?()
    }

    internal func scrollToLastOrUnreadItem() {
        if ChatInitialScrollPolicy.shouldDeferDefaultScroll(
            hasPendingAnchorRequest: self.pendingOpenMessageRequest != nil,
            isAnchorNavigationInFlight: self.isMessageAnchorNavigationInFlight
        ) {
            self.performPendingOpenMessageRequestIfNeeded()
            return
        }
        let shouldAnimateScroll = true

        if ChatOpenMessageRequestHandlingPolicy.shouldForceLatestOnOpen() {
            self.requestForceLatestOpen(animated: shouldAnimateScroll)
            return
        }

        self.scrollToLatestTimeline(animated: shouldAnimateScroll)
    }
}
