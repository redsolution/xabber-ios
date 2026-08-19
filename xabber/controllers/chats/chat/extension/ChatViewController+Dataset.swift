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
        return URL(string: videoPreviewURLRaw)
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
        guard let raw else { return nil }
        return URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
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
    case bootstrapSkeleton

    var rendersBootstrapSkeleton: Bool {
        self == .bootstrapSkeleton
    }
}

struct ChatDatasourceMappingContext {
    let owner: String
    let jid: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let ownerSender: Sender
    let opponentSender: Sender
    let purpose: ChatDatasourceMappingPurpose
    let skeletonDescriptors: [ChatSkeletonDescriptor]
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

struct ChatBoundedTimelineWindowState: Equatable {
    static let empty = ChatBoundedTimelineWindowState(
        oldest: nil,
        newest: nil,
        residentPrimaryKeys: [],
        residentArchivedIds: [],
        activePlaceholder: nil,
        isPagingLocked: false
    )

    let oldest: ChatTimelineBoundary?
    let newest: ChatTimelineBoundary?
    let residentPrimaryKeys: [String]
    let residentArchivedIds: [String]
    let activePlaceholder: ChatHistoryBoundaryPlaceholderPosition?
    let isPagingLocked: Bool

    var isEmpty: Bool {
        residentPrimaryKeys.isEmpty
    }

    init(
        oldest: ChatTimelineBoundary?,
        newest: ChatTimelineBoundary?,
        residentPrimaryKeys: [String],
        residentArchivedIds: [String],
        activePlaceholder: ChatHistoryBoundaryPlaceholderPosition?,
        isPagingLocked: Bool
    ) {
        self.oldest = oldest
        self.newest = newest
        self.residentPrimaryKeys = residentPrimaryKeys
        self.residentArchivedIds = residentArchivedIds
        self.activePlaceholder = activePlaceholder
        self.isPagingLocked = isPagingLocked
    }

    init(
        items: [MessageStorageItem],
        activePlaceholder: ChatHistoryBoundaryPlaceholderPosition? = nil,
        isPagingLocked: Bool = false
    ) {
        let archiveIds = items.compactMap {
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId($0.archivedId)
        }
        self.init(
            oldest: items.first.map(ChatTimelineBoundary.init(message:)),
            newest: items.last.map(ChatTimelineBoundary.init(message:)),
            residentPrimaryKeys: items.map(\.primary),
            residentArchivedIds: archiveIds,
            activePlaceholder: activePlaceholder,
            isPagingLocked: isPagingLocked
        )
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
            ChatInitialFirstFrameHistoryConfiguration.pageSize
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
            ChatInitialFirstFrameHistoryConfiguration.pageSize
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

    func messageWindow(
        primary: String?,
        archivedId: String?,
        messageId: String?,
        before: Int,
        after: Int
    ) -> ChatTimelineInitialFrameWindow? {
        exactInitialFrameWindow(
            operation: "messageWindow",
            before: before,
            after: after,
            resolveTarget: { [self] in
                resolvedMessage(
                    primary: primary,
                    archivedId: archivedId,
                    messageId: messageId
                )
            }
        )
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
            ChatInitialFirstFrameHistoryConfiguration.pageSize
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

    func firstIncomingWindow(
        afterArchiveBoundaryId boundaryArchivedId: String,
        before: Int,
        after: Int
    ) -> ChatTimelineInitialFrameWindow? {
        guard let boundaryDate = ChatInitialPositionPolicy.archiveDate(
            from: boundaryArchivedId
        ) else {
            return nil
        }
        let boundary = ChatTimelineBoundary(
            primary: boundaryArchivedId,
            archivedId: boundaryArchivedId,
            messageId: nil,
            date: boundaryDate
        )
        return exactInitialFrameWindow(
            operation: "firstIncomingWindow",
            before: before,
            after: after,
            resolveTarget: { [self] in
                baseQuery()
                    .filter(Self.cursorPredicate(after: boundary))
                    .filter("outgoing == false")
                    .sorted(by: Self.sortDescriptors(ascending: true))
                    .first
            }
        )
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

    /// Resolves one target and materializes its exact bounded first-frame
    /// context inside one measured provider operation. The initial-frame
    /// session consumes this closed result from memory, so it cannot repeat a
    /// target, older, or newer Realm lookup while opening around the anchor.
    private func exactInitialFrameWindow(
        operation: String,
        before: Int,
        after: Int,
        resolveTarget: () -> MessageStorageItem?
    ) -> ChatTimelineInitialFrameWindow? {
        let maximumCount = ChatInitialFirstFrameHistoryConfiguration.pageSize
        let boundedBefore = min(max(0, before), max(0, maximumCount - 1))
        let boundedAfter = min(
            max(0, after),
            max(0, maximumCount - boundedBefore - 1)
        )
        return ChatPerformanceSignposts.measure(.localHistoryQuery) {
            () -> ChatTimelineInitialFrameWindow? in
            guard !isCancelled(),
                  let target = resolveTarget(),
                  target.owner == owner,
                  target.opponent == jid,
                  target.conversationType == conversationType,
                  !target.isDeleted else {
                diagnostics?.record(operation: operation, candidateCount: 0)
                return nil
            }

            let targetBoundary = ChatTimelineBoundary(message: target)
            let olderItems: [MessageStorageItem]
            if boundedBefore > 0 {
                olderItems = Array(
                    baseQuery()
                        .filter(Self.cursorPredicate(before: targetBoundary))
                        .sorted(by: Self.sortDescriptors(ascending: false))
                        .prefix(boundedBefore)
                )
            } else {
                olderItems = []
            }
            guard !isCancelled() else { return nil }

            let newerItems: [MessageStorageItem]
            if boundedAfter > 0 {
                newerItems = Array(
                    baseQuery()
                        .filter(Self.cursorPredicate(after: targetBoundary))
                        .sorted(by: Self.sortDescriptors(ascending: true))
                        .prefix(boundedAfter)
                )
            } else {
                newerItems = []
            }
            guard !isCancelled() else { return nil }

            let candidates = olderItems + [target] + newerItems
            let materializedCandidateCount = candidates.count
            let targetIdentityKeys = Set(
                ChatTimelineMessageIdentity.keys(for: target)
            )
            let targetRetainingCandidates = candidates.filter { candidate in
                candidate.primary == target.primary ||
                    targetIdentityKeys.isDisjoint(
                        with: ChatTimelineMessageIdentity.keys(for: candidate)
                    )
            }
            let items = Self.deduplicatedChronologicalItems(
                targetRetainingCandidates
            )
            diagnostics?.record(
                operation: operation,
                candidateCount: materializedCandidateCount
            )
            guard items.contains(where: { $0.primary == target.primary }) else {
                return nil
            }
            return ChatTimelineInitialFrameWindow(
                target: target,
                items: items,
                materializedCandidateCount: materializedCandidateCount
            )
        }
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

enum ChatHistoryBoundaryPlaceholderPosition: Equatable {
    case top
    case bottom
}

enum ChatHistoryPagingLoadDecision: Equatable {
    case localOnly
    case remoteOlderPage
    case remoteNewerPage
    case remoteGapRepairOlder(RegularChatArchiveGap)
    case remoteGapRepairNewer(RegularChatArchiveGap)
    case endReached
}

enum ChatInteractiveHistoryPagingPlan: Equatable {
    case local
    case remote(ChatHistoryPagingLoadDecision)
    case endReached
    case noOp

    var shouldShowOverlay: Bool {
        if case .remote = self {
            return true
        }
        return false
    }

    var shouldShowBoundaryPlaceholder: Bool {
        shouldShowOverlay
    }

    var shouldCreateRemoteContext: Bool {
        shouldShowOverlay
    }
}

enum ChatInteractiveHistoryPagingPlanPolicy {
    static func plan(for decision: ChatHistoryPagingLoadDecision?) -> ChatInteractiveHistoryPagingPlan {
        guard let decision else {
            return .noOp
        }

        switch decision {
        case .localOnly:
            return .local
        case .remoteOlderPage,
             .remoteNewerPage,
             .remoteGapRepairOlder,
             .remoteGapRepairNewer:
            return .remote(decision)
        case .endReached:
            return .endReached
        }
    }
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

enum ChatBoundaryPagingExecutionAction: Equatable {
    case applyNow(ChatHistoryPageDirection)
    case prepareLocal(ChatHistoryPageDirection)
    case deferRemote(ChatHistoryPageDirection)
    case none

    var diagnosticName: String {
        switch self {
        case .applyNow:
            return "applyNow"
        case .prepareLocal:
            return "prepareLocal"
        case .deferRemote:
            return "deferRemote"
        case .none:
            return "none"
        }
    }
}

enum ChatBoundaryPagingExecutionPolicy {
    static func action(
        direction: ChatHistoryPageDirection,
        pagingPlan: ChatInteractiveHistoryPagingPlan,
        motionState: ChatScrollMotionState
    ) -> ChatBoundaryPagingExecutionAction {
        switch pagingPlan {
        case .local:
            return motionState.isMoving ? .prepareLocal(direction) : .applyNow(direction)
        case .remote:
            return motionState.isMoving ? .deferRemote(direction) : .applyNow(direction)
        case .endReached, .noOp:
            return .none
        }
    }
}

struct ChatPreparedLocalHistoryPage {
    let preparedPage: ChatTimelinePreparedLocalPage
    let baseVirtualState: ChatVirtualTimelineState
    let baseWindow: ChatDatasetWindow
    let boundaryVisibilityRequirement:
        ChatBoundaryPagingVisibilityRequirement

    var id: String { preparedPage.id }
    var direction: ChatHistoryPageDirection { preparedPage.direction }
    var conversationKey: ChatTimelineConversationKey { preparedPage.conversationKey }
    var snapshot: ChatTimelineSnapshot { preparedPage.snapshot }
}

enum ChatBoundaryPagingVisibilityRequirement: Equatable {
    case visibleBoundary
    case explicitFixtureAction
}

struct ChatLocalHistoryPagingIntent {
    let id: String
    let direction: ChatHistoryPageDirection
    let conversationKey: ChatTimelineConversationKey
    let baseGeneration: UInt64
    let baseVirtualState: ChatVirtualTimelineState
    let currentWindow: ChatDatasetWindow
    let requestedWindow: ChatDatasetWindow
    let deferUntilScrollRest: Bool
    let boundaryVisibilityRequirement:
        ChatBoundaryPagingVisibilityRequirement
}

struct ChatInteractiveHistoryPagingPreparation {
    let direction: ChatHistoryPageDirection
    let currentWindow: ChatDatasetWindow
    let requestedWindow: ChatDatasetWindow
    let archiveState: ChatArchiveStateSnapshot
    let virtualArchiveState: ChatArchiveStateSnapshot
    let preparedPage: ChatTimelinePreparedLocalPage
    let pagingPlan: ChatInteractiveHistoryPagingPlan
    let boundaryVisibilityRequirement:
        ChatBoundaryPagingVisibilityRequirement

    var snapshot: ChatTimelineSnapshot { preparedPage.snapshot }
}

enum ChatPendingBoundaryPagingValidationPolicy {
    static func shouldProceed(
        visibilityRequirement: ChatBoundaryPagingVisibilityRequirement,
        direction: ChatHistoryPageDirection,
        boundaryContext: ChatHistoryPagingBoundaryContext
    ) -> Bool {
        guard visibilityRequirement == .visibleBoundary else {
            return true
        }
        switch direction {
        case .older:
            guard let firstRealSection = boundaryContext.firstRealSection else {
                return false
            }
            return boundaryContext.visibleRealSections.contains(firstRealSection)
        case .newer:
            guard let lastRealSection = boundaryContext.lastRealSection else {
                return false
            }
            return boundaryContext.visibleRealSections.contains(lastRealSection)
        }
    }
}

enum ChatShortLocalOlderRemainderPolicy {
    static func shouldRequestRemoteFirst(
        localOlderCount: Int,
        pageSize: Int,
        archiveEnded: Bool
    ) -> Bool {
        guard localOlderCount > 0,
              !archiveEnded else {
            return false
        }
        return localOlderCount < max(1, pageSize)
    }
}

enum ChatHistoryLoadingOverlayPolicy {
    static let isOverlayUserInteractionEnabled = false
    static let shouldDisableCollectionInteraction = false
}

enum ChatInteractiveRemoteArchiveTimeoutPolicy {
    static let requestStartTimeout: TimeInterval = 45
    static let timeout: TimeInterval = 45
}

/// Keeps the account's single MAM scheduler lane occupied until the query's
/// transport reaches a terminal state. Completion may race with scheduler
/// dequeue, so attaching after a terminal signal must finish immediately and
/// every path remains exactly-once. Persistence continues under its own query
/// lease after a raw final releases this wire lane.
final class ChatInteractiveRemoteArchiveSchedulerLease {
    private let lock = NSLock()
    private let createdAt = Date()
    private var schedulerFinish: (() -> Void)?
    private var isTerminal = false

    func attach(_ finish: @escaping () -> Void) {
        let shouldFinishImmediately: Bool
        lock.lock()
        if isTerminal {
            shouldFinishImmediately = true
        } else if schedulerFinish == nil {
            schedulerFinish = finish
            shouldFinishImmediately = false
        } else {
            shouldFinishImmediately = false
        }
        lock.unlock()

        ChatArchiveDebugTrace.log("interactiveMamSchedulerLeaseAttached", [
            ("terminalBeforeAttach", shouldFinishImmediately),
            ("ageMs", ChatArchiveDebugTrace.milliseconds(since: createdAt))
        ])

        if shouldFinishImmediately {
            finish()
        }
    }

    func complete() {
        let finish: (() -> Void)?
        lock.lock()
        guard !isTerminal else {
            lock.unlock()
            return
        }
        isTerminal = true
        finish = schedulerFinish
        schedulerFinish = nil
        lock.unlock()

        ChatArchiveDebugTrace.log("interactiveMamSchedulerLeaseCompleted", [
            ("hadSchedulerFinish", finish != nil),
            ("ageMs", ChatArchiveDebugTrace.milliseconds(since: createdAt))
        ])

        finish?()
    }
}

/// Failure-path fallback for an interactive archive request that has not
/// received a raw final. A partial query batch reaches its persistence
/// terminal before MAM query state is removed. Scheduler completion remains
/// idempotent because a racing wire-terminal signal may already have released
/// the lane.
enum ChatInteractiveRemoteArchiveTerminalCleanup {
    private final class CompletionGate {
        private let lock = NSLock()
        private var didComplete = false

        func run(_ completion: () -> Void) {
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return
            }
            didComplete = true
            lock.unlock()
            completion()
        }
    }

    static func perform(
        flushPersistence: (@escaping () -> Void) -> Void,
        cancelPendingRequest: @escaping () -> Void,
        completeSchedulerLease: @escaping () -> Void
    ) {
        let gate = CompletionGate()
        flushPersistence {
            gate.run {
                cancelPendingRequest()
                completeSchedulerLease()
            }
        }
    }
}

struct ChatInteractiveRemoteArchiveDispatchRequest {
    let owner: String
    let queryId: String
    let direction: ChatHistoryPageDirection
    let cursorId: String?
    let pageSize: Int
    let priority: AccountXMPPTaskScheduler.Priority
    let resource: AccountXMPPTaskScheduler.Resource
    let deduplicationKey: String
    let schedulerLease: ChatInteractiveRemoteArchiveSchedulerLease
    let shouldDispatch: () -> Bool
    let send: (_ account: Account, _ stream: XMPPStream) -> String?
    let transportStarted: (_ sentQueryId: String, _ streamKind: MessageArchiveEndPageEvent.StreamKind, _ resource: String?) -> Void
    /// Test-only transport substitution used by the deterministic chat-open
    /// lab. The production request has already selected its cursor, canonical
    /// MAM operation, callbacks and consumer-persistence ownership before this
    /// closure can be invoked; the fixture only supplies isolated managers.
    let performanceFixtureSend: ((
        _ stream: XMPPStream,
        _ archiveManager: MessageArchiveManager,
        _ messageManager: MessageManager
    ) -> String?)?
    let dispatchUnavailable: (_ reason: String) -> Void

    init(
        owner: String,
        queryId: String,
        direction: ChatHistoryPageDirection,
        cursorId: String?,
        pageSize: Int,
        priority: AccountXMPPTaskScheduler.Priority,
        resource: AccountXMPPTaskScheduler.Resource,
        deduplicationKey: String,
        schedulerLease: ChatInteractiveRemoteArchiveSchedulerLease,
        shouldDispatch: @escaping () -> Bool,
        send: @escaping (_ account: Account, _ stream: XMPPStream) -> String?,
        transportStarted: @escaping (
            _ sentQueryId: String,
            _ streamKind: MessageArchiveEndPageEvent.StreamKind,
            _ resource: String?
        ) -> Void,
        performanceFixtureSend: ((
            _ stream: XMPPStream,
            _ archiveManager: MessageArchiveManager,
            _ messageManager: MessageManager
        ) -> String?)? = nil,
        dispatchUnavailable: @escaping (_ reason: String) -> Void
    ) {
        self.owner = owner
        self.queryId = queryId
        self.direction = direction
        self.cursorId = cursorId
        self.pageSize = pageSize
        self.priority = priority
        self.resource = resource
        self.deduplicationKey = deduplicationKey
        self.schedulerLease = schedulerLease
        self.shouldDispatch = shouldDispatch
        self.send = send
        self.transportStarted = transportStarted
        self.performanceFixtureSend = performanceFixtureSend
        self.dispatchUnavailable = dispatchUnavailable
    }
}

protocol ChatInteractiveRemoteArchiveRequestDispatching: AnyObject {
    func enqueue(_ request: ChatInteractiveRemoteArchiveDispatchRequest)
}

final class AccountSchedulerChatInteractiveRemoteArchiveRequestDispatcher: ChatInteractiveRemoteArchiveRequestDispatching {
    func enqueue(_ request: ChatInteractiveRemoteArchiveDispatchRequest) {
        let enqueuedAt = Date()
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestEnqueued", [
            ("owner", request.owner),
            ("queryId", request.queryId),
            ("direction", request.direction),
            ("cursor", request.cursorId ?? "-"),
            ("pageSize", request.pageSize),
            ("schedulerPriority", "\(request.priority)"),
            ("schedulerResource", "\(request.resource)"),
            ("deduplicationKey", request.deduplicationKey)
        ])

        guard let account = AccountManager.shared.find(for: request.owner) else {
            request.dispatchUnavailable("missingAccount")
            return
        }

        account.xmppTaskScheduler.enqueueAccountTask(
            priority: request.priority,
            resource: request.resource,
            deduplicationKey: request.deduplicationKey,
            requiresAuthenticatedStream: true,
            unavailable: {
                request.dispatchUnavailable("streamNotReady")
            }
        ) { account, stream, finish in
            request.schedulerLease.attach(finish)
            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestDequeued", [
                ("owner", request.owner),
                ("queryId", request.queryId),
                ("direction", request.direction),
                ("cursor", request.cursorId ?? "-"),
                ("schedulerPriority", "\(request.priority)"),
                ("schedulerResource", "\(request.resource)"),
                ("resource", stream.myJID?.resource ?? "-"),
                ("schedulerWaitMs", ChatArchiveDebugTrace.milliseconds(since: enqueuedAt))
            ])

            guard request.shouldDispatch() else {
                request.schedulerLease.complete()
                return
            }

            guard let sentQueryId = request.send(account, stream) else {
                request.schedulerLease.complete()
                return
            }

            request.transportStarted(
                sentQueryId,
                Self.remoteArchiveStreamKind(for: stream),
                stream.myJID?.resource
            )
        }
    }

    private static func remoteArchiveStreamKind(for stream: XMPPStream) -> MessageArchiveEndPageEvent.StreamKind {
        guard let resource = stream.myJID?.resource else {
            return .unknown
        }
        if resource.contains("_ui_upgrade_task") {
            return .uiAction
        }
        return .primary
    }
}

struct ChatTimelineConversationKey: Equatable {
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
    case knownGap(RegularChatArchiveGap)
    case unknownNewer
    case liveTail
    case loadingPlaceholder(ChatHistoryBoundaryPlaceholderPosition)
}

enum ChatTimelineLoadingState: Equatable {
    case none
    case initialSkeleton
    case edge(ChatHistoryBoundaryPlaceholderPosition)
    case gap(ChatHistoryBoundaryPlaceholderPosition)
}

struct ChatTimelineRemoteLoad: Equatable {
    let queryId: String
    let direction: ChatHistoryPageDirection
    let decision: ChatHistoryPagingLoadDecision
    let cursorId: String?
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
        activeRemoteLoad: nil,
        activePlaceholder: nil,
        isResidentAtLiveTail: true
    )

    let conversationKey: ChatTimelineConversationKey
    let segments: [ChatVirtualSegment]
    let oldest: ChatTimelineBoundary?
    let newest: ChatTimelineBoundary?
    let residentPrimaryKeys: [String]
    let residentArchivedIds: [String]
    let activeRemoteLoad: ChatTimelineRemoteLoad?
    let activePlaceholder: ChatHistoryBoundaryPlaceholderPosition?
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
            activeRemoteLoad: nil,
            activePlaceholder: nil,
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

    func withRuntimePlaceholder(
        _ placeholder: ChatHistoryBoundaryPlaceholderPosition?
    ) -> ChatVirtualTimelineState {
        let segmentsWithoutPlaceholder = segments.filter {
            if case .loadingPlaceholder = $0 {
                return false
            }
            return true
        }
        let nextSegments = placeholder.map {
            segmentsWithoutPlaceholder + [.loadingPlaceholder($0)]
        } ?? segmentsWithoutPlaceholder
        return ChatVirtualTimelineState(
            conversationKey: conversationKey,
            segments: nextSegments,
            oldest: oldest,
            newest: newest,
            residentPrimaryKeys: residentPrimaryKeys,
            residentArchivedIds: residentArchivedIds,
            activeRemoteLoad: activeRemoteLoad,
            activePlaceholder: placeholder,
            isResidentAtLiveTail: isResidentAtLiveTail
        )
    }

    func abortingRemoteLoad(queryId: String) -> ChatVirtualTimelineState {
        guard activeRemoteLoad?.queryId == queryId else {
            return self
        }
        let segmentsWithoutPlaceholder = segments.filter {
            if case .loadingPlaceholder = $0 {
                return false
            }
            return true
        }
        return ChatVirtualTimelineState(
            conversationKey: conversationKey,
            segments: segmentsWithoutPlaceholder,
            oldest: oldest,
            newest: newest,
            residentPrimaryKeys: residentPrimaryKeys,
            residentArchivedIds: residentArchivedIds,
            activeRemoteLoad: nil,
            activePlaceholder: nil,
            isResidentAtLiveTail: isResidentAtLiveTail
        )
    }
}

struct ChatTimelineSnapshot {
    let items: [MessageStorageItem]
    let state: ChatVirtualTimelineState
    let loadingState: ChatTimelineLoadingState
    let loadDecision: ChatHistoryPagingLoadDecision?
    let anchorRestore: ChatTimelineAnchorRestoreCommand?
    let localOlderCandidateCount: Int?
    let pageSize: Int?
    let shortLocalRemainderRemoteFirst: Bool

    init(
        items: [MessageStorageItem],
        state: ChatVirtualTimelineState,
        loadingState: ChatTimelineLoadingState,
        loadDecision: ChatHistoryPagingLoadDecision?,
        anchorRestore: ChatTimelineAnchorRestoreCommand?,
        localOlderCandidateCount: Int? = nil,
        pageSize: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false
    ) {
        self.items = items
        self.state = state
        self.loadingState = loadingState
        self.loadDecision = loadDecision
        self.anchorRestore = anchorRestore
        self.localOlderCandidateCount = localOlderCandidateCount
        self.pageSize = pageSize
        self.shortLocalRemainderRemoteFirst = shortLocalRemainderRemoteFirst
    }
}

extension ChatBoundedTimelineWindowState {
    init(virtualState: ChatVirtualTimelineState) {
        self.init(
            oldest: virtualState.oldest,
            newest: virtualState.newest,
            residentPrimaryKeys: virtualState.residentPrimaryKeys,
            residentArchivedIds: virtualState.residentArchivedIds,
            activePlaceholder: virtualState.activePlaceholder,
            isPagingLocked: virtualState.activeRemoteLoad != nil
        )
    }
}

struct ChatVirtualTimelineEngine {
    private let provider: ChatTimelinePageProviding
    private let pageSize: Int
    private let archiveState: ChatArchiveStateSnapshot
    private(set) var state: ChatVirtualTimelineState

    init(
        provider: ChatTimelinePageProviding,
        pageSize: Int,
        state: ChatVirtualTimelineState,
        archiveState: ChatArchiveStateSnapshot
    ) {
        self.provider = provider
        self.pageSize = max(1, pageSize)
        self.state = state
        self.archiveState = archiveState
    }

    mutating func openLatest(limit: Int? = nil) -> ChatTimelineSnapshot {
        let items = provider.latest(
            limit: limit ?? ChatBoundedTimelineWindowPolicy.targetLimit(pageSize: pageSize)
        )
        return apply(
            items: items,
            direction: nil,
            isResidentAtLiveTail: true,
            loadingState: .none,
            loadDecision: nil,
            anchorRestore: nil
        )
    }

    mutating func scrollToLatest(limit: Int? = nil) -> ChatTimelineSnapshot {
        openLatest(limit: limit)
    }

    mutating func openAround(anchor: ChatTimelineAnchor) -> ChatTimelineSnapshot {
        guard let message = provider.message(
            primary: anchor.primary,
            archivedId: anchor.archivedId,
            messageId: anchor.messageId
        ) else {
            return openLatest()
        }

        let before = pageSize / 2
        let after = max(0, pageSize - before - 1)
        let items = provider.around(anchor: message, before: before, after: after)
        return apply(
            items: items,
            direction: nil,
            isResidentAtLiveTail: false,
            loadingState: .none,
            loadDecision: nil,
            anchorRestore: ChatTimelineAnchorRestoreCommand(
                primary: message.primary,
                archivedId: RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(message.archivedId),
                viewportOffset: 0
            )
        )
    }

    mutating func pageOlder(queryId: String? = nil) -> ChatTimelineSnapshot {
        guard state.activeRemoteLoad == nil else {
            return currentSnapshot()
        }

        guard let oldest = state.oldest else {
            return openLatest()
        }

        let olderItems = provider.older(before: oldest, limit: pageSize)
        guard olderItems.isNotEmpty else {
            if archiveState.fullArchiveLoaded {
                return currentSnapshot(
                    loadDecision: .endReached,
                    localOlderCandidateCount: 0,
                    shortLocalRemainderRemoteFirst: false
                )
            }
            return remoteSnapshot(
                queryId: queryId,
                direction: .older,
                decision: .remoteOlderPage,
                cursorId: state.oldest?.archivedId,
                loadingState: .edge(.top),
                localOlderCandidateCount: 0,
                shortLocalRemainderRemoteFirst: false
            )
        }

        if let gapDecision = gapDecision(
            direction: .older,
            requestedItems: olderItems
        ) {
            return remoteSnapshot(
                queryId: queryId,
                direction: .older,
                decision: gapDecision,
                cursorId: cursorId(for: gapDecision),
                loadingState: .gap(.top),
                localOlderCandidateCount: olderItems.count,
                shortLocalRemainderRemoteFirst: false
            )
        }

        if ChatShortLocalOlderRemainderPolicy.shouldRequestRemoteFirst(
            localOlderCount: olderItems.count,
            pageSize: pageSize,
            archiveEnded: archiveState.fullArchiveLoaded
        ) {
            return remoteSnapshot(
                queryId: queryId,
                direction: .older,
                decision: .remoteOlderPage,
                cursorId: state.oldest?.archivedId,
                loadingState: .edge(.top),
                localOlderCandidateCount: olderItems.count,
                shortLocalRemainderRemoteFirst: true
            )
        }

        let currentItems = provider.items(primaryKeys: state.residentPrimaryKeys)
        let candidateItems = olderItems + currentItems
        let previousNewest = state.newest?.primary
        let wasLiveTail = state.isResidentAtLiveTail
        let trimmedItems = trimmed(candidateItems, direction: .older)
        let stillHasPreviousNewest = previousNewest.flatMap { newest in
            trimmedItems.contains(where: { $0.primary == newest })
        } ?? false

        return apply(
            items: trimmedItems,
            direction: .older,
            isResidentAtLiveTail: wasLiveTail && stillHasPreviousNewest,
            loadingState: .none,
            loadDecision: .localOnly,
            anchorRestore: nil,
            localOlderCandidateCount: olderItems.count,
            shortLocalRemainderRemoteFirst: false
        )
    }

    mutating func pageNewer(queryId: String? = nil) -> ChatTimelineSnapshot {
        guard state.activeRemoteLoad == nil else {
            return currentSnapshot()
        }

        guard let newest = state.newest else {
            return openLatest()
        }

        // Fetch one look-ahead row with the page so live-tail detection does not
        // require a second directional store query at the same boundary.
        let newerCandidates = provider.newer(after: newest, limit: pageSize + 1)
        let hasNewerCandidateBeyondPage = newerCandidates.count > pageSize
        let newerItems = Array(newerCandidates.prefix(pageSize))
        guard newerItems.isNotEmpty else {
            if archiveState.newerLiveEdgeReached || state.isResidentAtLiveTail {
                return currentSnapshot(loadDecision: .endReached)
            }
            return remoteSnapshot(
                queryId: queryId,
                direction: .newer,
                decision: .remoteNewerPage,
                cursorId: state.newest?.archivedId,
                loadingState: .edge(.bottom)
            )
        }

        if let gapDecision = gapDecision(
            direction: .newer,
            requestedItems: newerItems
        ) {
            return remoteSnapshot(
                queryId: queryId,
                direction: .newer,
                decision: gapDecision,
                cursorId: cursorId(for: gapDecision),
                loadingState: .gap(.bottom)
            )
        }

        let currentItems = provider.items(primaryKeys: state.residentPrimaryKeys)
        let candidateItems = currentItems + newerItems
        let trimmedItems = trimmed(candidateItems, direction: .newer)
        let reachesKnownLiveTail = archiveState.newerLiveEdgeReached && !hasNewerCandidateBeyondPage

        return apply(
            items: trimmedItems,
            direction: .newer,
            isResidentAtLiveTail: reachesKnownLiveTail,
            loadingState: .none,
            loadDecision: .localOnly,
            anchorRestore: nil
        )
    }

    mutating func appendLiveMessage(_ message: MessageStorageItem) -> ChatTimelineSnapshot {
        guard state.isResidentAtLiveTail else {
            return currentSnapshot()
        }

        let currentItems = provider.items(primaryKeys: state.residentPrimaryKeys)
        return apply(
            items: currentItems + [message],
            direction: .newer,
            isResidentAtLiveTail: true,
            loadingState: .none,
            loadDecision: .localOnly,
            anchorRestore: nil
        )
    }

    mutating func finishRemoteLoad(
        queryId: String,
        refetchDirection: ChatHistoryPageDirection? = nil,
        refetchLimit: Int? = nil
    ) -> ChatTimelineSnapshot {
        if let activeRemoteLoad = state.activeRemoteLoad,
           activeRemoteLoad.queryId != queryId {
            return currentSnapshot()
        }

        state = ChatVirtualTimelineState(
            conversationKey: state.conversationKey,
            segments: segments(
                oldest: state.oldest,
                newest: state.newest,
                activePlaceholder: nil,
                isResidentAtLiveTail: state.isResidentAtLiveTail
            ),
            oldest: state.oldest,
            newest: state.newest,
            residentPrimaryKeys: state.residentPrimaryKeys,
            residentArchivedIds: state.residentArchivedIds,
            activeRemoteLoad: nil,
            activePlaceholder: nil,
            isResidentAtLiveTail: state.isResidentAtLiveTail
        )

        guard let refetchDirection else {
            return currentSnapshot()
        }

        return refetchLocalAfterRemoteLoad(
            direction: refetchDirection,
            limit: refetchLimit
        )
    }

    mutating func abortRemoteLoad(queryId: String) -> ChatTimelineSnapshot {
        let nextState = state.abortingRemoteLoad(queryId: queryId)
        guard nextState != state else {
            return currentSnapshot()
        }
        state = nextState
        return currentSnapshot()
    }

    private mutating func refetchLocalAfterRemoteLoad(
        direction: ChatHistoryPageDirection,
        limit: Int?
    ) -> ChatTimelineSnapshot {
        let effectiveLimit = limit ?? pageSize
        guard effectiveLimit > 0 else {
            return currentSnapshot()
        }
        switch direction {
        case .older:
            guard let oldest = state.oldest else {
                return openLatest()
            }

            let olderItems = provider.older(
                before: oldest,
                limit: effectiveLimit
            )
            guard olderItems.isNotEmpty else {
                return currentSnapshot()
            }

            let currentItems = provider.items(primaryKeys: state.residentPrimaryKeys)
            let previousNewest = state.newest?.primary
            let wasLiveTail = state.isResidentAtLiveTail
            let candidateItems = olderItems + currentItems
            let trimmedItems = trimmed(candidateItems, direction: .older)
            let stillHasPreviousNewest = previousNewest.flatMap { newest in
                trimmedItems.contains(where: { $0.primary == newest })
            } ?? false

            return apply(
                items: trimmedItems,
                direction: .older,
                isResidentAtLiveTail: wasLiveTail && stillHasPreviousNewest,
                loadingState: .none,
                loadDecision: .localOnly,
                anchorRestore: nil
            )
        case .newer:
            guard let newest = state.newest else {
                return openLatest()
            }

            let newerItems = provider.newer(
                after: newest,
                limit: effectiveLimit
            )
            guard newerItems.isNotEmpty else {
                return currentSnapshot()
            }

            let currentItems = provider.items(primaryKeys: state.residentPrimaryKeys)
            let candidateItems = currentItems + newerItems
            let trimmedItems = trimmed(candidateItems, direction: .newer)
            let reachesKnownLiveTail = archiveState.newerLiveEdgeReached && (trimmedItems.last.map {
                provider.newer(after: ChatTimelineBoundary(message: $0), limit: 1).isEmpty
            } ?? false)

            return apply(
                items: trimmedItems,
                direction: .newer,
                isResidentAtLiveTail: reachesKnownLiveTail,
                loadingState: .none,
                loadDecision: .localOnly,
                anchorRestore: nil
            )
        }
    }

    private mutating func apply(
        items: [MessageStorageItem],
        direction: ChatHistoryPageDirection?,
        isResidentAtLiveTail: Bool,
        loadingState: ChatTimelineLoadingState,
        loadDecision: ChatHistoryPagingLoadDecision?,
        anchorRestore: ChatTimelineAnchorRestoreCommand?,
        localOlderCandidateCount: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false
    ) -> ChatTimelineSnapshot {
        let deduplicated = Self.deduplicatedChronologicalItems(items)
        let trimmedItems = trimmed(deduplicated, direction: direction)
        let archiveIds = trimmedItems.compactMap {
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId($0.archivedId)
        }
        let activePlaceholder = placeholder(for: loadingState)
        state = ChatVirtualTimelineState(
            conversationKey: state.conversationKey,
            segments: segments(
                oldest: trimmedItems.first.map(ChatTimelineBoundary.init(message:)),
                newest: trimmedItems.last.map(ChatTimelineBoundary.init(message:)),
                activePlaceholder: activePlaceholder,
                isResidentAtLiveTail: isResidentAtLiveTail
            ),
            oldest: trimmedItems.first.map(ChatTimelineBoundary.init(message:)),
            newest: trimmedItems.last.map(ChatTimelineBoundary.init(message:)),
            residentPrimaryKeys: trimmedItems.map(\.primary),
            residentArchivedIds: archiveIds,
            activeRemoteLoad: nil,
            activePlaceholder: activePlaceholder,
            isResidentAtLiveTail: isResidentAtLiveTail
        )
        return ChatTimelineSnapshot(
            items: trimmedItems,
            state: state,
            loadingState: loadingState,
            loadDecision: loadDecision,
            anchorRestore: anchorRestore,
            localOlderCandidateCount: localOlderCandidateCount,
            pageSize: pageSize,
            shortLocalRemainderRemoteFirst: shortLocalRemainderRemoteFirst
        )
    }

    private mutating func remoteSnapshot(
        queryId: String?,
        direction: ChatHistoryPageDirection,
        decision: ChatHistoryPagingLoadDecision,
        cursorId: String?,
        loadingState: ChatTimelineLoadingState,
        localOlderCandidateCount: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false
    ) -> ChatTimelineSnapshot {
        let activePlaceholder = placeholder(for: loadingState)
        let activeRemoteLoad = queryId.map {
            ChatTimelineRemoteLoad(
                queryId: $0,
                direction: direction,
                decision: decision,
                cursorId: cursorId
            )
        }
        state = ChatVirtualTimelineState(
            conversationKey: state.conversationKey,
            segments: segments(
                oldest: state.oldest,
                newest: state.newest,
                activePlaceholder: activePlaceholder,
                isResidentAtLiveTail: state.isResidentAtLiveTail
            ),
            oldest: state.oldest,
            newest: state.newest,
            residentPrimaryKeys: state.residentPrimaryKeys,
            residentArchivedIds: state.residentArchivedIds,
            activeRemoteLoad: activeRemoteLoad,
            activePlaceholder: activePlaceholder,
            isResidentAtLiveTail: state.isResidentAtLiveTail
        )
        return currentSnapshot(
            loadingState: loadingState,
            loadDecision: decision,
            localOlderCandidateCount: localOlderCandidateCount,
            shortLocalRemainderRemoteFirst: shortLocalRemainderRemoteFirst
        )
    }

    func currentSnapshot(
        loadingState: ChatTimelineLoadingState = .none,
        loadDecision: ChatHistoryPagingLoadDecision? = nil,
        localOlderCandidateCount: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false
    ) -> ChatTimelineSnapshot {
        ChatTimelineSnapshot(
            items: provider.items(primaryKeys: state.residentPrimaryKeys),
            state: state,
            loadingState: loadingState,
            loadDecision: loadDecision,
            anchorRestore: nil,
            localOlderCandidateCount: localOlderCandidateCount,
            pageSize: pageSize,
            shortLocalRemainderRemoteFirst: shortLocalRemainderRemoteFirst
        )
    }

    private func trimmed(
        _ items: [MessageStorageItem],
        direction: ChatHistoryPageDirection?
    ) -> [MessageStorageItem] {
        ChatBoundedTimelineWindowPolicy.trimmedItems(
            items,
            direction: direction,
            pageSize: pageSize
        )
    }

    private func gapDecision(
        direction: ChatHistoryPageDirection,
        requestedItems: [MessageStorageItem]
    ) -> ChatHistoryPagingLoadDecision? {
        guard let currentOldest = state.oldest,
              let currentNewest = state.newest,
              let requestedOldest = requestedItems.first.map(ChatTimelineBoundary.init(message:)),
              let requestedNewest = requestedItems.last.map(ChatTimelineBoundary.init(message:)) else {
            return nil
        }

        return ChatArchiveBoundaryGapPagingPolicy.loadDecision(
            direction: direction,
            currentOldestArchiveId: currentOldest.archivedId,
            currentNewestArchiveId: currentNewest.archivedId,
            requestedOldestArchiveId: requestedOldest.archivedId,
            requestedNewestArchiveId: requestedNewest.archivedId,
            knownGaps: archiveState.knownGaps
        )
    }

    private func cursorId(for decision: ChatHistoryPagingLoadDecision) -> String? {
        switch decision {
        case .remoteOlderPage:
            return state.oldest?.archivedId
        case .remoteNewerPage:
            return state.newest?.archivedId
        case .remoteGapRepairOlder(let gap):
            return gap.newerRangeOldestArchiveId
        case .remoteGapRepairNewer(let gap):
            return gap.olderRangeNewestArchiveId
        case .localOnly, .endReached:
            return nil
        }
    }

    private func placeholder(for loadingState: ChatTimelineLoadingState) -> ChatHistoryBoundaryPlaceholderPosition? {
        switch loadingState {
        case .edge(let position), .gap(let position):
            return position
        case .none, .initialSkeleton:
            return nil
        }
    }

    private func segments(
        oldest: ChatTimelineBoundary?,
        newest: ChatTimelineBoundary?,
        activePlaceholder: ChatHistoryBoundaryPlaceholderPosition?,
        isResidentAtLiveTail: Bool
    ) -> [ChatVirtualSegment] {
        var segments: [ChatVirtualSegment] = []
        if !archiveState.fullArchiveLoaded {
            segments.append(.unknownOlder)
        }
        if let oldestArchiveId = oldest?.archivedId,
           let newestArchiveId = newest?.archivedId {
            segments.append(.loadedRange(oldestArchiveId: oldestArchiveId, newestArchiveId: newestArchiveId))
        } else if oldest != nil || newest != nil {
            segments.append(.loadedRange(oldestArchiveId: oldest?.archivedId, newestArchiveId: newest?.archivedId))
        }
        segments.append(contentsOf: archiveState.knownGaps.map(ChatVirtualSegment.knownGap))
        if !archiveState.newerLiveEdgeReached || !isResidentAtLiveTail {
            segments.append(.unknownNewer)
        }
        if isResidentAtLiveTail {
            segments.append(.liveTail)
        }
        if let activePlaceholder {
            segments.append(.loadingPlaceholder(activePlaceholder))
        }
        return segments
    }

    private static func deduplicatedChronologicalItems(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        ChatTimelineOrdering.deduplicatedChronological(items)
    }
}

enum ChatInteractiveRemoteHistoryRefetchLimitPolicy {
    static func limit(
        coverageUpdateKind: RegularArchiveCoverageUpdateKind,
        visibleRowsForConversation: Int
    ) -> Int? {
        switch coverageUpdateKind {
        case .gapRepairOlder, .gapRepairNewer:
            return max(0, visibleRowsForConversation)
        case .bootstrapNewest, .pageOlder, .pageNewer, .disjointWindow,
             .none:
            return nil
        }
    }
}

struct ChatInteractiveHistoryPageLoadContext {
    let queryId: String
    let performanceTraceOwner: String?
    let performanceTraceContext: ChatOpenPerformanceTraceContext?
    var generation: Int = 0
    let direction: ChatHistoryPageDirection
    let chatPrimaryKey: String
    let persistedCursorId: String?
    let persistedFullArchiveLoaded: Bool
    let requestedCursorId: String?
    let requestedWindow: ChatDatasetWindow
    let preLoadObserverCount: Int
    let preLoadOldestArchivedId: String?
    let preLoadNewestArchivedId: String?
    let preLoadFullArchiveLoaded: Bool
    let preLoadNewerLiveEdgeReached: Bool
    var remoteFetchStarted: Bool
    let isArchiveEndVerificationProbe: Bool
    let canMutateOlderArchiveEnd: Bool
    let expectedWindowMaxIndex: Int
    let coverageUpdateKind: RegularArchiveCoverageUpdateKind
    var didReceiveEndPage: Bool = false
    var queryExhausted: Bool = false
    var persistedMessageCount: Int? = nil
    var resultFirst: String = ""
    var resultLast: String = ""
    var resultCount: Int = 0
    var persistedRowsForQuery: Int = 0
    var visibleRowsForConversation: Int = 0
    var didEnterObserverSettlePhase: Bool = false
    var didObservePostIdleTick: Bool = false
    var isArchivePagePersisted: Bool = false

    init(
        queryId: String,
        performanceTraceOwner: String? = nil,
        performanceTraceContext: ChatOpenPerformanceTraceContext? = nil,
        generation: Int = 0,
        direction: ChatHistoryPageDirection,
        chatPrimaryKey: String,
        persistedCursorId: String?,
        persistedFullArchiveLoaded: Bool,
        requestedCursorId: String?,
        requestedWindow: ChatDatasetWindow,
        preLoadObserverCount: Int,
        preLoadOldestArchivedId: String?,
        preLoadNewestArchivedId: String?,
        preLoadFullArchiveLoaded: Bool,
        preLoadNewerLiveEdgeReached: Bool,
        remoteFetchStarted: Bool,
        isArchiveEndVerificationProbe: Bool,
        canMutateOlderArchiveEnd: Bool,
        expectedWindowMaxIndex: Int,
        coverageUpdateKind: RegularArchiveCoverageUpdateKind,
        didReceiveEndPage: Bool = false,
        queryExhausted: Bool = false,
        persistedMessageCount: Int? = nil,
        resultFirst: String = "",
        resultLast: String = "",
        resultCount: Int = 0,
        persistedRowsForQuery: Int = 0,
        visibleRowsForConversation: Int = 0,
        didEnterObserverSettlePhase: Bool = false,
        didObservePostIdleTick: Bool = false,
        isArchivePagePersisted: Bool = false
    ) {
        self.queryId = queryId
        self.performanceTraceOwner = performanceTraceOwner
        self.performanceTraceContext = performanceTraceContext
        self.generation = generation
        self.direction = direction
        self.chatPrimaryKey = chatPrimaryKey
        self.persistedCursorId = persistedCursorId
        self.persistedFullArchiveLoaded = persistedFullArchiveLoaded
        self.requestedCursorId = requestedCursorId
        self.requestedWindow = requestedWindow
        self.preLoadObserverCount = preLoadObserverCount
        self.preLoadOldestArchivedId = preLoadOldestArchivedId
        self.preLoadNewestArchivedId = preLoadNewestArchivedId
        self.preLoadFullArchiveLoaded = preLoadFullArchiveLoaded
        self.preLoadNewerLiveEdgeReached = preLoadNewerLiveEdgeReached
        self.remoteFetchStarted = remoteFetchStarted
        self.isArchiveEndVerificationProbe = isArchiveEndVerificationProbe
        self.canMutateOlderArchiveEnd = canMutateOlderArchiveEnd
        self.expectedWindowMaxIndex = expectedWindowMaxIndex
        self.coverageUpdateKind = coverageUpdateKind
        self.didReceiveEndPage = didReceiveEndPage
        self.queryExhausted = queryExhausted
        self.persistedMessageCount = persistedMessageCount
        self.resultFirst = resultFirst
        self.resultLast = resultLast
        self.resultCount = resultCount
        self.persistedRowsForQuery = persistedRowsForQuery
        self.visibleRowsForConversation = visibleRowsForConversation
        self.didEnterObserverSettlePhase = didEnterObserverSettlePhase
        self.didObservePostIdleTick = didObservePostIdleTick
        self.isArchivePagePersisted = isArchivePagePersisted
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

enum ChatShortContentRemotePagingSuppressionPolicy {
    static let layoutTolerance: CGFloat = 8

    static func shouldSuppressRemoteBoundaryPaging(
        hasRealMessages: Bool,
        hasLocalOlderAvailable: Bool,
        hasLocalNewerAvailable: Bool,
        hasRemoteOlderAvailable: Bool = false,
        contentHeight: CGFloat,
        visibleHeight: CGFloat,
        tolerance: CGFloat = 8
    ) -> Bool {
        guard hasRealMessages,
              !hasLocalOlderAvailable,
              !hasLocalNewerAvailable,
              !hasRemoteOlderAvailable,
              contentHeight > 0,
              visibleHeight > 0 else {
            return false
        }

        return contentHeight <= visibleHeight + tolerance
    }
}

enum ChatHistoryPageCompletionPolicy {
    static func shouldFinish(
        didReceiveEndPage: Bool,
        didAdvance: Bool,
        persistedMessageCount: Int?,
        isMessagePipelineIdle: Bool,
        isArchivePagePersisted: Bool = false,
        requiresObserverSettle: Bool = false,
        didObservePostIdleTick: Bool = true
    ) -> Bool {
        guard didReceiveEndPage, isMessagePipelineIdle || isArchivePagePersisted else {
            return false
        }

        if requiresObserverSettle && !isArchivePagePersisted && !didObservePostIdleTick {
            return false
        }

        if didAdvance {
            return true
        }

        if persistedMessageCount == 0 {
            return true
        }

        if isArchivePagePersisted {
            return true
        }

        return requiresObserverSettle && didObservePostIdleTick
    }

    static func didAdvance(
        previousObserverCount: Int,
        currentObserverCount: Int,
        previousOldestArchivedId: String?,
        currentOldestArchivedId: String?,
        previousArchiveEnded: Bool,
        currentArchiveEnded: Bool
    ) -> Bool {
        currentObserverCount > previousObserverCount ||
        previousOldestArchivedId != currentOldestArchivedId ||
        (!previousArchiveEnded && currentArchiveEnded)
    }

    static func didAdvance(
        direction: ChatHistoryPageDirection,
        previousObserverCount: Int,
        currentObserverCount: Int,
        previousOldestArchivedId: String?,
        currentOldestArchivedId: String?,
        previousNewestArchivedId: String?,
        currentNewestArchivedId: String?,
        previousArchiveEnded: Bool,
        currentArchiveEnded: Bool,
        previousNewerLiveEdgeReached: Bool,
        currentNewerLiveEdgeReached: Bool
    ) -> Bool {
        if currentObserverCount > previousObserverCount {
            return true
        }

        switch direction {
        case .older:
            return previousOldestArchivedId != currentOldestArchivedId ||
            (!previousArchiveEnded && currentArchiveEnded)
        case .newer:
            return previousNewestArchivedId != currentNewestArchivedId ||
            (!previousNewerLiveEdgeReached && currentNewerLiveEdgeReached)
        }
    }

    static func finalizedWindow(
        direction: ChatHistoryPageDirection,
        requestedWindow: ChatDatasetWindow,
        expectedWindowMaxIndex: Int,
        preLoadObserverCount: Int,
        currentObserverCount: Int,
        totalCount: Int
    ) -> ChatDatasetWindow {
        let observerCountDelta = max(0, currentObserverCount - preLoadObserverCount)
        let requestedMaxIndex = direction == .older
            ? expectedWindowMaxIndex + observerCountDelta
            : expectedWindowMaxIndex
        return ChatDatasetCoordinator(pageSize: max(1, requestedWindow.count)).clamp(
            ChatDatasetWindow(
                minIndex: requestedWindow.minIndex,
                maxIndex: requestedMaxIndex
            ),
            totalCount: totalCount
        )
    }
}

enum ChatInitialBootstrapCompletionPolicy {
    static func shouldFinish(
        didReceiveEndPage: Bool,
        hasMessages: Bool,
        didConfirmEmpty: Bool,
        isMessagePipelineIdle: Bool,
        isArchivePagePersisted: Bool = false,
        hasCommittedContent: Bool = false,
        hasCommittedInitialFrame: Bool = true,
        isSupersededByDifferentTarget: Bool = false,
        requiresObserverSettle: Bool,
        didObservePostIdleTick: Bool
    ) -> Bool {
        guard didReceiveEndPage,
              isMessagePipelineIdle || isArchivePagePersisted else {
            return false
        }

        // Query-scoped persistence is not presentation. A non-empty page
        // remains under the watchdog until its datasource transaction commits.
        guard isSupersededByDifferentTarget ||
                didConfirmEmpty ||
                (
                    hasMessages &&
                    hasCommittedContent &&
                    hasCommittedInitialFrame
                ) else {
            return false
        }

        guard !requiresObserverSettle || isArchivePagePersisted || didObservePostIdleTick else {
            return false
        }

        return true
    }
}

enum ChatInitialBootstrapArchiveEndCommitPolicy {
    static func shouldCommitArchiveEnd(
        state: MessageArchivePageEndState?,
        resultCount: Int?,
        visibleRowsForLatestPage: Int,
        persistedRowsForQuery: Int = 0
    ) -> Bool {
        guard state?.archiveEnded == true,
              let resultCount else {
            return false
        }

        if resultCount == 0 {
            return true
        }

        return visibleRowsForLatestPage > 0 || persistedRowsForQuery > 0
    }
}

struct ChatRemoteHistoryCompletionResult: Equatable {
    let state: MessageArchivePageEndState
    let flushedMessageCount: Int
    let persistenceSummary: MessageManager.ArchivePersistenceSummary
}

struct ChatRemoteHistoryQueryDescriptor: Equatable {
    let conversationKey: ChatTimelineConversationKey
    let queryId: String
    let direction: ChatHistoryPageDirection
    let cursorId: String?
    let generation: Int
}

struct ChatRemoteHistoryFinalPage: Equatable {
    let state: MessageArchivePageEndState
    let first: String
    let last: String
    let count: Int
}

struct ChatRemoteHistoryCommittedPage: Equatable {
    let descriptor: ChatRemoteHistoryQueryDescriptor
    let finalPage: ChatRemoteHistoryFinalPage
    let persistence: ChatRemoteHistoryCompletionResult
}

enum ChatRemoteHistoryFinalDisposition: Equatable {
    case accepted
    case duplicate
    case stale
    case unknown
}

enum ChatRemoteHistoryTerminalReason: Equatable {
    case completed
    case timeout
    case iqError
    case disconnected
    case persistenceFailed
    case cancelled
    case superseded
}

struct ChatRemoteHistoryPersistenceBarrierError: LocalizedError {
    let failedRows: Int

    var errorDescription: String? {
        "Remote MAM page persistence failed for \(failedRows) row(s)"
    }
}

#if DEBUG || CHAT_PERFORMANCE_LAB
enum ChatRemoteHistoryApplyWorkerPhase: Equatable {
    case refetch
    case map
}
#endif

/// Owns final-IQ idempotency and the persist-before-resolve barrier for one
/// controller's generation-scoped remote history requests. The persistence
/// closure always starts on `workerQueue`; delivery is revalidated immediately
/// before it reaches `callbackQueue`, so disappearance/supersession can cancel
/// a result that was already prepared but not yet consumed by UI.
final class ChatRemoteHistoryQueryCoordinator {
    static let terminalTombstoneLimit = 64

    typealias PersistenceBarrier = (
        _ page: ChatRemoteHistoryFinalPage,
        _ completion: @escaping (Result<ChatRemoteHistoryCompletionResult, Error>) -> Void
    ) -> Void

    private enum State {
        case awaitingFinal
        case persisting(UUID)
        case ready(UUID, terminalReason: ChatRemoteHistoryTerminalReason)
        case terminal(ChatRemoteHistoryTerminalReason)
    }

    private struct ScheduledTimeout {
        let token: UUID
        let workItem: DispatchWorkItem
    }

    private struct Entry {
        let descriptor: ChatRemoteHistoryQueryDescriptor
        let persistenceBarrier: PersistenceBarrier
        var state: State
        var scheduledTimeout: ScheduledTimeout?
        var wireTerminal: (() -> Void)?
        var persistenceCleanup: (() -> Void)?
    }

    private let lock = NSLock()
    private let workerQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private var entriesByQueryId: [String: Entry] = [:]
    private var terminalQueryIds: [String] = []
#if DEBUG || CHAT_PERFORMANCE_LAB
    var remoteApplyWorkerObserverForTests:
        ((String, ChatRemoteHistoryApplyWorkerPhase, Bool) -> Void)?
#endif

    init(
        workerQueue: DispatchQueue = DispatchQueue(
            label: "com.xabber.chat.remote-history.persistence",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        ),
        callbackQueue: DispatchQueue = .main
    ) {
        self.workerQueue = workerQueue
        self.callbackQueue = callbackQueue
    }

    @discardableResult
    func register(
        _ descriptor: ChatRemoteHistoryQueryDescriptor,
        wireTerminal: @escaping () -> Void = {},
        persistenceCleanup: @escaping () -> Void = {},
        persistenceBarrier: @escaping PersistenceBarrier
    ) -> Bool {
        guard descriptor.queryId.isNotEmpty else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }
        if let entry = entriesByQueryId[descriptor.queryId] {
            switch entry.state {
            case .awaitingFinal, .persisting, .ready:
                return false
            case .terminal:
                terminalQueryIds.removeAll { $0 == descriptor.queryId }
                break
            }
        }
        entriesByQueryId[descriptor.queryId] = Entry(
            descriptor: descriptor,
            persistenceBarrier: persistenceBarrier,
            state: .awaitingFinal,
            scheduledTimeout: nil,
            wireTerminal: wireTerminal,
            persistenceCleanup: persistenceCleanup
        )
        return true
    }

    @discardableResult
    func receiveFinal(
        queryId: String,
        generation: Int,
        page: ChatRemoteHistoryFinalPage,
        completion: @escaping (Result<ChatRemoteHistoryCommittedPage, Error>) -> Void
    ) -> ChatRemoteHistoryFinalDisposition {
        let token = UUID()
        let descriptor: ChatRemoteHistoryQueryDescriptor
        let persistenceBarrier: PersistenceBarrier
        let wireTerminal: (() -> Void)?

        lock.lock()
        guard var entry = entriesByQueryId[queryId] else {
            lock.unlock()
            return .unknown
        }
        guard entry.descriptor.generation == generation else {
            lock.unlock()
            return .stale
        }
        switch entry.state {
        case .awaitingFinal:
            descriptor = entry.descriptor
            persistenceBarrier = entry.persistenceBarrier
            wireTerminal = entry.wireTerminal
            entry.wireTerminal = nil
            entry.state = .persisting(token)
            entriesByQueryId[queryId] = entry
            lock.unlock()
        case .persisting, .ready:
            lock.unlock()
            return .duplicate
        case .terminal(let reason):
            lock.unlock()
            return reason == .completed ? .duplicate : .stale
        }

        wireTerminal?()
        workerQueue.async { [weak self] in
            persistenceBarrier(page) { result in
                self?.prepareDelivery(
                    result,
                    descriptor: descriptor,
                    page: page,
                    token: token,
                    completion: completion
                )
            }
        }
        return .accepted
    }

    @discardableResult
    func terminate(
        queryId: String,
        generation: Int,
        reason: ChatRemoteHistoryTerminalReason
    ) -> Bool {
        guard reason != .completed else {
            return false
        }

        let cleanup: (() -> Void)?
        lock.lock()
        guard var entry = entriesByQueryId[queryId],
              entry.descriptor.generation == generation else {
            lock.unlock()
            return false
        }
        switch entry.state {
        case .awaitingFinal, .persisting, .ready:
            entry.scheduledTimeout?.workItem.cancel()
            entry.scheduledTimeout = nil
            entry.wireTerminal = nil
            cleanup = entry.persistenceCleanup
            entry.persistenceCleanup = nil
            entry.state = .terminal(reason)
            entriesByQueryId[queryId] = entry
            recordTerminalQueryLocked(queryId)
            lock.unlock()
            cleanup?()
            return true
        case .terminal:
            lock.unlock()
            return false
        }
    }

    func remove(queryId: String) {
        lock.lock()
        let entry = entriesByQueryId.removeValue(forKey: queryId)
        terminalQueryIds.removeAll { $0 == queryId }
        lock.unlock()
        entry?.scheduledTimeout?.workItem.cancel()
        entry?.persistenceCleanup?()
    }

    func cancelAll(reason: ChatRemoteHistoryTerminalReason = .cancelled) {
        var cleanups: [() -> Void] = []
        lock.lock()
        for queryId in Array(entriesByQueryId.keys) {
            guard var entry = entriesByQueryId[queryId] else {
                continue
            }
            entry.scheduledTimeout?.workItem.cancel()
            entry.scheduledTimeout = nil
            entry.wireTerminal = nil
            if let cleanup = entry.persistenceCleanup {
                cleanups.append(cleanup)
                entry.persistenceCleanup = nil
            }
            switch entry.state {
            case .terminal:
                entriesByQueryId[queryId] = entry
                break
            case .awaitingFinal, .persisting, .ready:
                entry.state = .terminal(reason)
                entriesByQueryId[queryId] = entry
                recordTerminalQueryLocked(queryId)
            }
        }
        lock.unlock()
        cleanups.forEach { $0() }
    }

    var trackedQueryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entriesByQueryId.count
    }

    var activeQueryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entriesByQueryId.values.reduce(into: 0) { count, entry in
            switch entry.state {
            case .awaitingFinal, .persisting, .ready:
                count += 1
            case .terminal:
                break
            }
        }
    }

    @discardableResult
    func scheduleTimeout(
        queryId: String,
        generation: Int,
        after interval: TimeInterval,
        terminalReason: ChatRemoteHistoryTerminalReason,
        onTimeout: @escaping () -> Void
    ) -> Bool {
        guard interval >= 0,
              terminalReason != .completed else {
            return false
        }

        let token = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            guard self?.fireTimeout(
                queryId: queryId,
                generation: generation,
                token: token,
                terminalReason: terminalReason
            ) == true else {
                return
            }
            onTimeout()
        }

        lock.lock()
        guard var entry = entriesByQueryId[queryId],
              entry.descriptor.generation == generation,
              case .awaitingFinal = entry.state else {
            lock.unlock()
            return false
        }
        entry.scheduledTimeout?.workItem.cancel()
        entry.scheduledTimeout = ScheduledTimeout(token: token, workItem: workItem)
        entriesByQueryId[queryId] = entry
        lock.unlock()

        callbackQueue.asyncAfter(deadline: .now() + interval, execute: workItem)
        return true
    }

    @discardableResult
    func cancelTimeout(queryId: String) -> Bool {
        lock.lock()
        guard var entry = entriesByQueryId[queryId],
              let scheduledTimeout = entry.scheduledTimeout else {
            lock.unlock()
            return false
        }
        entry.scheduledTimeout = nil
        entriesByQueryId[queryId] = entry
        lock.unlock()
        scheduledTimeout.workItem.cancel()
        return true
    }

    func cancelAllTimeouts() {
        var workItems: [DispatchWorkItem] = []
        lock.lock()
        for queryId in Array(entriesByQueryId.keys) {
            guard var entry = entriesByQueryId[queryId],
                  let scheduledTimeout = entry.scheduledTimeout else {
                continue
            }
            workItems.append(scheduledTimeout.workItem)
            entry.scheduledTimeout = nil
            entriesByQueryId[queryId] = entry
        }
        lock.unlock()
        workItems.forEach { $0.cancel() }
    }

    func hasScheduledTimeout(queryId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entriesByQueryId[queryId]?.scheduledTimeout != nil
    }

    func terminalReason(queryId: String) -> ChatRemoteHistoryTerminalReason? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entriesByQueryId[queryId] else {
            return nil
        }
        if case .terminal(let reason) = entry.state {
            return reason
        }
        return nil
    }

    /// Classifies a final IQ that no longer has the controller context which
    /// originally armed it. Such a query must never fall through to another
    /// chat/search completion path after supersession or disappearance.
    func classifyUnhandledFinal(queryId: String) -> ChatRemoteHistoryFinalDisposition {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entriesByQueryId[queryId] else {
            return .unknown
        }
        switch entry.state {
        case .terminal(.completed):
            return .duplicate
        case .terminal, .awaitingFinal, .persisting, .ready:
            return .stale
        }
    }

    private func prepareDelivery(
        _ result: Result<ChatRemoteHistoryCompletionResult, Error>,
        descriptor: ChatRemoteHistoryQueryDescriptor,
        page: ChatRemoteHistoryFinalPage,
        token: UUID,
        completion: @escaping (Result<ChatRemoteHistoryCommittedPage, Error>) -> Void
    ) {
        let terminalReason: ChatRemoteHistoryTerminalReason
        let delivery: Result<ChatRemoteHistoryCommittedPage, Error>
        switch result {
        case .success(let persistence):
            terminalReason = .completed
            delivery = .success(ChatRemoteHistoryCommittedPage(
                descriptor: descriptor,
                finalPage: page,
                persistence: persistence
            ))
        case .failure(let error):
            terminalReason = .persistenceFailed
            delivery = .failure(error)
        }

        lock.lock()
        guard var entry = entriesByQueryId[descriptor.queryId],
              entry.descriptor == descriptor,
              case .persisting(let activeToken) = entry.state,
              activeToken == token else {
            lock.unlock()
            return
        }
        entry.state = .ready(token, terminalReason: terminalReason)
        entriesByQueryId[descriptor.queryId] = entry
        lock.unlock()

        callbackQueue.async { [weak self] in
            guard let self,
                  self.consumeReadyDelivery(
                    queryId: descriptor.queryId,
                    descriptor: descriptor,
                    token: token,
                    terminalReason: terminalReason
                  ) else {
                return
            }
            completion(delivery)
        }
    }

    private func consumeReadyDelivery(
        queryId: String,
        descriptor: ChatRemoteHistoryQueryDescriptor,
        token: UUID,
        terminalReason: ChatRemoteHistoryTerminalReason
    ) -> Bool {
        let cleanup: (() -> Void)?
        lock.lock()
        guard var entry = entriesByQueryId[queryId],
              entry.descriptor == descriptor,
              case .ready(let activeToken, let activeReason) = entry.state,
              activeToken == token,
              activeReason == terminalReason else {
            lock.unlock()
            return false
        }
        entry.scheduledTimeout?.workItem.cancel()
        entry.scheduledTimeout = nil
        entry.wireTerminal = nil
        cleanup = entry.persistenceCleanup
        entry.persistenceCleanup = nil
        entry.state = .terminal(terminalReason)
        entriesByQueryId[queryId] = entry
        recordTerminalQueryLocked(queryId)
        lock.unlock()
        cleanup?()
        return true
    }

    private func fireTimeout(
        queryId: String,
        generation: Int,
        token: UUID,
        terminalReason: ChatRemoteHistoryTerminalReason
    ) -> Bool {
        let cleanup: (() -> Void)?
        lock.lock()
        guard var entry = entriesByQueryId[queryId],
              entry.descriptor.generation == generation,
              entry.scheduledTimeout?.token == token else {
            lock.unlock()
            return false
        }
        switch entry.state {
        case .awaitingFinal, .persisting, .ready:
            break
        case .terminal:
            lock.unlock()
            return false
        }
        entry.scheduledTimeout = nil
        cleanup = entry.persistenceCleanup
        entry.persistenceCleanup = nil
        entry.state = .terminal(terminalReason)
        entriesByQueryId[queryId] = entry
        recordTerminalQueryLocked(queryId)
        lock.unlock()
        cleanup?()
        return true
    }

    private func recordTerminalQueryLocked(_ queryId: String) {
        terminalQueryIds.removeAll { $0 == queryId }
        terminalQueryIds.append(queryId)

        while terminalQueryIds.count > Self.terminalTombstoneLimit {
            let expiredQueryId = terminalQueryIds.removeFirst()
            guard let entry = entriesByQueryId[expiredQueryId],
                  case .terminal = entry.state else {
                continue
            }
            entriesByQueryId.removeValue(forKey: expiredQueryId)
        }
    }
}

enum ChatBoundaryLoadingPresentationPolicy {
    static let usesTimelineRow = false

    static func geometryDelta(
        messageRowCount: Int,
        contentHeight: CGFloat
    ) -> CGSize {
        .zero
    }
}

final class ChatRemoteHistoryFlushSingleFlight<Key: Hashable, Value> {
    typealias Completion = (Value) -> Void
    typealias Producer = (@escaping Completion) -> Void

    private enum State {
        case inFlight([Completion])
        case completed(Value)
    }

    private let lock = NSLock()
    private let completedCapacity: Int
    private var statesByKey: [Key: State] = [:]
    private var completedOrder: [Key] = []

    init(completedCapacity: Int) {
        self.completedCapacity = max(0, completedCapacity)
    }

    func run(
        key: Key,
        producer: @escaping Producer,
        completion: @escaping Completion
    ) {
        var completedValues: [Value] = []
        var shouldProduce = false
        lock.lock()
        switch statesByKey[key] {
        case .inFlight(var completions):
            completions.append(completion)
            statesByKey[key] = .inFlight(completions)
        case .completed(let value):
            completedValues.append(value)
        case nil:
            statesByKey[key] = .inFlight([completion])
            shouldProduce = true
        }
        lock.unlock()

        completedValues.forEach(completion)
        if shouldProduce {
            producer { [weak self] value in
                self?.finish(key: key, value: value)
            }
        }
    }

    func invalidateCompleted(key: Key) {
        lock.lock()
        if case .completed = statesByKey[key] {
            statesByKey.removeValue(forKey: key)
            completedOrder.removeAll { $0 == key }
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        statesByKey.removeAll()
        completedOrder.removeAll()
        lock.unlock()
    }

    private func finish(key: Key, value: Value) {
        let completions: [Completion]
        lock.lock()
        guard case .inFlight(let waitingCompletions) = statesByKey[key] else {
            lock.unlock()
            return
        }
        completions = waitingCompletions
        if completedCapacity > 0 {
            statesByKey[key] = .completed(value)
            completedOrder.removeAll { $0 == key }
            completedOrder.append(key)
            while completedOrder.count > completedCapacity {
                let evictedKey = completedOrder.removeFirst()
                if case .completed = statesByKey[evictedKey] {
                    statesByKey.removeValue(forKey: evictedKey)
                }
            }
        } else {
            statesByKey.removeValue(forKey: key)
        }
        lock.unlock()

        completions.forEach { $0(value) }
    }
}

enum ChatRemoteHistoryCompletionCoordinator {
    private final class PersistenceSource {
        let manager: MessageManager
        let queryId: String
        let failurePreparationToken: MessageArchiveRequestFailurePreparationDispatcher.Token
        var priority: ArchivePersistencePriority
        var expectedReceivedCountProvider: ((String) -> Int?)?
        var ingressExpectationCleanup: ((String) -> Void)?
        var isTerminalFlushInFlight = false
        var terminalCompletions: [() -> Void] = []

        init(
            _ manager: MessageManager,
            queryId: String,
            priority: ArchivePersistencePriority,
            expectedReceivedCountProvider: ((String) -> Int?)?,
            ingressExpectationCleanup: ((String) -> Void)?,
            failurePreparationToken: MessageArchiveRequestFailurePreparationDispatcher.Token
        ) {
            self.manager = manager
            self.queryId = queryId
            self.priority = priority
            self.expectedReceivedCountProvider = expectedReceivedCountProvider
            self.ingressExpectationCleanup = ingressExpectationCleanup
            self.failurePreparationToken = failurePreparationToken
        }
    }

    private static let persistenceSourcesLock = NSLock()
    private static var persistenceSourcesByKey: [String: PersistenceSource] = [:]
    private static let persistenceFlushes = ChatRemoteHistoryFlushSingleFlight<
        String,
        ChatRemoteHistoryCompletionResult
    >(completedCapacity: 128)

    private static func persistenceSourceKey(owner: String, queryId: String) -> String {
        "\(owner)\u{1F}remote-history\u{1F}\(queryId)"
    }

    static func registerPersistenceSource(
        _ manager: MessageManager,
        archiveManager: MessageArchiveManager? = nil,
        owner: String,
        queryId: String,
        priority: ArchivePersistencePriority = .background
    ) {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return
        }

        let preparationToken = MessageArchiveRequestFailurePreparationDispatcher.register(
            owner: owner,
            queryId: queryId
        ) { _, completion in
            unregisterPersistenceSource(
                owner: owner,
                queryId: queryId,
                completion: completion
            )
        }
        let sourceKey = persistenceSourceKey(owner: owner, queryId: queryId)
        let expectedReceivedCountProvider: ((String) -> Int?)?
        let ingressExpectationCleanup: ((String) -> Void)?
        if let archiveManager {
            expectedReceivedCountProvider = { [weak archiveManager] queryId in
                archiveManager?.expectedPersistenceResultCount(queryId: queryId)
            }
            ingressExpectationCleanup = { [weak archiveManager] queryId in
                archiveManager?.discardPersistenceIngressExpectation(
                    queryId: queryId
                )
            }
        } else {
            expectedReceivedCountProvider = nil
            ingressExpectationCleanup = nil
        }
        let newSource = PersistenceSource(
            manager,
            queryId: queryId,
            priority: priority,
            expectedReceivedCountProvider: expectedReceivedCountProvider,
            ingressExpectationCleanup: ingressExpectationCleanup,
            failurePreparationToken: preparationToken
        )
        persistenceSourcesLock.lock()
        let currentSource = persistenceSourcesByKey[sourceKey]
        let shouldInstallSource = currentSource == nil
        let didJoinSource = currentSource?.manager === manager
        if didJoinSource, priority > (currentSource?.priority ?? .background) {
            currentSource?.priority = priority
        }
        if didJoinSource,
           let expectedReceivedCountProvider {
            currentSource?.expectedReceivedCountProvider =
                expectedReceivedCountProvider
            currentSource?.ingressExpectationCleanup =
                ingressExpectationCleanup
        }
        if shouldInstallSource {
            persistenceSourcesByKey[sourceKey] = newSource
        }
        persistenceSourcesLock.unlock()

        guard shouldInstallSource || didJoinSource else {
            MessageArchiveRequestFailurePreparationDispatcher.unregister(preparationToken)
            ChatArchiveDebugTrace.log("remoteCompletionSourceRegisterRejected", [
                ("priority", priority.rawValue),
                ("sourceConflict", true)
            ])
            return
        }

        if didJoinSource {
            MessageArchiveRequestFailurePreparationDispatcher.unregister(preparationToken)
            if priority == .interactive {
                manager.promoteArchiveQueryBatch(queryId: queryId)
            }
        } else {
            persistenceFlushes.invalidateCompleted(key: sourceKey)
            manager.beginArchiveQueryBatch(queryId: queryId, priority: priority)
        }
        ChatArchiveDebugTrace.log("remoteCompletionSourceRegister", [
            ("priority", priority.rawValue),
            ("joined", didJoinSource),
            ("installed", shouldInstallSource)
        ])
    }

    static func unregisterPersistenceSource(
        owner: String,
        queryId: String,
        completion: (() -> Void)? = nil
    ) {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            completion?()
            return
        }

        let sourceKey = persistenceSourceKey(owner: owner, queryId: queryId)
        persistenceSourcesLock.lock()
        let persistenceSource = persistenceSourcesByKey[sourceKey]
        if let completion {
            persistenceSource?.terminalCompletions.append(completion)
        }
        let shouldStartTerminalFlush = persistenceSource?.isTerminalFlushInFlight == false
        if shouldStartTerminalFlush {
            persistenceSource?.isTerminalFlushInFlight = true
        }
        let terminalFlushPriority = persistenceSource?.priority ?? .background
        let terminalIngressExpectationCleanup =
            persistenceSource?.ingressExpectationCleanup
        persistenceSourcesLock.unlock()

        ChatArchiveDebugTrace.log("remoteCompletionSourceUnregister", [
            ("sourcePresent", persistenceSource != nil),
            ("startedTerminalFlush", shouldStartTerminalFlush),
            ("joinedTerminalFlush", persistenceSource != nil && !shouldStartTerminalFlush)
        ])
        guard let persistenceSource else {
            completion?()
            return
        }
        guard shouldStartTerminalFlush else {
            return
        }
        let source = persistenceSource.manager
        source.releaseArchiveQueryBatchIngressExpectation(
            queryId: queryId
        )
        source.finishArchiveQueryBatchAsync(
            queryId: queryId,
            priority: terminalFlushPriority
        ) { _ in
            completePersistenceSourceUnregister(
                persistenceSource,
                sourceKey: sourceKey,
                owner: owner,
                queryId: queryId,
                manager: source,
                ingressExpectationCleanup:
                    terminalIngressExpectationCleanup
            )
        }
    }

    private static func completePersistenceSourceUnregister(
        _ persistenceSource: PersistenceSource,
        sourceKey: String,
        owner: String,
        queryId: String,
        manager: MessageManager?,
        ingressExpectationCleanup: ((String) -> Void)?
    ) {
        ingressExpectationCleanup?(queryId)
        manager?.clearArchivePersistenceSummary(forQueryId: queryId)
        MessageArchiveRequestFailurePreparationDispatcher.unregister(
            persistenceSource.failurePreparationToken
        )

        persistenceSourcesLock.lock()
        if let registeredSource = persistenceSourcesByKey[sourceKey],
           registeredSource === persistenceSource {
            persistenceSourcesByKey.removeValue(forKey: sourceKey)
        }
        let completions = persistenceSource.terminalCompletions
        persistenceSource.terminalCompletions.removeAll()
        persistenceSourcesLock.unlock()

        ChatArchiveDebugTrace.log("remoteCompletionSourceUnregisterTerminal", [
            ("managerPresent", manager != nil),
            ("completionCount", completions.count)
        ])
        completions.forEach { $0() }
    }

    private static func registeredPersistenceSource(
        owner: String,
        queryId: String
    ) -> (
        manager: MessageManager,
        priority: ArchivePersistencePriority,
        expectedReceivedCountProvider: ((String) -> Int?)?
    )? {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return nil
        }

        persistenceSourcesLock.lock()
        let key = persistenceSourceKey(owner: owner, queryId: queryId)
        let persistenceSource = persistenceSourcesByKey[key]
        let result = persistenceSource.map {
            (
                $0.manager,
                $0.priority,
                $0.expectedReceivedCountProvider
            )
        }
        persistenceSourcesLock.unlock()
        return result
    }

    @discardableResult
    static func promotePersistenceSource(
        owner: String,
        queryId: String
    ) -> Bool {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return false
        }

        persistenceSourcesLock.lock()
        let key = persistenceSourceKey(owner: owner, queryId: queryId)
        let persistenceSource = persistenceSourcesByKey[key]
        persistenceSource?.priority = .interactive
        let manager = persistenceSource?.manager
        persistenceSourcesLock.unlock()

        manager?.promoteArchiveQueryBatch(queryId: queryId)
        ChatArchiveDebugTrace.log("remoteCompletionSourcePromote", [
            ("sourcePresent", manager != nil),
            ("priority", ArchivePersistencePriority.interactive.rawValue)
        ])
        return manager != nil
    }

    static func hasPendingMessages(owner: String, queryId: String) -> Bool {
        if let source = registeredPersistenceSource(owner: owner, queryId: queryId) {
            return source.manager.hasPendingMessages(forQueryId: queryId)
        }
        return AccountManager.shared.find(for: owner)?
            .messages
            .hasPendingMessages(forQueryId: queryId) ?? false
    }

    static func flushQueryMessages(
        owner: String,
        queryId: String,
        state: MessageArchivePageEndState,
        conversationJid: String? = nil,
        conversationType: ClientSynchronizationManager.ConversationType? = nil
    ) -> ChatRemoteHistoryCompletionResult {
        let startedAt = Date()
        ChatArchiveDebugTrace.log("remoteCompletionFlushStart", [
            ("hasConversation", conversationJid != nil && conversationType != nil),
            ("statePersisted", state.persistedMessageCount)
        ])
        let registeredSource = registeredPersistenceSource(owner: owner, queryId: queryId)
        let source = registeredSource?.manager ?? AccountManager.shared.find(for: owner)?.messages
        ChatArchiveDebugTrace.log("remoteCompletionSourceSelected", [
            ("registeredSource", registeredSource != nil),
            ("sourcePresent", source != nil),
            ("priority", registeredSource?.priority.rawValue ?? ArchivePersistencePriority.background.rawValue)
        ])
        let sourceFlushStartedAt = Date()
        let sourceSummary = source?.finishArchiveQueryBatchSummary(queryId: queryId) ?? MessageManager.ArchivePersistenceSummary()
        ChatArchiveDebugTrace.log("remoteCompletionSourceFlushDone", [
            ("durationMs", ChatArchiveDebugTrace.milliseconds(since: sourceFlushStartedAt)),
            ("received", sourceSummary.received),
            ("queued", sourceSummary.queued),
            ("savedNew", sourceSummary.savedNew),
            ("updatedExisting", sourceSummary.updatedExisting),
            ("skipped", sourceSummary.skipped),
            ("failed", sourceSummary.failed)
        ])
        let persistenceSummary = sourceSummary
        if let conversationJid,
           let conversationType,
           persistenceSummary.persistedRows > 0,
           persistenceSummary.visibleRows(owner: owner, jid: conversationJid, conversationType: conversationType) == 0 {
            ChatArchiveDebugTrace.log("remoteCompletionRowsNotVisible", [
                ("persisted", persistenceSummary.persistedRows)
            ])
        }

        let persistedMessageCount = max(state.persistedMessageCount, persistenceSummary.persistedRows)
        let effectiveState: MessageArchivePageEndState

        if persistedMessageCount != state.persistedMessageCount {
            effectiveState = MessageArchivePageEndState(
                queryExhausted: state.queryExhausted,
                archiveEnded: state.archiveEnded,
                persistedMessageCount: persistedMessageCount,
                requestCursorId: state.requestCursorId
            )
        } else {
            effectiveState = state
        }

        ChatArchiveDebugTrace.log("remoteCompletionFlushFinish", [
            ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
            ("persistedRows", persistenceSummary.persistedRows),
            ("processedRows", persistenceSummary.processedRows),
            ("effectivePersisted", effectiveState.persistedMessageCount)
        ])
        return ChatRemoteHistoryCompletionResult(
            state: effectiveState,
            flushedMessageCount: persistenceSummary.persistedRows,
            persistenceSummary: persistenceSummary
        )
    }

    static func flushQueryMessagesAsync(
        owner: String,
        queryId: String,
        state: MessageArchivePageEndState,
        expectedReceivedCount: Int? = nil,
        conversationJid: String? = nil,
        conversationType: ClientSynchronizationManager.ConversationType? = nil,
        completion: @escaping (ChatRemoteHistoryCompletionResult) -> Void
    ) {
        let key = persistenceSourceKey(owner: owner, queryId: queryId)
        persistenceFlushes.run(
            key: key,
            producer: { finish in
                let registeredSource = registeredPersistenceSource(
                    owner: owner,
                    queryId: queryId
                )
                let source = registeredSource?.manager ??
                    AccountManager.shared.find(for: owner)?.messages
                guard let source else {
                    finish(completionResult(
                        state: state,
                        persistenceSummary: MessageManager.ArchivePersistenceSummary(),
                        owner: owner,
                        conversationJid: conversationJid,
                        conversationType: conversationType
                    ))
                    return
                }
                let resolvedExpectedReceivedCount = expectedReceivedCount ??
                    registeredSource?.expectedReceivedCountProvider?(queryId)
                ChatArchiveDebugTrace.log(
                    "remoteCompletionIngressExpectationResolved",
                    [
                        ("explicit", expectedReceivedCount != nil),
                        (
                            "provider",
                            registeredSource?.expectedReceivedCountProvider != nil
                        ),
                        ("expectedReceivedCount", resolvedExpectedReceivedCount)
                    ]
                )
                source.finishArchiveQueryBatchAsync(
                    queryId: queryId,
                    priority: registeredSource?.priority ?? .background,
                    expectedReceivedCount: resolvedExpectedReceivedCount
                ) { summary in
                    finish(completionResult(
                        state: state,
                        persistenceSummary: summary,
                        owner: owner,
                        conversationJid: conversationJid,
                        conversationType: conversationType
                    ))
                }
            },
            completion: { result in
                // Preserve asynchronous, off-main terminal delivery without
                // parking a worker on a synchronous MessageManager flush.
                DispatchQueue.global(qos: .userInitiated).async {
                    completion(result)
                }
            }
        )
    }

    private static func completionResult(
        state: MessageArchivePageEndState,
        persistenceSummary: MessageManager.ArchivePersistenceSummary,
        owner: String,
        conversationJid: String?,
        conversationType: ClientSynchronizationManager.ConversationType?
    ) -> ChatRemoteHistoryCompletionResult {
        if let conversationJid,
           let conversationType,
           persistenceSummary.persistedRows > 0,
           persistenceSummary.visibleRows(
               owner: owner,
               jid: conversationJid,
               conversationType: conversationType
           ) == 0 {
            ChatArchiveDebugTrace.log("remoteCompletionRowsNotVisible", [
                ("persisted", persistenceSummary.persistedRows)
            ])
        }

        let persistedMessageCount = max(
            state.persistedMessageCount,
            persistenceSummary.persistedRows
        )
        let effectiveState: MessageArchivePageEndState
        if persistedMessageCount != state.persistedMessageCount {
            effectiveState = MessageArchivePageEndState(
                queryExhausted: state.queryExhausted,
                archiveEnded: state.archiveEnded,
                persistedMessageCount: persistedMessageCount,
                requestCursorId: state.requestCursorId
            )
        } else {
            effectiveState = state
        }
        return ChatRemoteHistoryCompletionResult(
            state: effectiveState,
            flushedMessageCount: persistenceSummary.persistedRows,
            persistenceSummary: persistenceSummary
        )
    }

    static func resetPersistenceFlushesForTests() {
        persistenceFlushes.reset()
        persistenceSourcesLock.lock()
        let sources = Array(persistenceSourcesByKey.values)
        persistenceSourcesByKey.removeAll()
        persistenceSourcesLock.unlock()
        sources.forEach {
            $0.ingressExpectationCleanup?($0.queryId)
            MessageArchiveRequestFailurePreparationDispatcher.unregister(
                $0.failurePreparationToken
            )
        }
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
        isResidentAtLiveTail: Bool,
        hasBottomBoundaryPlaceholder: Bool,
        hasBottomVirtualPlaceholder: Bool,
        hasNewerRemoteLoad: Bool
    ) -> Bool {
        guard isNearBottom else {
            return true
        }

        return !isResidentAtLiveTail
    }
}

enum ChatTimelineObserverRefreshPolicy {
    static func shouldOpenLatest(
        isTimelineEmpty: Bool,
        isResidentAtLiveTail: Bool,
        isShowingBootstrapPlaceholder: Bool,
        hasActiveRemoteLoad: Bool,
        hasInteractiveRemoteContext: Bool,
        hasSearchAnchorWork: Bool = false
    ) -> Bool {
        guard !hasActiveRemoteLoad,
              !hasInteractiveRemoteContext,
              !hasSearchAnchorWork else {
            return false
        }

        return isTimelineEmpty || isResidentAtLiveTail || isShowingBootstrapPlaceholder
    }
}

enum ChatTimelineObserverRefreshWindowPolicy {
    static func shouldReuseCurrentBoundedWindow(
        isTimelineEmpty: Bool,
        isResidentAtLiveTail: Bool,
        isShowingBootstrapPlaceholder: Bool,
        hasPendingForceLatestOpen: Bool
    ) -> Bool {
        !isTimelineEmpty &&
        isResidentAtLiveTail &&
        !isShowingBootstrapPlaceholder &&
        !hasPendingForceLatestOpen
    }
}

enum ChatInitialFramePendingObserverRefreshPolicy {
    enum Action: Equatable {
        case cancelAlreadyCurrent
        case flushNewerTail
    }

    static func action(
        displayedNewestPrimary: String?,
        residentNewestPrimary: String?
    ) -> Action {
        guard let displayedNewestPrimary,
              displayedNewestPrimary == residentNewestPrimary else {
            return .flushNewerTail
        }
        return .cancelAlreadyCurrent
    }
}

enum ChatObserverRefreshAnchorRestorePolicy {
    static func shouldSuppressOpenLatest(
        isSearchModeActive: Bool,
        isNearBottom: Bool,
        hasPendingForceLatestOpen: Bool
    ) -> Bool {
        isSearchModeActive && !isNearBottom && !hasPendingForceLatestOpen
    }

    static func visibleAnchorDirection(
        isSearchModeActive: Bool,
        isNearBottom: Bool,
        willOpenLatest: Bool,
        hasSearchAnchorWork: Bool,
        isShowingBootstrapPlaceholder: Bool
    ) -> ChatHistoryPageDirection? {
        guard isSearchModeActive,
              !isNearBottom,
              !willOpenLatest,
              !hasSearchAnchorWork,
              !isShowingBootstrapPlaceholder else {
            return nil
        }

        return .newer
    }

    static func restorePhase(hasCapturedAnchor: Bool) -> ChatHistoryPageAnchorRestorePhase {
        hasCapturedAnchor ? .applyTransaction : .none
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

enum ChatHistoryLoadingTimeoutPolicy {
    static let checkInterval: TimeInterval = 5.0
    static let interactiveHardTimeout: TimeInterval = 180.0

    static func shouldAbortInteractivePageLoad(elapsed: TimeInterval) -> Bool {
        elapsed >= interactiveHardTimeout
    }
}

enum ChatDatasourceApplyGenerationPolicy {
    static func shouldApply(requestGeneration: Int, currentGeneration: Int) -> Bool {
        requestGeneration == currentGeneration
    }
}

enum ChatRemoteHistoryApplyGuardPolicy {
    static func shouldApply(
        requestConversationKey: ChatTimelineConversationKey,
        currentConversationKey: ChatTimelineConversationKey,
        requestQueryId: String,
        finishingQueryId: String?
    ) -> Bool {
        guard requestConversationKey == currentConversationKey else {
            return false
        }

        guard let finishingQueryId else {
            return false
        }

        return finishingQueryId == requestQueryId
    }
}

enum ChatRemoteHistoryApplyProofPolicy {
    static func didAdvance(
        direction: ChatHistoryPageDirection,
        visibleRows: Int,
        resultCount: Int,
        queryExhausted: Bool,
        previousOldestArchivedId: String?,
        previousNewestArchivedId: String?,
        newOldestArchivedId: String?,
        newNewestArchivedId: String?
    ) -> Bool {
        if resultCount == 0 && queryExhausted {
            return true
        }

        guard visibleRows > 0 else {
            return false
        }

        switch direction {
        case .older:
            return normalized(previousOldestArchivedId) != normalized(newOldestArchivedId)
        case .newer:
            return normalized(previousNewestArchivedId) != normalized(newNewestArchivedId)
        }
    }

    private static func normalized(_ archivedId: String?) -> String? {
        RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archivedId)
    }
}

struct ChatRemoteHistoryApplyResult {
    let queryId: String
    let direction: ChatHistoryPageDirection
    let visibleRows: Int
    let resultCount: Int
    let queryExhausted: Bool
    let previousOldestArchivedId: String?
    let previousNewestArchivedId: String?
    let newOldestArchivedId: String?
    let newNewestArchivedId: String?
    let itemCount: Int
    let queueWaitMs: Int
    let mapDurationMs: Int

    var didAdvance: Bool {
        ChatRemoteHistoryApplyProofPolicy.didAdvance(
            direction: direction,
            visibleRows: visibleRows,
            resultCount: resultCount,
            queryExhausted: queryExhausted,
            previousOldestArchivedId: previousOldestArchivedId,
            previousNewestArchivedId: previousNewestArchivedId,
            newOldestArchivedId: newOldestArchivedId,
            newNewestArchivedId: newNewestArchivedId
        )
    }
}

enum ChatHistoryPageOutcome: Equatable {
    case advanced(persistedCursorId: String?)
    case emptyExhausted(persistedCursorId: String?)
    case duplicateOrNoAdvance(persistedCursorId: String?)
}

enum ChatHistoryPageOutcomePolicy {
    static func resolve(
        queryExhausted: Bool,
        didAdvance: Bool,
        persistedMessageCount: Int,
        requestedCursorId: String?,
        currentCursorId: String?
    ) -> ChatHistoryPageOutcome {
        if didAdvance {
            return .advanced(persistedCursorId: currentCursorId)
        }

        if queryExhausted && persistedMessageCount == 0 && requestedCursorId == currentCursorId {
            return .emptyExhausted(persistedCursorId: currentCursorId)
        }

        return .duplicateOrNoAdvance(persistedCursorId: currentCursorId)
    }
}

struct ChatArchiveCoverageCommitDecision: Equatable {
    let resolvedCursorId: String?
    let shouldCommitCoverage: Bool
    let shouldAdvanceOlderCursor: Bool
    let nextFullArchiveLoaded: Bool
    let shouldMarkNewerLiveEdgeReached: Bool
    let hasPersistenceProof: Bool
    let cursorRepeatedAfterCompletion: Bool
    let duplicateCursorSuppressed: Bool
    let authoritativeEmptyGapCoverage: ChatAuthoritativeEmptyGapCoverage?
}

struct ChatAuthoritativeEmptyGapCoverage: Equatable {
    let first: String
    let last: String
    let updateKind: RegularArchiveCoverageUpdateKind
}

enum ChatArchiveCoverageCommitPolicy {
    static func resolve(
        direction: ChatHistoryPageDirection,
        snapshot: ChatArchiveStateSnapshot,
        requestedCursorId: String?,
        observedCursorId: String?,
        transportFirst: String,
        transportLast: String,
        resultCount: Int,
        persistedRowsForQuery: Int,
        visibleRowsForConversation: Int,
        queryExhausted: Bool,
        canMutateOlderArchiveEnd: Bool,
        coverageUpdateKind: RegularArchiveCoverageUpdateKind
    ) -> ChatArchiveCoverageCommitDecision {
        let hasPersistenceProof = persistedRowsForQuery > 0
        let hasTransportRange = resultCount > 0 && (transportFirst.isNotEmpty || transportLast.isNotEmpty)
        let hasTerminalProof = queryExhausted && (resultCount == 0 || hasPersistenceProof)
        let shouldCommitCoverage = coverageUpdateKind.shouldMutateCoverage &&
            hasTransportRange &&
            hasPersistenceProof
        let shouldAdvanceOlderCursor = shouldAdvanceOlderCursor(
            direction: direction,
            updateKind: coverageUpdateKind,
            hasPersistenceProof: hasPersistenceProof
        )
        let resolvedCursorId: String?

        if shouldAdvanceOlderCursor {
            resolvedCursorId = ChatArchiveStateMutationPolicy.resolveCursorId(
                direction: direction,
                observedCursorId: observedCursorId,
                transportFirst: transportFirst,
                transportLast: transportLast,
                currentPersistedCursorId: snapshot.persistedCursorId,
                hasPersistenceProof: hasPersistenceProof
            )
        } else {
            resolvedCursorId = snapshot.persistedCursorId
        }
        let requestedCursorId = requestedCursorId?.isNotEmpty == true ? requestedCursorId : nil
        let cursorRepeatedAfterCompletion = requestedCursorId != nil && requestedCursorId == resolvedCursorId
        let duplicateCursorSuppressed = cursorRepeatedAfterCompletion &&
            resultCount > 0 &&
            !queryExhausted

        let shouldMarkOlderArchiveEnd = direction == .older &&
            hasTerminalProof &&
            canMutateOlderArchiveEnd &&
            shouldMarkOlderArchiveEnd(updateKind: coverageUpdateKind)
        let shouldClearOlderArchiveEnd = direction == .older &&
            hasPersistenceProof &&
            shouldAdvanceOlderCursor
        let shouldMarkNewerLiveEdgeReached = direction == .newer &&
            hasTerminalProof &&
            shouldMarkNewerLiveEdgeReached(updateKind: coverageUpdateKind)
        let authoritativeEmptyGapCoverage = authoritativeEmptyGapCoverage(
            snapshot: snapshot,
            updateKind: coverageUpdateKind,
            resultCount: resultCount,
            transportFirst: transportFirst,
            transportLast: transportLast,
            persistedRowsForQuery: persistedRowsForQuery,
            visibleRowsForConversation: visibleRowsForConversation,
            queryExhausted: queryExhausted
        )

        return ChatArchiveCoverageCommitDecision(
            resolvedCursorId: resolvedCursorId,
            shouldCommitCoverage: shouldCommitCoverage,
            shouldAdvanceOlderCursor: shouldAdvanceOlderCursor,
            nextFullArchiveLoaded: shouldMarkOlderArchiveEnd ? true : (shouldClearOlderArchiveEnd ? false : snapshot.fullArchiveLoaded),
            shouldMarkNewerLiveEdgeReached: shouldMarkNewerLiveEdgeReached,
            hasPersistenceProof: hasPersistenceProof,
            cursorRepeatedAfterCompletion: cursorRepeatedAfterCompletion,
            duplicateCursorSuppressed: duplicateCursorSuppressed,
            authoritativeEmptyGapCoverage: authoritativeEmptyGapCoverage
        )
    }

    private static func authoritativeEmptyGapCoverage(
        snapshot: ChatArchiveStateSnapshot,
        updateKind: RegularArchiveCoverageUpdateKind,
        resultCount: Int,
        transportFirst: String,
        transportLast: String,
        persistedRowsForQuery: Int,
        visibleRowsForConversation: Int,
        queryExhausted: Bool
    ) -> ChatAuthoritativeEmptyGapCoverage? {
        guard queryExhausted,
              resultCount == 0,
              transportFirst.isEmpty,
              transportLast.isEmpty,
              persistedRowsForQuery == 0,
              visibleRowsForConversation == 0 else {
            return nil
        }

        let matchingGap: RegularChatArchiveGap?
        switch updateKind {
        case .gapRepairOlder(let cursorArchiveId):
            let cursor = RegularChatArchiveSyncStateStorageItem
                .normalizedArchiveId(cursorArchiveId)
            matchingGap = snapshot.knownGaps.first {
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    $0.newerRangeOldestArchiveId
                ) == cursor
            }
        case .gapRepairNewer(let cursorArchiveId):
            let cursor = RegularChatArchiveSyncStateStorageItem
                .normalizedArchiveId(cursorArchiveId)
            matchingGap = snapshot.knownGaps.first {
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    $0.olderRangeNewestArchiveId
                ) == cursor
            }
        default:
            matchingGap = nil
        }
        guard let matchingGap else { return nil }
        return ChatAuthoritativeEmptyGapCoverage(
            first: matchingGap.olderRangeNewestArchiveId,
            last: matchingGap.newerRangeOldestArchiveId,
            updateKind: updateKind
        )
    }

    private static func shouldAdvanceOlderCursor(
        direction: ChatHistoryPageDirection,
        updateKind: RegularArchiveCoverageUpdateKind,
        hasPersistenceProof: Bool
    ) -> Bool {
        guard direction == .older,
              hasPersistenceProof else {
            return false
        }

        if case .pageOlder = updateKind {
            return true
        }
        return false
    }

    private static func shouldMarkNewerLiveEdgeReached(updateKind: RegularArchiveCoverageUpdateKind) -> Bool {
        if case .pageNewer = updateKind {
            return true
        }
        return false
    }

    private static func shouldMarkOlderArchiveEnd(updateKind: RegularArchiveCoverageUpdateKind) -> Bool {
        if case .pageOlder = updateKind {
            return true
        }
        return false
    }
}

struct ChatArchiveStateSnapshot: Equatable {
    let primaryKey: String
    let persistedCursorId: String?
    let fullArchiveLoaded: Bool
    let newestCursorId: String?
    let newerLiveEdgeReached: Bool
    let hasKnownNewerGap: Bool
    let knownGaps: [RegularChatArchiveGap]

    static func unresolved(primaryKey: String) -> ChatArchiveStateSnapshot {
        ChatArchiveStateSnapshot(
            primaryKey: primaryKey,
            persistedCursorId: nil,
            fullArchiveLoaded: false,
            newestCursorId: nil,
            newerLiveEdgeReached: false,
            hasKnownNewerGap: false,
            knownGaps: []
        )
    }

    init(
        primaryKey: String,
        persistedCursorId: String?,
        fullArchiveLoaded: Bool,
        newestCursorId: String? = nil,
        newerLiveEdgeReached: Bool = true,
        hasKnownNewerGap: Bool = false,
        knownGaps: [RegularChatArchiveGap] = []
    ) {
        self.primaryKey = primaryKey
        self.persistedCursorId = persistedCursorId
        self.fullArchiveLoaded = fullArchiveLoaded
        self.newestCursorId = newestCursorId
        self.newerLiveEdgeReached = newerLiveEdgeReached
        self.hasKnownNewerGap = hasKnownNewerGap
        self.knownGaps = knownGaps
    }
}

struct ChatArchiveStateMutationPlan: Equatable {
    let resolvedCursorId: String?
    let fullArchiveLoaded: Bool
    let shouldWriteCursor: Bool
    let shouldWriteFullArchiveLoaded: Bool

    var needsWrite: Bool {
        shouldWriteCursor || shouldWriteFullArchiveLoaded
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

enum ChatArchiveStateMutationPolicy {
    static func resolveCursorId(
        direction: ChatHistoryPageDirection,
        observedCursorId: String?,
        transportFirst: String,
        transportLast: String,
        currentPersistedCursorId: String?,
        hasPersistenceProof: Bool
    ) -> String? {
        let currentCursorId = currentPersistedCursorId?.isNotEmpty == true ? currentPersistedCursorId : nil
        let observedCursorId = observedCursorId?.isNotEmpty == true ? observedCursorId : nil
        if direction == .older,
           hasPersistenceProof {
            let transportCursorId = MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
                purpose: .pageOlder,
                first: transportFirst,
                last: transportLast,
                current: currentCursorId
            )
            if let transportCursorId, transportCursorId.isNotEmpty {
                return transportCursorId
            }
        }

        let resolvedCursorId = observedCursorId ?? currentCursorId
        guard let resolvedCursorId, resolvedCursorId.isNotEmpty else {
            return nil
        }
        return resolvedCursorId
    }

    static func resolveCursorId(
        observedCursorId: String?,
        transportFirst: String,
        transportLast: String,
        currentPersistedCursorId: String?
    ) -> String? {
        let currentCursorId = currentPersistedCursorId?.isNotEmpty == true ? currentPersistedCursorId : nil
        let observedCursorId = observedCursorId?.isNotEmpty == true ? observedCursorId : nil
        let fallbackCursorId = MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
            purpose: .pageOlder,
            first: transportFirst,
            last: transportLast,
            current: currentCursorId
        )
        let resolvedCursorId = observedCursorId ?? currentCursorId ?? fallbackCursorId
        guard let resolvedCursorId, resolvedCursorId.isNotEmpty else {
            return nil
        }
        return resolvedCursorId
    }

    static func resolvePlan(
        snapshot: ChatArchiveStateSnapshot,
        resolvedCursorId: String?,
        nextFullArchiveLoaded: Bool
    ) -> ChatArchiveStateMutationPlan {
        let currentCursorId = snapshot.persistedCursorId?.isNotEmpty == true ? snapshot.persistedCursorId : nil
        return ChatArchiveStateMutationPlan(
            resolvedCursorId: resolvedCursorId,
            fullArchiveLoaded: nextFullArchiveLoaded,
            shouldWriteCursor: resolvedCursorId != nil && resolvedCursorId != currentCursorId,
            shouldWriteFullArchiveLoaded: snapshot.fullArchiveLoaded != nextFullArchiveLoaded
        )
    }
}

enum ChatArchiveEndVerificationPolicy {
    static func shouldProbePersistedArchiveEnd(
        persistedArchiveEnded: Bool,
        hasConfirmedArchiveEndThisSession: Bool,
        hasUsedVerificationProbe: Bool
    ) -> Bool {
        persistedArchiveEnded &&
        !hasConfirmedArchiveEndThisSession &&
        !hasUsedVerificationProbe
    }

    static func effectiveArchiveEnded(
        persistedArchiveEnded: Bool,
        shouldProbePersistedArchiveEnd: Bool
    ) -> Bool {
        persistedArchiveEnded && !shouldProbePersistedArchiveEnd
    }
}

enum ChatHistoryCursorSelectionPolicy {
    static func oldestCursorId(
        observedArchivedIds: [String],
        persistedCursorId: String?
    ) -> String? {
        if let observedCursorId = observedArchivedIds.first(where: { $0.isNotEmpty }) {
            return observedCursorId
        }

        guard let persistedCursorId, persistedCursorId.isNotEmpty else {
            return nil
        }
        return persistedCursorId
    }

    static func newestCursorId(
        observedArchivedIds: [String],
        persistedCursorId: String?
    ) -> String? {
        if let observedCursorId = observedArchivedIds.reversed().first(where: { $0.isNotEmpty }) {
            return observedCursorId
        }

        guard let persistedCursorId, persistedCursorId.isNotEmpty else {
            return nil
        }
        return persistedCursorId
    }
}

enum ChatInteractiveOlderCursorSelectionSource: String {
    case virtualTimelineOldest
    case boundedTimelineOldest
    case observedOldest
    case persistedArchiveCursor
    case persistedFallback
    case none
}

struct ChatInteractiveOlderCursorSelection: Equatable {
    let cursorId: String?
    let source: ChatInteractiveOlderCursorSelectionSource
}

enum ChatInteractiveOlderCursorSelectionPolicy {
    static func select(
        timelineOldestArchivedId: String?,
        boundedOldestArchivedId: String?,
        observedArchivedIds: [String],
        persistedCursorId: String?
    ) -> ChatInteractiveOlderCursorSelection {
        let persistedCursorId = persistedCursorId?.isNotEmpty == true ? persistedCursorId : nil
        let activeSelection: ChatInteractiveOlderCursorSelection?

        if let timelineOldestArchivedId,
           timelineOldestArchivedId.isNotEmpty {
            activeSelection = ChatInteractiveOlderCursorSelection(
                cursorId: timelineOldestArchivedId,
                source: .virtualTimelineOldest
            )
        } else if let boundedOldestArchivedId,
                  boundedOldestArchivedId.isNotEmpty {
            activeSelection = ChatInteractiveOlderCursorSelection(
                cursorId: boundedOldestArchivedId,
                source: .boundedTimelineOldest
            )
        } else if let observedOldestArchivedId = observedArchivedIds.first(where: { $0.isNotEmpty }) {
            activeSelection = ChatInteractiveOlderCursorSelection(
                cursorId: observedOldestArchivedId,
                source: .observedOldest
            )
        } else {
            activeSelection = nil
        }

        if let persistedCursorId,
           let activeCursorId = activeSelection?.cursorId,
           compareArchiveIds(persistedCursorId, activeCursorId) == .orderedAscending {
            return ChatInteractiveOlderCursorSelection(
                cursorId: persistedCursorId,
                source: .persistedArchiveCursor
            )
        }

        if let activeSelection {
            return activeSelection
        }

        if let persistedCursorId {
            return ChatInteractiveOlderCursorSelection(
                cursorId: persistedCursorId,
                source: .persistedFallback
            )
        }

        return ChatInteractiveOlderCursorSelection(cursorId: nil, source: .none)
    }
}

enum ChatHistoryPagingPolicy {
    private static func boundaryAvailability(
        boundaryContext: ChatHistoryPagingBoundaryContext,
        currentPageMinIndex: Int,
        currentPageMaxIndex: Int,
        totalCount: Int,
        hasLocalOlderAvailable: Bool = false,
        hasLocalNewerAvailable: Bool = false,
        hasRemoteOlderAvailable: Bool = false,
        hasRemoteNewerAvailable: Bool = false,
        suppressRemoteBoundaryPaging: Bool = false
    ) -> (olderVisible: Bool, newerVisible: Bool) {
        let minVisibleSection = boundaryContext.visibleRealSections.min()
        let maxVisibleSection = boundaryContext.visibleRealSections.max()
        let hasLocalOlderPage = currentPageMinIndex > 0 || hasLocalOlderAvailable
        let hasLocalNewerPage = currentPageMaxIndex < totalCount || hasLocalNewerAvailable
        let allowsRemoteBoundaryPaging = !suppressRemoteBoundaryPaging && !boundaryContext.isEntireRealRangeVisible
        // `hasRemoteOlderAvailable` is already an authoritative, single-flight
        // availability bit: it becomes false while a remote page is active and
        // after archive end. A short resident page must therefore be allowed to
        // fetch its next server page even when every local row is visible.
        let hasOlderAvailable = hasLocalOlderPage || hasRemoteOlderAvailable
        let hasNewerAvailable = hasLocalNewerPage || (allowsRemoteBoundaryPaging && hasRemoteNewerAvailable)

        let olderVisible = hasOlderAvailable && (minVisibleSection.flatMap { visibleSection in
            boundaryContext.firstRealSection.map { visibleSection <= $0 }
        } ?? false)
        let newerVisible = hasNewerAvailable && (maxVisibleSection.flatMap { visibleSection in
            boundaryContext.lastRealSection.map { visibleSection >= $0 }
        } ?? false)

        return (olderVisible, newerVisible)
    }

    private static func directionForBoundaryDrag(
        gestureTranslationY: CGFloat,
        boundary: (olderVisible: Bool, newerVisible: Bool)
    ) -> ChatHistoryPageDirection? {
        switch boundary {
        case (true, false):
            return .older
        case (false, true):
            return .newer
        case (true, true):
            if gestureTranslationY > 0 {
                return .older
            }
            if gestureTranslationY < 0 {
                return .newer
            }
            return nil
        case (false, false):
            return nil
        }
    }

    static func triggerDirection(
        isUserScrolling: Bool,
        canLoadDatasource: Bool,
        gestureTranslationY: CGFloat,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        currentPageMinIndex: Int,
        currentPageMaxIndex: Int,
        totalCount: Int,
        hasLocalOlderAvailable: Bool = false,
        hasLocalNewerAvailable: Bool = false,
        hasRemoteOlderAvailable: Bool = false,
        hasRemoteNewerAvailable: Bool = false,
        suppressRemoteBoundaryPaging: Bool = false
    ) -> ChatHistoryPageDirection? {
        guard isUserScrolling,
              canLoadDatasource,
              !boundaryContext.visibleRealSections.isEmpty else {
            return nil
        }

        let boundary = boundaryAvailability(
            boundaryContext: boundaryContext,
            currentPageMinIndex: currentPageMinIndex,
            currentPageMaxIndex: currentPageMaxIndex,
            totalCount: totalCount,
            hasLocalOlderAvailable: hasLocalOlderAvailable,
            hasLocalNewerAvailable: hasLocalNewerAvailable,
            hasRemoteOlderAvailable: hasRemoteOlderAvailable,
            hasRemoteNewerAvailable: hasRemoteNewerAvailable,
            suppressRemoteBoundaryPaging: suppressRemoteBoundaryPaging
        )

        return directionForBoundaryDrag(
            gestureTranslationY: gestureTranslationY,
            boundary: boundary
        )
    }

    static func loadDecision(
        direction: ChatHistoryPageDirection,
        currentWindow: ChatDatasetWindow,
        requestedWindow: ChatDatasetWindow,
        localWindow: ChatDatasetWindow,
        totalCount: Int,
        isArchiveEnded: Bool,
        hasKnownNewerGap: Bool = false,
        newerLiveEdgeReached: Bool = true
    ) -> ChatHistoryPagingLoadDecision {
        switch direction {
        case .newer:
            guard requestedWindow.maxIndex > totalCount || localWindow.maxIndex < requestedWindow.maxIndex else {
                return .localOnly
            }
            return (hasKnownNewerGap || !newerLiveEdgeReached) ? .remoteNewerPage : .endReached
        case .older:
            if localWindow.minIndex < currentWindow.minIndex {
                let localOlderCount = currentWindow.minIndex - localWindow.minIndex
                let requestedOlderCount = currentWindow.minIndex - requestedWindow.minIndex
                if ChatShortLocalOlderRemainderPolicy.shouldRequestRemoteFirst(
                    localOlderCount: localOlderCount,
                    pageSize: requestedOlderCount,
                    archiveEnded: isArchiveEnded
                ) {
                    return .remoteOlderPage
                }
                return .localOnly
            }
            guard requestedWindow.minIndex < 0 else {
                return .localOnly
            }
            return isArchiveEnded ? .endReached : .remoteOlderPage
        }
    }

    static func fallbackDirectionForShortContentDrag(
        canLoadDatasource: Bool,
        gestureTranslationY: CGFloat,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        currentPageMinIndex: Int,
        currentPageMaxIndex: Int,
        totalCount: Int,
        hasLocalOlderAvailable: Bool = false,
        hasLocalNewerAvailable: Bool = false,
        hasRemoteOlderAvailable: Bool = false,
        hasRemoteNewerAvailable: Bool = false,
        suppressRemoteBoundaryPaging: Bool = false
    ) -> ChatHistoryPageDirection? {
        guard canLoadDatasource,
              !boundaryContext.visibleRealSections.isEmpty else {
            return nil
        }

        let boundary = boundaryAvailability(
            boundaryContext: boundaryContext,
            currentPageMinIndex: currentPageMinIndex,
            currentPageMaxIndex: currentPageMaxIndex,
            totalCount: totalCount,
            hasLocalOlderAvailable: hasLocalOlderAvailable,
            hasLocalNewerAvailable: hasLocalNewerAvailable,
            hasRemoteOlderAvailable: hasRemoteOlderAvailable,
            hasRemoteNewerAvailable: hasRemoteNewerAvailable,
            suppressRemoteBoundaryPaging: suppressRemoteBoundaryPaging
        )

        return directionForBoundaryDrag(
            gestureTranslationY: gestureTranslationY,
            boundary: boundary
        )
    }
}

enum ChatArchiveGapPagingPolicy {
    static func loadDecision(
        direction: ChatHistoryPageDirection,
        currentWindow: ChatDatasetWindow,
        requestedWindow: ChatDatasetWindow,
        archivedIdsByIndex: [String?],
        knownGaps: [RegularChatArchiveGap]
    ) -> ChatHistoryPagingLoadDecision? {
        guard knownGaps.isNotEmpty else {
            return nil
        }

        let currentArchiveIds = archiveIds(in: currentWindow, archivedIdsByIndex: archivedIdsByIndex)
        let requestedArchiveIds = archiveIds(in: requestedWindow, archivedIdsByIndex: archivedIdsByIndex)
        guard currentArchiveIds.isNotEmpty,
              requestedArchiveIds.isNotEmpty else {
            return nil
        }

        switch direction {
        case .older:
            let sortedGaps = knownGaps.sorted {
                (compareArchiveIds($0.newerRangeOldestArchiveId, $1.newerRangeOldestArchiveId) ?? .orderedAscending) == .orderedDescending
            }
            return sortedGaps.first(where: { gap in
                containsNewerSide(of: gap, in: currentArchiveIds) &&
                containsOlderSide(of: gap, in: requestedArchiveIds)
            }).map { .remoteGapRepairOlder($0) }
        case .newer:
            let sortedGaps = knownGaps.sorted {
                (compareArchiveIds($0.olderRangeNewestArchiveId, $1.olderRangeNewestArchiveId) ?? .orderedAscending) == .orderedAscending
            }
            return sortedGaps.first(where: { gap in
                containsOlderSide(of: gap, in: currentArchiveIds) &&
                containsNewerSide(of: gap, in: requestedArchiveIds)
            }).map { .remoteGapRepairNewer($0) }
        }
    }

    private static func archiveIds(
        in window: ChatDatasetWindow,
        archivedIdsByIndex: [String?]
    ) -> [String] {
        guard archivedIdsByIndex.isNotEmpty else {
            return []
        }
        let minIndex = max(0, window.minIndex)
        let maxIndex = min(archivedIdsByIndex.count, window.maxIndex)
        guard minIndex < maxIndex else {
            return []
        }
        return archivedIdsByIndex[minIndex..<maxIndex].compactMap {
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId($0)
        }
    }

    private static func containsOlderSide(
        of gap: RegularChatArchiveGap,
        in archiveIds: [String]
    ) -> Bool {
        archiveIds.contains {
            (compareArchiveIds($0, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending
        }
    }

    private static func containsNewerSide(
        of gap: RegularChatArchiveGap,
        in archiveIds: [String]
    ) -> Bool {
        archiveIds.contains {
            (compareArchiveIds($0, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        }
    }
}

enum ChatArchiveBoundaryGapPagingPolicy {
    static func loadDecision(
        direction: ChatHistoryPageDirection,
        currentOldestArchiveId: String?,
        currentNewestArchiveId: String?,
        requestedOldestArchiveId: String?,
        requestedNewestArchiveId: String?,
        knownGaps: [RegularChatArchiveGap]
    ) -> ChatHistoryPagingLoadDecision? {
        guard knownGaps.isNotEmpty,
              let currentOldestArchiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(currentOldestArchiveId),
              let currentNewestArchiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(currentNewestArchiveId),
              let requestedOldestArchiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(requestedOldestArchiveId),
              let requestedNewestArchiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(requestedNewestArchiveId) else {
            return nil
        }

        switch direction {
        case .older:
            let sortedGaps = knownGaps.sorted {
                (compareArchiveIds($0.newerRangeOldestArchiveId, $1.newerRangeOldestArchiveId) ?? .orderedAscending) == .orderedDescending
            }
            return sortedGaps.first(where: { gap in
                containsNewerSide(of: gap, oldest: currentOldestArchiveId, newest: currentNewestArchiveId) &&
                crossesBelowNewerBoundary(of: gap, oldest: requestedOldestArchiveId, newest: requestedNewestArchiveId)
            }).map { .remoteGapRepairOlder($0) }
        case .newer:
            let sortedGaps = knownGaps.sorted {
                (compareArchiveIds($0.olderRangeNewestArchiveId, $1.olderRangeNewestArchiveId) ?? .orderedAscending) == .orderedAscending
            }
            return sortedGaps.first(where: { gap in
                containsOlderSide(of: gap, oldest: currentOldestArchiveId, newest: currentNewestArchiveId) &&
                crossesAboveOlderBoundary(of: gap, oldest: requestedOldestArchiveId, newest: requestedNewestArchiveId)
            }).map { .remoteGapRepairNewer($0) }
        }
    }

    private static func containsOlderSide(
        of gap: RegularChatArchiveGap,
        oldest: String,
        newest: String
    ) -> Bool {
        let oldestIsOlderSide = (compareArchiveIds(oldest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending
        let newestIsOlderSide = (compareArchiveIds(newest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending
        let spansOlderSide = (compareArchiveIds(oldest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending &&
            (compareArchiveIds(newest, gap.olderRangeNewestArchiveId) ?? .orderedAscending) != .orderedAscending
        return oldestIsOlderSide || newestIsOlderSide || spansOlderSide
    }

    private static func containsNewerSide(
        of gap: RegularChatArchiveGap,
        oldest: String,
        newest: String
    ) -> Bool {
        let oldestIsNewerSide = (compareArchiveIds(oldest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        let newestIsNewerSide = (compareArchiveIds(newest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        let spansNewerSide = (compareArchiveIds(oldest, gap.newerRangeOldestArchiveId) ?? .orderedDescending) != .orderedDescending &&
            (compareArchiveIds(newest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        return oldestIsNewerSide || newestIsNewerSide || spansNewerSide
    }

    private static func crossesBelowNewerBoundary(
        of gap: RegularChatArchiveGap,
        oldest: String,
        newest: String
    ) -> Bool {
        let oldestIsBelowNewerBoundary = (compareArchiveIds(oldest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) == .orderedAscending
        let newestIsBelowNewerBoundary = (compareArchiveIds(newest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) == .orderedAscending
        let spansNewerBoundary = (compareArchiveIds(oldest, gap.newerRangeOldestArchiveId) ?? .orderedDescending) != .orderedDescending &&
            (compareArchiveIds(newest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        return oldestIsBelowNewerBoundary || newestIsBelowNewerBoundary || spansNewerBoundary
    }

    private static func crossesAboveOlderBoundary(
        of gap: RegularChatArchiveGap,
        oldest: String,
        newest: String
    ) -> Bool {
        let oldestIsAboveOlderBoundary = (compareArchiveIds(oldest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) == .orderedDescending
        let newestIsAboveOlderBoundary = (compareArchiveIds(newest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) == .orderedDescending
        let spansOlderBoundary = (compareArchiveIds(oldest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending &&
            (compareArchiveIds(newest, gap.olderRangeNewestArchiveId) ?? .orderedAscending) != .orderedAscending
        return oldestIsAboveOlderBoundary || newestIsAboveOlderBoundary || spansOlderBoundary
    }
}

enum ChatBootstrapViewState: Equatable {
    case skeleton
    case content
    case empty

    static func resolve(
        messageCount: Int,
        isSynced: Bool,
        isInitialArchiveLoaded: Bool = true,
        isInitialBootstrapInFlight: Bool,
        hasPendingInitialAnchorRequest: Bool,
        allowsStaleLocalHistory: Bool = false,
        allowsBootstrapFailureFallback: Bool = false
    ) -> ChatBootstrapViewState {
        ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: messageCount,
            isSynced: isSynced,
            isInitialArchiveLoaded: isInitialArchiveLoaded,
            isInitialBootstrapInFlight: isInitialBootstrapInFlight,
            hasPendingInitialAnchorRequest: hasPendingInitialAnchorRequest,
            allowsStaleLocalHistory: allowsStaleLocalHistory,
            hasTerminalFailure: allowsBootstrapFailureFallback
        )).viewState
    }
}

enum ChatBootstrapFailureFallback: Equatable {
    case content
    case empty
}

enum ChatBootstrapLoadingState: Equatable {
    case blockingArchive
    case blockingTarget
    case content
    case empty
    case failure(fallback: ChatBootstrapFailureFallback)

    var viewState: ChatBootstrapViewState {
        switch self {
        case .blockingArchive, .blockingTarget:
            return .skeleton
        case .content:
            return .content
        case .empty:
            return .empty
        case .failure(let fallback):
            return fallback == .content ? .content : .empty
        }
    }

    var showsSkeleton: Bool {
        switch self {
        case .blockingArchive, .blockingTarget:
            return true
        case .content, .empty, .failure:
            return false
        }
    }

    var showsRetry: Bool {
        if case .failure = self {
            return true
        }
        return false
    }

    var locksTimeline: Bool {
        showsSkeleton
    }
}

enum ChatInitialBootstrapAutomaticRetryPolicy {
    private static let initialDelay: TimeInterval = 0.5
    private static let maximumDelay: TimeInterval = 30

    static func delay(afterFailureCount failureCount: Int) -> TimeInterval {
        let exponent = min(max(0, failureCount - 1), 6)
        return min(
            maximumDelay,
            initialDelay * Double(1 << exponent)
        )
    }
}

enum ChatInitialBootstrapCommittedPresentationPolicy {
    static func loadingState(
        liveLoadingState: ChatBootstrapLoadingState,
        didConfirmEmpty: Bool
    ) -> ChatBootstrapLoadingState {
        didConfirmEmpty ? .empty : liveLoadingState
    }
}

enum ChatInitialBootstrapBoundaryFollowUpPolicy {
    static func requiresFollowUp(
        readiness: ConversationArchiveReadiness?,
        committedBoundaryMatchesCurrent: Bool,
        currentSnapshotRequiresFollowUp: Bool
    ) -> Bool {
        if let readiness,
           readiness.phase == .committed {
            // Persistence owns the terminal for this boundary. A frame that
            // started mapping before the coverage transaction may still carry
            // `isSynced == false`; it cannot turn the same committed page into
            // a second archive generation. A genuinely newer snapshot remains
            // visible through the boundary mismatch.
            return !readiness.hasDurableCoverage ||
                !committedBoundaryMatchesCurrent
        }
        return currentSnapshotRequiresFollowUp
    }
}

enum ChatBootstrapLoadingReducer {
    struct Input: Equatable {
        let messageCount: Int
        let isSynced: Bool
        let isInitialArchiveLoaded: Bool
        let isInitialBootstrapInFlight: Bool
        let hasPendingInitialAnchorRequest: Bool
        let allowsStaleLocalHistory: Bool
        let hasTerminalFailure: Bool
        let archiveReadiness: ConversationArchiveReadiness?

        init(
            messageCount: Int,
            isSynced: Bool,
            isInitialArchiveLoaded: Bool,
            isInitialBootstrapInFlight: Bool,
            hasPendingInitialAnchorRequest: Bool,
            allowsStaleLocalHistory: Bool,
            hasTerminalFailure: Bool,
            archiveReadiness: ConversationArchiveReadiness? = nil
        ) {
            self.messageCount = messageCount
            self.isSynced = isSynced
            self.isInitialArchiveLoaded = isInitialArchiveLoaded
            self.isInitialBootstrapInFlight = isInitialBootstrapInFlight
            self.hasPendingInitialAnchorRequest = hasPendingInitialAnchorRequest
            self.allowsStaleLocalHistory = allowsStaleLocalHistory
            self.hasTerminalFailure = hasTerminalFailure
            self.archiveReadiness = archiveReadiness
        }
    }

    static func resolve(_ input: Input) -> ChatBootstrapLoadingState {
        if input.hasPendingInitialAnchorRequest {
            return .blockingTarget
        }
        if let readiness = input.archiveReadiness {
            switch readiness.phase {
            case .queued, .transport, .persistence:
                return .blockingArchive
            case .committed:
                guard readiness.hasDurableCoverage else {
                    return .blockingArchive
                }
                if input.messageCount > 0 {
                    return .content
                }
                return readiness.confirmsEmptyConversation ? .empty : .blockingArchive
            case .failed:
                return .failure(fallback: input.messageCount > 0 ? .content : .empty)
            }
        }
        if input.isInitialBootstrapInFlight {
            return input.isSynced && input.isInitialArchiveLoaded && input.messageCount > 0
                ? .content
                : .blockingArchive
        }
        if input.hasTerminalFailure {
            return .failure(fallback: input.messageCount > 0 ? .content : .empty)
        }
        if input.allowsStaleLocalHistory && input.messageCount > 0 {
            return .content
        }
        if !input.isSynced || !input.isInitialArchiveLoaded {
            return .blockingArchive
        }
        return input.messageCount > 0 ? .content : .empty
    }
}

enum ChatBootstrapStateApplicationDecision: Equatable {
    case apply
    case noOp
}

enum ChatBootstrapStateApplicationPolicy {
    static func decision(
        previous: ChatBootstrapLoadingState?,
        next: ChatBootstrapLoadingState,
        hasCommittedContent: Bool = false,
        forceRender: Bool = false,
        hasCommittedSkeletonRows: Bool = false
    ) -> ChatBootstrapStateApplicationDecision {
        if previous == next {
            if !next.showsSkeleton,
               forceRender,
               hasCommittedSkeletonRows {
                // The reducer can observe durable empty coverage before the
                // UI has replaced an already committed skeleton datasource.
                // Equal terminal state is therefore not a visual no-op until
                // that older placeholder frame has been reconciled.
                return .apply
            }
            if next.showsSkeleton,
               forceRender,
               !hasCommittedContent,
               !hasCommittedSkeletonRows {
                return .apply
            }
            return .noOp
        }
        let hasCommittedTerminalPresentation =
            previous == .content ||
            previous == .empty ||
            hasCommittedContent
        if next.showsSkeleton,
           hasCommittedTerminalPresentation {
            return .noOp
        }
        return .apply
    }
}

enum ChatBootstrapTerminalPresentationInvariant {
    static func resolvedState(
        requested: ChatBootstrapLoadingState,
        hasCommittedTerminalPresentation: Bool,
        hasMaterializedContent: Bool,
        isReplacingConversation: Bool
    ) -> ChatBootstrapLoadingState {
        guard requested.showsSkeleton,
              hasCommittedTerminalPresentation,
              !isReplacingConversation else {
            return requested
        }
        return hasMaterializedContent ? .content : .empty
    }
}

enum ChatCommittedArchiveTerminalPresentationPolicy {
    static func resolvedState(
        requested: ChatBootstrapLoadingState,
        readiness: ConversationArchiveReadiness?,
        committedBoundaryMatchesCurrent: Bool,
        hasMaterializedContent: Bool,
        hasConsumedDurableEmptyTerminal: Bool = false
    ) -> ChatBootstrapLoadingState {
        if hasConsumedDurableEmptyTerminal {
            return hasMaterializedContent ? .content : .empty
        }
        guard let readiness,
              readiness.phase == .committed,
              readiness.hasDurableCoverage,
              committedBoundaryMatchesCurrent else {
            return requested
        }
        if hasMaterializedContent || readiness.persistedVisibleRowCount > 0 {
            return .content
        }
        if readiness.confirmsEmptyConversation {
            return .empty
        }
        return requested
    }
}

enum ChatBootstrapSkeletonDatasourceIdentity {
    static func matches(
        _ items: [ChatViewController.Datasource],
        owner: String,
        jid: String
    ) -> Bool {
        guard items.count == ChatSkeletonTemplate.descriptors.count else {
            return false
        }
        return zip(items, ChatSkeletonTemplate.descriptors).allSatisfy { pair in
            let (item, descriptor) = pair
            guard item.isFakeMessage,
                  item.owner == owner,
                  item.jid == jid,
                  item.primary == descriptor.primary,
                  item.messageId == descriptor.messageId,
                  item.sentDate == descriptor.sentDate,
                  case .skeleton = item.kind else {
                return false
            }
            return true
        }
    }
}

enum ChatBootstrapMappedSkeletonApplyPolicy {
    static func shouldApply(
        generationMatches: Bool,
        conversationMatches: Bool,
        loadingShowsSkeleton: Bool,
        skeletonVisibilityRequested: Bool,
        hasCommittedRealContent: Bool,
        hasRealDatasourceRows: Bool,
        hasCommittedSkeletonRows: Bool
    ) -> Bool {
        generationMatches &&
        conversationMatches &&
        loadingShowsSkeleton &&
        skeletonVisibilityRequested &&
        !hasCommittedRealContent &&
        !hasRealDatasourceRows &&
        !hasCommittedSkeletonRows
    }
}

struct ChatBootstrapAtomicRevealPlan: Equatable {
    let destinationRowCount: Int
    let datasourceApplyCount: Int
    let intermediateEmptyFrameCount: Int

    static func resolve(
        previous: ChatBootstrapLoadingState,
        destinationRowCount: Int
    ) -> ChatBootstrapAtomicRevealPlan {
        ChatBootstrapAtomicRevealPlan(
            destinationRowCount: max(0, destinationRowCount),
            datasourceApplyCount: 1,
            intermediateEmptyFrameCount: 0
        )
    }
}

enum ChatBootstrapCoverageFollowUpPresentationPolicy {
    static func loadingState(
        hasCommittedTargetRows: Bool
    ) -> ChatBootstrapLoadingState {
        hasCommittedTargetRows ? .content : .blockingArchive
    }

    static func shouldRefreshDatasource(
        isLatestCoverageFollowUp: Bool,
        isSupersededByPendingTarget: Bool,
        pendingTargetMatchesCurrentTarget: Bool = false,
        hasCommittedTargetRows: Bool,
        hasPersistedPageContent: Bool
    ) -> Bool {
        hasPersistedPageContent &&
            (
                !isSupersededByPendingTarget ||
                pendingTargetMatchesCurrentTarget
            ) &&
            !(isLatestCoverageFollowUp && hasCommittedTargetRows)
    }
}

enum ChatInitialBootstrapContentRevealPolicy {
    static func shouldRevealContent(
        isShowingSkeleton: Bool,
        bootstrapState: ChatBootstrapViewState
    ) -> Bool {
        isShowingSkeleton && bootstrapState == .content
    }
}

enum ChatInitialBootstrapFailureRecoveryPolicy {
    static func shouldRevealLocalHistory(
        messageCount: Int,
        hasPendingInitialAnchorRequest: Bool
    ) -> Bool {
        messageCount > 0 && !hasPendingInitialAnchorRequest
    }
}

enum ChatBootstrapLocalHistoryFallbackPolicy {
    static let fallbackDelay: TimeInterval = 0.25

    static func shouldScheduleFallback(
        messageCount: Int,
        isShowingSkeleton: Bool,
        allowsStaleLocalHistory: Bool,
        hasPendingInitialAnchorRequest: Bool,
        isRequiredArchiveBootstrapInFlight: Bool = false
    ) -> Bool {
        messageCount > 0 &&
        isShowingSkeleton &&
        !allowsStaleLocalHistory &&
        !hasPendingInitialAnchorRequest &&
        !isRequiredArchiveBootstrapInFlight
    }

    static func shouldRevealLocalHistory(
        messageCount: Int,
        isShowingSkeleton: Bool,
        hasPendingInitialAnchorRequest: Bool,
        isRequiredArchiveBootstrapInFlight: Bool = false
    ) -> Bool {
        messageCount > 0 &&
        isShowingSkeleton &&
        !hasPendingInitialAnchorRequest &&
        !isRequiredArchiveBootstrapInFlight
    }
}

enum ChatBootstrapSkeletonRenderPolicy {
    static func shouldRenderSkeletonDatasource(
        forceRender: Bool,
        isDatasourceEmpty: Bool,
        isShowingBootstrapPlaceholder: Bool
    ) -> Bool {
        forceRender || isDatasourceEmpty || !isShowingBootstrapPlaceholder
    }
}

enum ChatCommittedSkeletonBlockingTransitionPolicy {
    static func shouldApplyStateOnly(
        previous: ChatBootstrapLoadingState?,
        next: ChatBootstrapLoadingState,
        hasCommittedExactSkeletonRows: Bool,
        hasCommittedRealContent: Bool
    ) -> Bool {
        previous != next &&
        previous?.showsSkeleton == true &&
        next.showsSkeleton &&
        hasCommittedExactSkeletonRows &&
        !hasCommittedRealContent
    }
}

struct ChatLocalFirstFrameDescriptor: Equatable {
    let target: ChatTimelineInitialFrameTarget
    let request: ChatOpenMessageRequest?
}

/// Exact visible state that preceded an unacknowledged first-frame attempt.
/// It remains attached to the immutable attempt through the CA/stable-frame
/// boundary so a replacement can synchronously remove A before B remaps.
struct ChatInitialFramePresentationRollbackSnapshot {
    let datasource: [ChatViewController.Datasource]
    let datasourceSnapshot: ChatDatasourceSnapshot
    let layoutSnapshot: ChatMessageLayoutSnapshot
    let contentInsets: UIEdgeInsets
    let verticalScrollIndicatorInsets: UIEdgeInsets
    let horizontalScrollIndicatorInsets: UIEdgeInsets
    let contentOffset: CGPoint
    let residentDatasetWindow: ChatDatasetWindow
    let boundaryPlaceholder: ChatHistoryBoundaryPlaceholderPosition?
    let boundaryAvailabilityCache: ChatScrollBoundaryAvailabilityCache
    let bootstrapLoadingState: ChatBootstrapLoadingState?
    let showsSkeleton: Bool
    let canLoadDatasource: Bool
    let showsLoadingIndicator: Bool
    let showsArchiveLoadingIndicator: Bool
    let isCollectionUserInteractionEnabled: Bool
    let isCollectionScrollEnabled: Bool
    let isTimelineInteractionLoading: Bool
    let isTimelineInteractionLocked: Bool
    let showsInitialMessage: Bool
    let hasCommittedRealContent: Bool
    let hasCommittedSkeletonPresentation: Bool
    let hasCommittedTimelinePresentation: Bool
    let initialContentApplyCount: Int
    let lastAtomicRevealPlan: ChatBootstrapAtomicRevealPlan?
    let hasRenderedStableInitialHistory: Bool
    let initialHistoryAppearancePending: Bool
    let hasCompletedInitialHistoryViewAppearance: Bool
    let allowsBootstrapFailureFallback: Bool
    let preservesBootstrapFailureOverlayUntilRetryCommit: Bool
    let showsBootstrapFailure: Bool
}

/// Small, value-only proof for effects that may outlive strong presentation
/// ownership. It intentionally excludes the rollback snapshot and mapping
/// token so delayed read/highlight/proof work cannot retain the old frame.
struct ChatInitialFrameEffectToken: Hashable {
    let presentationGeneration: UInt64
    let sessionIdentifier: ObjectIdentifier
    let descriptor: ChatLocalFirstFrameDescriptor
    let anchorTransactionToken: ChatAnchorTransactionToken?

    static func == (
        lhs: ChatInitialFrameEffectToken,
        rhs: ChatInitialFrameEffectToken
    ) -> Bool {
        lhs.presentationGeneration == rhs.presentationGeneration &&
            lhs.sessionIdentifier == rhs.sessionIdentifier &&
            lhs.descriptor == rhs.descriptor &&
            lhs.anchorTransactionToken == rhs.anchorTransactionToken
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(presentationGeneration)
        hasher.combine(sessionIdentifier)
    }
}

/// Immutable identity of one real initial-frame publication attempt. The
/// descriptor alone is deliberately insufficient: the same semantic request
/// can be remapped while an older UIKit/CATransaction completion is still
/// queued. Holding the exact mapping token also prevents its object identity
/// from being reused through a later controller-owned generation.
final class ChatInitialFramePresentationAttempt {
    let descriptor: ChatLocalFirstFrameDescriptor
    let mappingToken: ChatDatasetMappingCancellationToken?
    let mappingGeneration: Int
    let sessionIdentifier: ObjectIdentifier
    let timelineGeneration: UInt64
    let anchorTransactionToken: ChatAnchorTransactionToken?
    let presentationGeneration: UInt64
    let performanceTraceContext: ChatOpenPerformanceTraceContext?
    let ownsPerformancePresentingInterval: Bool
    let rollbackSnapshot: ChatInitialFramePresentationRollbackSnapshot?

    var effectToken: ChatInitialFrameEffectToken {
        ChatInitialFrameEffectToken(
            presentationGeneration: presentationGeneration,
            sessionIdentifier: sessionIdentifier,
            descriptor: descriptor,
            anchorTransactionToken: anchorTransactionToken
        )
    }

    init(
        descriptor: ChatLocalFirstFrameDescriptor,
        mappingToken: ChatDatasetMappingCancellationToken?,
        mappingGeneration: Int,
        session: ChatTimelineSession,
        timelineGeneration: UInt64,
        anchorTransactionToken: ChatAnchorTransactionToken?,
        presentationGeneration: UInt64,
        performanceTraceContext: ChatOpenPerformanceTraceContext?,
        ownsPerformancePresentingInterval: Bool,
        rollbackSnapshot: ChatInitialFramePresentationRollbackSnapshot? = nil
    ) {
        self.descriptor = descriptor
        self.mappingToken = mappingToken
        self.mappingGeneration = mappingGeneration
        self.sessionIdentifier = ObjectIdentifier(session)
        self.timelineGeneration = timelineGeneration
        self.anchorTransactionToken = anchorTransactionToken
        self.presentationGeneration = presentationGeneration
        self.performanceTraceContext = performanceTraceContext
        self.ownsPerformancePresentingInterval = ownsPerformancePresentingInterval
        self.rollbackSnapshot = rollbackSnapshot
    }
}

enum ChatInitialFramePresentationAttemptPhase: Equatable {
    case presenting
    case committed
}

struct ChatInitialFramePresentationOwnership {
    let attempt: ChatInitialFramePresentationAttempt
    var phase: ChatInitialFramePresentationAttemptPhase
}

final class ChatDeferredInitialFrameReplacement {
    let supersededAttempt: ChatInitialFramePresentationAttempt
    let request: ChatOpenMessageRequest
    let hooks: ChatAnchorExecutionHooks?

    init(
        supersededAttempt: ChatInitialFramePresentationAttempt,
        request: ChatOpenMessageRequest,
        hooks: ChatAnchorExecutionHooks?
    ) {
        self.supersededAttempt = supersededAttempt
        self.request = request
        self.hooks = hooks
    }
}

enum ChatLocalFirstFramePhase: Equatable {
    case idle
    case preparing(ChatLocalFirstFrameDescriptor)
    case presenting(ChatLocalFirstFrameDescriptor)
    case committed(ChatLocalFirstFrameDescriptor)
    case blockedArchiveBootstrap(ChatLocalFirstFrameDescriptor)
    case blockedMissingTarget(ChatLocalFirstFrameDescriptor)
    case failedPresentation(ChatLocalFirstFrameDescriptor)
}

enum ChatInitialFramePendingRequestOwnershipPolicy {
    /// A matching exact request is already being executed by the typed
    /// initial-frame pipeline. The stacked-presentation timeout may commit a
    /// skeleton and let UIKit finish its push while that mapping is still in
    /// flight, but it does not transfer request ownership to the generic
    /// anchor pipeline. Starting both pipelines would let either mapping
    /// cancel the other's shared dataset generation and can reinterpret the
    /// surviving retry as a latest open after the request is cleared.
    static func isOwnedByInitialFrame(
        request: ChatOpenMessageRequest,
        phase: ChatLocalFirstFramePhase
    ) -> Bool {
        switch phase {
        case .preparing(let descriptor), .presenting(let descriptor):
            return descriptor.request == request
        case .idle,
             .committed,
             .blockedArchiveBootstrap,
             .blockedMissingTarget,
             .failedPresentation:
            return false
        }
    }
}

/// Identity of one fully prepared initial frame whose UIKit publication is
/// suspended only because the application is in background. Store selection,
/// display mapping, and layout prewarming already belong to this identity and
/// must not run again when the app becomes presentation-eligible.
struct ChatInitialFrameLifecyclePresentationIdentity: Equatable {
    let conversationKey: ChatTimelineConversationKey
    let bootstrapQueryId: String?
    let targetFingerprint: MessageArchiveManager.ChatBootstrapTargetFingerprint?
    let descriptor: ChatLocalFirstFrameDescriptor
    let datasetMappingGeneration: Int
    let timelineGeneration: UInt64
    let timelineProjection: ChatTimelineStoreObservationAuthorityProjection
}

/// A background-only generation advance may come from installing the Realm
/// observation for the frame that was already materialized. Reuse the exact
/// prepared mapping only when every presentation-relevant value projection is
/// unchanged; a new row, edit, gap/load transition, or unread-state mutation
/// still invalidates it.
enum ChatInitialFrameLifecycleSnapshotContinuityPolicy {
    static func admits(
        preparedGeneration: UInt64,
        preparedProjection: ChatTimelineStoreObservationAuthorityProjection,
        current: ChatTimelineSessionSnapshot
    ) -> Bool {
        current.generation == preparedGeneration ||
            (
                current.generation > preparedGeneration &&
                ChatTimelineStoreObservationAuthorityProjection.capture(
                    current
                ) == preparedProjection
            )
    }
}

/// Immutable ownership of the compound post-bootstrap target-window commit.
/// Its revocation bit is lock-protected because query replacement is
/// main-owned while authorization runs on the timeline preparation queue.
struct ChatPostBootstrapInitialFrameAdmissionIdentity: Equatable {
    let conversationKey: ChatTimelineConversationKey
    let bootstrapQueryId: String?
    let targetFingerprint: MessageArchiveManager.ChatBootstrapTargetFingerprint?
    let descriptor: ChatLocalFirstFrameDescriptor
    let datasetMappingGeneration: Int
    let timelineGeneration: UInt64
}

final class ChatPostBootstrapInitialFrameAdmission {
    let identity: ChatPostBootstrapInitialFrameAdmissionIdentity
    let mappingToken: ChatDatasetMappingCancellationToken
    weak var session: ChatTimelineSession?

    private let lock = NSLock()
    private var revoked = false

    init(
        identity: ChatPostBootstrapInitialFrameAdmissionIdentity,
        mappingToken: ChatDatasetMappingCancellationToken,
        session: ChatTimelineSession
    ) {
        self.identity = identity
        self.mappingToken = mappingToken
        self.session = session
    }

    var authorizesCommit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !revoked && !mappingToken.isCancelled
    }

    func revoke() {
        lock.lock()
        revoked = true
        mappingToken.cancel()
        lock.unlock()
    }
}

/// Thread-safe ownership for a bounded target-window rematerialization that
/// belongs to the already active exact-anchor transaction. Query/lifecycle
/// cancellation is main-owned, while the compound Realm lease authorizes its
/// generation commit on the timeline preparation queue.
final class ChatAnchorPersistenceMaterializationAdmission {
    let transactionToken: ChatAnchorTransactionToken
    let request: ChatOpenMessageRequest
    let expectedTimelineGeneration: UInt64
    let mappingToken: ChatDatasetMappingCancellationToken?
    weak var session: ChatTimelineSession?

    private let lock = NSLock()
    private var revoked = false

    init(
        transactionToken: ChatAnchorTransactionToken,
        request: ChatOpenMessageRequest,
        expectedTimelineGeneration: UInt64,
        mappingToken: ChatDatasetMappingCancellationToken?,
        session: ChatTimelineSession
    ) {
        self.transactionToken = transactionToken
        self.request = request
        self.expectedTimelineGeneration = expectedTimelineGeneration
        self.mappingToken = mappingToken
        self.session = session
    }

    var authorizesCommit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !revoked && mappingToken?.isCancelled != true
    }

    func revoke() {
        lock.lock()
        revoked = true
        mappingToken?.cancel()
        lock.unlock()
    }
}

enum ChatAnchorPersistenceWindowMaterializationResult {
    case committed(
        ChatTimelineSessionSnapshot,
        ChatTimelineSearchResolutionProof
    )
    case failed(ChatAnchorTransactionFailure)
    case blocked
    case rejected
    case stale
}

struct ChatAnchorMappedPersistenceWindow {
    let descriptor: ChatLocalFirstFrameDescriptor
    let mappingGeneration: Int
    let mappingToken: ChatDatasetMappingCancellationToken
    let preparedFrame: ChatTimelinePreparedInitialFrame
    let committedSnapshot: ChatTimelineSessionSnapshot
    let mappingResult: ChatDatasourceMappingResult
    let mappedOnMainThread: Bool
}

enum ChatAnchorMappedPersistenceWindowResult {
    case committed(ChatAnchorMappedPersistenceWindow)
    case failed(ChatAnchorTransactionFailure)
    case blocked
    case rejected
    case stale
}

/// A controller-local visual continuation, not an archive/page cache. The
/// account coordinator remains the sole owner of the durable receipt; this
/// object retains only the already prepared frame until UIKit may publish it.
final class ChatInitialFrameLifecyclePresentation {
    let identity: ChatInitialFrameLifecyclePresentationIdentity
    let mappingToken: ChatDatasetMappingCancellationToken?
    let apply: () -> Void

    init(
        identity: ChatInitialFrameLifecyclePresentationIdentity,
        mappingToken: ChatDatasetMappingCancellationToken?,
        apply: @escaping () -> Void
    ) {
        self.identity = identity
        self.mappingToken = mappingToken
        self.apply = apply
    }
}

enum ChatInitialFrameBoundaryPagingAdmissionPolicy {
    static func shouldAdmit(
        phase: ChatLocalFirstFramePhase,
        hasCommittedTimelinePresentation: Bool,
        hasRealDatasourceRows: Bool,
        isShowingSkeleton: Bool
    ) -> Bool {
        switch phase {
        case .committed, .idle:
            break
        case .preparing, .presenting, .blockedArchiveBootstrap,
             .blockedMissingTarget, .failedPresentation:
            return false
        }
        return hasCommittedTimelinePresentation &&
            hasRealDatasourceRows &&
            !isShowingSkeleton
    }
}

enum ChatInitialFramePresentationFailureRecoveryAction: Equatable {
    case remapFreshGeneration
    case showTerminalRetry
}

enum ChatInitialFramePresentationFailureRecoveryPolicy {
    static func action(
        failedDescriptor: ChatLocalFirstFrameDescriptor,
        previouslyRetriedDescriptor: ChatLocalFirstFrameDescriptor?
    ) -> ChatInitialFramePresentationFailureRecoveryAction {
        previouslyRetriedDescriptor == failedDescriptor
            ? .showTerminalRetry
            : .remapFreshGeneration
    }
}

enum ChatInitialFrameLogicalCommitStatePolicy {
    static func loadingState(
        previous: ChatBootstrapLoadingState,
        committedItemsAreEmpty: Bool,
        hasTrustedPersistedBootstrapPage: Bool
    ) -> ChatBootstrapLoadingState {
        if previous.showsRetry,
           !hasTrustedPersistedBootstrapPage {
            return previous
        }
        return committedItemsAreEmpty ? .empty : .content
    }
}

enum ChatInitialFrameStoreChangeRoutingAction: Equatable {
    case coalesce
    case apply
    case ignore
}

enum ChatInitialFrameStoreChangeRoutingPolicy {
    static func action(
        phase: ChatLocalFirstFramePhase,
        hasCommittedTimelinePresentation: Bool
    ) -> ChatInitialFrameStoreChangeRoutingAction {
        switch phase {
        case .preparing, .presenting, .blockedArchiveBootstrap,
                .blockedMissingTarget, .failedPresentation:
            return .coalesce
        case .idle, .committed:
            return hasCommittedTimelinePresentation ? .apply : .ignore
        }
    }
}

enum ChatInitialFrameObserverRefreshBarrierPolicy {
    static func shouldDefer(
        phase: ChatLocalFirstFramePhase,
        hasCommittedTimelinePresentation: Bool
    ) -> Bool {
        switch phase {
        case .preparing, .presenting, .blockedArchiveBootstrap,
                .blockedMissingTarget, .failedPresentation:
            return true
        case .idle:
            return !hasCommittedTimelinePresentation
        case .committed:
            return false
        }
    }
}

enum ChatLocalFirstFrameDescriptorPolicy {
    static func descriptor(
        request: ChatOpenMessageRequest?,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ChatLocalFirstFrameDescriptor {
        guard let request,
              request.owner == owner,
              request.chatJid == jid,
              request.conversationType == conversationType else {
            return ChatLocalFirstFrameDescriptor(target: .latest, request: nil)
        }

        let target: ChatTimelineInitialFrameTarget
        switch request.targetResolution {
        case .firstIncomingAfterBoundary(let boundaryArchivedId):
            target = .firstIncomingAfterBoundary(boundaryArchivedId)
        case .anchor:
            target = .message(
                ChatTimelineAnchor(
                    primary: request.anchor.messagePrimary,
                    archivedId: request.anchor.archivedId,
                    messageId: request.anchor.messageId,
                    date: request.anchor.sourceDate
                )
            )
        }
        return ChatLocalFirstFrameDescriptor(target: target, request: request)
    }
}

enum ChatLocalFirstFrameRequestAdmissionPolicy {
    /// Admission is intentionally structural. It answers whether the request
    /// can be handed to the typed background window preparation, never whether
    /// Realm currently contains the target. Target existence and its bounded
    /// window are resolved exactly once by `messageWindow` or
    /// `firstIncomingWindow` off the main thread.
    static func isStructurallyAdmissible(
        request: ChatOpenMessageRequest,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> Bool {
        guard request.owner == owner,
              request.chatJid == jid,
              request.conversationType == conversationType else {
            return false
        }

        guard ChatInitialAnchorBootstrapPolicy.needsLocalAnchorLookup(
            source: request.source
        ) else {
            return false
        }

        switch request.targetResolution {
        case .firstIncomingAfterBoundary(let boundaryArchivedId):
            return request.source == .initialUnreadBoundary &&
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    boundaryArchivedId
                ) != nil &&
                ChatInitialPositionPolicy.archiveDate(
                    from: boundaryArchivedId
                ) != nil
        case .anchor:
            return request.anchor.messagePrimary?.isNotEmpty == true ||
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    request.anchor.archivedId
                ) != nil ||
                request.anchor.messageId?.isNotEmpty == true
        }
    }
}

enum ChatLocalFirstFrameAvailabilityDecision: Equatable {
    case prepareLocal
    case blockForArchiveBootstrap
}

enum ChatInitialMaterializationProbeAdmissionPolicy {
    /// A readiness proof embedded in a reused session belongs to the previous
    /// presentation lifecycle. A fresh controller must still run its one
    /// bounded typed preparation so it can publish that session without
    /// remaining on skeleton. Once preparation has begun, a current proof
    /// suppresses duplicate probes.
    static func allows(
        isFreshPresentationLifecycle: Bool,
        hasCurrentReadinessProof: Bool
    ) -> Bool {
        isFreshPresentationLifecycle || !hasCurrentReadinessProof
    }
}

enum ChatInitialSessionObservationTransferPolicy {
    /// A session may outlive its presenting controller. Its store observer is
    /// authoritative for the old presentation, but must not publish a
    /// metadata-only generation between this controller's typed query and
    /// generation-checked initial commit. The normal successful commit path
    /// reactivates observation after the sole real frame is installed.
    static func shouldQuiesce(
        isFreshPresentationLifecycle: Bool,
        hasCommittedInitialContent: Bool
    ) -> Bool {
        isFreshPresentationLifecycle && !hasCommittedInitialContent
    }
}

enum ChatLocalAnchorFirstFrameEligibilityPolicy {
    /// A local explicit push/search/unread/mention target is authoritative even while
    /// the surrounding archive is still repairing. A saved position is only
    /// a reusable local first frame after both its window and the conversation's
    /// current durable archive generation are proven safe.
    static func isEligible(
        requestSource: ChatOpenMessageRequestSource?,
        hasStructurallySafeLocalAnchor: Bool,
        hasDurableArchiveReadiness: Bool
    ) -> Bool {
        guard hasStructurallySafeLocalAnchor else {
            return false
        }
        guard requestSource == .savedVisiblePosition else {
            return true
        }
        return hasDurableArchiveReadiness
    }
}

enum ChatSavedPositionDurableWindowCoveragePolicy {
    /// Saved-position history is reusable only when every stable archive id
    /// in the proposed first frame belongs to one positively persisted range.
    /// Empty/nil archive bounds require a stronger target-scoped receipt,
    /// which this local-range path deliberately cannot infer.
    static func isCovered(
        requestSource: ChatOpenMessageRequestSource?,
        windowArchiveIds: [String?],
        loadedRanges: [RegularChatArchiveIDRange]
    ) -> Bool {
        guard requestSource == .savedVisiblePosition else {
            return true
        }
        guard !windowArchiveIds.isEmpty else {
            return false
        }
        let archiveIds = windowArchiveIds.compactMap {
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId($0)
        }
        guard archiveIds.count == windowArchiveIds.count else {
            return false
        }
        return loadedRanges.contains { range in
            archiveIds.allSatisfy { archiveId in
                contains(archiveId, in: range)
            }
        }
    }

    private static func contains(
        _ archiveId: String,
        in range: RegularChatArchiveIDRange
    ) -> Bool {
        guard let oldestArchiveId =
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    range.oldestArchiveId
                ),
              let newestArchiveId =
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    range.newestArchiveId
                ),
              let lower = compareArchiveIds(archiveId, oldestArchiveId),
              let upper = compareArchiveIds(archiveId, newestArchiveId) else {
            return false
        }
        return lower != .orderedAscending && upper != .orderedDescending
    }
}

enum ChatLocalFirstFrameAvailabilityPolicy {
    static func decision(
        isSynced: Bool,
        isInitialArchiveLoaded: Bool,
        isInitialBootstrapInFlight: Bool,
        allowsStaleLocalHistory: Bool,
        allowsBootstrapFailureFallback: Bool,
        hasTrustedPersistedBootstrapPage: Bool = false,
        hasLocalAnchorRequest: Bool = false,
        allowsInitialMaterializationProbe: Bool = false,
        liveLoadingState: ChatBootstrapLoadingState? = nil
    ) -> ChatLocalFirstFrameAvailabilityDecision {
        if hasTrustedPersistedBootstrapPage {
            return .prepareLocal
        }
        if hasLocalAnchorRequest {
            return .prepareLocal
        }
        if allowsInitialMaterializationProbe {
            return .prepareLocal
        }
        if allowsStaleLocalHistory || allowsBootstrapFailureFallback {
            return .prepareLocal
        }
        // `.content` is the reducer's terminal proof that a real local frame
        // exists. Rejecting it after the one-shot materialization probe makes
        // the terminal invariant resolve skeleton back to content and then
        // synchronously retry this same gate forever.
        if liveLoadingState == .content {
            return .prepareLocal
        }
        if liveLoadingState?.showsSkeleton == true {
            return .blockForArchiveBootstrap
        }
        if isSynced && isInitialArchiveLoaded {
            return .prepareLocal
        }
        if isInitialBootstrapInFlight {
            return .blockForArchiveBootstrap
        }
        return .blockForArchiveBootstrap
    }
}

enum ChatInitialLocalFirstFrameSupersessionPolicy {
    static func shouldRetry(
        mappingWasCancelled: Bool,
        hasTerminalNonSkeletonPresentation: Bool,
        didRunDisappearanceCleanup: Bool
    ) -> Bool {
        mappingWasCancelled &&
            !hasTerminalNonSkeletonPresentation &&
            !didRunDisappearanceCleanup
    }
}

enum ChatPreparedInitialFrameCommitPolicy {
    /// A real local frame (including a resolved anchor) may atomically replace
    /// skeleton. An empty preparation is valid only after the live reducer has
    /// durable proof that the timeline no longer needs to remain blocked.
    static func shouldCommit(
        hasMappedRealRows: Bool,
        liveLoadingState: ChatBootstrapLoadingState,
        allowsBlockingRealRows: Bool = false
    ) -> Bool {
        if hasMappedRealRows {
            return !liveLoadingState.showsSkeleton ||
                allowsBlockingRealRows
        }
        switch liveLoadingState {
        case .empty, .failure(fallback: .empty):
            return true
        case .blockingArchive, .blockingTarget, .content, .failure(fallback: .content):
            return false
        }
    }
}

enum ChatInitialLatestOpenStabilizationState: Equatable {
    case inactive
    case active
    case bottomAligned
}

enum ChatInitialLatestOpenStabilizationPolicy {
    enum ObserverRefreshAction: Equatable {
        case followDefault
        case keepCurrentNoScroll
        case openLatestNonAnimated
    }

    static func shouldStart(forceLatestOpen: Bool) -> Bool {
        forceLatestOpen
    }

    static func stateAfterBottomAlignment(
        current: ChatInitialLatestOpenStabilizationState,
        hasRealMessages: Bool
    ) -> ChatInitialLatestOpenStabilizationState {
        guard hasRealMessages else {
            return current
        }

        switch current {
        case .inactive:
            return .inactive
        case .active, .bottomAligned:
            return .bottomAligned
        }
    }

    static func shouldComplete(
        state: ChatInitialLatestOpenStabilizationState,
        hasViewAppeared: Bool
    ) -> Bool {
        state == .bottomAligned && hasViewAppeared
    }

    static func shouldSkipForcedContentRender(
        state: ChatInitialLatestOpenStabilizationState,
        forceRender: Bool,
        hasRealDatasource: Bool,
        newestLocalPrimary: String?,
        datasourceNewestPrimary: String?
    ) -> Bool {
        guard state != .inactive,
              forceRender,
              hasRealDatasource,
              let newestLocalPrimary,
              let datasourceNewestPrimary else {
            return false
        }

        return newestLocalPrimary == datasourceNewestPrimary
    }

    static func observerRefreshAction(
        state: ChatInitialLatestOpenStabilizationState,
        baseShouldOpenLatest: Bool,
        newestLocalPrimary: String?,
        datasourceNewestPrimary: String?
    ) -> ObserverRefreshAction {
        guard state != .inactive,
              baseShouldOpenLatest,
              let newestLocalPrimary,
              let datasourceNewestPrimary else {
            return .followDefault
        }

        return newestLocalPrimary == datasourceNewestPrimary ? .keepCurrentNoScroll : .openLatestNonAnimated
    }

    static func shouldAnimateAuxiliaryUpdate(
        state: ChatInitialLatestOpenStabilizationState,
        requestedAnimated: Bool
    ) -> Bool {
        requestedAnimated && state == .inactive
    }
}

enum ChatObserverRefreshBackpressureAction: Equatable {
    case applyImmediately
    case scheduleCoalesced
    case keepCoalesced
    case deferUntilScrollRest
    case deferUntilSearchNavigationCommit
}

enum ChatObserverRefreshFlushAction: Equatable {
    case none
    case keepPending
    case flush
}

enum ChatObserverRefreshBackpressurePolicy {
    static let coalescingDelay: TimeInterval = 0.18

    static func action(
        isShowingBootstrapPlaceholder: Bool,
        isHistoryPressureActive: Bool,
        motionState: ChatScrollMotionState,
        hasScheduledRefresh: Bool,
        isBlockedBySearchNavigation: Bool = false
    ) -> ChatObserverRefreshBackpressureAction {
        if isBlockedBySearchNavigation {
            return .deferUntilSearchNavigationCommit
        }

        guard !isShowingBootstrapPlaceholder,
              isHistoryPressureActive else {
            return .applyImmediately
        }

        if motionState.isMoving {
            return .deferUntilScrollRest
        }

        return hasScheduledRefresh ? .keepCoalesced : .scheduleCoalesced
    }

    static func flushAction(
        hasPendingRefresh: Bool,
        motionState: ChatScrollMotionState,
        isBlockedBySearchNavigation: Bool = false
    ) -> ChatObserverRefreshFlushAction {
        guard hasPendingRefresh else {
            return .none
        }

        guard !isBlockedBySearchNavigation else {
            return .keepPending
        }

        return motionState.isMoving ? .keepPending : .flush
    }
}

enum ChatInitialHistoryAppearancePolicy {
    static func shouldStart(isShowingBootstrapPlaceholder: Bool) -> Bool {
        isShowingBootstrapPlaceholder
    }

    static func shouldFinish(itemCount: Int, containsOnlyFakeMessages: Bool) -> Bool {
        itemCount == 0 || !containsOnlyFakeMessages
    }

    static func shouldAnimateDatasourceApply(isInitialHistoryAppearancePending: Bool) -> Bool {
        !isInitialHistoryAppearancePending
    }

    static func shouldUseReloadFallbackForTargetedDiff(animated: Bool) -> Bool {
        !animated
    }

    static func shouldApplyFollowupChangesetAfterBootstrapReload(didReloadInitialWindow: Bool) -> Bool {
        !didReloadInitialWindow
    }

    static func shouldCompleteInitialAppearance(hasViewAppeared: Bool, hasRenderedStableHistory: Bool) -> Bool {
        hasViewAppeared && hasRenderedStableHistory
    }

    static func shouldForceNonAnimatedApplyForInitialPopulation(oldItemCount: Int, newItemCount: Int) -> Bool {
        oldItemCount == 0 && newItemCount > 0
    }
}

enum ChatFirstFrameAuxiliaryWorkDecision: Equatable {
    case runImmediately
    case skipInitialCommit
}

enum ChatFirstFrameAuxiliaryWorkPolicy {
    static func datasourceApplyDecision(
        isInitialHistoryAppearancePending: Bool,
        containsRealMessages: Bool,
        containsOnlyFakeMessages: Bool
    ) -> ChatFirstFrameAuxiliaryWorkDecision {
        guard isInitialHistoryAppearancePending,
              containsRealMessages,
              !containsOnlyFakeMessages else {
            return .runImmediately
        }

        return .skipInitialCommit
    }
}

enum ChatStackedNavigationPreparationPolicy {
    static func shouldLoadInitialDatasource(
        isDatasourceEmpty: Bool,
        isShowingBootstrapPlaceholder: Bool
    ) -> Bool {
        isDatasourceEmpty || isShowingBootstrapPlaceholder
    }
}

enum ChatSavedPositionGapRepairDirection: Equatable {
    /// Continue from the newer loaded side towards older archive ids.
    case older
    /// Continue from the older loaded side towards newer archive ids.
    case newer
}

struct ChatSavedPositionGapRepairPlan: Equatable {
    let gap: RegularChatArchiveGap
    let direction: ChatSavedPositionGapRepairDirection
}

enum ChatSavedPositionFirstFrameDecision: Equatable {
    case standardContent
    case blockingRepair(ChatSavedPositionGapRepairPlan)
    case savedPosition(anchorIndex: Int, window: ChatDatasetWindow)
}

struct ChatSavedPositionFirstFrameProbeResult: Equatable {
    let request: ChatOpenMessageRequest
    let decision: ChatSavedPositionFirstFrameDecision
    let knownGaps: [RegularChatArchiveGap]
    let preparedWindowArchiveIds: [String?]
}

enum ChatSavedPositionFirstFramePolicy {
    static func shouldApplySynchronously(
        bootstrapState: ChatBootstrapViewState,
        isShowingBootstrapPlaceholder: Bool,
        decision: ChatSavedPositionFirstFrameDecision
    ) -> Bool {
        guard bootstrapState == .content,
              isShowingBootstrapPlaceholder,
              case .savedPosition = decision else {
            return false
        }
        return true
    }

    static func decision(
        requestSource: ChatOpenMessageRequestSource?,
        isSynced: Bool,
        observerCount: Int,
        localAnchorIndex: Int?,
        pageSize: Int,
        isPageUnlocked: Bool = true,
        archivedIdsByIndex: [Int: String] = [:],
        knownGaps: [RegularChatArchiveGap] = []
    ) -> ChatSavedPositionFirstFrameDecision {
        guard requestSource == .savedVisiblePosition,
              isSynced,
              isPageUnlocked,
              observerCount > 0,
              let localAnchorIndex,
              localAnchorIndex >= 0,
              localAnchorIndex < observerCount else {
            return .standardContent
        }

        let window = ChatDatasetCoordinator(pageSize: pageSize)
            .replacementWindow(around: localAnchorIndex, totalCount: observerCount)
        if let repair = blockingRepairPlan(
            window,
            localAnchorIndex: localAnchorIndex,
            archivedIdsByIndex: archivedIdsByIndex,
            knownGaps: knownGaps
        ) {
            return .blockingRepair(repair)
        }
        return .savedPosition(anchorIndex: localAnchorIndex, window: window)
    }

    private static func blockingRepairPlan(
        _ window: ChatDatasetWindow,
        localAnchorIndex: Int,
        archivedIdsByIndex: [Int: String],
        knownGaps: [RegularChatArchiveGap]
    ) -> ChatSavedPositionGapRepairPlan? {
        guard !archivedIdsByIndex.isEmpty,
              knownGaps.isNotEmpty else {
            return nil
        }

        let archiveIds = archiveIds(in: window, archivedIdsByIndex: archivedIdsByIndex)
        guard archiveIds.isNotEmpty else {
            return nil
        }

        var nearestRepair: (distance: Int, plan: ChatSavedPositionGapRepairPlan)?
        for gap in knownGaps {
            let olderSideIndices = archiveIds.compactMap { sample -> Int? in
                let comparison = compareArchiveIds(
                    sample.archiveId,
                    gap.olderRangeNewestArchiveId
                ) ?? .orderedDescending
                return comparison != .orderedDescending ? sample.index : nil
            }
            let newerSideIndices = archiveIds.compactMap { sample -> Int? in
                let comparison = compareArchiveIds(
                    sample.archiveId,
                    gap.newerRangeOldestArchiveId
                ) ?? .orderedAscending
                return comparison != .orderedAscending ? sample.index : nil
            }
            guard let nearestOlderIndex = olderSideIndices.max(),
                  let nearestNewerIndex = newerSideIndices.min() else {
                continue
            }

            let direction = repairDirection(
                localAnchorIndex: localAnchorIndex,
                anchorArchiveId: archivedIdsByIndex[localAnchorIndex],
                gap: gap,
                nearestOlderIndex: nearestOlderIndex,
                nearestNewerIndex: nearestNewerIndex
            )
            let distance = min(
                abs(localAnchorIndex - nearestOlderIndex),
                abs(nearestNewerIndex - localAnchorIndex)
            )
            let candidate = ChatSavedPositionGapRepairPlan(
                gap: gap,
                direction: direction
            )
            if let currentNearestRepair = nearestRepair {
                if distance < currentNearestRepair.distance {
                    nearestRepair = (distance, candidate)
                }
            } else {
                nearestRepair = (distance, candidate)
            }
        }
        return nearestRepair?.plan
    }

    private static func archiveIds(
        in window: ChatDatasetWindow,
        archivedIdsByIndex: [Int: String]
    ) -> [(index: Int, archiveId: String)] {
        guard window.minIndex < window.maxIndex else {
            return []
        }

        return (window.minIndex..<window.maxIndex).compactMap { index in
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archivedIdsByIndex[index])
                .map { (index, $0) }
        }
    }

    private static func repairDirection(
        localAnchorIndex: Int,
        anchorArchiveId: String?,
        gap: RegularChatArchiveGap,
        nearestOlderIndex: Int,
        nearestNewerIndex: Int
    ) -> ChatSavedPositionGapRepairDirection {
        if let anchorArchiveId = RegularChatArchiveSyncStateStorageItem
            .normalizedArchiveId(anchorArchiveId) {
            let olderComparison = compareArchiveIds(
                anchorArchiveId,
                gap.olderRangeNewestArchiveId
            ) ?? .orderedDescending
            if olderComparison != .orderedDescending {
                return .newer
            }

            let newerComparison = compareArchiveIds(
                anchorArchiveId,
                gap.newerRangeOldestArchiveId
            ) ?? .orderedAscending
            if newerComparison != .orderedAscending {
                return .older
            }
        }

        let distanceToOlderSide = abs(localAnchorIndex - nearestOlderIndex)
        let distanceToNewerSide = abs(nearestNewerIndex - localAnchorIndex)
        return distanceToOlderSide <= distanceToNewerSide ? .newer : .older
    }
}

enum ChatBootstrapContentRenderPolicy {
    static func shouldReloadInitialWindow(
        forceRender: Bool,
        isShowingBootstrapPlaceholder: Bool,
        isDatasourceEmpty: Bool = false,
        hasCommittedRealContent: Bool = false
    ) -> Bool {
        forceRender ||
        isShowingBootstrapPlaceholder ||
        (isDatasourceEmpty && !hasCommittedRealContent)
    }
}

enum ChatStackedFirstFrameReadinessPolicy {
    static func isReady(
        hasCommittedRealRows: Bool,
        hasCommittedSkeletonRows: Bool,
        hasCommittedEmptyState: Bool,
        showsDeterministicFailureFallback: Bool
    ) -> Bool {
        hasCommittedRealRows ||
        hasCommittedSkeletonRows ||
        hasCommittedEmptyState ||
        showsDeterministicFailureFallback
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
    let previousNewestPrimary: String?
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
        _ = outgoingAutoScrollDecision
        return false
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
    let size: CGSize
    let isSensitive: Bool
    let isSensitiveRevealed: Bool

    init(_ attachment: ImageAttachment) {
        self.primary = attachment.primary
        self.url = attachment.url
        self.size = attachment.size
        self.isSensitive = attachment.isSensitive
        self.isSensitiveRevealed = attachment.isSensitiveRevealed
    }

    var description: String {
        "image(primary:\(primary),url:\(url?.absoluteString ?? ""),size:\(size),sensitive:\(isSensitive),revealed:\(isSensitiveRevealed))"
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
            skeletonDescriptors: ChatSkeletonTemplate.descriptors,
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

    private func consumePendingOutgoingAutoScrollDecision(
        items: [Datasource]
    ) -> ChatOutgoingAutoScrollDecision {
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
        if decision.consumesPendingRequest {
            self.pendingOutgoingAutoScrollRequest = nil
        }
        return decision
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
                    url: Self.imageDisplayURL(for: item),
                    size: item.sizeInPx ?? CGSize(square: 128),
                    isSensitive: item.isSensitive,
                    isSensitiveRevealed: revealedSensitiveMediaPrimaries.contains(item.primary)
                ))
            case .video:
                videos.append(VideoAttachment(
                    primary: item.primary,
                    url: item.downloadUrl,
                    size: item.sizeInPx ?? CGSize(square: 128),
                    previewUrl: item.videoPreviewUrl,
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
                        name: item.filename ?? item.name ?? "file",
                        mimeType: item.mimeType,
                        downloaded: item.isDownloaded
                    ))
                }
            }
        }

        return (images, videos, locations, contacts, audio, files)
    }

    private static func imageDisplayURL(for reference: ChatMessageReferenceSnapshot) -> URL? {
        if let downloadUrl = reference.downloadUrl {
            return downloadUrl
        }
        if let localFileUrl = reference.localFileUrl,
           localFileUrl.isFileURL {
            return localFileUrl
        }
        return reference.videoPreviewUrl
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
        }), let url = imageDisplayURL(for: reference) else {
            return nil
        }
        return ImageAttachment(
            primary: reference.primary,
            url: url,
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
        let timeString = formatters.attachmentTimeFormatter.string(from: attachment.originalDate ?? Date())
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
        presentationCommitMode: ChatDatasourcePresentationCommitMode = .standard,
        transactionCommitAuthorization: (() -> Bool)? = nil,
        transactionCompletion: ((ChatViewportTransactionResult) -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        var datasourceApplySignpost = ChatPerformanceSignposts.begin(.datasourceApply)
        let applyStartedAt = Date()
        let applyConversationKey = self.chatTimelineConversationKey
        let initialBootstrapQueryIdAtApplyStart = self.initialBootstrapQueryId
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
        let containsBootstrapSkeletonRows =
            ChatBootstrapSkeletonDatasourceIdentity.matches(
                items,
                owner: self.owner,
                jid: self.jid
            )
        if containsRealMessages,
           presentationCommitMode == .standard {
            // A real frame owns presentation as soon as its transaction starts.
            // Cancelling the independent skeleton generation here closes the
            // interval before the real transaction's committed marker is set.
            self.cancelBootstrapSkeletonMappingJobs()
        }
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
        let requestedAnimatedApply = animated && !ChatInitialHistoryAppearancePolicy.shouldForceNonAnimatedApplyForInitialPopulation(
            oldItemCount: previousSnapshot.items.count,
            newItemCount: newSnapshot.items.count
        )
        let requestedStructuralAnimation = ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
            requestedAnimated: requestedAnimatedApply,
            isTransitionActive: self.isNavigationTransitionActive,
            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
        )
        let outgoingAutoScrollDecision = self.consumePendingOutgoingAutoScrollDecision(items: items)
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
        if let effectiveViewportAnchor {
            anchorStrategy = .message(effectiveViewportAnchor)
        } else if forceBottomAlignmentTarget != nil ||
                    shouldTailAppendBottomPin ||
                    shouldAutoScrollToBottom ||
                    outgoingRequestsScroll {
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
            if transactionCommitted, !containsOnlyFakeMessages {
                self.hasCommittedTimelinePresentationInCurrentLifecycle = true
            }
            if transactionCommitted, containsBootstrapSkeletonRows {
                self.hasCommittedBootstrapSkeletonPresentationInCurrentLifecycle = true
                ChatArchiveDebugTrace.log("bootstrapSkeletonCommitted", [
                    ("rowCount", items.count),
                    ("snapshotCount", self.datasourceSnapshot.items.count)
                ])
            } else if transactionCommitted {
                self.hasCommittedBootstrapSkeletonPresentationInCurrentLifecycle = false
            }
            let didCommitCurrentConversationContent = transactionCommitted &&
                containsRealMessages &&
                applyConversationKey == self.chatTimelineConversationKey &&
                self.datasourceSnapshot.items.map(\.primary) == newSnapshot.items.map(\.primary)
            if didCommitCurrentConversationContent {
                self.hasCommittedRealContentInCurrentLifecycle = true
                self.appliedBootstrapLoadingState = .content
                self.preservesBootstrapFailureOverlayUntilRetryCommit = false
                self.setBootstrapFailureVisible(false)
                self.setSkeletonVisible(false)
                self.setDatasourceLoadingEnabled(true)
                self.setShouldShowInitialMessage(false)
                self.messagesCollectionView.isUserInteractionEnabled = true
                self.timelineInteractionState.unlock()
            }
            if transactionCommitted,
               presentationCommitMode == .standard {
                self.resolvePendingBootstrapFirstFrameReadinessCompletionsIfPossible()
            }
            let completionMs = ChatArchiveDebugTrace.milliseconds(since: completionStartedAt)
            if transactionCommitted || presentationCommitMode == .standard {
                self.handleChatDatasourceAuxiliaryRefreshAfterApply(
                    containsRealMessages: containsRealMessages,
                    containsOnlyFakeMessages: containsOnlyFakeMessages
                )
            }
            if transactionCommitted,
               self.initialHistoryAppearancePending,
               ChatInitialHistoryAppearancePolicy.shouldFinish(itemCount: items.count, containsOnlyFakeMessages: containsOnlyFakeMessages) {
                self.hasRenderedStableInitialHistory = true
                self.finishInitialHistoryAppearanceIfPossible()
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
            let shouldCompleteInitialBootstrap =
                didCommitCurrentConversationContent &&
                initialBootstrapQueryIdAtApplyStart != nil &&
                self.initialBootstrapQueryId ==
                    initialBootstrapQueryIdAtApplyStart
            if shouldCompleteInitialBootstrap,
               presentationCommitMode == .standard {
                _ = self.completeInitialBootstrapIfNeeded()
            }
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
                    // `transactionCompletion` advances the formal first-frame
                    // phase from `.presenting` to `.committed`. Only after
                    // that receipt may persistence completion release the
                    // initial lease or schedule a coverage repair.
                    // Revoke UIKit callbacks captured during the visual
                    // transaction, including any work admitted by the receipt
                    // callback itself. The metadata resample below must own an
                    // isolated scheduler generation.
                    if didCommitCurrentConversationContent {
                        self.enqueuePostAtomicInitialFrameReceiptScrollWorkResample()
                    } else {
                        self.scrollWorkScheduler.cancel()
                    }
                    if shouldCompleteInitialBootstrap {
                        _ = self.completeInitialBootstrapIfNeeded()
                    }
                    completion?()
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
                if containsRealMessages {
                    self.cancelBootstrapSkeletonMappingJobs()
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
            if self.isPreparingStackedNavigationPresentation {
                // A presentation timeout may fire before an asynchronous
                // `performBatchUpdates` completion. During first-frame
                // preparation use one synchronous non-animated reload so the
                // fallback can observe a real commit receipt without nesting
                // another collection transaction.
                runWithoutAnimation {
                    self.scrollFrameOperationCounter.record(.reloads)
                    self.messagesCollectionView.reloadData()
                }
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
                    self.finishChatDatasourceStructuralTransaction()
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
        self.refreshScrollBoundaryAvailabilityCache(reason: "syncCurrentPage")
    }

    internal func visibleWindow() -> ChatDatasetWindow {
        self.residentDatasetWindow
    }

    private func messageWindowSliceForMapping(
        _ window: ChatDatasetWindow,
        currentWindow _: ChatDatasetWindow,
        activePlaceholder _: ChatHistoryBoundaryPlaceholderPosition?,
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
            currentWindow: self.visibleWindow(),
            activePlaceholder: self.activeHistoryBoundaryPlaceholder
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
            self.messageLoadingActivityIndicator.isHidden = !isLoading
        }
    }

    internal func oldestObservedArchivedId(persistedCursorId: String? = nil) -> String? {
        if let oldest = self.virtualTimelineState.oldest?.archivedId {
            return oldest
        }
        guard self.timelineSession != nil else { return nil }
        return persistedCursorId ?? self.persistedHistoryCursorId()
    }

    internal func observedOldestArchivedId() -> String? {
        self.virtualTimelineState.oldest?.archivedId
    }

    internal func observedNewestArchivedId() -> String? {
        self.virtualTimelineState.newest?.archivedId
    }

    internal func observedArchivedIds(in window: ChatDatasetWindow) -> [String] {
        let timelineState = self.virtualTimelineState
        if window == self.visibleWindow(),
           timelineState.residentArchivedIds.isNotEmpty {
            return timelineState.residentArchivedIds
        }
        guard let items = self.timelineSession?.snapshot.items else { return [] }
        let normalized = self.datasetCoordinator.clamp(window, totalCount: items.count)
        guard normalized.count > 0 else { return [] }
        return (normalized.minIndex..<normalized.maxIndex).compactMap { index in
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(items[index].archivedId)
        }
    }

    internal func authoritativeOlderPagingCursorId(persistedCursorId: String? = nil) -> String? {
        if let persistedCursorId, persistedCursorId.isNotEmpty {
            return persistedCursorId
        }
        return self.observedOldestArchivedId()
    }

    internal func interactiveOlderPagingCursorSelection(
        in window: ChatDatasetWindow,
        persistedCursorId: String? = nil
    ) -> ChatInteractiveOlderCursorSelection {
        ChatInteractiveOlderCursorSelectionPolicy.select(
            timelineOldestArchivedId: self.virtualTimelineState.oldest?.archivedId,
            boundedOldestArchivedId: self.boundedTimelineWindowState.oldest?.archivedId,
            observedArchivedIds: self.observedArchivedIds(in: window),
            persistedCursorId: persistedCursorId
        )
    }

    internal func visibleNewerPagingCursorId(
        in window: ChatDatasetWindow,
        persistedCursorId: String? = nil
    ) -> String? {
        ChatHistoryCursorSelectionPolicy.newestCursorId(
            observedArchivedIds: self.observedArchivedIds(in: window),
            persistedCursorId: persistedCursorId
        )
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
        positionedMessagePrimary: String? = nil,
        initialFrameEffectToken: ChatInitialFrameEffectToken? = nil
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
                messagePrimary: messagePrimary,
                initialFrameEffectToken: initialFrameEffectToken
            )
        }
        self.readVisiblePresentationCoordinator.enqueue(candidates)
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.visibleMentionReadScheduledForTests?(candidates.count)
        self.visibleMentionReadScheduledEffectTokenForTests?(
            candidates.count,
            candidates.isEmpty ? nil : initialFrameEffectToken
        )
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
            candidateAdmission: { [weak self] candidate in
                guard let token = candidate.initialFrameEffectToken else {
                    return true
                }
                return self?.isLatestInitialFrameEffectToken(token) == true
            }
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
                    self.visibleMentionReadTerminalEffectTokenForTests?(
                        false,
                        flush.exactInitialFrameEffectToken
                    )
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
                        self.visibleMentionReadAfterFirstPersistentMutationEffectTokenForTests?(
                            flush.exactInitialFrameEffectToken
                        )
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
                self.visibleMentionReadTerminalEffectTokenForTests?(
                    false,
                    flush.exactInitialFrameEffectToken
                )
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
                    self.visibleMentionReadTerminalEffectTokenForTests?(
                        succeeded && didChangeReadState,
                        flush.exactInitialFrameEffectToken
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
                self.visibleMentionReadTerminalEffectTokenForTests?(
                    succeeded,
                    flush.exactInitialFrameEffectToken
                )
#endif
            }
        }
    }

    internal func loadChatArchiveStateSnapshot() -> ChatArchiveStateSnapshot {
        let primaryKey = LastChatsStorageItem.genPrimary(
            jid: self.jid,
            owner: self.owner,
            conversationType: self.conversationType
        )
        do {
            let realm = try WRealm.safe()
            let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: primaryKey
            )
            let conversationArchiveState = self.conversationType.supportsSnapshotArchiveRepair
                ? realm.object(
                    ofType: RegularChatArchiveSyncStateStorageItem.self,
                    forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                        jid: self.jid,
                        owner: self.owner,
                        conversationType: self.conversationType
                    )
                )
                : nil
            let persistedCursorId = chat?.lastLoadedMessageHistoryId?.isNotEmpty == true ? chat?.lastLoadedMessageHistoryId : nil
            return ChatArchiveStateSnapshot(
                primaryKey: primaryKey,
                persistedCursorId: conversationArchiveState?.oldestLoadedArchiveId ?? persistedCursorId,
                fullArchiveLoaded: conversationArchiveState?.olderArchiveEndReached ?? chat?.fullArchiveLoaded ?? false,
                newestCursorId: conversationArchiveState?.newestLoadedArchiveId,
                newerLiveEdgeReached: conversationArchiveState?.newerLiveEdgeReached ?? true,
                hasKnownNewerGap: conversationArchiveState?.knownGaps.isNotEmpty ?? false,
                knownGaps: conversationArchiveState?.knownGaps ?? []
            )
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return ChatArchiveStateSnapshot(
                primaryKey: primaryKey,
                persistedCursorId: nil,
                fullArchiveLoaded: false
            )
        }
    }

    internal func persistedHistoryCursorId() -> String? {
        self.loadChatArchiveStateSnapshot().persistedCursorId
    }

    @discardableResult
    internal func applyChatArchiveStateIfNeeded(
        snapshot: ChatArchiveStateSnapshot,
        plan: ChatArchiveStateMutationPlan,
        markNewerLiveEdgeReached: Bool = false
    ) -> ChatArchiveStateSnapshot {
        let updatedSnapshot = ChatArchiveStateSnapshot(
            primaryKey: snapshot.primaryKey,
            persistedCursorId: plan.resolvedCursorId,
            fullArchiveLoaded: plan.fullArchiveLoaded,
            newestCursorId: snapshot.newestCursorId,
            newerLiveEdgeReached: snapshot.newerLiveEdgeReached || markNewerLiveEdgeReached,
            hasKnownNewerGap: snapshot.hasKnownNewerGap,
            knownGaps: snapshot.knownGaps
        )

        guard plan.needsWrite || markNewerLiveEdgeReached else {
            return updatedSnapshot
        }

        do {
            let realm = try WRealm.safe()
            guard let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: snapshot.primaryKey
            ) else {
                return snapshot
            }
            try realm.write {
                if chat.isInvalidated { return }
                if plan.shouldWriteCursor {
                    chat.lastLoadedMessageHistoryId = plan.resolvedCursorId
                }
                if plan.shouldWriteFullArchiveLoaded {
                    chat.fullArchiveLoaded = plan.fullArchiveLoaded
                }
                if self.conversationType.supportsSnapshotArchiveRepair {
                    let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                        owner: self.owner,
                        jid: self.jid,
                        conversationType: self.conversationType,
                        in: realm
                    )
                    if plan.shouldWriteCursor {
                        archiveState.oldestLoadedArchiveId = plan.resolvedCursorId
                    }
                    if plan.shouldWriteFullArchiveLoaded {
                        archiveState.olderArchiveEndReached = plan.fullArchiveLoaded
                    }
                    if markNewerLiveEdgeReached {
                        archiveState.newerLiveEdgeReached = true
                    }
                    archiveState.updatedAt = Date()
                }
            }
            self.refreshScrollBoundaryAvailabilityCache(reason: "archiveStateChanged")
            return updatedSnapshot
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return snapshot
        }
    }

    internal func applyConversationArchiveLoadedRangeIfNeeded(
        first: String,
        last: String,
        updateKind: RegularArchiveCoverageUpdateKind
    ) {
        guard self.conversationType.supportsSnapshotArchiveRepair,
              first.isNotEmpty || last.isNotEmpty else {
            return
        }

        do {
            let realm = try WRealm.safe()
            try realm.write {
                let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                    owner: self.owner,
                    jid: self.jid,
                    conversationType: self.conversationType,
                    in: realm
                )
                archiveState.mergeLoadedRange(first: first, last: last, updateKind: updateKind)
                archiveState.updatedAt = Date()

                if let chat = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: self.jid,
                        owner: self.owner,
                        conversationType: self.conversationType
                    )
                ) {
                    chat.lastLoadedMessageHistoryId = archiveState.oldestLoadedArchiveId ?? chat.lastLoadedMessageHistoryId
                    chat.fullArchiveLoaded = archiveState.olderArchiveEndReached
                }
            }
            self.refreshScrollBoundaryAvailabilityCache(reason: "archiveCoverageChanged")
        } catch {
            DDLogDebug("ChatViewController.applyConversationArchiveLoadedRangeIfNeeded error=\(error.localizedDescription)")
        }
    }

    internal func isFullArchiveLoaded() -> Bool {
        self.loadChatArchiveStateSnapshot().fullArchiveLoaded
    }

    internal func setFullArchiveLoaded(_ isLoaded: Bool) {
        do {
            let realm = try WRealm.safe()
            if let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            ) {
                guard chat.fullArchiveLoaded != isLoaded else { return }
                try realm.write {
                    if chat.isInvalidated { return }
                    chat.fullArchiveLoaded = isLoaded
                    if self.conversationType.supportsSnapshotArchiveRepair {
                        let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                            owner: self.owner,
                            jid: self.jid,
                            conversationType: self.conversationType,
                            in: realm
                        )
                        archiveState.olderArchiveEndReached = isLoaded
                        archiveState.updatedAt = Date()
                    }
                }
                self.refreshScrollBoundaryAvailabilityCache(reason: "fullArchiveLoadedChanged")
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }

    internal func pagingBoundaryContext(visibleSections: [Int]) -> ChatHistoryPagingBoundaryContext {
        self.scrollResidentMetadata.boundaryContext(visibleSections: visibleSections)
    }

    /// Updates only visual eligibility. Archive transport, persistence, the
    /// conversation lease, and the prepared mapping token continue unchanged
    /// while backgrounded.
    internal func synchronizeInitialFramePresentationLifecycleWithApplicationState() {
        assert(Thread.isMainThread, "Chat lifecycle presentation state is main-owned")
        // Only downgrade from the sampled state. A direct did-enter-background
        // receipt may already have made the controller ineligible while a
        // testable/application state provider is crossing its own transition.
        if self.initialFramePresentationApplicationStateProvider() == .background {
            self.isInitialFramePresentationLifecycleEligible = false
        }
    }

    internal func setInitialFramePresentationLifecycleEligible(
        _ isEligible: Bool
    ) {
        assert(Thread.isMainThread, "Chat lifecycle presentation state is main-owned")
        self.isInitialFramePresentationLifecycleEligible = isEligible
        guard isEligible else {
            return
        }
        self.resumePendingInitialFrameLifecyclePresentationIfCurrent()
    }

    private func retainInitialFrameLifecyclePresentation(
        identity: ChatInitialFrameLifecyclePresentationIdentity,
        mappingToken: ChatDatasetMappingCancellationToken?,
        apply: @escaping () -> Void
    ) {
        assert(Thread.isMainThread, "Prepared UIKit continuations are main-owned")
        if let pending = self.pendingInitialFrameLifecyclePresentation,
           pending.identity == identity,
           pending.mappingToken === mappingToken {
            // Coordinator readiness, cached-final replay, and a raw-final
            // callback may all report the same CURRENT receipt. The first
            // fully prepared continuation owns publication; an identical
            // callback is a reducer no-op and must not cancel its token.
            return
        }
        if self.pendingInitialFrameLifecyclePresentation != nil {
            self.discardPendingInitialFrameLifecyclePresentation()
        }
        self.pendingInitialFrameLifecyclePresentation =
            ChatInitialFrameLifecyclePresentation(
                identity: identity,
                mappingToken: mappingToken,
                apply: apply
            )
        ChatArchiveDebugTrace.log("chatInitialFramePreparedAwaitingForeground", [
            ("hasBootstrapQuery", identity.bootstrapQueryId != nil),
            ("mappingGeneration", identity.datasetMappingGeneration),
            ("timelineGeneration", identity.timelineGeneration)
        ])
    }

#if DEBUG || CHAT_PERFORMANCE_LAB
    internal func retainInitialFrameLifecyclePresentationForTesting(
        identity: ChatInitialFrameLifecyclePresentationIdentity,
        mappingToken: ChatDatasetMappingCancellationToken?,
        apply: @escaping () -> Void
    ) {
        self.retainInitialFrameLifecyclePresentation(
            identity: identity,
            mappingToken: mappingToken,
            apply: apply
        )
    }
#endif

    private func resumePendingInitialFrameLifecyclePresentationIfCurrent() {
        assert(Thread.isMainThread, "Prepared UIKit continuations are main-owned")
        guard self.isInitialFramePresentationLifecycleEligible,
              let pending = self.pendingInitialFrameLifecyclePresentation else {
            return
        }
        self.pendingInitialFrameLifecyclePresentation = nil
        guard self.isCurrentInitialFrameLifecyclePresentation(pending) else {
            self.cancelInitialFrameLifecyclePresentation(pending)
            ChatArchiveDebugTrace.log("chatInitialFrameForegroundDiscardedStale", [
                ("hasBootstrapQuery", pending.identity.bootstrapQueryId != nil),
                ("mappingGeneration", pending.identity.datasetMappingGeneration),
                ("timelineGeneration", pending.identity.timelineGeneration)
            ])
            return
        }
        ChatArchiveDebugTrace.log("chatInitialFrameForegroundCommit", [
            ("hasBootstrapQuery", pending.identity.bootstrapQueryId != nil),
            ("mappingGeneration", pending.identity.datasetMappingGeneration),
            ("timelineGeneration", pending.identity.timelineGeneration)
        ])
        pending.apply()
    }

    private func isCurrentInitialFrameLifecyclePresentation(
        _ pending: ChatInitialFrameLifecyclePresentation
    ) -> Bool {
        let identity = pending.identity
        guard identity.conversationKey == self.chatTimelineConversationKey,
              identity.bootstrapQueryId == self.initialBootstrapQueryId,
              identity.targetFingerprint == self.initialBootstrapTargetFingerprint,
              identity.datasetMappingGeneration == self.datasetMappingGeneration,
              self.timelineSession.map({ session in
                  ChatInitialFrameLifecycleSnapshotContinuityPolicy.admits(
                      preparedGeneration: identity.timelineGeneration,
                      preparedProjection: identity.timelineProjection,
                      current: session.snapshot
                  )
              }) == true,
              self.initialLocalFirstFramePhase == .preparing(identity.descriptor),
              ChatLocalFirstFrameDescriptorPolicy.descriptor(
                request: self.pendingOpenMessageRequest,
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
              ) == identity.descriptor else {
            return false
        }
        if let mappingToken = pending.mappingToken {
            return self.initialLocalFirstFrameMappingToken === mappingToken &&
                !mappingToken.isCancelled
        }
        return self.initialLocalFirstFrameMappingToken == nil
    }

    internal func discardPendingInitialFrameLifecyclePresentation() {
        assert(Thread.isMainThread, "Prepared UIKit continuations are main-owned")
        guard let pending = self.pendingInitialFrameLifecyclePresentation else {
            return
        }
        self.pendingInitialFrameLifecyclePresentation = nil
        self.cancelInitialFrameLifecyclePresentation(pending)
    }

    private func cancelInitialFrameLifecyclePresentation(
        _ pending: ChatInitialFrameLifecyclePresentation
    ) {
        guard let mappingToken = pending.mappingToken else {
            if self.initialLocalFirstFramePhase ==
                .preparing(pending.identity.descriptor) {
                self.initialLocalFirstFramePhase = .idle
                self.initialLocalFirstFrameReadinessProof = nil
            }
            return
        }
        mappingToken.cancel()
        guard self.initialLocalFirstFrameMappingToken === mappingToken else {
            return
        }
        self.initialLocalFirstFrameMappingToken = nil
        self.initialLocalFirstFrameReadinessProof = nil
        if self.initialLocalFirstFramePhase ==
            .preparing(pending.identity.descriptor) {
            self.initialLocalFirstFramePhase = .idle
        }
    }

    internal func beginInitialBootstrapTracking(
        queryId: String,
        timeout: TimeInterval? = ChatInteractiveRemoteArchiveTimeoutPolicy.timeout
    ) {
        self.cancelInitialBootstrapLocalHistoryFallback()
        self.cancelInitialBootstrapTimeout()
        self.detachInitialBootstrapReadinessObservation()
        self.revokePostBootstrapInitialFrameAdmissionIfSuperseded(
            bootstrapQueryId: queryId,
            targetFingerprint: self.initialBootstrapTargetFingerprint
        )
        if self.initialBootstrapQueryId != queryId {
            self.discardPendingInitialFrameLifecyclePresentation()
            self.initialBootstrapScopedRefreshQueryId = nil
        }
        self.initialBootstrapQueryId = queryId
        self.isInitialBootstrapInFlight = true
        self.didReceiveInitialBootstrapEndPage = false
        self.initialBootstrapPageEndState = nil
        self.initialBootstrapResultCount = nil
        self.initialBootstrapPersistedMessageCount = nil
        self.initialBootstrapPersistedRowsForQuery = nil
        self.initialBootstrapVisibleRowsForConversation = nil
        self.didEnterInitialBootstrapObserverSettlePhase = false
        self.didObserveInitialBootstrapPostIdleTick = false
        self.registerRemoteHistoryFailureDispatcher(queryId: queryId)
        if let timeout {
            self.scheduleInitialBootstrapTimeout(queryId: queryId, timeout: timeout)
        }
        self.beginChatHistoryLoadActivity(reason: "initial:\(queryId)")
        // Observation is deliberately last. A joined lease may synchronously
        // replay a page that committed before this controller existed. Its
        // completion must be able to cancel the timeout and end the activity;
        // no tracking work may be installed after that terminal reset.
        self.observeInitialBootstrapReadiness(queryId: queryId)
    }

    /// Query/target replacement must revoke the compound op2 before it can
    /// generation-commit. This gate intentionally exists only for the
    /// post-bootstrap retry, so starting the first saved-position probe is not
    /// cancelled merely because it subsequently acquires its initial query.
    private func revokePostBootstrapInitialFrameAdmissionIfSuperseded(
        bootstrapQueryId: String?,
        targetFingerprint:
            MessageArchiveManager.ChatBootstrapTargetFingerprint?
    ) {
        guard let admission = self.activePostBootstrapInitialFrameAdmission,
              admission.identity.bootstrapQueryId != bootstrapQueryId ||
                admission.identity.targetFingerprint != targetFingerprint else {
            return
        }
        self.revokeActivePostBootstrapInitialFrameAdmission(admission)
    }

    private func revokeActivePostBootstrapInitialFrameAdmission(
        _ admission: ChatPostBootstrapInitialFrameAdmission
    ) {
        if self.activePostBootstrapInitialFrameAdmission === admission {
            self.activePostBootstrapInitialFrameAdmission = nil
        }
        admission.revoke()
        admission.session?.cancelInitialFramePreparations()
        guard self.initialLocalFirstFrameMappingToken === admission.mappingToken else {
            return
        }
        self.initialLocalFirstFrameMappingToken = nil
        self.initialLocalFirstFrameReadinessProof = nil
        if self.initialLocalFirstFramePhase ==
            .preparing(admission.identity.descriptor) {
            self.initialLocalFirstFramePhase = .idle
        }
    }

    internal func revokeActivePostBootstrapInitialFrameAdmission() {
        guard let admission = self.activePostBootstrapInitialFrameAdmission else {
            return
        }
        self.revokeActivePostBootstrapInitialFrameAdmission(admission)
    }

    /// Initial bootstrap presentation follows the account-scoped archive
    /// transaction. A raw `<fin>` only moves that transaction to persistence;
    /// the UI may consume its page after the coordinator has committed MAM
    /// coverage and readiness in the same terminal operation.
    internal func observeInitialBootstrapReadiness(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = self.initialBootstrapLeaseKey ??
            self.initialBootstrapRequestKey
        let observation = coordinator.observe(
            key: key,
            consumesInteractiveCommittedJoin: true
        ) { [weak self] readiness in
            guard readiness?.phase == .committed,
                  let page = coordinator.cachedCommittedPage(
                    key: key,
                    queryId: queryId
                  ) else {
                return
            }
            self?.performOnMain { [weak self] in
                guard let self,
                      self.isInitialBootstrapInFlight,
                      self.initialBootstrapQueryId == queryId else {
                    return
                }
                self.consumeInitialBootstrapCommittedPage(page)
            }
        }
        if self.isInitialBootstrapInFlight,
           self.initialBootstrapQueryId == queryId {
            self.initialBootstrapReadinessObservationKey = key
            self.initialBootstrapReadinessObservationToken = observation
        } else {
            // `observe` may synchronously replay an already committed page.
            // Do not reinstall that consumed observation after reset cleared
            // the controller-owned bootstrap state.
            coordinator.detach(key: key, observation: observation)
        }
    }

    internal func detachInitialBootstrapReadinessObservation() {
        guard let key = self.initialBootstrapReadinessObservationKey,
              let observation = self.initialBootstrapReadinessObservationToken else {
            self.initialBootstrapReadinessObservationKey = nil
            self.initialBootstrapReadinessObservationToken = nil
            return
        }
        self.initialBootstrapReadinessObservationKey = nil
        self.initialBootstrapReadinessObservationToken = nil
        ChatInitialBootstrapRequestCoordinator.shared.detach(
            key: key,
            observation: observation
        )
    }

    /// Conversation-scoped terminal ownership is independent from a
    /// controller-owned query. It stays attached across ordinary appearance
    /// cleanup so a fast durable count=0 cannot be lost while the chat is
    /// prepared off screen or moved between navigation columns.
    internal func observeConversationArchiveTerminal() {
        let key = self.initialBootstrapRequestKey
        if self.conversationArchiveTerminalObservationKey == key,
           self.conversationArchiveTerminalObservationToken != nil {
            return
        }
        self.detachConversationArchiveTerminalObservation()
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let observation = coordinator.observe(key: key) { [weak self] readiness in
            guard let readiness,
                  readiness.phase == .committed,
                  readiness.hasDurableCoverage,
                  readiness.confirmsEmptyConversation else {
                return
            }
            self?.performOnMain { [weak self] in
                guard let self,
                      self.initialBootstrapRequestKey == key,
                      self.committedArchiveReceiptMatchesCurrentBoundary(
                        readiness
                      ) else {
                    return
                }
                self.consumedEmptyArchiveTerminalKey = key
                self.cancelInitialBootstrapAutomaticRetry(
                    resetFailureCount: true
                )
                self.preservesBootstrapFailureOverlayUntilRetryCommit = false
                self.setBootstrapFailureVisible(false)
                self.resetInitialBootstrapTracking()
                self.releaseInteractiveChatOpenGate()
                self.applyBootstrapLoadingState(
                    .empty,
                    forceRender: true,
                    hasTrustedPersistedBootstrapPage: true
                )
            }
        }
        self.conversationArchiveTerminalObservationKey = key
        self.conversationArchiveTerminalObservationToken = observation
    }

    internal func detachConversationArchiveTerminalObservation() {
        guard let key = self.conversationArchiveTerminalObservationKey,
              let observation =
                self.conversationArchiveTerminalObservationToken else {
            self.conversationArchiveTerminalObservationKey = nil
            self.conversationArchiveTerminalObservationToken = nil
            return
        }
        self.conversationArchiveTerminalObservationKey = nil
        self.conversationArchiveTerminalObservationToken = nil
        ChatInitialBootstrapRequestCoordinator.shared.detach(
            key: key,
            observation: observation
        )
    }

    /// Reconciles the exact bootstrap still owned by this controller. Direct
    /// off-screen navigation can move between lifecycle observers while a
    /// fast empty MAM page commits. A durable receipt is replayed immediately;
    /// otherwise the stable presentation boundary reattaches observation to
    /// the existing account-scoped lease without starting another request.
    @discardableResult
    internal func reconcileInitialBootstrapReadinessAfterNavigationIfNeeded()
        -> Bool {
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = self.initialBootstrapLeaseKey ??
            self.initialBootstrapRequestKey
        guard self.isInitialBootstrapInFlight,
              let queryId = self.initialBootstrapQueryId else {
            // Off-screen direct navigation may reset the controller-owned
            // query while the account-scoped transaction finishes. The
            // committed receipt remains the authority; adopt it on the first
            // visible navigation boundary instead of leaving the old skeleton
            // or starting a second MAM.
            guard self.appliedBootstrapLoadingState?.showsSkeleton == true ||
                    self.isShowingBootstrapPlaceholder,
                  let lease = coordinator.committedLease(for: key),
                  let page = coordinator.cachedCommittedPage(
                    key: key,
                    queryId: lease.queryId
                  ) else {
                return false
            }
            self.initialBootstrapLeaseKey = key
            self.initialBootstrapTargetFingerprint = lease.targetFingerprint
            self.initialBootstrapPerformanceSemanticTargetFingerprint =
                lease.performanceSemanticTargetFingerprint
            self.initialBootstrapFollowUpTargetOverride = nil
            self.beginInitialBootstrapTracking(
                queryId: lease.queryId,
                timeout: nil
            )
            if self.isInitialBootstrapInFlight,
               self.initialBootstrapQueryId == lease.queryId {
                self.consumeInitialBootstrapCommittedPage(page)
            }
            return true
        }
        if let page = coordinator.cachedCommittedPage(
            key: key,
            queryId: queryId
        ) {
            self.consumeInitialBootstrapCommittedPage(page)
            return true
        }
        if self.initialBootstrapReadinessObservationKey == nil ||
            self.initialBootstrapReadinessObservationToken == nil {
            self.observeInitialBootstrapReadiness(queryId: queryId)
        }
        return false
    }

    internal func resetInitialBootstrapTracking(
        preserveInteractiveChatOpenGate: Bool = false,
        acknowledgeConsumedCommittedReceipt: Bool = true
    ) {
        self.cancelInitialBootstrapLocalHistoryFallback()
        self.cancelInitialBootstrapTimeout()
        self.revokeActivePostBootstrapInitialFrameAdmission()
        self.discardPendingInitialFrameLifecyclePresentation()
        let didConsumeCommittedPage = self.didReceiveInitialBootstrapEndPage
        self.detachInitialBootstrapReadinessObservation()
        let leaseKey = self.initialBootstrapLeaseKey ?? self.initialBootstrapRequestKey
        if let initialBootstrapQueryId {
            // A receipt is acknowledged only after this controller actually
            // consumed its committed page. Teardown may win the main-queue hop
            // from coordinator readiness to presentation; in that case the
            // account-scoped receipt must remain available to a reopened chat.
            if didConsumeCommittedPage,
               acknowledgeConsumedCommittedReceipt {
                _ = ChatInitialBootstrapRequestCoordinator.shared
                    .acknowledgeCommittedReceipt(
                        key: leaseKey,
                        queryId: initialBootstrapQueryId
                    )
            }
            self.endChatHistoryLoadActivity(reason: "initial:\(initialBootstrapQueryId)")
            // The account-scoped coordinator owns query persistence. Controller
            // teardown detaches only presentation dispatchers and must not
            // terminate the shared batch between raw <fin> and Realm commit.
            self.unregisterRemoteHistoryFailureDispatcher(queryId: initialBootstrapQueryId)
            self.unregisterRemoteHistoryEndPageDispatcher(queryId: initialBootstrapQueryId)
        }
        self.initialBootstrapQueryId = nil
        self.initialBootstrapLeaseKey = nil
        self.initialBootstrapTargetFingerprint = nil
        self.initialBootstrapPerformanceSemanticTargetFingerprint = nil
        self.isInitialBootstrapInFlight = false
        self.didReceiveInitialBootstrapEndPage = false
        self.initialBootstrapPageEndState = nil
        self.initialBootstrapResultCount = nil
        self.initialBootstrapPersistedMessageCount = nil
        self.initialBootstrapPersistedRowsForQuery = nil
        self.initialBootstrapVisibleRowsForConversation = nil
        self.initialBootstrapScopedRefreshQueryId = nil
        self.didEnterInitialBootstrapObserverSettlePhase = false
        self.didObserveInitialBootstrapPostIdleTick = false
        if !preserveInteractiveChatOpenGate {
            self.initialBootstrapPresentationDeadline = nil
            self.releaseInteractiveChatOpenGate()
        }
    }

    internal func scheduleInitialBootstrapTimeout(
        queryId: String,
        timeout: TimeInterval = ChatInteractiveRemoteArchiveTimeoutPolicy.timeout
    ) {
        guard queryId.isNotEmpty else {
            return
        }
        self.cancelInitialBootstrapTimeout()
        guard !self.hasCommittedRealContentInCurrentLifecycle else {
            self.initialBootstrapPresentationDeadline = nil
            return
        }

        let now = Date()
        if self.initialBootstrapPresentationDeadline == nil {
            self.initialBootstrapPresentationDeadline =
                now.addingTimeInterval(max(0, timeout))
        }
        let remainingPresentationBudget = max(
            0,
            self.initialBootstrapPresentationDeadline?.timeIntervalSince(now) ?? 0
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isInitialBootstrapInFlight,
                  self.initialBootstrapQueryId == queryId,
                  !self.hasCommittedRealContentInCurrentLifecycle else {
                return
            }
            self.initialBootstrapTimeoutWorkItem = nil
            let coordinator = ChatInitialBootstrapRequestCoordinator.shared
            let leaseKey =
                self.initialBootstrapLeaseKey ?? self.initialBootstrapRequestKey
            let readiness = coordinator.readiness(for: leaseKey)
            guard readiness?.phase == .failed else {
                // The presentation SLA is allowed to release background/chat
                // navigation pressure, but an active archive phase is not a
                // load failure. Keep the exact committed skeleton until the
                // coordinator publishes content, confirmed empty, or a real
                // terminal failure.
                self.initialBootstrapPresentationDeadline = nil
                self.releaseInteractiveChatOpenGate()
                ChatArchiveDebugTrace.log(
                    "initialBootstrapPresentationWatchdogDeferredToArchiveTerminal",
                    [
                        ("operationActive", true),
                        ("phaseCode", readiness?.phase.traceCode)
                    ]
                )
                return
            }
            self.handleInitialBootstrapRemoteArchiveFailure(
                queryId: queryId,
                reason: .timeout,
                streamKind: .unknown,
                errorDescription: "Archive request reached terminal failure"
            )
        }
        self.initialBootstrapTimeoutWorkItem = workItem
        ChatArchiveDebugTrace.log("initialBootstrapTimeoutScheduled", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId),
            ("timeoutMs", Int(max(0, timeout) * 1000))
        ])
        DispatchQueue.main.asyncAfter(
            deadline: .now() + remainingPresentationBudget,
            execute: workItem
        )
    }

    internal func cancelInitialBootstrapTimeout() {
        self.initialBootstrapTimeoutWorkItem?.cancel()
        self.initialBootstrapTimeoutWorkItem = nil
    }

    internal func scheduleInitialBootstrapAutomaticRetryAfterFailure() {
        if !Thread.isMainThread {
            self.performOnMain { [weak self] in
                self?.scheduleInitialBootstrapAutomaticRetryAfterFailure()
            }
            return
        }

        self.initialBootstrapAutomaticRetryWorkItem?.cancel()
        self.initialBootstrapAutomaticRetryWorkItem = nil
        self.initialBootstrapAutomaticRetryGeneration &+= 1
        self.isInitialBootstrapAutomaticRetryPending = true
        self.preservesBootstrapFailureOverlayUntilRetryCommit = false
        self.allowsBootstrapFailureFallback = false
        self.setBootstrapFailureVisible(false)
        self.applyBootstrapLoadingState(
            self.silentInitialBootstrapRetryLoadingState(),
            forceRender: true
        )

        guard self.isInitialFramePresentationLifecycleEligible,
              self.initialFramePresentationApplicationStateProvider() == .active else {
            return
        }
        guard self.currentBootstrapRequiresArchiveConfirmation() else {
            self.cancelInitialBootstrapAutomaticRetry(resetFailureCount: true)
            self.applyBootstrapLoadingState(
                self.currentBootstrapLoadingState(),
                forceRender: true
            )
            return
        }

        let failureCount = max(1, self.initialBootstrapAutomaticRetryFailureCount)
        let delay: TimeInterval
#if DEBUG || CHAT_PERFORMANCE_LAB
        delay = self.initialBootstrapAutomaticRetryDelayProvider?(failureCount) ??
            ChatInitialBootstrapAutomaticRetryPolicy.delay(
                afterFailureCount: failureCount
            )
#else
        delay = ChatInitialBootstrapAutomaticRetryPolicy.delay(
            afterFailureCount: failureCount
        )
#endif
        let generation = self.initialBootstrapAutomaticRetryGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.initialBootstrapAutomaticRetryGeneration == generation,
                  self.isInitialBootstrapAutomaticRetryPending else {
                return
            }
            self.initialBootstrapAutomaticRetryWorkItem = nil
            guard self.isInitialFramePresentationLifecycleEligible,
                  self.initialFramePresentationApplicationStateProvider() == .active else {
                return
            }
            guard self.currentBootstrapRequiresArchiveConfirmation() else {
                self.cancelInitialBootstrapAutomaticRetry(resetFailureCount: true)
                self.applyBootstrapLoadingState(
                    self.currentBootstrapLoadingState(),
                    forceRender: true
                )
                return
            }
            self.isInitialBootstrapAutomaticRetryPending = false
            self.requestInitialBootstrapArchive(showFailureIfUnavailable: false)
        }
        self.initialBootstrapAutomaticRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: workItem
        )
    }

    internal func resumeInitialBootstrapAutomaticRetryIfNeeded() {
        guard self.isInitialBootstrapAutomaticRetryPending,
              self.initialBootstrapAutomaticRetryWorkItem == nil else {
            return
        }
        self.scheduleInitialBootstrapAutomaticRetryAfterFailure()
    }

    internal func suspendInitialBootstrapAutomaticRetry() {
        guard self.isInitialBootstrapAutomaticRetryPending else {
            return
        }
        self.initialBootstrapAutomaticRetryWorkItem?.cancel()
        self.initialBootstrapAutomaticRetryWorkItem = nil
        self.initialBootstrapAutomaticRetryGeneration &+= 1
    }

    internal func cancelInitialBootstrapAutomaticRetry(
        resetFailureCount: Bool
    ) {
        self.initialBootstrapAutomaticRetryWorkItem?.cancel()
        self.initialBootstrapAutomaticRetryWorkItem = nil
        self.initialBootstrapAutomaticRetryGeneration &+= 1
        self.isInitialBootstrapAutomaticRetryPending = false
        if resetFailureCount {
            self.initialBootstrapAutomaticRetryFailureCount = 0
        }
    }

    private func silentInitialBootstrapRetryLoadingState()
        -> ChatBootstrapLoadingState {
        if self.hasPendingInitialAnchorRequest() {
            return .blockingTarget
        }
        if self.allowsStaleLocalHistoryDuringInitialBootstrap,
           self.localHistoryMessageCountForBootstrap() > 0 {
            return .content
        }
        return .blockingArchive
    }

    internal func localHistoryMessageCountForBootstrap() -> Int {
        let proofCount = self.currentInitialFrameReadinessProof()?
            .materializedLocalMessageCount ?? 0
        let residentCount = self.timelineSession?.snapshot.items.reduce(into: 0) {
            if !$1.isDeleted { $0 += 1 }
        } ?? 0
        let presentedCount = self.datasource.reduce(into: 0) {
            if !$1.isFakeMessage { $0 += 1 }
        }
        let materializedCount = max(proofCount, residentCount, presentedCount)
        if materializedCount > 0 {
            return materializedCount
        }
        // Before the typed off-main preparation, absence is deliberately
        // unknown. Synchronous admission must stay conservative instead of
        // probing MessageStorageItem on the main thread.
        return 0
    }

    internal func currentInitialFrameReadinessProof()
        -> ChatTimelineInitialFrameReadinessProof? {
        guard let session = self.timelineSession else { return nil }
        let conversationKey = ChatTimelineConversationKey(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        if let proof = self.initialLocalFirstFrameReadinessProof,
           proof.conversationKey == conversationKey,
           (proof.baseGeneration == session.snapshot.generation ||
            proof.baseGeneration &+ 1 == session.snapshot.generation) {
            return proof
        }
        if case .preparing = self.initialLocalFirstFramePhase {
            return nil
        }
        if let proof = session.snapshot.unreadMetadata.initialFrameReadinessProof,
           proof.conversationKey == conversationKey,
           proof.baseGeneration &+ 1 == session.snapshot.generation {
            return proof
        }
        return nil
    }

    @discardableResult
    internal func completeInitialBootstrapIfNeeded() -> Bool {
        guard self.isInitialBootstrapInFlight else {
            return false
        }

        let localMessageCount = self.localHistoryMessageCountForBootstrap()
        let visibleRowsForLatestPage = self.initialBootstrapVisibleRowsForConversation ?? 0
        let persistedRowsForQuery = self.initialBootstrapPersistedRowsForQuery ?? 0
        let hasMessages = visibleRowsForLatestPage > 0 || persistedRowsForQuery > 0
        let didConfirmEmpty =
            ChatInitialBootstrapRequestCoordinator.shared
                .readiness(for: self.initialBootstrapRequestKey)?
                .confirmsEmptyConversation == true
        let hasCommittedContent = self.hasCommittedRealContentInCurrentLifecycle &&
            self.datasource.contains { !$0.isFakeMessage }
        let pendingFollowUpRequest =
            ChatInitialBootstrapRequestCoordinator.shared.pendingFollowUpRequest(
                for: self.initialBootstrapRequestKey
            )
        let pendingTargetMatchesCurrentTarget =
            ChatInitialBootstrapFollowUpTargetPolicy.matchesActiveLease(
                coordinatorRequest: pendingFollowUpRequest,
                activeTargetFingerprint:
                    self.initialBootstrapTargetFingerprint,
                activePerformanceSemanticTargetFingerprint:
                    self.initialBootstrapPerformanceSemanticTargetFingerprint
            )
        let isSupersededByDifferentTarget =
            pendingFollowUpRequest != nil &&
            !pendingTargetMatchesCurrentTarget
        let hasCommittedInitialFrame: Bool = {
            guard hasCommittedContent else {
                return false
            }
            switch self.initialLocalFirstFramePhase {
            case .preparing, .presenting:
                return false
            case .idle, .committed, .blockedArchiveBootstrap,
                 .blockedMissingTarget, .failedPresentation:
                return true
            }
        }()
        // `didReceiveInitialBootstrapEndPage` is set only after the async
        // query-scoped persistence barrier has completed. Do not synchronously
        // poll MessageManager's queue from the main-thread completion path.
        let isMessagePipelineIdle = self.didReceiveInitialBootstrapEndPage
        let isArchivePagePersisted = visibleRowsForLatestPage > 0 || persistedRowsForQuery > 0

        let requiresObserverSettle = visibleRowsForLatestPage > 0
        if self.didReceiveInitialBootstrapEndPage,
           isMessagePipelineIdle,
           requiresObserverSettle,
           !isArchivePagePersisted,
           !self.didEnterInitialBootstrapObserverSettlePhase {
            self.didEnterInitialBootstrapObserverSettlePhase = true
            DispatchQueue.main.async {
                self.didObserveInitialBootstrapPostIdleTick = true
                _ = self.completeInitialBootstrapIfNeeded()
            }
            return false
        }

        guard ChatInitialBootstrapCompletionPolicy.shouldFinish(
            didReceiveEndPage: self.didReceiveInitialBootstrapEndPage,
            hasMessages: hasMessages,
            didConfirmEmpty: didConfirmEmpty,
            isMessagePipelineIdle: isMessagePipelineIdle,
            isArchivePagePersisted: isArchivePagePersisted,
            hasCommittedContent: hasCommittedContent,
            hasCommittedInitialFrame: hasCommittedInitialFrame,
            isSupersededByDifferentTarget:
                isSupersededByDifferentTarget,
            requiresObserverSettle: requiresObserverSettle,
            didObservePostIdleTick: self.didObserveInitialBootstrapPostIdleTick
        ) else {
            return false
        }

        // Coverage, cursor and durable readiness are committed atomically by
        // MessageArchiveManager after the query-scoped persistence barrier.
        // Presentation must never infer a live edge from a target page.
        if didConfirmEmpty {
            // This controller consumed the exact committed bootstrap page.
            // Keep that authoritative count=0 locally before any boundary
            // follow-up/reset releases the shared coordinator receipt.
            self.consumedEmptyArchiveTerminalKey =
                self.initialBootstrapRequestKey
        }
        self.cancelInitialBootstrapAutomaticRetry(resetFailureCount: true)
        self.rebuildUnreadMentionItems()
        let persistedMessageCount = self.initialBootstrapPersistedMessageCount ?? 0
        let completedQueryId = self.initialBootstrapQueryId ?? "-"
        let requiresBoundaryFollowUp = self.currentBootstrapCommitRequiresBoundaryFollowUp()
        if requiresBoundaryFollowUp {
            let hasCommittedTargetRows =
                self.hasCommittedRealContentInCurrentLifecycle &&
                self.datasource.contains { !$0.isFakeMessage }
            let coordinatorRequest =
                ChatInitialBootstrapRequestCoordinator.shared.pendingFollowUpRequest(
                    for: self.initialBootstrapRequestKey
                )
            let consumesSnapshotRepairBudget =
                ChatInitialBootstrapFollowUpTargetPolicy.consumesSnapshotRepairBudget(
                    coordinatorRequest: coordinatorRequest
                )
            let shouldStartFollowUp = !consumesSnapshotRepairBudget ||
                !self.hasAttemptedInitialBootstrapBoundaryFollowUp
            let followUpTarget = ChatInitialBootstrapFollowUpTargetPolicy.target(
                coordinatorRequest: coordinatorRequest
            )
            self.resetInitialBootstrapTracking(
                preserveInteractiveChatOpenGate: true
            )

            ChatArchiveDebugTrace.log("initialBootstrapBoundaryRecheck", [
                ("queryId", completedQueryId),
                ("persisted", persistedMessageCount),
                ("persistedRowsForQuery", persistedRowsForQuery),
                ("visibleRows", visibleRowsForLatestPage),
                ("startFollowUp", shouldStartFollowUp),
                ("followUpExhausted", !shouldStartFollowUp)
            ])

            if shouldStartFollowUp {
                if consumesSnapshotRepairBudget {
                    self.hasAttemptedInitialBootstrapBoundaryFollowUp = true
                }
                self.initialBootstrapFollowUpTargetOverride = followUpTarget
                self.applyBootstrapLoadingState(
                    ChatBootstrapCoverageFollowUpPresentationPolicy.loadingState(
                        hasCommittedTargetRows: hasCommittedTargetRows
                    ),
                    forceRender: true
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          !self.isInitialBootstrapInFlight else {
                        return
                    }
                    self.requestInitialBootstrapArchive(showFailureIfUnavailable: true)
                }
            } else {
                if hasCommittedTargetRows {
                    // Exhausting coverage repair is not a presentation
                    // failure. The persistence-confirmed page remains fully
                    // interactive and a later background trigger may repair
                    // the newer snapshot boundary.
                    self.allowsBootstrapFailureFallback = false
                    self.allowsStaleLocalHistoryDuringInitialBootstrap = true
                    self.applyBootstrapLoadingState(.content, forceRender: true)
                    self.setDatasourceLoadingEnabled(true)
                } else {
                    self.allowsBootstrapFailureFallback = true
                    self.applyBootstrapLoadingState(
                        .failure(
                            fallback:
                                localMessageCount > 0 ? .content : .empty
                        ),
                        forceRender: true
                    )
                }
                self.initialBootstrapPresentationDeadline = nil
                self.releaseInteractiveChatOpenGate()
            }
            return true
        }

        self.hasAttemptedInitialBootstrapBoundaryFollowUp = false
        self.resetInitialBootstrapTracking()
        ChatArchiveDebugTrace.log("initialBootstrapFinished", [
            ("persisted", persistedMessageCount),
            ("persistedRowsForQuery", persistedRowsForQuery),
            ("visibleRows", visibleRowsForLatestPage),
            ("localCount", localMessageCount)
        ])
        self.applyBootstrapLoadingState(
            ChatInitialBootstrapCommittedPresentationPolicy.loadingState(
                liveLoadingState: self.currentBootstrapLoadingState(),
                didConfirmEmpty: didConfirmEmpty
            ),
            forceRender: true,
            hasTrustedPersistedBootstrapPage: didConfirmEmpty
        )
        return true
    }

    internal func scheduleInitialBootstrapLocalHistoryFallbackIfNeeded() {
        guard ChatBootstrapLocalHistoryFallbackPolicy.shouldScheduleFallback(
            messageCount: self.localHistoryMessageCountForBootstrap(),
            isShowingSkeleton: self.showSkeletonObserver.value,
            allowsStaleLocalHistory: self.allowsStaleLocalHistoryDuringInitialBootstrap,
            hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest(),
            isRequiredArchiveBootstrapInFlight: self.isInitialBootstrapInFlight || self.currentBootstrapRequiresArchiveConfirmation()
        ) else {
            return
        }

        self.initialBootstrapLocalHistoryFallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.initialBootstrapLocalHistoryFallbackWorkItem = nil
            _ = self.revealStaleLocalHistoryIfNeeded()
        }
        self.initialBootstrapLocalHistoryFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ChatBootstrapLocalHistoryFallbackPolicy.fallbackDelay,
            execute: workItem
        )
    }

    internal func cancelInitialBootstrapLocalHistoryFallback() {
        self.initialBootstrapLocalHistoryFallbackWorkItem?.cancel()
        self.initialBootstrapLocalHistoryFallbackWorkItem = nil
        self.allowsStaleLocalHistoryDuringInitialBootstrap = false
        self.allowsBootstrapFailureFallback = false
    }

    @discardableResult
    internal func revealStaleLocalHistoryIfNeeded() -> Bool {
        guard ChatBootstrapLocalHistoryFallbackPolicy.shouldRevealLocalHistory(
            messageCount: self.localHistoryMessageCountForBootstrap(),
            isShowingSkeleton: self.showSkeletonObserver.value,
            hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest(),
            isRequiredArchiveBootstrapInFlight: self.isInitialBootstrapInFlight || self.currentBootstrapRequiresArchiveConfirmation()
        ) else {
            return false
        }

        self.initialBootstrapLocalHistoryFallbackWorkItem?.cancel()
        self.initialBootstrapLocalHistoryFallbackWorkItem = nil
        self.allowsStaleLocalHistoryDuringInitialBootstrap = true
        self.applyBootstrapLoadingState(self.currentBootstrapLoadingState(), forceRender: true)
        return true
    }

    @discardableResult
    internal func revealInitialBootstrapContentIfAvailable() -> Bool {
        let state = self.currentBootstrapViewState()
        guard ChatInitialBootstrapContentRevealPolicy.shouldRevealContent(
            isShowingSkeleton: self.showSkeletonObserver.value,
            bootstrapState: state
        ) else {
            return false
        }

        self.initialBootstrapLocalHistoryFallbackWorkItem?.cancel()
        self.initialBootstrapLocalHistoryFallbackWorkItem = nil
        self.applyBootstrapLoadingState(self.currentBootstrapLoadingState(), forceRender: true)
        return true
    }

    internal func handleInitialBootstrapRemoteArchiveFailure(
        queryId: String,
        reason: MessageArchiveRequestFailureReason,
        streamKind: MessageArchiveEndPageEvent.StreamKind,
        errorDescription: String?
    ) {
        self.performOnMain {
            guard self.isInitialBootstrapInFlight,
                  self.initialBootstrapQueryId == queryId else {
                ChatArchiveDebugTrace.log("initialBootstrapFailureSkipped", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("activeQueryId", self.initialBootstrapQueryId ?? "-"),
                    ("reason", reason.rawValue)
                ])
                return
            }

            let event = MessageArchiveRequestFailureEvent(
                owner: self.owner,
                queryId: queryId,
                streamKind: streamKind,
                reason: reason,
                errorDescription: errorDescription,
                pendingQueryCount: 1
            )
            let coordinator = ChatInitialBootstrapRequestCoordinator.shared
            let didRecordFailure = coordinator.recordFailure(
                key: self.initialBootstrapRequestKey,
                event: event,
                publishEvent: true
            )
            let hasCommittedPage = coordinator.cachedCommittedPage(
                key: self.initialBootstrapRequestKey,
                queryId: queryId
            ) != nil
            let finalOwnsActiveAttempt = !didRecordFailure && !hasCommittedPage && (
                coordinator.cachedEndPageEvent(
                    key: self.initialBootstrapRequestKey,
                    queryId: queryId
                ) != nil || (
                    coordinator.isActive(
                        key: self.initialBootstrapRequestKey,
                        queryId: queryId
                    ) && MessageArchiveEndPageDispatcher.hasAcceptedSynchronousDelivery(
                        owner: self.owner,
                        queryId: queryId
                    )
                )
            )
            if finalOwnsActiveAttempt {
                ChatArchiveDebugTrace.log("initialBootstrapFailureSupersededByFinal", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("reason", reason.rawValue)
                ])
                return
            }

            let localMessageCount = self.localHistoryMessageCountForBootstrap()
            let hasPendingInitialAnchorRequest = self.hasPendingInitialAnchorRequest()
            let isNonblockingCoverageFailure =
                self.hasAttemptedInitialBootstrapBoundaryFollowUp &&
                self.hasCommittedRealContentInCurrentLifecycle &&
                self.datasource.contains { !$0.isFakeMessage }
            let shouldRevealLocalHistory = ChatInitialBootstrapFailureRecoveryPolicy.shouldRevealLocalHistory(
                messageCount: localMessageCount,
                hasPendingInitialAnchorRequest: hasPendingInitialAnchorRequest
            )
            ChatArchiveDebugTrace.log("initialBootstrapFailure", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("reason", reason.rawValue),
                ("streamKind", streamKind.rawValue),
                ("error", errorDescription ?? "none"),
                ("localCount", localMessageCount),
                ("revealLocalHistory", shouldRevealLocalHistory),
                (
                    "allowFailureFallback",
                    !hasPendingInitialAnchorRequest &&
                    !isNonblockingCoverageFailure
                ),
                (
                    "nonblockingCoverageFailure",
                    isNonblockingCoverageFailure
                )
            ])

            self.resetInitialBootstrapTracking()
            self.preservesBootstrapFailureOverlayUntilRetryCommit = false
            coordinator.clearTerminal(key: self.initialBootstrapRequestKey)
            self.allowsBootstrapFailureFallback = false
            self.setBootstrapFailureVisible(false)
            if isNonblockingCoverageFailure || shouldRevealLocalHistory {
                self.allowsStaleLocalHistoryDuringInitialBootstrap = true
            }
            if isNonblockingCoverageFailure {
                self.applyBootstrapLoadingState(.content, forceRender: true)
                self.setDatasourceLoadingEnabled(true)
                self.cancelPendingArchiveObserverRefresh(
                    reason: "initialBootstrapCoverageFailure"
                )
                self.performPendingOpenMessageRequestIfNeeded(
                    trigger: .observerRefresh
                )
            } else {
                self.applyBootstrapLoadingState(
                    self.silentInitialBootstrapRetryLoadingState(),
                    forceRender: true
                )
                self.cancelPendingArchiveObserverRefresh(
                    reason: "initialBootstrapFailure"
                )
                self.performPendingOpenMessageRequestIfNeeded(
                    trigger: .observerRefresh
                )
            }
            self.initialBootstrapAutomaticRetryFailureCount &+= 1
            self.scheduleInitialBootstrapAutomaticRetryAfterFailure()
        }
    }

    @discardableResult
    internal func handleInitialBootstrapEndPageIfNeeded(
        queryId: String,
        state: MessageArchivePageEndState,
        count: Int,
        persistedMessageCount: Int,
        persistedRowsForQuery: Int = 0,
        visibleRowsForConversation: Int
    ) -> Bool {
        guard queryId == self.initialBootstrapQueryId else {
            return false
        }

        self.didReceiveInitialBootstrapEndPage = true
        self.initialBootstrapPageEndState = state
        self.initialBootstrapResultCount = count
        self.initialBootstrapPersistedMessageCount = persistedMessageCount
        self.initialBootstrapPersistedRowsForQuery = persistedRowsForQuery
        self.initialBootstrapVisibleRowsForConversation = visibleRowsForConversation
        let hasPersistedPageContent = count > 0 ||
            persistedRowsForQuery > 0 ||
            visibleRowsForConversation > 0
        let hasCommittedTargetRows =
            self.hasCommittedRealContentInCurrentLifecycle &&
            self.datasource.contains { !$0.isFakeMessage }
        let isLatestCoverageFollowUp =
            self.hasAttemptedInitialBootstrapBoundaryFollowUp &&
            self.initialBootstrapTargetFingerprint?.target == .latest
        let pendingFollowUpRequest =
            ChatInitialBootstrapRequestCoordinator.shared.pendingFollowUpRequest(
                for: self.initialBootstrapRequestKey
            )
        let isSupersededByPendingTarget = pendingFollowUpRequest != nil
        let pendingTargetMatchesCurrentTarget =
            ChatInitialBootstrapFollowUpTargetPolicy.matchesActiveLease(
                coordinatorRequest: pendingFollowUpRequest,
                activeTargetFingerprint:
                    self.initialBootstrapTargetFingerprint,
                activePerformanceSemanticTargetFingerprint:
                    self.initialBootstrapPerformanceSemanticTargetFingerprint
            )
        let shouldRefreshDatasource =
            ChatBootstrapCoverageFollowUpPresentationPolicy.shouldRefreshDatasource(
                isLatestCoverageFollowUp: isLatestCoverageFollowUp,
                isSupersededByPendingTarget: isSupersededByPendingTarget,
                pendingTargetMatchesCurrentTarget:
                    pendingTargetMatchesCurrentTarget,
                hasCommittedTargetRows: hasCommittedTargetRows,
                hasPersistedPageContent: hasPersistedPageContent
            )
        let awaitsDatasourceCommit: Bool
        if shouldRefreshDatasource {
            awaitsDatasourceCommit =
                self.refreshInitialBootstrapTimelineAfterPersistenceIfNeeded(
                    queryId: queryId,
                    hasPersistedPageContent: true
                ) { [weak self] in
                    _ = self?.completeInitialBootstrapIfNeeded()
                }
        } else {
            awaitsDatasourceCommit = false
        }
        if !awaitsDatasourceCommit {
            _ = self.completeInitialBootstrapIfNeeded()
        }
        return true
    }

    /// Performs exactly one presentation refresh for a persisted initial page.
    /// It deliberately bypasses the general observer-pressure gate: the
    /// bootstrap watchdog needs a chance to observe the page's committed frame.
    @discardableResult
    internal func refreshInitialBootstrapTimelineAfterPersistenceIfNeeded(
        queryId: String,
        hasPersistedPageContent: Bool,
        completion: (() -> Void)? = nil
    ) -> Bool {
        guard queryId == self.initialBootstrapQueryId,
              hasPersistedPageContent,
              self.initialBootstrapScopedRefreshQueryId != queryId else {
            return false
        }
        self.initialBootstrapScopedRefreshQueryId = queryId
        _ = self.reloadInitialWindowAfterBootstrapIfNeeded(
            force: true,
            hasTrustedPersistedBootstrapPage: true,
            completion: completion
        )
        // Once a persisted non-empty page is admitted, completion belongs to
        // the datasource transaction even when the timeline session is still
        // being installed. Coverage follow-up must not race that first frame.
        return true
    }

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
                isResidentAtLiveTail: normalizedState.isResidentAtLiveTail,
                hasBottomBoundaryPlaceholder: self.activeHistoryBoundaryPlaceholder == .bottom,
                hasBottomVirtualPlaceholder: normalizedState.activePlaceholder == .bottom,
                hasNewerRemoteLoad: normalizedState.activeRemoteLoad?.direction == .newer
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

    internal func abortInteractiveHistoryPageLoad() {
        self.abortInteractiveHistoryPageLoad(
            queryId: self.interactiveHistoryPageLoadContext?.queryId,
            reason: .requestStartFailed,
            streamKind: .unknown,
            errorDescription: nil
        )
    }

    internal func handleInteractiveRemoteArchiveFailure(
        queryId: String,
        reason: MessageArchiveRequestFailureReason,
        streamKind: MessageArchiveEndPageEvent.StreamKind,
        errorDescription: String?
    ) {
        self.performOnMain {
            guard let context = self.interactiveHistoryPageLoadContext,
                  context.queryId == queryId else {
                ChatArchiveDebugTrace.log("interactiveRemoteArchiveAbortSkipped", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("reason", reason.rawValue),
                    ("activeQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
                    ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-")
                ])
                return
            }

            _ = self.remoteHistoryQueryCoordinator.terminate(
                queryId: queryId,
                generation: context.generation,
                reason: self.remoteHistoryTerminalReason(for: reason)
            )

            if reason == .timeout {
                let startedAt = self.remoteHistoryRequestStartedAtByQueryId[queryId]
                ChatArchiveDebugTrace.log("interactiveRemoteArchiveTimeout", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("ageMs", startedAt.map { ChatArchiveDebugTrace.milliseconds(since: $0) } ?? -1),
                    ("direction", context.direction),
                    ("cursor", context.requestedCursorId ?? "-"),
                    ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                    ("pageLocked", self.timelineInteractionState.locked)
                ])
            } else if reason == .uiActionDisconnect {
                ChatArchiveDebugTrace.log("interactiveRemoteArchiveDisconnect", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("streamKind", streamKind.rawValue),
                    ("disconnectError", errorDescription ?? "none"),
                    ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                    ("pageLocked", self.timelineInteractionState.locked)
                ])
            }

            self.abortInteractiveHistoryPageLoad(
                queryId: queryId,
                reason: reason,
                streamKind: streamKind,
                errorDescription: errorDescription
            )
        }
    }

    internal func handleInteractiveRemoteArchiveRequestStartTimeout(queryId: String) {
        self.performOnMain {
            guard let context = self.interactiveHistoryPageLoadContext,
                  context.queryId == queryId else {
                ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartTimeoutSkipped", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("reason", "queryMismatch"),
                    ("activeQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
                    ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-")
                ])
                return
            }

            guard !context.remoteFetchStarted else {
                ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartTimeoutSkipped", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("reason", "alreadyStarted"),
                    ("direction", context.direction),
                    ("cursor", context.requestedCursorId ?? "-"),
                    ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                    ("pageLocked", self.timelineInteractionState.locked)
                ])
                return
            }

            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestDispatchTimeout", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("direction", context.direction),
                ("cursor", context.requestedCursorId ?? "-"),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                ("pageLocked", self.timelineInteractionState.locked),
                ("remoteFetchStarted", context.remoteFetchStarted),
                ("visibleLoader", self.timelineInteractionState.isLoading),
                ("placeholderState", self.activeHistoryBoundaryPlaceholder != nil || self.virtualTimelineState.activePlaceholder != nil),
                ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count)
            ])
            self.abortInteractiveHistoryPageLoad(
                queryId: queryId,
                reason: .requestStartFailed,
                streamKind: .unknown,
                errorDescription: "request dispatch did not start"
            )
        }
    }

    private func abortInteractiveHistoryPageLoad(
        queryId: String?,
        reason: MessageArchiveRequestFailureReason,
        streamKind: MessageArchiveEndPageEvent.StreamKind,
        errorDescription: String?
    ) {
        let context = self.interactiveHistoryPageLoadContext
        let hadBoundaryPlaceholder = self.activeHistoryBoundaryPlaceholder != nil
        let hadVirtualPlaceholder = self.virtualTimelineState.activePlaceholder != nil
        if let context,
           queryId == nil || queryId == context.queryId {
            _ = self.remoteHistoryQueryCoordinator.terminate(
                queryId: context.queryId,
                generation: context.generation,
                reason: self.remoteHistoryTerminalReason(for: reason)
            )
            if let performanceTraceContext = context.performanceTraceContext {
                _ = ChatArchivePerformanceTraceRegistry.shared.terminate(
                    owner: context.performanceTraceOwner ?? self.owner,
                    queryID: context.queryId,
                    context: performanceTraceContext,
                    terminal: reason == .requestStartFailed
                        ? .cancelled
                        : .failed
                )
            }
        }
        if let queryId {
            self.unregisterRemoteHistoryPersistenceSource(queryId: queryId)
            self.abortedRemoteHistoryQueryIds.insert(queryId)
            if let timelineSession = self.timelineSession {
                _ = timelineSession.abortRemoteLoad(queryId: queryId)
            } else {
                let abortedState = self.virtualTimelineState.abortingRemoteLoad(queryId: queryId)
                self.virtualTimelineState = abortedState
                self.boundedTimelineWindowState = ChatBoundedTimelineWindowState(
                    virtualState: abortedState
                )
            }
            self.refreshScrollBoundaryAvailabilityCache(reason: "remoteLoadAbort")
        }
        self.cancelInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)
        self.cancelInteractiveHistoryCompletionRetry()
        self.interactiveHistoryPageLoadContext = nil
        self.activeHistoryBoundaryPlaceholder = nil
        self.endHistoryLoadingUI(unlockPage: false)
        self.setArchiveLoading(false)
        self.timelineInteractionState.unlock()
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveAbort", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId ?? "-"),
            ("reason", reason.rawValue),
            ("streamKind", streamKind.rawValue),
            ("error", errorDescription ?? "none"),
            ("placeholderRemoved", hadBoundaryPlaceholder || hadVirtualPlaceholder),
            ("activeRemoteLoadCleared", self.virtualTimelineState.activeRemoteLoad == nil),
            ("coverageCommitted", false)
        ])
    }

    private func remoteHistoryTerminalReason(
        for reason: MessageArchiveRequestFailureReason
    ) -> ChatRemoteHistoryTerminalReason {
        switch reason {
        case .timeout:
            return .timeout
        case .uiActionDisconnect:
            return .disconnected
        case .serverError, .malformedResponse:
            return .iqError
        case .requestStartFailed:
            return .cancelled
        }
    }

    private func scheduleInteractiveHistoryCompletionRetry(queryId: String) {
        self.interactiveHistoryCompletionRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let context = self.interactiveHistoryPageLoadContext,
                  context.queryId == queryId,
                  context.didReceiveEndPage else {
                return
            }

            if self.tryFinishInteractiveHistoryPageLoadIfReady() {
                return
            }

            self.scheduleInteractiveHistoryCompletionRetry(queryId: queryId)
        }
        self.interactiveHistoryCompletionRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func cancelInteractiveHistoryCompletionRetry() {
        self.interactiveHistoryCompletionRetryWorkItem?.cancel()
        self.interactiveHistoryCompletionRetryWorkItem = nil
    }

    internal func finishPagingInteraction(
        window: ChatDatasetWindow,
        shouldApplyWindow: Bool,
        direction: ChatHistoryPageDirection,
        animated: Bool = true
    ) {
        let anchor = self.capturePagingAnchorIfNeeded(direction: direction)
        let applyPlan = ChatHistoryPageApplyPolicy.plan(
            direction: direction,
            hasCapturedAnchor: anchor != nil
        )
        let applyMode: ChatDatasourceApplyMode = .windowReload(
            keepOffset: applyPlan.keepOffset
        )
        let applyAnimated = applyPlan.applyCategory == .olderAnchorReload ? false : animated
        self.activeHistoryBoundaryPlaceholder = nil

        guard shouldApplyWindow else {
            self.endHistoryLoadingUI(unlockPage: false)
            self.timelineInteractionState.unlock()
            return
        }

        self.mapAndApplyTimelineCurrent(
            mode: applyMode,
            animated: applyAnimated,
            invalidateLayout: false,
            preserveBoundaryPlaceholder: false,
            applyCategory: applyPlan.applyCategory,
            anchorRestorePhase: applyPlan.restorePhase,
            anchorPrimary: anchor?.primary,
            restoreAnchor: anchor,
            completion: {
                self.endHistoryLoadingUI(unlockPage: false)
                self.timelineInteractionState.unlock()
            },
            cancelledCompletion: {
                self.endHistoryLoadingUI(unlockPage: false)
                self.timelineInteractionState.unlock()
            }
        )
    }

    internal func finishPagingInteraction(
        preparedPage: ChatPreparedLocalHistoryPage,
        animated: Bool = true
    ) {
        let direction = preparedPage.direction
        let anchor = self.capturePagingAnchorIfNeeded(direction: direction)
        let applyPlan = ChatHistoryPageApplyPolicy.plan(
            direction: direction,
            hasCapturedAnchor: anchor != nil
        )
        let applyMode: ChatDatasourceApplyMode = .windowReload(
            keepOffset: applyPlan.keepOffset
        )
        let applyAnimated = applyPlan.applyCategory == .olderAnchorReload ? false : animated
        self.activeHistoryBoundaryPlaceholder = nil

        self.mapAndApplyTimelinePreparedPage(
            preparedPage.preparedPage,
            mode: applyMode,
            animated: applyAnimated,
            invalidateLayout: false,
            applyCategory: applyPlan.applyCategory,
            anchorRestorePhase: applyPlan.restorePhase,
            anchorPrimary: anchor?.primary,
            restoreAnchor: anchor,
            completion: {
                self.endHistoryLoadingUI(unlockPage: false)
                self.timelineInteractionState.unlock()
            },
            cancelledCompletion: {
                self.endHistoryLoadingUI(unlockPage: false)
                self.timelineInteractionState.unlock()
            }
        )
    }

    @discardableResult
    internal func completeInteractiveHistoryPageLoadIfNeeded(
        queryId: String,
        state: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int,
        persistedRowsForQuery: Int = 0,
        visibleRowsForConversation: Int = 0
    ) -> Bool {
        guard var context = self.interactiveHistoryPageLoadContext,
              context.queryId == queryId else {
            return false
        }

        context.didReceiveEndPage = true
        context.queryExhausted = state.queryExhausted
        context.persistedMessageCount = max(
            state.persistedMessageCount,
            persistedRowsForQuery,
            visibleRowsForConversation
        )
        context.resultFirst = first
        context.resultLast = last
        context.resultCount = count
        context.persistedRowsForQuery = persistedRowsForQuery
        context.visibleRowsForConversation = visibleRowsForConversation
        context.isArchivePagePersisted = persistedRowsForQuery > 0 || visibleRowsForConversation > 0
        self.interactiveHistoryPageLoadContext = context
        if !self.tryFinishInteractiveHistoryPageLoadIfReady() {
            self.scheduleInteractiveHistoryCompletionRetry(queryId: queryId)
        }

        return true
    }

    @discardableResult
    internal func tryFinishInteractiveHistoryPageLoadIfReady() -> Bool {
        guard var context = self.interactiveHistoryPageLoadContext,
              context.didReceiveEndPage else {
            return false
        }

        let currentArchiveState = self.loadChatArchiveStateSnapshot()
        let currentCount = self.timelineSession?.snapshot.items.count ?? 0
        let currentOldestArchivedId = self.observedOldestArchivedId()
        let currentNewestArchivedId = self.observedNewestArchivedId()
        let didAdvance = ChatHistoryPageCompletionPolicy.didAdvance(
            direction: context.direction,
            previousObserverCount: context.preLoadObserverCount,
            currentObserverCount: currentCount,
            previousOldestArchivedId: context.preLoadOldestArchivedId,
            currentOldestArchivedId: currentOldestArchivedId,
            previousNewestArchivedId: context.preLoadNewestArchivedId,
            currentNewestArchivedId: currentNewestArchivedId,
            previousArchiveEnded: context.preLoadFullArchiveLoaded,
            currentArchiveEnded: currentArchiveState.fullArchiveLoaded,
            previousNewerLiveEdgeReached: context.preLoadNewerLiveEdgeReached,
            currentNewerLiveEdgeReached: currentArchiveState.newerLiveEdgeReached
        )
        let hasProviderVisibleRows = context.visibleRowsForConversation > 0
        // The typed final is delivered here only after its persistence barrier.
        // Treat that committed result as the proof instead of queue.sync polling.
        let isMessagePipelineIdle = context.didReceiveEndPage
        let requiresObserverSettle = (context.persistedMessageCount ?? 0) > 0
        let persistenceReady = isMessagePipelineIdle || context.isArchivePagePersisted

        if requiresObserverSettle,
           persistenceReady,
           !context.isArchivePagePersisted,
           !context.didEnterObserverSettlePhase {
            context.didEnterObserverSettlePhase = true
            self.interactiveHistoryPageLoadContext = context

            DispatchQueue.main.async {
                guard var settleContext = self.interactiveHistoryPageLoadContext,
                      settleContext.queryId == context.queryId else {
                    return
                }
                settleContext.didObservePostIdleTick = true
                self.interactiveHistoryPageLoadContext = settleContext
                _ = self.tryFinishInteractiveHistoryPageLoadIfReady()
            }
            return false
        }

        guard ChatHistoryPageCompletionPolicy.shouldFinish(
            didReceiveEndPage: context.didReceiveEndPage,
            didAdvance: didAdvance,
            persistedMessageCount: context.persistedMessageCount,
            isMessagePipelineIdle: isMessagePipelineIdle,
            isArchivePagePersisted: context.isArchivePagePersisted,
            requiresObserverSettle: requiresObserverSettle,
            didObservePostIdleTick: context.didObservePostIdleTick
        ) else {
            return false
        }

        if !hasProviderVisibleRows,
           context.resultCount > 0 {
            let eventName = context.persistedRowsForQuery > 0
                ? "nonVisiblePersistedRows"
                : "persistenceMissing"
            DDLogDebug(
                "ChatViewController.interactivePaging \(eventName) queryId=\(context.queryId) count=\(context.resultCount) persistedRowsForQuery=\(context.persistedRowsForQuery) visibleRows=\(context.visibleRowsForConversation) direction=\(context.direction)"
            )
        }

        let anchor = self.capturePagingAnchorIfNeeded(direction: context.direction)
        let applyPlan = ChatHistoryPageApplyPolicy.plan(
            direction: context.direction,
            hasCapturedAnchor: anchor != nil
        )
        let applyMode: ChatDatasourceApplyMode = .windowReload(
            keepOffset: applyPlan.keepOffset
        )
        let remoteApplyConversationKey = ChatTimelineConversationKey(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        self.cancelInteractiveHistoryCompletionRetry()
        self.interactiveHistoryPageLoadContext = nil
        self.remoteHistoryFinishingQueryId = context.queryId
        self.unregisterRemoteHistoryPersistenceSource(queryId: context.queryId)
        self.rebuildUnreadMentionItems()

        self.mapAndApplyFinishedVirtualTimelineRemoteLoad(
            queryId: context.queryId,
            performanceTraceContext: context.performanceTraceContext,
            archiveState: currentArchiveState,
            refetchDirection: context.direction,
            refetchLimit:
                ChatInteractiveRemoteHistoryRefetchLimitPolicy.limit(
                    coverageUpdateKind: context.coverageUpdateKind,
                    visibleRowsForConversation:
                        context.visibleRowsForConversation
                ),
            visibleRows: context.visibleRowsForConversation,
            resultCount: context.resultCount,
            queryExhausted: context.queryExhausted,
            mode: applyMode,
            animated: false,
            applyCategory: applyPlan.applyCategory,
            anchorRestorePhase: applyPlan.restorePhase,
            anchorPrimary: anchor?.primary,
            restoreAnchor: anchor,
            completion: { applyResult in
                self.commitRemoteHistoryArchiveStateAfterApply(
                    context: context,
                    applyResult: applyResult,
                    baseArchiveState: currentArchiveState
                )

                if !applyResult.didAdvance,
                   context.resultCount > 0 {
                    DDLogDebug(
                        "ChatViewController.remoteHistoryApplyNoAdvance queryId=\(context.queryId) direction=\(context.direction) persistedRowsForQuery=\(context.persistedRowsForQuery) visibleRows=\(context.visibleRowsForConversation) count=\(context.resultCount) oldOldest=\(applyResult.previousOldestArchivedId ?? "-") newOldest=\(applyResult.newOldestArchivedId ?? "-") oldNewest=\(applyResult.previousNewestArchivedId ?? "-") newNewest=\(applyResult.newNewestArchivedId ?? "-")"
                    )
                }

                self.endHistoryLoadingUI(unlockPage: false)
                self.timelineInteractionState.unlock()
                self.remoteHistoryFinishingQueryId = nil
                self.remoteHistoryQueryCoordinator.remove(queryId: context.queryId)
                DDLogDebug(
                    "ChatViewController.remoteHistoryApplySuccess queryId=\(context.queryId) direction=\(context.direction) didAdvance=\(applyResult.didAdvance) persistedRowsForQuery=\(context.persistedRowsForQuery) visibleRows=\(context.visibleRowsForConversation) persisted=\(context.persistedMessageCount ?? 0) items=\(applyResult.itemCount) oldOldest=\(applyResult.previousOldestArchivedId ?? "-") newOldest=\(applyResult.newOldestArchivedId ?? "-") oldNewest=\(applyResult.previousNewestArchivedId ?? "-") newNewest=\(applyResult.newNewestArchivedId ?? "-") queueWaitMs=\(applyResult.queueWaitMs) mapMs=\(applyResult.mapDurationMs)"
                )
            },
            cancelledCompletion: {
                self.clearFinishedRemoteLoadRuntimeStateIfNeeded(
                    queryId: context.queryId,
                    conversationKey: remoteApplyConversationKey
                )
                self.remoteHistoryFinishingQueryId = nil
                self.remoteHistoryQueryCoordinator.remove(queryId: context.queryId)
                self.endHistoryLoadingUI(unlockPage: false)
                self.timelineInteractionState.unlock()
            }
        )

        return true
    }

    internal func mapAndApplyWindow(
        _ window: ChatDatasetWindow,
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        let mappingJob = self.beginDatasetMappingJob()
        let generation = mappingJob.generation
        let cancellationToken = mappingJob.token
        let boundaryPlaceholder = self.activeHistoryBoundaryPlaceholder
        let currentWindow = self.visibleWindow()
        let timelineSnapshot = self.timelineSession?.snapshot
        let mappingContext = self.captureDatasourceMappingContext()

        self.datasetMappingQueue.async { [weak self] in
            guard let self, !cancellationToken.isCancelled else {
                DispatchQueue.main.async { cancelledCompletion?() }
                return
            }
            let mappedWindow = self.messageWindowSliceForMapping(
                window,
                currentWindow: currentWindow,
                activePlaceholder: boundaryPlaceholder,
                timelineSnapshot: timelineSnapshot
            )
            let normalizedWindow = mappedWindow.window
            let slice = mappedWindow.items
            let mappingResult = self.mapDataset(
                dataset: slice,
                context: mappingContext,
                cancellationToken: cancellationToken
            )

            DispatchQueue.main.async {
                guard !mappingResult.wasCancelled,
                      !cancellationToken.isCancelled,
                      ChatDatasourceApplyGenerationPolicy.shouldApply(
                    requestGeneration: generation,
                    currentGeneration: self.datasetMappingGeneration
                ) else {
                    cancelledCompletion?()
                    return
                }
                var mappedDatasource = mappingResult.datasource
                if let boundaryPlaceholder {
                    mappedDatasource = self.datasourceByAddingHistoryBoundaryPlaceholder(
                        to: mappedDatasource,
                        position: boundaryPlaceholder
                    )
                }
                self.syncCurrentPage(with: normalizedWindow)
                self.invalidateEditedMessageLayoutCache(
                    primaries: mappingResult.editedMessagePrimariesNeedingLayoutInvalidation
                )
                self.applyChatDatasource(
                    mappedDatasource,
                    mode: mode,
                    animated: animated,
                    invalidateLayout: invalidateLayout,
                    preparedLayouts: mappingResult.layoutSnapshot,
                    completion: completion
                )
            }
        }
    }

    internal func mapAndApplyTimelineAnchor(
        _ anchor: ChatTimelineAnchor,
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        centerTargetInViewport: Bool = false,
        shouldApply: (() -> Bool)? = nil,
        transactionCompletion: ((ChatViewportTransactionResult) -> Void)? = nil,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        guard let session = self.timelineSession else {
            cancelledCompletion?()
            return
        }
        let mappingJob = self.beginDatasetMappingJob()
        let generation = mappingJob.generation
        let cancellationToken = mappingJob.token
        let boundaryPlaceholder = self.activeHistoryBoundaryPlaceholder
        let archiveState = self.loadChatArchiveStateSnapshot()
        let mappingContext = self.captureDatasourceMappingContext()

        self.datasetMappingQueue.async { [weak self] in
            guard let self, !cancellationToken.isCancelled else {
                DispatchQueue.main.async { cancelledCompletion?() }
                return
            }
            session.updateArchiveState(archiveState)
            var snapshot = session.openAround(anchor: anchor)
            if let boundaryPlaceholder {
                snapshot = session.applyRuntimePlaceholder(boundaryPlaceholder)
            }
            let mappingResult = self.mapDataset(
                dataset: snapshot.items,
                context: mappingContext,
                cancellationToken: cancellationToken
            )

            DispatchQueue.main.async {
                guard !mappingResult.wasCancelled,
                      !cancellationToken.isCancelled,
                      ChatDatasourceApplyGenerationPolicy.shouldApply(
                    requestGeneration: generation,
                    currentGeneration: self.datasetMappingGeneration
                ),
                      shouldApply?() != false else {
                    cancelledCompletion?()
                    return
                }

                var mappedDatasource = mappingResult.datasource
                if let boundaryPlaceholder {
                    mappedDatasource = self.datasourceByAddingHistoryBoundaryPlaceholder(
                        to: mappedDatasource,
                        position: boundaryPlaceholder
                    )
                }
                let committedSnapshot = session.commitPresentationSnapshot(snapshot)
                self.syncCurrentPage(
                    with: ChatDatasetWindow(minIndex: 0, maxIndex: committedSnapshot.items.count)
                )
                self.invalidateEditedMessageLayoutCache(
                    primaries: mappingResult.editedMessagePrimariesNeedingLayoutInvalidation
                )
                let targetHeight = anchor.primary.flatMap {
                    mappingResult.layoutSnapshot.layout(forPrimary: $0)?.cellSize.height
                } ?? 0
                let centeredAnchor = centerTargetInViewport
                    ? anchor.primary.map { targetPrimary in
                        ChatHistoryPageAnchor(
                        primary: targetPrimary,
                        viewportRelativeMinY: ChatAnchorCenteringPolicy.viewportRelativeMinY(
                            viewportHeight: self.messagesCollectionView.bounds.height,
                            targetHeight: targetHeight
                        )
                    )
                    }
                    : nil
                self.applyChatDatasource(
                    mappedDatasource,
                    mode: mode,
                    animated: animated,
                    invalidateLayout: invalidateLayout,
                    preparedLayouts: mappingResult.layoutSnapshot,
                    suppressDefaultBottomScroll: centerTargetInViewport,
                    anchorRestorePhase: centeredAnchor == nil ? .none : .applyTransaction,
                    anchorPrimary: centeredAnchor?.primary,
                    restoreAnchor: centeredAnchor,
                    transactionCompletion: transactionCompletion,
                    completion: completion
                )
            }
        }
    }

    internal func mapAndApplyTimelineLatest(
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        limit: Int? = nil,
        suppressDefaultBottomScroll: Bool = false,
        forceBottomAlignmentTarget: ChatBottomAlignmentTarget? = nil,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        guard let session = self.timelineSession else {
            cancelledCompletion?()
            return
        }
        let mappingJob = self.beginDatasetMappingJob()
        let generation = mappingJob.generation
        let cancellationToken = mappingJob.token
        let archiveState = self.loadChatArchiveStateSnapshot()
        let mappingContext = self.captureDatasourceMappingContext()

        self.datasetMappingQueue.async { [weak self] in
            guard let self, !cancellationToken.isCancelled else {
                DispatchQueue.main.async { cancelledCompletion?() }
                return
            }
            session.updateArchiveState(archiveState)
            let snapshot = session.scrollToLatest(limit: limit)
            let mappingResult = self.mapDataset(
                dataset: snapshot.items,
                context: mappingContext,
                cancellationToken: cancellationToken
            )

            DispatchQueue.main.async {
                guard !mappingResult.wasCancelled,
                      !cancellationToken.isCancelled,
                      ChatDatasourceApplyGenerationPolicy.shouldApply(
                    requestGeneration: generation,
                    currentGeneration: self.datasetMappingGeneration
                ) else {
                    cancelledCompletion?()
                    return
                }

                let mappedDatasource = mappingResult.datasource
                self.activeHistoryBoundaryPlaceholder = nil
                self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: snapshot.items.count))
                self.invalidateEditedMessageLayoutCache(
                    primaries: mappingResult.editedMessagePrimariesNeedingLayoutInvalidation
                )
                self.applyChatDatasource(
                    mappedDatasource,
                    mode: mode,
                    animated: animated,
                    invalidateLayout: invalidateLayout,
                    preparedLayouts: mappingResult.layoutSnapshot,
                    suppressDefaultBottomScroll: suppressDefaultBottomScroll,
                    forceBottomAlignmentTarget: forceBottomAlignmentTarget,
                    completion: completion
                )
            }
        }
    }

    internal func mapAndApplyTimelineCurrent(
        mode: ChatDatasourceApplyMode,
        isObserverCurrentRoute: Bool = false,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        preserveBoundaryPlaceholder: Bool = true,
        suppressDefaultBottomScroll: Bool = false,
        applyCategory: ChatDatasourceApplyCategory = .default,
        anchorRestorePhase: ChatHistoryPageAnchorRestorePhase = .none,
        anchorPrimary: String? = nil,
        restoreAnchor: ChatHistoryPageAnchor? = nil,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        guard let session = self.timelineSession else {
            cancelledCompletion?()
            return
        }
        let mappingJob = self.beginDatasetMappingJob()
        let generation = mappingJob.generation
        let cancellationToken = mappingJob.token
        let boundaryPlaceholder = preserveBoundaryPlaceholder ? self.activeHistoryBoundaryPlaceholder : nil
        let mappingContext = self.captureDatasourceMappingContext()

        self.datasetMappingQueue.async { [weak self] in
            guard let self, !cancellationToken.isCancelled else {
                DispatchQueue.main.async { cancelledCompletion?() }
                return
            }
            let snapshot = boundaryPlaceholder.map {
                session.applyRuntimePlaceholder($0)
            } ?? session.snapshot
            let mappingResult = self.mapDataset(
                dataset: snapshot.items,
                context: mappingContext,
                cancellationToken: cancellationToken
            )

            DispatchQueue.main.async {
                guard !mappingResult.wasCancelled,
                      !cancellationToken.isCancelled,
                      ChatDatasourceApplyGenerationPolicy.shouldApply(
                    requestGeneration: generation,
                    currentGeneration: self.datasetMappingGeneration
                ) else {
                    cancelledCompletion?()
                    return
                }

                var mappedDatasource = mappingResult.datasource
                if let boundaryPlaceholder {
                    mappedDatasource = self.datasourceByAddingHistoryBoundaryPlaceholder(
                        to: mappedDatasource,
                        position: boundaryPlaceholder
                    )
                }
                let isTargetedDiff: Bool
                if case .targetedDiff = mode {
                    isTargetedDiff = true
                } else {
                    isTargetedDiff = false
                }
                let mappedDatasourceSnapshot =
                    ChatDatasourceCoordinator.makeSnapshot(
                        items: mappedDatasource
                    )
                let currentLayoutSnapshot =
                    (self.messagesCollectionView.collectionViewLayout as?
                        MessagesCollectionViewFlowLayout)?
                        .cache.reuseSnapshot() ?? .empty
                let modelOnlyDecision =
                    ChatObserverModelOnlyAssimilationPolicy.decision(
                        current: self.datasourceSnapshot,
                        mapped: mappedDatasourceSnapshot,
                        currentLayout: {
                            currentLayoutSnapshot.layout(forPrimary: $0)
                        },
                        mappedLayout: {
                            mappingResult.layoutSnapshot
                                .layout(forPrimary: $0)
                        },
                        route: ChatObserverModelOnlyAssimilationRoute(
                            isObserverCurrentRoute:
                                isObserverCurrentRoute,
                            isTargetedDiff: isTargetedDiff,
                            invalidatesLayout: invalidateLayout,
                            hasBoundaryPlaceholder:
                                boundaryPlaceholder != nil ||
                                self.activeHistoryBoundaryPlaceholder != nil,
                            usesDefaultApplyCategory:
                                applyCategory == .default,
                            hasPendingOutgoingAutoScroll:
                                self.pendingOutgoingAutoScrollRequest != nil,
                            hasExplicitSearchOrAnchorMutation:
                                anchorRestorePhase != .none ||
                                anchorPrimary != nil ||
                                restoreAnchor != nil ||
                                self.hasActiveSearchNavigationTransaction
                        )
                    )
#if DEBUG || CHAT_PERFORMANCE_LAB
                self.observerModelOnlyAssimilationDecisionObserverForTests?(
                    modelOnlyDecision,
                    ChatObserverModelOnlyAssimilationPolicy
                        .rejectionReasonForTesting(
                            current: self.datasourceSnapshot,
                            mapped: mappedDatasourceSnapshot,
                            currentLayout: {
                                currentLayoutSnapshot.layout(forPrimary: $0)
                            },
                            mappedLayout: {
                                mappingResult.layoutSnapshot
                                    .layout(forPrimary: $0)
                            },
                            route: ChatObserverModelOnlyAssimilationRoute(
                                isObserverCurrentRoute:
                                    isObserverCurrentRoute,
                                isTargetedDiff: isTargetedDiff,
                                invalidatesLayout: invalidateLayout,
                                hasBoundaryPlaceholder:
                                    boundaryPlaceholder != nil ||
                                    self.activeHistoryBoundaryPlaceholder != nil,
                                usesDefaultApplyCategory:
                                    applyCategory == .default,
                                hasPendingOutgoingAutoScroll:
                                    self.pendingOutgoingAutoScrollRequest != nil,
                                hasExplicitSearchOrAnchorMutation:
                                    anchorRestorePhase != .none ||
                                    anchorPrimary != nil ||
                                    restoreAnchor != nil ||
                                    self.hasActiveSearchNavigationTransaction
                            ),
                            decision: modelOnlyDecision
                        )
                )
#endif
                switch modelOnlyDecision {
                case .exactNoOp:
                    self.reconcileUnreadMentionPresentationMetadataIfNeeded(
                        snapshot.unreadMetadata,
                        animated: false
                    )
                    completion?()
                    return
                case .incomingReadOnly:
                    self.datasourceSnapshot = mappedDatasourceSnapshot
                    self.datasource = mappedDatasource
                    self.reconcileUnreadMentionPresentationMetadataIfNeeded(
                        snapshot.unreadMetadata,
                        animated: false
                    )
                    completion?()
                    return
                case .requiresUIKitApply:
                    self.rebuildUnreadMentionItems()
                    break
                }
                self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: snapshot.items.count))
                self.invalidateEditedMessageLayoutCache(
                    primaries: mappingResult.editedMessagePrimariesNeedingLayoutInvalidation
                )
                self.applyChatDatasource(
                    mappedDatasource,
                    mode: mode,
                    animated: animated,
                    invalidateLayout: invalidateLayout,
                    preparedLayouts: mappingResult.layoutSnapshot,
                    suppressDefaultBottomScroll: suppressDefaultBottomScroll,
                    applyCategory: applyCategory,
                    anchorRestorePhase: anchorRestorePhase,
                    anchorPrimary: anchorPrimary,
                    restoreAnchor: restoreAnchor,
                    completion: completion
                )
            }
        }
    }

    internal func mapAndApplyTimelineSnapshot(
        _ snapshot: ChatTimelineSnapshot,
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        suppressDefaultBottomScroll: Bool = false,
        applyCategory: ChatDatasourceApplyCategory = .default,
        anchorRestorePhase: ChatHistoryPageAnchorRestorePhase = .none,
        anchorPrimary: String? = nil,
        restoreAnchor: ChatHistoryPageAnchor? = nil,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        guard let session = self.timelineSession else {
            cancelledCompletion?()
            return
        }
        let mappingJob = self.beginDatasetMappingJob()
        let generation = mappingJob.generation
        let cancellationToken = mappingJob.token
        let committedSnapshot = session.commit(snapshot)
        let frozenItems = committedSnapshot.items
        let mappingContext = self.captureDatasourceMappingContext()

        self.datasetMappingQueue.async { [weak self] in
            guard let self, !cancellationToken.isCancelled else {
                DispatchQueue.main.async { cancelledCompletion?() }
                return
            }
            let mappingResult = self.mapDataset(
                dataset: frozenItems,
                context: mappingContext,
                cancellationToken: cancellationToken
            )
            DispatchQueue.main.async {
                guard !mappingResult.wasCancelled,
                      !cancellationToken.isCancelled,
                      ChatDatasourceApplyGenerationPolicy.shouldApply(
                    requestGeneration: generation,
                    currentGeneration: self.datasetMappingGeneration
                ) else {
                    cancelledCompletion?()
                    return
                }

                let mappedDatasource = mappingResult.datasource
                self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: frozenItems.count))
                self.invalidateEditedMessageLayoutCache(
                    primaries: mappingResult.editedMessagePrimariesNeedingLayoutInvalidation
                )
                self.applyChatDatasource(
                    mappedDatasource,
                    mode: mode,
                    animated: animated,
                    invalidateLayout: invalidateLayout,
                    preparedLayouts: mappingResult.layoutSnapshot,
                    suppressDefaultBottomScroll: suppressDefaultBottomScroll,
                    applyCategory: applyCategory,
                    anchorRestorePhase: anchorRestorePhase,
                    anchorPrimary: anchorPrimary,
                    restoreAnchor: restoreAnchor,
                    completion: completion
                )
            }
        }
    }

    internal func mapAndApplyTimelinePreparedPage(
        _ preparedPage: ChatTimelinePreparedLocalPage,
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        suppressDefaultBottomScroll: Bool = false,
        applyCategory: ChatDatasourceApplyCategory = .default,
        anchorRestorePhase: ChatHistoryPageAnchorRestorePhase = .none,
        anchorPrimary: String? = nil,
        restoreAnchor: ChatHistoryPageAnchor? = nil,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        guard let session = self.timelineSession,
              let committedSnapshot = session.commitPreparedLocalPage(preparedPage) else {
            cancelledCompletion?()
            return
        }
        let mappingJob = self.beginDatasetMappingJob()
        let generation = mappingJob.generation
        let cancellationToken = mappingJob.token
        let frozenItems = committedSnapshot.items
        let mappingContext = self.captureDatasourceMappingContext()

        self.datasetMappingQueue.async { [weak self] in
            guard let self, !cancellationToken.isCancelled else {
                DispatchQueue.main.async { cancelledCompletion?() }
                return
            }
            let mappingResult = self.mapDataset(
                dataset: frozenItems,
                context: mappingContext,
                cancellationToken: cancellationToken
            )
            DispatchQueue.main.async {
                guard !mappingResult.wasCancelled,
                      !cancellationToken.isCancelled,
                      ChatDatasourceApplyGenerationPolicy.shouldApply(
                    requestGeneration: generation,
                    currentGeneration: self.datasetMappingGeneration
                ) else {
                    cancelledCompletion?()
                    return
                }

                self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: frozenItems.count))
                self.invalidateEditedMessageLayoutCache(
                    primaries: mappingResult.editedMessagePrimariesNeedingLayoutInvalidation
                )
                self.applyChatDatasource(
                    mappingResult.datasource,
                    mode: mode,
                    animated: animated,
                    invalidateLayout: invalidateLayout,
                    preparedLayouts: mappingResult.layoutSnapshot,
                    suppressDefaultBottomScroll: suppressDefaultBottomScroll,
                    applyCategory: applyCategory,
                    anchorRestorePhase: anchorRestorePhase,
                    anchorPrimary: anchorPrimary,
                    restoreAnchor: restoreAnchor,
                    completion: completion
                )
            }
        }
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

    internal func datasourceByAddingHistoryBoundaryPlaceholder(
        to datasource: [Datasource],
        position: ChatHistoryBoundaryPlaceholderPosition
    ) -> [Datasource] {
        _ = position
        return datasource
    }

    internal func showHistoryBoundaryPlaceholder(
        direction: ChatHistoryPageDirection,
        currentWindow: ChatDatasetWindow
    ) {
        _ = currentWindow
        self.activeHistoryBoundaryPlaceholder = direction == .older ? .top : .bottom
    }

    internal var hasCommittedBootstrapSkeletonRows: Bool {
        self.hasCommittedBootstrapSkeletonPresentationInCurrentLifecycle &&
        ChatBootstrapSkeletonDatasourceIdentity.matches(
            self.datasource,
            owner: self.owner,
            jid: self.jid
        )
    }

    internal var hasCommittedExactBootstrapSkeletonRows: Bool {
        guard self.hasCommittedBootstrapSkeletonRows,
              self.datasource.count == ChatSkeletonTemplate.descriptors.count else {
            return false
        }
        return zip(self.datasource, ChatSkeletonTemplate.descriptors).allSatisfy { pair in
            let (item, descriptor) = pair
            return item.primary == descriptor.primary &&
            item.messageId == descriptor.messageId &&
            item.sentDate == descriptor.sentDate
        }
    }

    internal var isShowingBootstrapPlaceholder: Bool {
        self.hasCommittedBootstrapSkeletonRows
    }

    internal var shouldAnimateInitialHistoryAppearance: Bool {
        ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
            requestedAnimated: ChatInitialHistoryAppearancePolicy.shouldAnimateDatasourceApply(
                isInitialHistoryAppearancePending: self.initialHistoryAppearancePending
            ),
            isTransitionActive: self.isNavigationTransitionActive,
            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
        )
    }

    internal func handleChatDatasourceAuxiliaryRefreshAfterApply(
        containsRealMessages: Bool,
        containsOnlyFakeMessages: Bool
    ) {
        switch ChatFirstFrameAuxiliaryWorkPolicy.datasourceApplyDecision(
            isInitialHistoryAppearancePending: self.initialHistoryAppearancePending,
            containsRealMessages: containsRealMessages,
            containsOnlyFakeMessages: containsOnlyFakeMessages
        ) {
        case .runImmediately:
            self.performChatDatasourceAuxiliaryRefresh()
        case .skipInitialCommit:
            break
        }
    }

    internal func performChatDatasourceAuxiliaryRefresh() {
        self.refreshUnreadMentionsNavigatorState()
        self.updateVisibleVoiceMessageQueue()
    }

    internal func finishInitialHistoryAppearanceIfPossible() {
        guard self.initialHistoryAppearancePending,
              ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                hasViewAppeared: self.hasCompletedInitialHistoryViewAppearance,
                hasRenderedStableHistory: self.hasRenderedStableInitialHistory
              ) else { return }

        DispatchQueue.main.async {
            guard self.initialHistoryAppearancePending,
                  ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                    hasViewAppeared: self.hasCompletedInitialHistoryViewAppearance,
                    hasRenderedStableHistory: self.hasRenderedStableInitialHistory
                  ) else { return }

            self.initialHistoryAppearancePending = false
            self.hasRenderedStableInitialHistory = false
        }
    }

    internal func bootstrapLoadingState(chatInstance: LastChatsStorageItem?) -> ChatBootstrapLoadingState {
        let readinessProof = self.currentInitialFrameReadinessProof()
        let localMessageCount = self.localHistoryMessageCountForBootstrap()
        let standardState = ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: localMessageCount,
            isSynced: readinessProof?.isSynced ?? chatInstance?.isSynced ?? false,
            isInitialArchiveLoaded:
                readinessProof?.isInitialArchiveLoaded ??
                chatInstance?.isInitialArchiveLoaded ?? false,
            isInitialBootstrapInFlight: self.isInitialBootstrapInFlight,
            hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest(chatInstance: chatInstance),
            allowsStaleLocalHistory: self.allowsStaleLocalHistoryDuringInitialBootstrap,
            hasTerminalFailure: self.allowsBootstrapFailureFallback,
            archiveReadiness: self.archiveReadinessForBootstrap(
                localMessageCount: localMessageCount,
                chatInstance: chatInstance
            )
        ))
        return ChatInitialPresentationContextPolicy.loadingState(
            standard: standardState,
            context: self.effectiveInitialPresentationContext,
            localMessageCount: localMessageCount
        )
    }

    internal func bootstrapViewState(chatInstance: LastChatsStorageItem?) -> ChatBootstrapViewState {
        bootstrapLoadingState(chatInstance: chatInstance).viewState
    }

    internal func currentBootstrapLoadingState() -> ChatBootstrapLoadingState {
        bootstrapLoadingState(chatInstance: nil)
    }

    internal func currentBootstrapViewState() -> ChatBootstrapViewState {
        currentBootstrapLoadingState().viewState
    }

    internal func hasPendingInitialAnchorRequest(chatInstance: LastChatsStorageItem? = nil) -> Bool {
        if let executionState = self.activeAnchorExecutionState,
           executionState.request.owner == self.owner,
           executionState.request.chatJid == self.jid,
           executionState.request.conversationType == self.conversationType,
           executionState.usesBootstrapLoading,
           !executionState.isPositioning {
            return self.shouldBlockBootstrapForInitialAnchorRequest(
                executionState.request,
                chatInstance: chatInstance
            )
        }

        guard self.isShowingBootstrapPlaceholder,
              let request = self.pendingOpenMessageRequest,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType else {
            return false
        }

        return self.shouldBlockBootstrapForInitialAnchorRequest(
            request,
            chatInstance: chatInstance
        )
    }

    private func shouldBlockBootstrapForInitialAnchorRequest(
        _ request: ChatOpenMessageRequest,
        chatInstance: LastChatsStorageItem?
    ) -> Bool {
        let hasStructurallySafeLocalAnchor = ChatInitialAnchorBootstrapPolicy.needsLocalAnchorLookup(source: request.source)
            ? self.hasLocalAnchorForBootstrap(request)
            : false
        // Saved-position target/window authority exists only in a prepared
        // typed frame. While its request is pending, keep the bootstrap
        // presentation blocked without re-resolving the target synchronously.
        let hasEligibleLocalAnchor = request.source == .savedVisiblePosition
            ? hasStructurallySafeLocalAnchor &&
                self.hasPreparedDurableSavedPositionFirstFrameEligibility(
                    request: request
                )
            : hasStructurallySafeLocalAnchor

        if request.source == .savedVisiblePosition,
           self.isShowingBootstrapPlaceholder,
           !hasEligibleLocalAnchor {
            return true
        }

        return ChatInitialAnchorBootstrapPolicy.shouldBlockBootstrap(
            source: request.source,
            isSynced: chatInstance?.isSynced ?? self.currentChatIsSyncedForBootstrap(),
            messageCount: self.localHistoryMessageCountForBootstrap(),
            hasLocalAnchor: hasEligibleLocalAnchor,
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
        )
    }

    private func currentChatIsSyncedForBootstrap() -> Bool {
        self.currentInitialFrameReadinessProof()?.isSynced ?? false
    }

    internal func currentBootstrapRequiresArchiveConfirmation() -> Bool {
        if let request = self.pendingOpenMessageRequest,
           request.owner == self.owner,
           request.chatJid == self.jid,
           request.conversationType == self.conversationType,
           request.source == .savedVisiblePosition {
            // A saved frame stays provisional until its already-prepared IDs
            // pass the durable coverage gate and commit. This helper must not
            // rematerialize that window merely to answer loading state.
            return !self.hasPreparedDurableSavedPositionFirstFrameEligibility(
                request: request
            )
        }
        return !self.hasDurableArchiveReadinessForBootstrap(
            localMessageCount: self.localHistoryMessageCountForBootstrap(),
            chatInstance: nil
        )
    }

    internal func archiveReadinessForBootstrap(
        localMessageCount: Int,
        chatInstance: LastChatsStorageItem?
    ) -> ConversationArchiveReadiness? {
        let hasDurableReadiness = self.hasDurableArchiveReadinessForBootstrap(
            localMessageCount: localMessageCount,
            chatInstance: chatInstance
        )
        let blockingReadiness = ConversationArchiveReadiness(
            phase: .queued,
            hasDurableCoverage: false,
            confirmsEmptyConversation: false,
            persistedVisibleRowCount: 0
        )

        if let readiness = ChatInitialBootstrapRequestCoordinator.shared.readiness(
            for: self.initialBootstrapRequestKey
        ) {
            if readiness.phase == .committed,
               !self.committedArchiveReceiptMatchesCurrentBoundary(readiness) {
                // A committed receipt belongs to the snapshot it proved. Do
                // not let legacy readiness flags publish an empty timeline
                // while a newer Realm boundary awaits another transaction.
                // Existing local rows may remain visible; zero rows reduce to
                // blocking skeleton until requestInitialBootstrapArchive
                // invalidates this receipt and acquires fresh work.
                return blockingReadiness
            }
            switch readiness.phase {
            case .queued, .transport, .persistence:
                // A lease for a different/legacy proof must dominate stale
                // flags. A genuinely current local page may remain visible
                // while orthogonal target work is active.
                return hasDurableReadiness ? nil : readiness
            case .committed:
                // A durable committed transaction is itself the archive
                // proof for the exact current boundary. An empty conversation
                // cannot produce a local timeline frame, so requiring a frame
                // proof here would turn authoritative count=0 back into a
                // skeleton and schedule another bootstrap pass.
                if readiness.hasDurableCoverage {
                    return readiness
                }
                return hasDurableReadiness ? readiness : blockingReadiness
            case .failed:
                return readiness
            }
        }

        guard !self.allowsBootstrapFailureFallback,
              !hasDurableReadiness else {
            return nil
        }

        // Model missing durable proof as queued until the account-scoped
        // coordinator acquires or joins the required transaction.
        return blockingReadiness
    }

    private func hasDurableArchiveReadinessForBootstrap(
        localMessageCount: Int,
        chatInstance: LastChatsStorageItem?
    ) -> Bool {
        guard let proof = self.currentInitialFrameReadinessProof(),
              proof.materializedLocalMessageCount >= max(0, localMessageCount) else {
            return false
        }
        return proof.hasDurableArchiveReadiness
    }

    internal func committedArchiveReceiptMatchesCurrentBoundary(
        _ readiness: ConversationArchiveReadiness
    ) -> Bool {
        guard readiness.phase == .committed,
              let committedFingerprint = readiness.boundaryFingerprint else {
            // Non-snapshot conversation types and legacy/unit sources do not
            // carry a fingerprint; their durable readiness remains reusable.
            return true
        }
        if let sessionFingerprint = self.currentInitialFrameReadinessProof()?
            .archiveBoundaryFingerprint {
            return sessionFingerprint == committedFingerprint
        }
        // A fresh zero-row timeline has no local frame from which to publish a
        // readiness proof. Compare the transaction fingerprint with the
        // current boundary rows directly so absence of a frame is not treated
        // as a newer snapshot. This fallback reads boundary identity only; it
        // never reinterprets legacy readiness flags.
        return MessageArchiveManager.currentConversationArchiveBoundaryFingerprint(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        ) == committedFingerprint
    }

    internal func shouldInvalidateCommittedArchiveReceipt(
        _ readiness: ConversationArchiveReadiness,
        requiresArchiveConfirmation: Bool
    ) -> Bool {
        requiresArchiveConfirmation &&
            readiness.phase == .committed &&
            !self.committedArchiveReceiptMatchesCurrentBoundary(readiness)
    }

    private func currentSnapshotBoundaryRequiresBootstrapFollowUp() -> Bool {
        guard self.conversationType.supportsSnapshotArchiveRepair else {
            return false
        }

        guard let proof = self.currentInitialFrameReadinessProof() else {
            return false
        }
        return !proof.isSynced && proof.hasKnownRemoteArchiveBoundary
    }

    private func currentBootstrapCommitRequiresBoundaryFollowUp() -> Bool {
        let readiness = ChatInitialBootstrapRequestCoordinator.shared.readiness(
            for: self.initialBootstrapRequestKey
        )
        return ChatInitialBootstrapBoundaryFollowUpPolicy.requiresFollowUp(
            readiness: readiness,
            committedBoundaryMatchesCurrent:
                readiness.map(self.committedArchiveReceiptMatchesCurrentBoundary) ?? true,
            currentSnapshotRequiresFollowUp:
                self.currentSnapshotBoundaryRequiresBootstrapFollowUp()
        )
    }

    @discardableResult
    internal func reloadInitialWindowAfterBootstrapIfNeeded(
        force: Bool = false,
        hasTrustedPersistedBootstrapPage: Bool = false,
        completion: (() -> Void)? = nil
    ) -> Bool {
        guard ChatBootstrapContentRenderPolicy.shouldReloadInitialWindow(
            forceRender: force,
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder,
            isDatasourceEmpty: self.datasource.isEmpty,
            hasCommittedRealContent: self.hasCommittedRealContentInCurrentLifecycle
        ) else { return false }

        return self.prepareInitialLocalFirstFrame(
            chatInstance: nil,
            performPendingOpenMessageRequest: false,
            hasTrustedPersistedBootstrapPage: hasTrustedPersistedBootstrapPage,
            completion: completion
        )
    }

    @discardableResult
    internal func prepareInitialLocalFirstFrame(
        chatInstance: LastChatsStorageItem?,
        performPendingOpenMessageRequest: Bool,
        hasTrustedPersistedBootstrapPage: Bool = false,
        completion: (() -> Void)? = nil
    ) -> Bool {
        guard !self.isStackedNavigationPresentationPreparationCancelled else {
            return false
        }
        guard let session = self.timelineSession else {
            if let completion {
                self.initialLocalFirstFrameCompletions.append(completion)
            }
            self.initialLocalFirstFrameShouldPerformPendingRequest =
                self.initialLocalFirstFrameShouldPerformPendingRequest || performPendingOpenMessageRequest
            if self.appliedBootstrapLoadingState?.showsRetry == true {
                // Retry is already a deterministic terminal first frame.
                // Session installation may continue independently, but it
                // must not regress the visible failure state to skeleton.
                self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
                return false
            }
            self.acquireInteractiveChatOpenGateIfNeeded()
            self.applyBootstrapViewState(
                .skeleton,
                forceRender: true,
                synchronousSkeletonCommit: self.isPreparingStackedNavigationPresentation
            )
            self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
            return false
        }

        if let completion {
            self.initialLocalFirstFrameCompletions.append(completion)
        }
        self.initialLocalFirstFrameShouldPerformPendingRequest =
            self.initialLocalFirstFrameShouldPerformPendingRequest || performPendingOpenMessageRequest

        if ChatInitialSessionObservationTransferPolicy.shouldQuiesce(
            isFreshPresentationLifecycle:
                self.initialLocalFirstFramePhase == .idle,
            hasCommittedInitialContent:
                self.initialFirstContentApplyCount > 0
        ) {
            session.deactivateStoreObservation()
        }

        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: self.pendingOpenMessageRequest,
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        let hasEligibleLocalAnchorRequest = self.hasEligibleLocalAnchorFirstFrame(
            descriptor: descriptor
        )
        let hasSavedPositionRequest =
            descriptor.request?.source == .savedVisiblePosition
        let shouldPrepareSavedPositionProbe: Bool = {
            guard hasSavedPositionRequest,
                  !hasEligibleLocalAnchorRequest,
                  let request = descriptor.request else {
                return false
            }
            let priorDecision = self.savedPositionFirstFrameProbedDecision(
                for: request
            )
            let resumesPersistedGapRepair: Bool = {
                guard hasTrustedPersistedBootstrapPage,
                      case .blockingRepair = priorDecision else {
                    return false
                }
                return true
            }()
            guard self.hasLocalAnchorForBootstrap(request) ||
                    resumesPersistedGapRepair else {
                return false
            }
            // One bounded preparation is still required to derive N11's
            // target-window gap repair. It may publish no rows until the
            // separate durable-window proof succeeds below. A persisted gap
            // terminal must also resample the immutable readiness snapshot;
            // the prior blocking probe proves the local target identity even
            // though hasLocalAnchorForBootstrap intentionally rejects its
            // unsafe window.
            return hasTrustedPersistedBootstrapPage ||
                priorDecision == nil
        }()
        let initialLoadingState = self.bootstrapLoadingState(
            chatInstance: chatInstance
        )
        let allowsInitialMaterializationProbe =
            ChatInitialMaterializationProbeAdmissionPolicy.allows(
                isFreshPresentationLifecycle:
                    self.initialLocalFirstFramePhase == .idle,
                hasCurrentReadinessProof:
                    self.currentInitialFrameReadinessProof() != nil
            )
        let availability: ChatLocalFirstFrameAvailabilityDecision =
            hasSavedPositionRequest &&
                !hasEligibleLocalAnchorRequest &&
                !shouldPrepareSavedPositionProbe
                ? .blockForArchiveBootstrap
                : ChatLocalFirstFrameAvailabilityPolicy.decision(
                    isSynced: chatInstance?.isSynced ?? false,
                    isInitialArchiveLoaded: chatInstance?.isInitialArchiveLoaded ?? false,
                    isInitialBootstrapInFlight: self.isInitialBootstrapInFlight,
                    allowsStaleLocalHistory: self.allowsStaleLocalHistoryDuringInitialBootstrap,
                    allowsBootstrapFailureFallback: self.allowsBootstrapFailureFallback,
                    // A trusted callback is not itself a reusable saved-position
                    // proof. Saved admission is derived from current Realm
                    // readiness above so a newer boundary can invalidate it.
                    hasTrustedPersistedBootstrapPage:
                        hasTrustedPersistedBootstrapPage && !hasSavedPositionRequest,
                    hasLocalAnchorRequest:
                        hasEligibleLocalAnchorRequest ||
                        shouldPrepareSavedPositionProbe,
                    allowsInitialMaterializationProbe:
                        allowsInitialMaterializationProbe,
                    liveLoadingState: initialLoadingState
                )

        guard availability == .prepareLocal else {
            self.initialLocalFirstFramePhase = .blockedArchiveBootstrap(descriptor)
            self.acquireInteractiveChatOpenGateIfNeeded()
            self.applyBootstrapViewState(
                .skeleton,
                forceRender: true,
                synchronousSkeletonCommit: self.isPreparingStackedNavigationPresentation
            )
            self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
            return true
        }

        let resumesPersistedMissingTarget: Bool = {
            guard hasTrustedPersistedBootstrapPage,
                  case .blockedMissingTarget(let current) =
                    self.initialLocalFirstFramePhase else {
                return false
            }
            return current == descriptor
        }()

        switch self.initialLocalFirstFramePhase {
        case .preparing(let current)
            where current == descriptor && !hasTrustedPersistedBootstrapPage:
            return true
        case .presenting(let current)
            where current == descriptor && !hasTrustedPersistedBootstrapPage:
            return true
        case .committed(let current)
            where current == descriptor && !hasTrustedPersistedBootstrapPage:
            self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
            return true
        case .blockedMissingTarget(let current)
            where current == descriptor && !hasTrustedPersistedBootstrapPage:
            self.acquireInteractiveChatOpenGateIfNeeded()
            self.applyBootstrapViewState(
                .skeleton,
                forceRender: true,
                synchronousSkeletonCommit: self.isPreparingStackedNavigationPresentation
            )
            self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
            return true
        case .failedPresentation(let current)
            where current == descriptor && !hasTrustedPersistedBootstrapPage:
            self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
            return true
        default:
            break
        }

        self.revokeActivePostBootstrapInitialFrameAdmission()
        session.cancelInitialFramePreparations()
        let mappingJob = self.beginDatasetMappingJob()
        let mappingGeneration = mappingJob.generation
        let mappingToken = mappingJob.token
        self.initialLocalFirstFrameMappingToken = mappingToken
        let expectedSessionGeneration = session.snapshot.generation
        let performanceTraceContext = self.chatOpenPerformanceTraceContext
        self.initialLocalFirstFramePhase = .preparing(descriptor)
        self.initialLocalFirstFrameReadinessProof = nil
        if resumesPersistedMissingTarget {
            let mappingContext = self.captureDatasourceMappingContext()
            let admission = ChatPostBootstrapInitialFrameAdmission(
                identity: ChatPostBootstrapInitialFrameAdmissionIdentity(
                    conversationKey: self.chatTimelineConversationKey,
                    bootstrapQueryId: self.initialBootstrapQueryId,
                    targetFingerprint: self.initialBootstrapTargetFingerprint,
                    descriptor: descriptor,
                    datasetMappingGeneration: mappingGeneration,
                    timelineGeneration: expectedSessionGeneration
                ),
                mappingToken: mappingToken,
                session: session
            )
            self.activePostBootstrapInitialFrameAdmission = admission
            let disposition = session.prepareMapAndCommitPostBootstrapInitialFrame(
                target: descriptor.target,
                searchAnchor: descriptor.request?.source == .search
                    ? descriptor.request?.anchor
                    : nil,
                limit: self.initialFirstFramePageSize,
                expectedGeneration: expectedSessionGeneration,
                performanceTraceContext: performanceTraceContext,
                map: { [weak self] preparedFrame
                    -> ChatFirstFrameMappedValue<ChatDatasourceMappingResult>? in
                    guard let self,
                          performanceTraceContext.map({
                            self.chatOpenPerformanceTraceLifecycle.isCurrent($0)
                          }) ?? true else { return nil }
                    var mapped: ChatFirstFrameMappedValue<ChatDatasourceMappingResult>?
                    self.datasetMappingQueue.sync {
                        let mappedOnMainThread = Thread.isMainThread
#if DEBUG || CHAT_PERFORMANCE_LAB
                        self.initialFirstFrameMappingBarrierForTests?()
#endif
                        mapped = ChatFirstFrameMappedValue(
                            value: self.mapDataset(
                                dataset: preparedFrame.snapshot.items,
                                context: mappingContext,
                                cancellationToken: mappingToken,
                                performanceTraceContext: performanceTraceContext
                            ),
                            mappedOnMainThread: mappedOnMainThread
                        )
                    }
                    return mapped
                },
                shouldCommit: { _, mapped in
                    admission.authorizesCommit &&
                        !mapped.value.wasCancelled &&
                        !mapped.mappedOnMainThread
                },
                completion: { [weak self, weak session] result in
                    guard let self,
                          let session,
                          self.timelineSession === session,
                          performanceTraceContext.map({
                            self.chatOpenPerformanceTraceLifecycle.isCurrent($0)
                          }) ?? true,
                          self.isCurrentPostBootstrapInitialFrameAdmission(
                            admission,
                            session: session
                          ) else {
                        if self?.activePostBootstrapInitialFrameAdmission ===
                            admission {
                            self?.activePostBootstrapInitialFrameAdmission = nil
                            admission.revoke()
                        }
                        self?.resolveSupersededInitialLocalFirstFramePreparation(
                            descriptor: descriptor,
                            mappingToken: mappingToken
                        )
                        return
                    }
                    switch result {
                    case .stale, .rejected:
                        self.activePostBootstrapInitialFrameAdmission = nil
                        self.resolveSupersededInitialLocalFirstFramePreparation(
                            descriptor: descriptor,
                            mappingToken: mappingToken
                        )
                    case .blocked(let reason):
                        guard self.isCurrentPostBootstrapInitialFrameAdmission(
                            admission,
                            session: session,
                            requiredTimelineGeneration:
                                admission.identity.timelineGeneration
                        ) else {
                            self.activePostBootstrapInitialFrameAdmission = nil
                            admission.revoke()
                            self.resolveSupersededInitialLocalFirstFramePreparation(
                                descriptor: descriptor,
                                mappingToken: mappingToken
                            )
                            return
                        }
                        self.activePostBootstrapInitialFrameAdmission = nil
                        self.handlePreparedInitialLocalFirstFrame(
                            .blocked(reason),
                            descriptor: descriptor,
                            session: session,
                            mappingGeneration: mappingGeneration,
                            mappingToken: mappingToken,
                            performanceTraceContext: performanceTraceContext,
                            hasTrustedPersistedBootstrapPage:
                                hasTrustedPersistedBootstrapPage
                        )
                    case .committed(
                        let finalizedFrame,
                        let committedSnapshot,
                        let mapped
                    ):
                        guard committedSnapshot.generation ==
                                admission.identity.timelineGeneration &+ 1,
                              self.isCurrentPostBootstrapInitialFrameAdmission(
                                admission,
                                session: session,
                                requiredTimelineGeneration:
                                    committedSnapshot.generation
                              ) else {
                            self.activePostBootstrapInitialFrameAdmission = nil
                            admission.revoke()
                            self.resolveSupersededInitialLocalFirstFramePreparation(
                                descriptor: descriptor,
                                mappingToken: mappingToken
                            )
                            return
                        }
                        self.activePostBootstrapInitialFrameAdmission = nil
                        self.handleCommittedMappedInitialLocalFirstFrame(
                            descriptor: descriptor,
                            session: session,
                            mappingGeneration: mappingGeneration,
                            mappingToken: mappingToken,
                            finalizedFrame: finalizedFrame,
                            committedSnapshot: committedSnapshot,
                            mappingResult: mapped.value,
                            mappedOnMainThread: mapped.mappedOnMainThread,
                            hasTrustedPersistedBootstrapPage:
                                hasTrustedPersistedBootstrapPage
                        )
                    }
                }
            )
            if disposition == .rejectedStale {
                if self.isCurrentPostBootstrapInitialFrameAdmission(
                    admission,
                    session: session
                ) {
                    self.activePostBootstrapInitialFrameAdmission = nil
                    admission.revoke()
                    if self.initialLocalFirstFrameMappingToken === mappingToken {
                        self.initialLocalFirstFrameMappingToken = nil
                    }
                    self.initialLocalFirstFramePhase = .idle
                    self.retryInitialLocalFirstFramePreparation()
                }
            }
            return true
        }
        let disposition = session.prepareInitialFrame(
            target: descriptor.target,
            limit: self.initialFirstFramePageSize,
            expectedGeneration: expectedSessionGeneration,
            deferMetadataUntilFinalization: true,
            performanceTraceContext: performanceTraceContext
        ) { [weak self, weak session] result in
            guard let self,
                  let session,
                  self.timelineSession === session,
                  performanceTraceContext.map({
                    self.chatOpenPerformanceTraceLifecycle.isCurrent($0)
                  }) ?? true else {
                return
            }
            guard self.initialLocalFirstFramePhase == .preparing(descriptor),
                  !mappingToken.isCancelled,
                  ChatDatasourceApplyGenerationPolicy.shouldApply(
                    requestGeneration: mappingGeneration,
                    currentGeneration: self.datasetMappingGeneration
                  ) else {
                self.resolveSupersededInitialLocalFirstFramePreparation(
                    descriptor: descriptor,
                    mappingToken: mappingToken
                )
                return
            }
            self.handlePreparedInitialLocalFirstFrame(
                result,
                descriptor: descriptor,
                session: session,
                mappingGeneration: mappingGeneration,
                mappingToken: mappingToken,
                performanceTraceContext: performanceTraceContext,
                hasTrustedPersistedBootstrapPage:
                    hasTrustedPersistedBootstrapPage
            )
        }

        if disposition == .rejectedStale {
            self.initialLocalFirstFramePhase = .idle
            self.retryInitialLocalFirstFramePreparation()
        }
        return true
    }

    internal func isCurrentPostBootstrapInitialFrameAdmission(
        _ admission: ChatPostBootstrapInitialFrameAdmission,
        session: ChatTimelineSession,
        requiredTimelineGeneration: UInt64? = nil
    ) -> Bool {
        let identity = admission.identity
        return admission.authorizesCommit &&
            self.activePostBootstrapInitialFrameAdmission === admission &&
            self.timelineSession === session &&
            self.initialLocalFirstFrameMappingToken === admission.mappingToken &&
            self.initialLocalFirstFramePhase ==
                .preparing(identity.descriptor) &&
            identity.conversationKey == self.chatTimelineConversationKey &&
            identity.bootstrapQueryId == self.initialBootstrapQueryId &&
            identity.targetFingerprint == self.initialBootstrapTargetFingerprint &&
            identity.descriptor == ChatLocalFirstFrameDescriptorPolicy.descriptor(
                request: self.pendingOpenMessageRequest,
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            ) &&
            identity.datasetMappingGeneration == self.datasetMappingGeneration &&
            (requiredTimelineGeneration.map {
                session.snapshot.generation == $0
            } ?? true)
    }

    internal func revokeActiveAnchorPersistenceMaterializationAdmission() {
        guard let admission = self.activeAnchorPersistenceMaterializationAdmission else {
            return
        }
        self.activeAnchorPersistenceMaterializationAdmission = nil
        admission.revoke()
        admission.session?.cancelInitialFramePreparations()
    }

    private func ownsCurrentAnchorPersistenceMaterializationAdmission(
        _ admission: ChatAnchorPersistenceMaterializationAdmission,
        session: ChatTimelineSession
    ) -> Bool {
        admission.authorizesCommit &&
            self.activeAnchorPersistenceMaterializationAdmission === admission &&
            self.timelineSession === session &&
            self.pendingOpenMessageRequest == admission.request &&
            self.activeAnchorExecutionState?.request == admission.request &&
            self.activeAnchorExecutionState?.transactionToken ==
                admission.transactionToken &&
            self.anchorTransactionGate.snapshot.activeToken ==
                admission.transactionToken
    }

    /// Phase A of a remote exact open. The compound store lease resolves and
    /// commits one bounded command snapshot, but deliberately maps no UIKit
    /// datasource. The production session callback ignores command snapshots,
    /// so the existing skeleton remains the only visible frame while blocking
    /// context is admitted under the same anchor token.
    @discardableResult
    internal func prepareAnchorPersistenceWindow(
        request: ChatOpenMessageRequest,
        transactionToken: ChatAnchorTransactionToken,
        completion: @escaping (
            ChatAnchorPersistenceWindowMaterializationResult
        ) -> Void
    ) -> Bool {
        guard let session = self.timelineSession,
              self.pendingOpenMessageRequest == request,
              self.activeAnchorExecutionState?.transactionToken ==
                transactionToken,
              self.anchorTransactionGate.snapshot.activeToken ==
                transactionToken else {
            return false
        }
        self.revokeActiveAnchorPersistenceMaterializationAdmission()
        session.cancelInitialFramePreparations()
        let expectedGeneration = session.snapshot.generation
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        let admission = ChatAnchorPersistenceMaterializationAdmission(
            transactionToken: transactionToken,
            request: request,
            expectedTimelineGeneration: expectedGeneration,
            mappingToken: nil,
            session: session
        )
        self.activeAnchorPersistenceMaterializationAdmission = admission
        let disposition = session.prepareMapAndCommitPostBootstrapInitialFrame(
            target: descriptor.target,
            searchAnchor: request.source == .search ? request.anchor : nil,
            limit: self.initialFirstFramePageSize,
            expectedGeneration: expectedGeneration,
            performanceTraceContext: self.chatOpenPerformanceTraceContext,
            map: { _ in
                ChatFirstFrameMappedValue(
                    value: true,
                    mappedOnMainThread: Thread.isMainThread
                )
            },
            shouldCommit: { _, mapped in
                admission.authorizesCommit && !mapped.mappedOnMainThread
            },
            completion: { [weak self, weak session] result in
                guard let self, let session else { return }
                guard self.ownsCurrentAnchorPersistenceMaterializationAdmission(
                        admission,
                        session: session
                      ) else {
                    if self.activeAnchorPersistenceMaterializationAdmission ===
                        admission {
                        self.revokeActiveAnchorPersistenceMaterializationAdmission()
                        completion(.stale)
                    }
                    return
                }
                self.activeAnchorPersistenceMaterializationAdmission = nil
                switch result {
                case .committed(let frame, let snapshot, _):
                    guard snapshot.generation ==
                            admission.expectedTimelineGeneration &+ 1 else {
                        completion(.stale)
                        return
                    }
                    completion(.committed(
                        snapshot,
                        frame.searchResolutionProof
                    ))
                case .blocked(
                    .searchResolutionFailed(let failure)
                ):
                    completion(.failed(failure))
                case .blocked(.targetMissing):
                    guard session.snapshot.generation ==
                            admission.expectedTimelineGeneration else {
                        completion(.stale)
                        return
                    }
                    completion(.blocked)
                case .rejected:
                    guard session.snapshot.generation ==
                            admission.expectedTimelineGeneration else {
                        completion(.stale)
                        return
                    }
                    completion(.rejected)
                case .stale:
                    completion(.stale)
                }
            }
        )
        guard disposition == .started else {
            if self.activeAnchorPersistenceMaterializationAdmission === admission {
                self.activeAnchorPersistenceMaterializationAdmission = nil
            }
            admission.revoke()
            completion(.stale)
            return false
        }
        return true
    }

    /// Phase B runs only after every blocking context query has crossed its
    /// persistence barrier. It maps the same bounded target window inside the
    /// compound lease and returns an already committed immutable frame. UIKit
    /// presentation is a separate main-thread step so the caller can recheck
    /// context coverage before publishing the sole real frame.
    @discardableResult
    internal func prepareMappedAnchorPersistenceWindow(
        request: ChatOpenMessageRequest,
        transactionToken: ChatAnchorTransactionToken,
        completion: @escaping (ChatAnchorMappedPersistenceWindowResult) -> Void
    ) -> Bool {
        guard let session = self.timelineSession,
              self.pendingOpenMessageRequest == request,
              let executionState = self.activeAnchorExecutionState,
              executionState.request == request,
              executionState.transactionToken == transactionToken,
              self.anchorTransactionGate.snapshot.activeToken ==
                transactionToken else {
            return false
        }
        let expectedGeneration = session.snapshot.generation
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        let materializationTarget: ChatTimelineInitialFrameTarget
        let provedSearchPrimary: String?
        if request.source == .search {
            switch ChatPersistenceMaterializedSearchTargetPolicy
                .phaseBAdmission(
                    request: request,
                    executionState: executionState,
                    snapshot: session.snapshot
                ) {
            case .admitted(let primary):
                provedSearchPrimary = primary
                // Phase A already resolved the archive-only semantic anchor
                // under its consistency lease. Phase B must materialize that
                // exact primary and must not run a second Realm semantic
                // resolution that could observe a newer ambiguity or refresh
                // state unrelated to the admitted transaction generation.
                materializationTarget = .message(ChatTimelineAnchor(
                    primary: primary,
                    archivedId: nil,
                    messageId: nil,
                    date: request.anchor.sourceDate
                ))
            case .failed(let failure):
                completion(.failed(failure))
                return false
            }
        } else {
            provedSearchPrimary = nil
            materializationTarget = descriptor.target
        }
        self.revokeActiveAnchorPersistenceMaterializationAdmission()
        session.cancelInitialFramePreparations()
        let mappingJob = self.beginDatasetMappingJob()
        let mappingGeneration = mappingJob.generation
        let mappingToken = mappingJob.token
        self.initialLocalFirstFrameMappingToken = mappingToken
        self.initialLocalFirstFramePhase = .preparing(descriptor)
        let mappingContext = self.captureDatasourceMappingContext()
        let admission = ChatAnchorPersistenceMaterializationAdmission(
            transactionToken: transactionToken,
            request: request,
            expectedTimelineGeneration: expectedGeneration,
            mappingToken: mappingToken,
            session: session
        )
        self.activeAnchorPersistenceMaterializationAdmission = admission
        let performanceTraceContext = self.chatOpenPerformanceTraceContext
        let disposition = session.prepareMapAndCommitPostBootstrapInitialFrame(
            target: materializationTarget,
            searchAnchor: nil,
            limit: self.initialFirstFramePageSize,
            expectedGeneration: expectedGeneration,
            performanceTraceContext: performanceTraceContext,
            map: { [weak self] preparedFrame
                -> ChatFirstFrameMappedValue<ChatDatasourceMappingResult>? in
                guard let self,
                      admission.authorizesCommit,
                      performanceTraceContext.map({
                        self.chatOpenPerformanceTraceLifecycle.isCurrent($0)
                      }) ?? true else {
                    return nil
                }
                var mapped:
                    ChatFirstFrameMappedValue<ChatDatasourceMappingResult>?
                self.datasetMappingQueue.sync {
                    mapped = ChatFirstFrameMappedValue(
                        value: self.mapDataset(
                            dataset: preparedFrame.snapshot.items,
                            context: mappingContext,
                            cancellationToken: mappingToken,
                            performanceTraceContext: performanceTraceContext
                        ),
                        mappedOnMainThread: Thread.isMainThread
                    )
                }
                return mapped
            },
            shouldCommit: { _, mapped in
                admission.authorizesCommit &&
                    !mapped.value.wasCancelled &&
                    !mapped.mappedOnMainThread
            },
            completion: { [weak self, weak session] result in
                guard let self, let session else { return }
                guard self.ownsCurrentAnchorPersistenceMaterializationAdmission(
                        admission,
                        session: session
                      ) else {
                    if self.activeAnchorPersistenceMaterializationAdmission ===
                        admission {
                        self.revokeActiveAnchorPersistenceMaterializationAdmission()
                        completion(.stale)
                    }
                    return
                }
                self.activeAnchorPersistenceMaterializationAdmission = nil
                switch result {
                case .committed(
                    let preparedFrame,
                    let snapshot,
                    let mapped
                ):
                    guard snapshot.generation ==
                            admission.expectedTimelineGeneration &+ 1 else {
                        completion(.stale)
                        return
                    }
                    if let provedSearchPrimary {
                        guard let currentState =
                                self.activeAnchorExecutionState,
                              currentState.request == request,
                              currentState.transactionToken == transactionToken,
                              let proofGeneration = currentState
                                .persistenceMaterializedWindowGeneration,
                              proofGeneration <=
                                admission.expectedTimelineGeneration,
                              case .found(let currentProofPrimary) =
                                currentState.persistenceSearchResolutionProof,
                              currentProofPrimary == provedSearchPrimary,
                              case .message(let preparedAnchor) =
                                preparedFrame.target,
                              preparedAnchor.primary == provedSearchPrimary,
                              case .anchor(let alignedPrimary, _) =
                                preparedFrame.alignment,
                              alignedPrimary == provedSearchPrimary,
                              let committedProofMessage = snapshot.item(
                                primary: provedSearchPrimary
                              )
                        else {
                            completion(.failed(.targetMissing))
                            return
                        }
                        guard !committedProofMessage.isDeleted else {
                            completion(.failed(.targetDeleted))
                            return
                        }
                    }
                    completion(.committed(
                        ChatAnchorMappedPersistenceWindow(
                            descriptor: descriptor,
                            mappingGeneration: mappingGeneration,
                            mappingToken: mappingToken,
                            preparedFrame: preparedFrame,
                            committedSnapshot: snapshot,
                            mappingResult: mapped.value,
                            mappedOnMainThread: mapped.mappedOnMainThread
                        )
                    ))
                case .blocked(.searchResolutionFailed(let failure)):
                    completion(.failed(failure))
                case .blocked(.targetMissing):
                    guard session.snapshot.generation ==
                            admission.expectedTimelineGeneration else {
                        completion(.stale)
                        return
                    }
                    completion(.blocked)
                case .rejected:
                    guard session.snapshot.generation ==
                            admission.expectedTimelineGeneration else {
                        completion(.stale)
                        return
                    }
                    completion(.rejected)
                case .stale:
                    completion(.stale)
                }
            }
        )
        guard disposition == .started else {
            if self.activeAnchorPersistenceMaterializationAdmission === admission {
                self.activeAnchorPersistenceMaterializationAdmission = nil
            }
            admission.revoke()
            completion(.stale)
            return false
        }
        return true
    }

    internal func presentMappedAnchorPersistenceWindow(
        _ window: ChatAnchorMappedPersistenceWindow
    ) {
        guard let session = self.timelineSession else { return }
        self.handleCommittedMappedInitialLocalFirstFrame(
            descriptor: window.descriptor,
            session: session,
            mappingGeneration: window.mappingGeneration,
            mappingToken: window.mappingToken,
            finalizedFrame: window.preparedFrame,
            committedSnapshot: window.committedSnapshot,
            mappingResult: window.mappingResult,
            mappedOnMainThread: window.mappedOnMainThread,
            hasTrustedPersistedBootstrapPage: true
        )
    }

    private func handlePreparedInitialLocalFirstFrame(
        _ result: ChatTimelineInitialFramePreparationResult,
        descriptor: ChatLocalFirstFrameDescriptor,
        session: ChatTimelineSession,
        mappingGeneration: Int,
        mappingToken: ChatDatasetMappingCancellationToken,
        performanceTraceContext: ChatOpenPerformanceTraceContext?,
        hasTrustedPersistedBootstrapPage: Bool
    ) {
        switch result {
        case .stale:
            self.initialLocalFirstFramePhase = .idle
            self.retryInitialLocalFirstFramePreparation()
        case .blocked(.targetMissing):
            self.initialLocalFirstFramePhase = .blockedMissingTarget(descriptor)
            self.resumeInitialBootstrapArchiveRequestAfterSavedPositionProbeIfNeeded()
            self.acquireInteractiveChatOpenGateIfNeeded()
            self.applyBootstrapViewState(
                .skeleton,
                forceRender: true,
                synchronousSkeletonCommit: self.isPreparingStackedNavigationPresentation
            )
            self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
        case .blocked(.searchResolutionFailed(let failure)):
            mappingToken.cancel()
            self.initialLocalFirstFrameMappingToken = nil
            self.initialLocalFirstFramePhase = .blockedMissingTarget(descriptor)
            if let request = descriptor.request,
               self.failActiveAnchorExecutionFromInitialFrame(
                   request: request,
                   failure: failure
               ) {
                return
            }
            // A semantic search failure is terminal for this exact request.
            // Do not reinterpret it as a missing target and admit the looser
            // date/context fallback pipeline.
            self.initialLocalFirstFramePhase = .failedPresentation(descriptor)
            self.preservesBootstrapFailureOverlayUntilRetryCommit = false
            self.allowsBootstrapFailureFallback = true
            self.applyBootstrapLoadingState(
                .failure(fallback: .empty),
                forceRender: true
            )
            self.cancelInitialBootstrapTimeout()
            self.initialBootstrapPresentationDeadline = nil
            self.releaseInteractiveChatOpenGate()
            self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
        case .prepared(let preparedFrame):
            let mappingContext = self.captureDatasourceMappingContext()
            ChatFirstFrameDisplayMappingExecutor.map(
                preparedFrame.snapshot.items,
                on: self.datasetMappingQueue,
                transform: { [weak self] items in
#if DEBUG || CHAT_PERFORMANCE_LAB
                    self?.initialFirstFrameMappingBarrierForTests?()
#endif
                    return self?.mapDataset(
                        dataset: items,
                        context: mappingContext,
                        cancellationToken: mappingToken,
                        performanceTraceContext: performanceTraceContext
                    )
                }
            ) { [weak self, weak session] mapped in
                guard let self,
                      let session,
                      self.timelineSession === session,
                      performanceTraceContext.map({
                        self.chatOpenPerformanceTraceLifecycle.isCurrent($0)
                      }) ?? true,
                      self.initialLocalFirstFramePhase == .preparing(descriptor),
                      !mappingToken.isCancelled,
                      ChatDatasourceApplyGenerationPolicy.shouldApply(
                        requestGeneration: mappingGeneration,
                        currentGeneration: self.datasetMappingGeneration
                      ),
                      let mappingResult = mapped.value,
                      !mappingResult.wasCancelled,
                      !mapped.mappedOnMainThread else {
                    self?.resolveSupersededInitialLocalFirstFramePreparation(
                        descriptor: descriptor,
                        mappingToken: mappingToken
                    )
                    return
                }
                session.finalizeAndCommitPreparedInitialFrame(
                    preparedFrame,
                    shouldCommit: { _ in !mappingToken.isCancelled },
                    completion: { [weak self, weak session] result in
                        guard let self,
                              let session,
                              self.timelineSession === session,
                              performanceTraceContext.map({
                                self.chatOpenPerformanceTraceLifecycle.isCurrent($0)
                              }) ?? true else {
                            return
                        }
                        switch result {
                        case .stale:
                            self.resolveSupersededInitialLocalFirstFramePreparation(
                                descriptor: descriptor,
                                mappingToken: mappingToken
                            )
                        case .rejected:
                            self.resolveSupersededInitialLocalFirstFramePreparation(
                                descriptor: descriptor,
                                mappingToken: mappingToken
                            )
                        case .committed(
                            let finalizedFrame,
                            let committedSnapshot
                        ):
                            self.handleCommittedMappedInitialLocalFirstFrame(
                                descriptor: descriptor,
                                session: session,
                                mappingGeneration: mappingGeneration,
                                mappingToken: mappingToken,
                                finalizedFrame: finalizedFrame,
                                committedSnapshot: committedSnapshot,
                                mappingResult: mappingResult,
                                mappedOnMainThread: mapped.mappedOnMainThread,
                                hasTrustedPersistedBootstrapPage:
                                    hasTrustedPersistedBootstrapPage
                            )
                        }
                    }
                )
            }
        }
    }

    private func handleCommittedMappedInitialLocalFirstFrame(
        descriptor: ChatLocalFirstFrameDescriptor,
        session: ChatTimelineSession,
        mappingGeneration: Int,
        mappingToken: ChatDatasetMappingCancellationToken,
        finalizedFrame: ChatTimelinePreparedInitialFrame,
        committedSnapshot: ChatTimelineSessionSnapshot,
        mappingResult: ChatDatasourceMappingResult,
        mappedOnMainThread: Bool,
        hasTrustedPersistedBootstrapPage: Bool
    ) {
        guard self.initialLocalFirstFramePhase == .preparing(descriptor),
              !mappingToken.isCancelled,
              !mappingResult.wasCancelled,
              !mappedOnMainThread,
              ChatDatasourceApplyGenerationPolicy.shouldApply(
                requestGeneration: mappingGeneration,
                currentGeneration: self.datasetMappingGeneration
              ),
              let readinessProof = finalizedFrame.unreadMetadata
                .initialFrameReadinessProof,
              readinessProof.conversationKey == finalizedFrame.conversationKey,
              readinessProof.baseGeneration == finalizedFrame.baseGeneration,
              readinessProof.baseGeneration &+ 1 == session.snapshot.generation else {
            self.resolveSupersededInitialLocalFirstFramePreparation(
                descriptor: descriptor,
                mappingToken: mappingToken
            )
            return
        }
        self.initialLocalFirstFrameReadinessProof = readinessProof
        let shouldCommitSavedFirstFrame =
            self.shouldCommitPreparedSavedFirstFrame(
                descriptor: descriptor,
                preparedFrame: finalizedFrame
            )
        let hasSavedPositionRequest = descriptor.request?
            .source == .savedVisiblePosition
        let hasDurableSavedPositionWindow: Bool
        if hasSavedPositionRequest,
           let request = descriptor.request {
            hasDurableSavedPositionWindow =
                self.hasDurableSavedPositionFirstFrameEligibility(
                    request: request,
                    preparedWindowArchiveIds:
                        finalizedFrame.snapshot.items.map(\.archivedId),
                    readinessProof: readinessProof
                )
        } else {
            hasDurableSavedPositionWindow = true
        }
        let liveLoadingState = self.currentBootstrapLoadingState()
        let hasMappedRealRows = mappingResult.datasource
            .contains { !$0.isFakeMessage }
        let hasEligibleLocalAnchorRequest: Bool
        if hasSavedPositionRequest,
           let request = descriptor.request {
            hasEligibleLocalAnchorRequest =
                self.hasLocalAnchorForBootstrap(request) &&
                shouldCommitSavedFirstFrame &&
                hasDurableSavedPositionWindow
        } else {
            hasEligibleLocalAnchorRequest =
                self.hasEligibleLocalAnchorFirstFrame(descriptor: descriptor)
        }
        let mayPresent = shouldCommitSavedFirstFrame &&
            hasDurableSavedPositionWindow &&
            (!hasSavedPositionRequest || hasEligibleLocalAnchorRequest) &&
            ChatPreparedInitialFrameCommitPolicy.shouldCommit(
                hasMappedRealRows: hasMappedRealRows,
                liveLoadingState: liveLoadingState,
                allowsBlockingRealRows:
                    (hasTrustedPersistedBootstrapPage &&
                        !hasSavedPositionRequest) ||
                    hasEligibleLocalAnchorRequest ||
                    self.allowsStaleLocalHistoryDuringInitialBootstrap ||
                    self.allowsBootstrapFailureFallback
            )
        guard mayPresent else {
            self.resumeInitialBootstrapArchiveRequestAfterSavedPositionProbeIfNeeded()
            session.cancelInitialFramePreparations()
            mappingToken.cancel()
            self.initialLocalFirstFrameMappingToken = nil
            self.initialLocalFirstFramePhase = shouldCommitSavedFirstFrame
                ? .blockedArchiveBootstrap(descriptor)
                : .blockedMissingTarget(descriptor)
            self.acquireInteractiveChatOpenGateIfNeeded()
            self.applyBootstrapLoadingState(
                hasSavedPositionRequest ? .blockingTarget : liveLoadingState,
                forceRender: true,
                synchronousSkeletonCommit:
                    self.isPreparingStackedNavigationPresentation
            )
            self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
            return
        }
        self.resumeInitialBootstrapArchiveRequestAfterSavedPositionProbeIfNeeded()
        self.initialLocalFirstFrameReadinessProof = nil
        self.commitInitialLocalFirstFrame(
            descriptor: descriptor,
            session: session,
            mappingGeneration: mappingGeneration,
            mappingToken: mappingToken,
            preparedFrame: finalizedFrame,
            committedSnapshot: committedSnapshot,
            mappingResult: mappingResult,
            mappedOnMainThread: mappedOnMainThread,
            hasTrustedPersistedBootstrapPage:
                hasTrustedPersistedBootstrapPage
        )
    }

    private func hasEligibleLocalAnchorFirstFrame(
        descriptor: ChatLocalFirstFrameDescriptor
    ) -> Bool {
        guard let request = descriptor.request,
              ChatInitialAnchorBootstrapPolicy.needsLocalAnchorLookup(
                source: request.source
              ) else {
            return false
        }
        let hasStructurallySafeLocalAnchor = self.hasLocalAnchorForBootstrap(request)
        // Saved-position window readiness can only reuse IDs captured by an
        // earlier typed background probe. It must never resolve or materialize
        // a target window from this synchronous admission helper.
        let hasDurableArchiveReadiness = request.source == .savedVisiblePosition
            ? self.hasPreparedDurableSavedPositionFirstFrameEligibility(
                request: request
            )
            : false
        return ChatLocalAnchorFirstFrameEligibilityPolicy.isEligible(
            requestSource: request.source,
            hasStructurallySafeLocalAnchor: hasStructurallySafeLocalAnchor,
            hasDurableArchiveReadiness: hasDurableArchiveReadiness
        )
    }

    private func hasDurableSavedPositionFirstFrameEligibility(
        request: ChatOpenMessageRequest,
        preparedWindowArchiveIds: [String?],
        readinessProof suppliedProof: ChatTimelineInitialFrameReadinessProof? = nil
    ) -> Bool {
        guard request.source == .savedVisiblePosition,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType,
              self.conversationType.supportsSnapshotArchiveRepair else {
            return false
        }

        let conversationKey = ChatTimelineConversationKey(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        guard let proof = suppliedProof ?? self.currentInitialFrameReadinessProof(),
              proof.conversationKey == conversationKey,
              proof.hasDurableArchiveReadiness,
              proof.materializedLocalMessageCount > 0 else {
            return false
        }

        return ChatSavedPositionDurableWindowCoveragePolicy.isCovered(
            requestSource: request.source,
            windowArchiveIds: preparedWindowArchiveIds,
            loadedRanges: proof.loadedRanges
        )
    }

    private func hasPreparedDurableSavedPositionFirstFrameEligibility(
        request: ChatOpenMessageRequest
    ) -> Bool {
        guard let probe = self.savedPositionFirstFrameProbeResult,
              probe.request == request,
              case .savedPosition = probe.decision else {
            return false
        }
        return self.hasDurableSavedPositionFirstFrameEligibility(
            request: request,
            preparedWindowArchiveIds: probe.preparedWindowArchiveIds
        )
    }

    private func resolveSupersededInitialLocalFirstFramePreparation(
        descriptor: ChatLocalFirstFrameDescriptor,
        mappingToken: ChatDatasetMappingCancellationToken
    ) {
        guard self.initialLocalFirstFrameMappingToken === mappingToken,
              self.initialLocalFirstFramePhase == .preparing(descriptor) else {
            return
        }
        self.initialLocalFirstFrameMappingToken = nil
        self.initialLocalFirstFramePhase = .idle
        self.initialLocalFirstFrameReadinessProof = nil
        guard !self.isStackedNavigationPresentationPreparationCancelled else {
            return
        }
        if mappingToken.isCancelled {
            let hasTerminalNonSkeletonPresentation =
                self.hasCommittedTerminalNonSkeletonBootstrapPresentation
            let shouldRetry = ChatInitialLocalFirstFrameSupersessionPolicy.shouldRetry(
                mappingWasCancelled: true,
                hasTerminalNonSkeletonPresentation: hasTerminalNonSkeletonPresentation,
                didRunDisappearanceCleanup: self.didRunNavigationDisappearanceCleanup
            )
            ChatArchiveDebugTrace.log("chatInitialLocalFirstFrameSuperseded", [
                ("mappingGeneration", self.datasetMappingGeneration),
                ("hasTerminalNonSkeletonPresentation", hasTerminalNonSkeletonPresentation),
                ("retry", shouldRetry)
            ])
            if shouldRetry {
                self.retryInitialLocalFirstFramePreparation()
            } else if hasTerminalNonSkeletonPresentation {
                self.finishInitialLocalFirstFramePreparation()
            }
        } else {
            self.retryInitialLocalFirstFramePreparation()
        }
    }

    private func shouldCommitPreparedSavedFirstFrame(
        descriptor: ChatLocalFirstFrameDescriptor,
        preparedFrame: ChatTimelinePreparedInitialFrame
    ) -> Bool {
        guard let request = descriptor.request,
              request.source == .savedVisiblePosition else {
            return true
        }
        let items = preparedFrame.snapshot.items
        let knownGaps = preparedFrame.unreadMetadata
            .initialFrameReadinessProof?.knownGaps ?? []
        guard case .anchor(let primary, _) = preparedFrame.alignment,
              let anchorIndex = items.firstIndex(where: { $0.primary == primary }) else {
            self.savedPositionFirstFrameProbeResult = ChatSavedPositionFirstFrameProbeResult(
                request: request,
                decision: .standardContent,
                knownGaps: knownGaps,
                preparedWindowArchiveIds: items.map(\.archivedId)
            )
            return false
        }
        let archivedIdsByIndex = Dictionary(
            uniqueKeysWithValues: items.enumerated().compactMap { index, item in
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(item.archivedId)
                    .map { (index, $0) }
            }
        )
        let decision = ChatSavedPositionFirstFramePolicy.decision(
            requestSource: .savedVisiblePosition,
            isSynced: true,
            observerCount: items.count,
            localAnchorIndex: anchorIndex,
            pageSize: self.initialFirstFramePageSize,
            isPageUnlocked: true,
            archivedIdsByIndex: archivedIdsByIndex,
            knownGaps: knownGaps
        )
        self.savedPositionFirstFrameProbeResult = ChatSavedPositionFirstFrameProbeResult(
            request: request,
            decision: decision,
            knownGaps: knownGaps,
            preparedWindowArchiveIds: items.map(\.archivedId)
        )
        if case .savedPosition = decision {
            return true
        }
        return false
    }

    private func beginInitialFramePresentationAttempt(
        descriptor: ChatLocalFirstFrameDescriptor,
        session: ChatTimelineSession,
        mappingGeneration: Int,
        mappingToken: ChatDatasetMappingCancellationToken,
        timelineGeneration: UInt64,
        anchorTransactionToken: ChatAnchorTransactionToken?,
        performanceTraceContext: ChatOpenPerformanceTraceContext?,
        rollbackSnapshot: ChatInitialFramePresentationRollbackSnapshot
    ) -> ChatInitialFramePresentationAttempt {
        if let prior = self.initialLocalFirstFramePresentationOwnership?.attempt {
            self.revokeInitialFramePresentationAttempt(prior)
        } else if let priorToken =
                    self.initialLocalFirstFrameLatestEffectToken {
            self.readVisiblePresentationCoordinator.revoke(
                initialFrameEffectToken: priorToken
            )
            self.initialLocalFirstFrameLatestEffectToken = nil
        }
        self.initialLocalFirstFramePresentationGeneration &+= 1
        let ownsPresentingInterval = performanceTraceContext.map {
            self.chatOpenPerformanceTraceLifecycle.beginPresenting(context: $0)
        } ?? false
        let attempt = ChatInitialFramePresentationAttempt(
            descriptor: descriptor,
            mappingToken: mappingToken,
            mappingGeneration: mappingGeneration,
            session: session,
            timelineGeneration: timelineGeneration,
            anchorTransactionToken: anchorTransactionToken,
            presentationGeneration:
                self.initialLocalFirstFramePresentationGeneration,
            performanceTraceContext: performanceTraceContext,
            ownsPerformancePresentingInterval: ownsPresentingInterval,
            rollbackSnapshot: rollbackSnapshot
        )
        self.initialLocalFirstFramePresentationOwnership =
            ChatInitialFramePresentationOwnership(
                attempt: attempt,
                phase: .presenting
            )
        self.initialLocalFirstFrameLatestEffectToken = attempt.effectToken
        self.initialLocalFirstFrameCoreAnimationReceiptGeneration = nil
        return attempt
    }

    internal func isCurrentInitialFramePresentationAttempt(
        _ attempt: ChatInitialFramePresentationAttempt,
        phase expectedPhase: ChatInitialFramePresentationAttemptPhase
    ) -> Bool {
        guard let ownership = self.initialLocalFirstFramePresentationOwnership,
              ownership.attempt === attempt,
              ownership.phase == expectedPhase,
              let session = self.timelineSession,
              ObjectIdentifier(session) == attempt.sessionIdentifier else {
            return false
        }
        switch expectedPhase {
        case .presenting:
            guard attempt.mappingGeneration == self.datasetMappingGeneration,
                  session.snapshot.generation == attempt.timelineGeneration,
                  self.initialLocalFirstFramePhase ==
                    .presenting(attempt.descriptor) else {
                return false
            }
            if let mappingToken = attempt.mappingToken {
                guard self.initialLocalFirstFrameMappingToken === mappingToken,
                      !mappingToken.isCancelled else {
                    return false
                }
            } else if self.initialLocalFirstFrameMappingToken != nil {
                return false
            }
            if let request = attempt.descriptor.request {
                guard let anchorToken = attempt.anchorTransactionToken,
                      let execution = self.activeAnchorExecutionState,
                      execution.request == request,
                      execution.transactionToken == anchorToken,
                      self.anchorTransactionGate.snapshot.activeToken ==
                        anchorToken else {
                    return false
                }
            }
            return true
        case .committed:
            return self.initialLocalFirstFramePhase ==
                .committed(attempt.descriptor)
        }
    }

    /// Downstream work such as mention reconciliation may legitimately run
    /// after the stable-frame owner has retired its strong attempt ownership.
    /// The monotonic generation still rejects every older or replaced frame.
    internal func isLatestInitialFramePresentationAttempt(
        _ attempt: ChatInitialFramePresentationAttempt
    ) -> Bool {
        guard attempt.presentationGeneration ==
                self.initialLocalFirstFramePresentationGeneration,
              let session = self.timelineSession,
              ObjectIdentifier(session) == attempt.sessionIdentifier else {
            return false
        }
        return self.initialLocalFirstFramePhase ==
            .committed(attempt.descriptor)
    }

    internal func isLatestInitialFrameEffectToken(
        _ token: ChatInitialFrameEffectToken
    ) -> Bool {
        guard self.initialLocalFirstFrameLatestEffectToken == token,
              token.presentationGeneration ==
                self.initialLocalFirstFramePresentationGeneration,
              let session = self.timelineSession,
              ObjectIdentifier(session) == token.sessionIdentifier else {
            return false
        }
        return self.initialLocalFirstFramePhase ==
            .committed(token.descriptor)
    }

    internal func isInitialFramePresentationAttemptSemanticallyCurrent(
        _ attempt: ChatInitialFramePresentationAttempt
    ) -> Bool {
        self.isLatestInitialFramePresentationAttempt(attempt) &&
            self.deferredInitialLocalFirstFrameReplacement?
                .supersededAttempt !== attempt
    }

    internal func ownsInitialFramePresentationAttemptForAtomicTransaction(
        _ attempt: ChatInitialFramePresentationAttempt
    ) -> Bool {
        self.isCurrentInitialFramePresentationAttempt(
            attempt,
            phase: .presenting
        ) || self.isCurrentInitialFramePresentationAttempt(
            attempt,
            phase: .committed
        )
    }

    @discardableResult
    private func markInitialFramePresentationAttemptCommitted(
        _ attempt: ChatInitialFramePresentationAttempt
    ) -> Bool {
        guard self.isCurrentInitialFramePresentationAttempt(
            attempt,
            phase: .presenting
        ) else {
            return false
        }
        self.initialLocalFirstFramePresentationOwnership =
            ChatInitialFramePresentationOwnership(
                attempt: attempt,
                phase: .committed
            )
        return true
    }

    internal func revokeInitialFramePresentationAttempt(
        _ attempt: ChatInitialFramePresentationAttempt
    ) {
        guard self.initialLocalFirstFramePresentationOwnership?.attempt ===
                attempt else {
            return
        }
        self.initialLocalFirstFramePresentationOwnership = nil
        self.readVisiblePresentationCoordinator.revoke(
            initialFrameEffectToken: attempt.effectToken
        )
        if self.initialLocalFirstFrameLatestEffectToken ==
            attempt.effectToken {
            self.initialLocalFirstFrameLatestEffectToken = nil
        }
        if self.initialLocalFirstFrameTerminalizingAttempt === attempt {
            self.initialLocalFirstFrameTerminalizingAttempt = nil
        }
        if self.initialLocalFirstFrameCoreAnimationReceiptGeneration ==
            attempt.presentationGeneration {
            self.initialLocalFirstFrameCoreAnimationReceiptGeneration = nil
        }
        self.invalidateChatOpenPerformanceStableFrameDisplayLink()
        if attempt.ownsPerformancePresentingInterval,
           let context = attempt.performanceTraceContext,
           self.chatOpenPerformanceTraceLifecycle.isCurrent(context) {
            _ = self.chatOpenPerformanceTraceLifecycle.endPresenting(
                context: context,
                terminal: .cancelled
            )
        }
    }

    /// Restores the exact frame that preceded A. This bypasses the normal
    /// bootstrap reducer intentionally: once A's logical apply has set the
    /// committed-content flags, the ordinary reducer correctly refuses a
    /// skeleton regression, but an unacknowledged superseded publication is
    /// not a committed user-visible frame.
    @discardableResult
    internal func rollbackUnacknowledgedInitialFramePresentation(
        _ attempt: ChatInitialFramePresentationAttempt
    ) -> Bool {
        guard self.initialLocalFirstFramePresentationOwnership?.attempt ===
                attempt,
              self.initialLocalFirstFramePresentationOwnership?.phase ==
                .committed,
              self.initialLocalFirstFramePhase ==
                .committed(attempt.descriptor),
              attempt.presentationGeneration ==
                self.initialLocalFirstFramePresentationGeneration,
              self.initialLocalFirstFrameCoreAnimationReceiptGeneration !=
                attempt.presentationGeneration,
              let session = self.timelineSession,
              ObjectIdentifier(session) == attempt.sessionIdentifier,
              let snapshot = attempt.rollbackSnapshot else {
            return false
        }

        let previousTerminalizingAttempt =
            self.initialLocalFirstFrameTerminalizingAttempt
        self.initialLocalFirstFrameTerminalizingAttempt = attempt
        if let request = attempt.descriptor.request {
            // Tear down A while its ownership is still terminalizing. The
            // cancellation path deliberately preserves viewport state; the
            // complete pre-A snapshot below is therefore the final visual
            // mutation and cannot be partially overwritten by anchor cleanup.
            self.rollbackPreparedLocalFirstFrameAnchor(
                request: request,
                transactionToken: attempt.anchorTransactionToken
            )
        }
        self.hasCommittedRealContentInCurrentLifecycle =
            snapshot.hasCommittedRealContent
        self.hasCommittedBootstrapSkeletonPresentationInCurrentLifecycle =
            snapshot.hasCommittedSkeletonPresentation
        self.hasCommittedTimelinePresentationInCurrentLifecycle =
            snapshot.hasCommittedTimelinePresentation
        self.initialFirstContentApplyCount = snapshot.initialContentApplyCount
        self.lastBootstrapAtomicRevealPlan = snapshot.lastAtomicRevealPlan
        self.appliedBootstrapLoadingState = snapshot.bootstrapLoadingState
        self.hasRenderedStableInitialHistory =
            snapshot.hasRenderedStableInitialHistory
        self.initialHistoryAppearancePending =
            snapshot.initialHistoryAppearancePending
        self.hasCompletedInitialHistoryViewAppearance =
            snapshot.hasCompletedInitialHistoryViewAppearance
        self.allowsBootstrapFailureFallback =
            snapshot.allowsBootstrapFailureFallback
        self.preservesBootstrapFailureOverlayUntilRetryCommit =
            snapshot.preservesBootstrapFailureOverlayUntilRetryCommit

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            self.datasource = snapshot.datasource
            self.datasourceSnapshot = snapshot.datasourceSnapshot
            (self.messagesCollectionView.collectionViewLayout as?
                MessagesCollectionViewFlowLayout)?
                .cache.install(snapshot.layoutSnapshot)
            self.messagesCollectionView.contentInset = snapshot.contentInsets
            self.messagesCollectionView.verticalScrollIndicatorInsets =
                snapshot.verticalScrollIndicatorInsets
            self.messagesCollectionView.horizontalScrollIndicatorInsets =
                snapshot.horizontalScrollIndicatorInsets
            self.scrollFrameOperationCounter.record(.reloads)
            self.messagesCollectionView.reloadData()
            self.messagesCollectionView.layoutIfNeeded()
            self.messagesCollectionView.setContentOffset(
                snapshot.contentOffset,
                animated: false
            )
            self.messagesCollectionView.layoutIfNeeded()
            self.setSkeletonVisible(snapshot.showsSkeleton)
            self.setDatasourceLoadingEnabled(snapshot.canLoadDatasource)
            self.setLoadingIndicatorVisible(snapshot.showsLoadingIndicator)
            self.messageLoadingActivityIndicator.isHidden =
                !snapshot.showsArchiveLoadingIndicator
            self.messagesCollectionView.isUserInteractionEnabled =
                snapshot.isCollectionUserInteractionEnabled
            self.messagesCollectionView.isScrollEnabled =
                snapshot.isCollectionScrollEnabled
            self.setShouldShowInitialMessage(snapshot.showsInitialMessage)
            self.setBootstrapFailureVisible(snapshot.showsBootstrapFailure)
        }
        CATransaction.commit()
        self.timelineInteractionState.isLoading =
            snapshot.isTimelineInteractionLoading
        self.timelineInteractionState.locked =
            snapshot.isTimelineInteractionLocked
        self.syncCurrentPage(with: snapshot.residentDatasetWindow)
        self.activeHistoryBoundaryPlaceholder = snapshot.boundaryPlaceholder
        self.scrollBoundaryAvailabilityCache =
            snapshot.boundaryAvailabilityCache
        if self.initialLocalFirstFrameTerminalizingAttempt === attempt {
            self.initialLocalFirstFrameTerminalizingAttempt =
                previousTerminalizingAttempt === attempt
                    ? attempt
                    : nil
        }
        return true
    }

    internal func retireCommittedInitialFramePresentationAttempt(
        _ attempt: ChatInitialFramePresentationAttempt
    ) {
        guard self.initialLocalFirstFramePresentationOwnership?.attempt ===
                attempt,
              self.initialLocalFirstFramePresentationOwnership?.phase ==
                .committed else {
            return
        }
        self.initialLocalFirstFramePresentationOwnership = nil
        if self.initialLocalFirstFrameTerminalizingAttempt === attempt {
            self.initialLocalFirstFrameTerminalizingAttempt = nil
        }
    }

    internal func resolveSupersededInitialFramePresentationAttempt(
        _ attempt: ChatInitialFramePresentationAttempt
    ) {
        guard let replacement =
                self.deferredInitialLocalFirstFrameReplacement,
              replacement.supersededAttempt === attempt else {
            return
        }
        if let mappingToken = attempt.mappingToken,
           self.initialLocalFirstFrameMappingToken === mappingToken {
            mappingToken.cancel()
            self.initialLocalFirstFrameMappingToken = nil
        }
        if let request = attempt.descriptor.request {
            self.rollbackPreparedLocalFirstFrameAnchor(
                request: request,
                transactionToken: attempt.anchorTransactionToken
            )
        }
        if self.initialLocalFirstFramePhase ==
            .presenting(attempt.descriptor) ||
            self.initialLocalFirstFramePhase ==
                .committed(attempt.descriptor) {
            self.initialLocalFirstFramePhase = .idle
        }
        self.pendingOpenMessageRequest = nil
        self.initialLocalFirstFrameShouldPerformPendingRequest = false

        DispatchQueue.main.async { [weak self, weak replacement] in
            guard let self,
                  let replacement,
                  self.deferredInitialLocalFirstFrameReplacement ===
                    replacement else {
                return
            }
            self.deferredInitialLocalFirstFrameReplacement = nil
            self.queueOpenMessageRequest(
                replacement.request,
                hooks: replacement.hooks
            )
        }
    }

    private func commitInitialLocalFirstFrame(
        descriptor: ChatLocalFirstFrameDescriptor,
        session: ChatTimelineSession,
        mappingGeneration: Int,
        mappingToken: ChatDatasetMappingCancellationToken,
        preparedFrame: ChatTimelinePreparedInitialFrame,
        committedSnapshot: ChatTimelineSessionSnapshot,
        mappingResult: ChatDatasourceMappingResult,
        mappedOnMainThread: Bool,
        hasTrustedPersistedBootstrapPage: Bool
    ) {
        assert(Thread.isMainThread, "Initial-frame lifecycle admission must run on main")
        let currentSnapshot = session.snapshot
        guard self.timelineSession === session,
              self.initialLocalFirstFramePhase == .preparing(descriptor),
              self.initialLocalFirstFrameMappingToken === mappingToken,
              !mappingToken.isCancelled,
              mappingGeneration == self.datasetMappingGeneration,
              ChatInitialFrameLifecycleSnapshotContinuityPolicy.admits(
                  preparedGeneration: committedSnapshot.generation,
                  preparedProjection:
                      ChatTimelineStoreObservationAuthorityProjection.capture(
                          committedSnapshot
                      ),
                  current: currentSnapshot
              ) else {
            self.resolveSupersededInitialLocalFirstFramePreparation(
                descriptor: descriptor,
                mappingToken: mappingToken
            )
            return
        }
        self.synchronizeInitialFramePresentationLifecycleWithApplicationState()
        if !self.isInitialFramePresentationLifecycleEligible {
            let identity = ChatInitialFrameLifecyclePresentationIdentity(
                conversationKey: self.chatTimelineConversationKey,
                bootstrapQueryId: self.initialBootstrapQueryId,
                targetFingerprint: self.initialBootstrapTargetFingerprint,
                descriptor: descriptor,
                datasetMappingGeneration: mappingGeneration,
                timelineGeneration: committedSnapshot.generation,
                timelineProjection:
                    ChatTimelineStoreObservationAuthorityProjection.capture(
                        committedSnapshot
                    )
            )
            self.retainInitialFrameLifecyclePresentation(
                identity: identity,
                mappingToken: mappingToken
            ) { [weak self, weak session] in
                guard let self, let session else {
                    return
                }
                self.commitInitialLocalFirstFrame(
                    descriptor: descriptor,
                    session: session,
                    mappingGeneration: mappingGeneration,
                    mappingToken: mappingToken,
                    preparedFrame: preparedFrame,
                    committedSnapshot: committedSnapshot,
                    mappingResult: mappingResult,
                    mappedOnMainThread: mappedOnMainThread,
                    hasTrustedPersistedBootstrapPage:
                        hasTrustedPersistedBootstrapPage
                )
            }
            return
        }

        let presentationStartedAt = Date()
        let previousBootstrapState = self.appliedBootstrapLoadingState ?? .blockingArchive
        let previousBoundaryPlaceholder = self.activeHistoryBoundaryPlaceholder
        let previousResidentDatasetWindow = self.residentDatasetWindow
        let previousScrollBoundaryAvailabilityCache =
            self.scrollBoundaryAvailabilityCache
        let performanceTraceContext = self.chatOpenPerformanceTraceContext
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.initialFrameRollbackSnapshotWillCaptureForTests?()
#endif
        let rollbackSnapshot = ChatInitialFramePresentationRollbackSnapshot(
            datasource: self.datasource,
            datasourceSnapshot: self.datasourceSnapshot,
            layoutSnapshot:
                (self.messagesCollectionView.collectionViewLayout as?
                    MessagesCollectionViewFlowLayout)?
                    .cache.reuseSnapshot() ?? .empty,
            contentInsets: self.messagesCollectionView.contentInset,
            verticalScrollIndicatorInsets:
                self.messagesCollectionView.verticalScrollIndicatorInsets,
            horizontalScrollIndicatorInsets:
                self.messagesCollectionView.horizontalScrollIndicatorInsets,
            contentOffset: self.messagesCollectionView.contentOffset,
            residentDatasetWindow: previousResidentDatasetWindow,
            boundaryPlaceholder: previousBoundaryPlaceholder,
            boundaryAvailabilityCache:
                previousScrollBoundaryAvailabilityCache,
            bootstrapLoadingState: self.appliedBootstrapLoadingState,
            showsSkeleton: self.showSkeletonObserver.value,
            canLoadDatasource: self.canLoadDatasource,
            showsLoadingIndicator: self.showLoadingIndicator.value,
            showsArchiveLoadingIndicator:
                !self.messageLoadingActivityIndicator.isHidden,
            isCollectionUserInteractionEnabled:
                self.messagesCollectionView.isUserInteractionEnabled,
            isCollectionScrollEnabled:
                self.messagesCollectionView.isScrollEnabled,
            isTimelineInteractionLoading:
                self.timelineInteractionState.isLoading,
            isTimelineInteractionLocked:
                self.timelineInteractionState.locked,
            showsInitialMessage: self.shouldShowInitialMessage.value,
            hasCommittedRealContent:
                self.hasCommittedRealContentInCurrentLifecycle,
            hasCommittedSkeletonPresentation:
                self.hasCommittedBootstrapSkeletonPresentationInCurrentLifecycle,
            hasCommittedTimelinePresentation:
                self.hasCommittedTimelinePresentationInCurrentLifecycle,
            initialContentApplyCount: self.initialFirstContentApplyCount,
            lastAtomicRevealPlan: self.lastBootstrapAtomicRevealPlan,
            hasRenderedStableInitialHistory:
                self.hasRenderedStableInitialHistory,
            initialHistoryAppearancePending:
                self.initialHistoryAppearancePending,
            hasCompletedInitialHistoryViewAppearance:
                self.hasCompletedInitialHistoryViewAppearance,
            allowsBootstrapFailureFallback:
                self.allowsBootstrapFailureFallback,
            preservesBootstrapFailureOverlayUntilRetryCommit:
                self.preservesBootstrapFailureOverlayUntilRetryCommit,
            showsBootstrapFailure: !self.bootstrapFailureView.isHidden
        )
        self.initialLocalFirstFramePhase = .presenting(descriptor)
        let anchorTransactionToken: ChatAnchorTransactionToken?
        if case .anchor = preparedFrame.alignment,
           let request = descriptor.request {
            anchorTransactionToken =
                self.prepareLocalFirstFrameAnchorExecution(request: request)
        } else {
            anchorTransactionToken = nil
        }
        let presentationAttempt = self.beginInitialFramePresentationAttempt(
            descriptor: descriptor,
            session: session,
            mappingGeneration: mappingGeneration,
            mappingToken: mappingToken,
            timelineGeneration: currentSnapshot.generation,
            anchorTransactionToken: anchorTransactionToken,
            performanceTraceContext: performanceTraceContext,
            rollbackSnapshot: rollbackSnapshot
        )
        let rollbackPresentationState: () -> Void = { [weak self] in
            guard let self else {
                return
            }
            self.activeHistoryBoundaryPlaceholder = previousBoundaryPlaceholder
            self.syncCurrentPage(with: previousResidentDatasetWindow)
            self.scrollBoundaryAvailabilityCache =
                previousScrollBoundaryAvailabilityCache
            if case .anchor = preparedFrame.alignment,
               let request = descriptor.request {
                self.rollbackPreparedLocalFirstFrameAnchor(
                    request: request,
                    transactionToken:
                        presentationAttempt.anchorTransactionToken
                )
            }
        }
        let reportSupersededRollback: () -> Void = { [weak self] in
            rollbackPresentationState()
#if DEBUG || CHAT_PERFORMANCE_LAB
            self?.initialFrameSupersededRollbackForTests?(
                previousResidentDatasetWindow,
                previousBoundaryPlaceholder,
                previousScrollBoundaryAvailabilityCache
            )
#endif
        }
        self.activeHistoryBoundaryPlaceholder = nil
        self.syncCurrentPage(
            with: ChatDatasetWindow(minIndex: 0, maxIndex: committedSnapshot.items.count)
        )
        self.invalidateEditedMessageLayoutCache(
            primaries: mappingResult.editedMessagePrimariesNeedingLayoutInvalidation
        )
        if let anchorTransactionToken,
           let request = descriptor.request {
            self.activatePreparedLocalFirstFrameAnchor(
                request: request,
                transactionToken: anchorTransactionToken
            )
        }
        guard self.isCurrentInitialFramePresentationAttempt(
            presentationAttempt,
            phase: .presenting
        ) else {
            if self.deferredInitialLocalFirstFrameReplacement?
                .supersededAttempt === presentationAttempt {
                reportSupersededRollback()
            }
            self.resolveSupersededInitialFramePresentationAttempt(
                presentationAttempt
            )
            return
        }

        let presentationAttemptCount =
            self.initialLocalFirstFramePresentationRetryDescriptor == descriptor
                ? 2
                : 1
        var applyPreparedFrame: (() -> Void)?
        let handlePresentationResult: (ChatViewportTransactionResult) -> Void = { [weak self] result in
            guard let self else {
                applyPreparedFrame = nil
                return
            }
            guard self.isCurrentInitialFramePresentationAttempt(
                presentationAttempt,
                phase: .presenting
            ), performanceTraceContext.map({
                self.chatOpenPerformanceTraceLifecycle.isCurrent($0)
            }) ?? true else {
                if self.deferredInitialLocalFirstFrameReplacement?
                    .supersededAttempt === presentationAttempt {
                    reportSupersededRollback()
                }
                self.resolveSupersededInitialFramePresentationAttempt(
                    presentationAttempt
                )
                applyPreparedFrame = nil
                return
            }

            switch result {
            case .committed(let diagnostics):
                guard self.markInitialFramePresentationAttemptCommitted(
                    presentationAttempt
                ) else {
                    self.resolveSupersededInitialFramePresentationAttempt(
                        presentationAttempt
                    )
                    applyPreparedFrame = nil
                    return
                }
                applyPreparedFrame = nil
                if let mappingToken = presentationAttempt.mappingToken,
                   self.initialLocalFirstFrameMappingToken === mappingToken {
                    self.initialLocalFirstFrameMappingToken = nil
                }
                self.initialLocalFirstFramePresentationRetryDescriptor = nil
                self.initialLocalFirstFramePhase = .committed(descriptor)
                self.initialLocalFirstFrameTerminalizingAttempt =
                    presentationAttempt
                let abortTerminalForDeferredReplacement: () -> Bool = {
                    guard self.deferredInitialLocalFirstFrameReplacement?
                        .supersededAttempt === presentationAttempt else {
                        return false
                    }
                    rollbackPresentationState()
                    _ = self.rollbackUnacknowledgedInitialFramePresentation(
                        presentationAttempt
                    )
#if DEBUG || CHAT_PERFORMANCE_LAB
                    self.initialFrameSupersededRollbackForTests?(
                        previousResidentDatasetWindow,
                        previousBoundaryPlaceholder,
                        previousScrollBoundaryAvailabilityCache
                    )
#endif
                    self.initialLocalFirstFrameTerminalizingAttempt = nil
                    self.revokeInitialFramePresentationAttempt(
                        presentationAttempt
                    )
                    self.resolveSupersededInitialFramePresentationAttempt(
                        presentationAttempt
                    )
                    return true
                }
                if abortTerminalForDeferredReplacement() {
                    return
                }
                self.scheduleReadVisibleStableLayoutRetryIfNeeded()
                if abortTerminalForDeferredReplacement() {
                    return
                }
                self.initialFirstContentApplyCount += 1
#if DEBUG || CHAT_PERFORMANCE_LAB
                let committedTargetKind: ChatOpenRealPipelineFixtureTargetKind
                switch preparedFrame.alignment {
                case .bottom:
                    committedTargetKind = committedSnapshot.items.isEmpty
                        ? .empty
                        : .latest
                case .anchor:
                    committedTargetKind = .anchor
                }
                let finalArchiveState = preparedFrame.unreadMetadata
                    .initialFrameReadinessProof?.archiveState
                self.performanceFixtureInitialFrameCommitDiagnosticsHandler?(
                    ChatPerformanceInitialFrameCommitDiagnostics(
                        initialFrameEffectToken:
                            presentationAttempt.effectToken,
                        requestSource: descriptor.request?.source,
                        requestHighlight: descriptor.request?.highlight ?? false,
                        requestMarkReadOnVisible:
                            descriptor.request?.markReadOnVisible,
                        targetKind: committedTargetKind,
                        viewportDiagnostics: diagnostics,
                        storeQueryCount: preparedFrame.metrics.storeQueryCount,
                        mainThreadStoreQueryCount:
                            preparedFrame.metrics.mainThreadStoreQueryCount,
                        fullScanCount: preparedFrame.metrics.fullScanCount,
                        maxCandidateCount: preparedFrame.metrics.maxCandidateCount,
                        preparedOnMainThread:
                            preparedFrame.metrics.preparedOnMainThread,
                        mappedOnMainThread: mappedOnMainThread,
                        realDatasourceApplyCount:
                            self.initialFirstContentApplyCount,
                        atomicLayoutCommitCount: diagnostics.forcedLayoutCount,
                        realRowCount: mappingResult.datasource.lazy.filter {
                            !$0.isFakeMessage
                        }.count,
                        bootstrapRequestCount:
                            self.initialBootstrapQueryId == nil ? 0 : 1,
                        bootstrapFinalCount:
                            self.didReceiveInitialBootstrapEndPage ? 1 : 0,
                        bootstrapDeliveredMessageCount:
                            self.initialBootstrapResultCount ?? 0,
                        bootstrapPersistedMessageCount:
                            self.initialBootstrapPersistedRowsForQuery ?? 0,
                        finalNewerLiveEdgeReached:
                            finalArchiveState?.newerLiveEdgeReached ?? false,
                        finalOlderArchiveEndReached:
                            finalArchiveState?.fullArchiveLoaded ?? false,
                        finalFullArchiveLoaded:
                            preparedFrame.unreadMetadata
                                .initialFrameReadinessProof?
                                .chatFullArchiveLoaded ?? false
                    )
                )
#endif
                if abortTerminalForDeferredReplacement() {
                    return
                }
                self.lastBootstrapAtomicRevealPlan = ChatBootstrapAtomicRevealPlan.resolve(
                    previous: previousBootstrapState,
                    destinationRowCount: mappingResult.datasource.count
                )
                let committedLoadingState =
                    ChatInitialFrameLogicalCommitStatePolicy.loadingState(
                        previous: previousBootstrapState,
                        committedItemsAreEmpty: committedSnapshot.items.isEmpty,
                        hasTrustedPersistedBootstrapPage:
                            hasTrustedPersistedBootstrapPage
                    )
                self.allowsBootstrapFailureFallback =
                    committedLoadingState.showsRetry
                self.appliedBootstrapLoadingState = committedLoadingState
                self.preservesBootstrapFailureOverlayUntilRetryCommit = false
                self.setBootstrapFailureVisible(
                    committedLoadingState.showsRetry
                )
                if abortTerminalForDeferredReplacement() {
                    return
                }
                self.setSkeletonVisible(false)
                if abortTerminalForDeferredReplacement() {
                    return
                }
                self.setDatasourceLoadingEnabled(true)
                if abortTerminalForDeferredReplacement() {
                    return
                }
                self.setShouldShowInitialMessage(
                    committedSnapshot.items.isEmpty &&
                        !committedLoadingState.showsRetry
                )
                if abortTerminalForDeferredReplacement() {
                    return
                }
                self.rebuildUnreadMentionItems()
                if abortTerminalForDeferredReplacement() {
                    return
                }

                ConnectionDiagnosticsLogger.log(
                    event: "chat_anchor_local_first_frame_committed",
                    stream: .primary,
                    jid: nil,
                    details: [
                        "source": descriptor.request?.source.rawValue ?? "default",
                        "anchorAligned": {
                            if case .anchor = preparedFrame.alignment { return true }
                            return false
                        }(),
                        "residentAtLiveTail": committedSnapshot.state.isResidentAtLiveTail,
                        "realMessageCount": mappingResult.datasource.lazy.filter { !$0.isFakeMessage }.count
                    ]
                )
                ChatArchiveDebugTrace.log("chatInitialLocalFirstFramePrepared", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("target", String(describing: descriptor.target)),
                    ("messageCount", preparedFrame.metrics.preparedMessageCount),
                    ("storeQueryCount", preparedFrame.metrics.storeQueryCount),
                    ("mainThreadStoreQueryCount",
                     preparedFrame.metrics.mainThreadStoreQueryCount),
                    ("fullScanCount", preparedFrame.metrics.fullScanCount),
                    ("maxCandidateCount", preparedFrame.metrics.maxCandidateCount),
                    ("preparedOnMainThread", preparedFrame.metrics.preparedOnMainThread),
                    ("contentApplyCount", self.initialFirstContentApplyCount)
                ])

                let realRowCount = mappingResult.datasource.lazy.filter { !$0.isFakeMessage }.count
                let skeletonRowCount = mappingResult.datasource.count - realRowCount
                let bottomDistance = ChatTailAppendBottomPinPolicy.bottomDistance(
                    contentHeight: self.messagesCollectionView.contentSize.height,
                    viewportHeight: self.messagesCollectionView.bounds.height,
                    contentInsets: self.messagesCollectionView.contentInset,
                    contentOffsetY: self.messagesCollectionView.contentOffset.y
                )
                let targetKind: String
                switch preparedFrame.alignment {
                case .bottom:
                    targetKind = committedSnapshot.items.isEmpty ? "empty" : "latest"
                case .anchor:
                    targetKind = "anchor"
                }
                ChatArchiveDebugTrace.log("chatInitialFramePresentationCommitted", [
                    ("targetKind", targetKind),
                    ("realRows", realRowCount),
                    ("skeletonRows", skeletonRowCount),
                    ("visualCommitCount", 1),
                    ("attemptCount", presentationAttemptCount),
                    ("alignmentResult", "committed"),
                    ("bottomDistanceMilliPoints", Int(bottomDistance * 1_000)),
                    ("anchorErrorMilliPoints", Int((diagnostics.anchorError ?? 0) * 1_000)),
                    ("finalAlignmentCorrectionCount", diagnostics.finalAlignmentCorrectionCount),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: presentationStartedAt))
                ])

                switch preparedFrame.alignment {
                case .bottom:
                    self.pendingForceLatestOpen = false
                    self.pendingForceLatestOpenAnimated = false
                    self.initialLatestOpenStabilizationState = committedSnapshot.items.isEmpty
                        ? .inactive
                        : .bottomAligned
                case .anchor(let primary, let archivedId):
                    if let request = descriptor.request {
                        self.finishPreparedLocalFirstFrameAnchor(
                            request: request,
                            primary: primary,
                            archivedId: archivedId,
                            transactionToken:
                                presentationAttempt.anchorTransactionToken,
                            presentationAttempt: presentationAttempt
                        )
                    }
                }
                if abortTerminalForDeferredReplacement() {
                    return
                }
                self.cancelInitialBootstrapTimeout()
                self.initialBootstrapPresentationDeadline = nil
                self.releaseInteractiveChatOpenGate()
                if abortTerminalForDeferredReplacement() {
                    return
                }
                self.resolvePendingBootstrapFirstFrameReadinessCompletionsIfPossible(
                    presentationAttempt: presentationAttempt
                )
                if abortTerminalForDeferredReplacement() {
                    return
                }
                self.finishInitialLocalFirstFramePreparation(
                    presentationAttempt: presentationAttempt
                )
                if abortTerminalForDeferredReplacement() {
                    return
                }
                if self.initialLocalFirstFrameTerminalizingAttempt ===
                    presentationAttempt {
                    self.initialLocalFirstFrameTerminalizingAttempt = nil
                }
                self.scheduleTimelineStoreObservationActivation()

            case .failed(let failure, _):
                applyPreparedFrame = nil
                if self.initialLocalFirstFrameTerminalizingAttempt ===
                    presentationAttempt {
                    self.initialLocalFirstFrameTerminalizingAttempt = nil
                }
                if presentationAttempt.ownsPerformancePresentingInterval,
                   let performanceTraceContext {
                    _ = self.chatOpenPerformanceTraceLifecycle.endPresenting(
                        context: performanceTraceContext,
                        terminal: .failed
                    )
                }
                rollbackPresentationState()
                if let mappingToken = presentationAttempt.mappingToken,
                   self.initialLocalFirstFrameMappingToken === mappingToken {
                    mappingToken.cancel()
                    self.initialLocalFirstFrameMappingToken = nil
                }
                self.initialLocalFirstFramePresentationOwnership = nil
                let failureKind: String
                switch failure {
                case .targetMissing:
                    failureKind = "targetMissing"
                case .alignmentUnresolved:
                    failureKind = "alignmentUnresolved"
                case .superseded:
                    failureKind = "superseded"
                }
                let recoveryAction =
                    ChatInitialFramePresentationFailureRecoveryPolicy.action(
                        failedDescriptor: descriptor,
                        previouslyRetriedDescriptor:
                            self.initialLocalFirstFramePresentationRetryDescriptor
                    )
                ChatArchiveDebugTrace.log("chatInitialFramePresentationFailed", [
                    ("targetKind", {
                        if case .anchor = preparedFrame.alignment { return "anchor" }
                        return "latest"
                    }()),
                    ("failureKind", failureKind),
                    ("attemptCount", presentationAttemptCount),
                    ("willRemap", recoveryAction == .remapFreshGeneration),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: presentationStartedAt))
                ])
                // `applyChatDatasource` has already restored the exact
                // committed placeholder snapshot, layout cache, insets, and
                // offset inside the same visual transaction. Do not invoke
                // the high-level skeleton renderer here: that would create a
                // second placeholder generation with different geometry.
                switch recoveryAction {
                case .remapFreshGeneration:
                    self.initialLocalFirstFramePresentationRetryDescriptor =
                        descriptor
                    self.initialLocalFirstFramePhase = .idle
                    self.retryInitialLocalFirstFramePreparation()
                case .showTerminalRetry:
                    self.initialLocalFirstFramePresentationRetryDescriptor = nil
                    self.initialLocalFirstFramePhase =
                        .failedPresentation(descriptor)
                    self.preservesBootstrapFailureOverlayUntilRetryCommit = false
                    self.allowsBootstrapFailureFallback = true
                    self.applyBootstrapLoadingState(
                        .failure(fallback: .empty),
                        forceRender: true
                    )
                    self.cancelInitialBootstrapTimeout()
                    self.initialBootstrapPresentationDeadline = nil
                    self.releaseInteractiveChatOpenGate()
                    self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
                }
            }
        }

        applyPreparedFrame = { [weak self] in
            guard let self,
                  self.isCurrentInitialFramePresentationAttempt(
                    presentationAttempt,
                    phase: .presenting
                  ) else {
                return
            }
            let receipt: ChatOpenPerformancePresentationReceipt =
                committedSnapshot.items.isEmpty ? .empty : .content
            switch preparedFrame.alignment {
            case .bottom:
                self.performChatOpenPerformancePresentationTransaction(
                    receipt: receipt,
                    context: performanceTraceContext,
                    initialFramePresentationAttempt: presentationAttempt,
                    schedulesStableFrame: true
                ) {
                    self.applyChatDatasource(
                        mappingResult.datasource,
                        mode: .fullReload(),
                        animated: false,
                        invalidateLayout: false,
                        preparedLayouts: mappingResult.layoutSnapshot,
                        suppressDefaultBottomScroll: true,
                        forceBottomAlignmentTarget: committedSnapshot.items.isEmpty
                            ? nil
                            : .newestRealMessage,
                        presentationCommitMode: .atomicInitialFrame,
                        transactionCommitAuthorization: { [weak self] in
                            self?.ownsInitialFramePresentationAttemptForAtomicTransaction(
                                presentationAttempt
                            ) == true
                        },
                        transactionCompletion: handlePresentationResult
                    )
                }
            case .anchor(let primary, _):
                let targetHeight = mappingResult.layoutSnapshot
                    .layout(forPrimary: primary)?.cellSize.height ?? 0
                self.performChatOpenPerformancePresentationTransaction(
                    receipt: receipt,
                    context: performanceTraceContext,
                    initialFramePresentationAttempt: presentationAttempt,
                    schedulesStableFrame: true
                ) {
                    self.applyChatDatasource(
                        mappingResult.datasource,
                        mode: .fullReload(),
                        animated: false,
                        invalidateLayout: false,
                        preparedLayouts: mappingResult.layoutSnapshot,
                        suppressDefaultBottomScroll: true,
                        applyCategory: .default,
                        anchorRestorePhase: .applyTransaction,
                        anchorPrimary: primary,
                        restoreAnchor: ChatHistoryPageAnchor(
                            primary: primary,
                            viewportRelativeMinY: ChatAnchorCenteringPolicy.viewportRelativeMinY(
                                viewportHeight: self.messagesCollectionView.bounds.height,
                                targetHeight: targetHeight
                            )
                        ),
                        presentationCommitMode: .atomicInitialFrame,
                        transactionCommitAuthorization: { [weak self] in
                            self?.ownsInitialFramePresentationAttemptForAtomicTransaction(
                                presentationAttempt
                            ) == true
                        },
                        transactionCompletion: handlePresentationResult
                    )
                }
            }
        }
        applyPreparedFrame?()
    }

    internal func retryInitialLocalFirstFramePreparation() {
        guard !self.isStackedNavigationPresentationPreparationCancelled else {
            return
        }
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.initialLocalFirstFrameRetryScheduledForTests?()
#endif
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isStackedNavigationPresentationPreparationCancelled else {
                return
            }
            self.loadInitialDatasource(
                performPendingOpenMessageRequest: self.initialLocalFirstFrameShouldPerformPendingRequest
            )
        }
    }

    private func finishInitialLocalFirstFramePreparation(
        presentationAttempt: ChatInitialFramePresentationAttempt? = nil
    ) {
        let completions = self.initialLocalFirstFrameCompletions
        self.initialLocalFirstFrameCompletions.removeAll(keepingCapacity: false)
        let shouldPerformPendingRequest = self.initialLocalFirstFrameShouldPerformPendingRequest
        self.initialLocalFirstFrameShouldPerformPendingRequest = false
        for (index, completion) in completions.enumerated() {
            if let presentationAttempt,
               !self.isInitialFramePresentationAttemptSemanticallyCurrent(
                    presentationAttempt
               ) {
                self.initialLocalFirstFrameCompletions.append(
                    contentsOf: completions[index...]
                )
                return
            }
            completion()
        }
        if let presentationAttempt,
           !self.isInitialFramePresentationAttemptSemanticallyCurrent(
                presentationAttempt
           ) {
            return
        }
        if shouldPerformPendingRequest {
            self.performPendingOpenMessageRequestIfNeeded()
        }
        if self.pendingArchiveObserverRefresh,
           !ChatInitialFrameObserverRefreshBarrierPolicy.shouldDefer(
                phase: self.initialLocalFirstFramePhase,
                hasCommittedTimelinePresentation:
                    self.hasCommittedTimelinePresentationInCurrentLifecycle
           ) {
            let displayedNewestPrimary = self.datasource.last(where: { !$0.isFakeMessage })?.primary
            let residentNewestPrimary = self.timelineSession?.snapshot.items.last?.primary
            switch ChatInitialFramePendingObserverRefreshPolicy.action(
                displayedNewestPrimary: displayedNewestPrimary,
                residentNewestPrimary: residentNewestPrimary
            ) {
            case .cancelAlreadyCurrent:
                self.cancelPendingArchiveObserverRefresh(reason: "initialFirstFrameAlreadyCurrent")
            case .flushNewerTail:
                _ = self.flushPendingArchiveObserverRefreshIfPossible(
                    reason: "initialFirstFrameCommitted"
                )
            }
        }
    }

#if DEBUG || CHAT_PERFORMANCE_LAB
    /// Exercises the real terminal replay reducer without admitting archive
    /// transport in focused ownership tests.
    internal func finishInitialLocalFirstFramePreparationForTesting() {
        self.finishInitialLocalFirstFramePreparation()
    }
#endif

    @discardableResult
    private func finishInitialLocalFirstFramePreparationIfPresentationIsReady() -> Bool {
        guard self.isCommittedStackedNavigationFirstFrameReady else {
            return false
        }
        self.finishInitialLocalFirstFramePreparation()
        return true
    }

    private func finishInitialLocalFirstFramePreparationWhenPresentationIsReady() {
        if self.finishInitialLocalFirstFramePreparationIfPresentationIsReady() {
            return
        }
        self.whenBootstrapFirstFramePresentationIsReady { [weak self] in
            self?.finishInitialLocalFirstFramePreparation()
        }
    }

    /// A source whose message anchor is intentionally suppressed still owns
    /// the stacked-open completion after replacing an in-flight typed frame.
    /// The force-latest path publishes through the normal loaded datasource;
    /// bridge that presentation back to the initial-frame completion gate so
    /// the navigation preparation cannot remain latched forever.
    internal func finishInitialFramePreparationAfterSuppressedOpenRequest() {
        self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
    }

    internal var isCommittedStackedNavigationFirstFrameReady: Bool {
        if case .presenting = self.initialLocalFirstFramePhase {
            // Visual state is complete, but the high-level content commit has
            // not published readiness or released the presentation gate yet.
            return false
        }
        let hasCommittedRealRows = self.hasCommittedRealContentInCurrentLifecycle &&
            self.datasource.contains { !$0.isFakeMessage }
        let hasCommittedEmptyState = self.hasCommittedTimelinePresentationInCurrentLifecycle &&
            self.datasource.isEmpty &&
            self.appliedBootstrapLoadingState?.viewState == .empty
        let showsDeterministicFailureFallback = self.appliedBootstrapLoadingState?.showsRetry == true &&
            !self.bootstrapFailureView.isHidden
        return ChatStackedFirstFrameReadinessPolicy.isReady(
            hasCommittedRealRows: hasCommittedRealRows,
            hasCommittedSkeletonRows: self.hasCommittedBootstrapSkeletonRows,
            hasCommittedEmptyState: hasCommittedEmptyState,
            showsDeterministicFailureFallback: showsDeterministicFailureFallback
        )
    }

    /// Skeleton rows are a valid receipt for releasing an animated push, but
    /// they are never terminal proof for an in-flight content preparation.
    private var hasCommittedTerminalNonSkeletonBootstrapPresentation: Bool {
        let hasCommittedRealRows = self.hasCommittedRealContentInCurrentLifecycle &&
            self.datasource.contains { !$0.isFakeMessage }
        let hasCommittedEmptyState = self.hasCommittedTimelinePresentationInCurrentLifecycle &&
            self.datasource.isEmpty &&
            self.appliedBootstrapLoadingState?.viewState == .empty
        let showsDeterministicFailureFallback = self.appliedBootstrapLoadingState?.showsRetry == true &&
            !self.bootstrapFailureView.isHidden
        return hasCommittedRealRows ||
            hasCommittedEmptyState ||
            showsDeterministicFailureFallback
    }

    internal func whenBootstrapFirstFramePresentationIsReady(
        _ completion: @escaping () -> Void
    ) {
        guard !self.isStackedNavigationPresentationPreparationCancelled else {
            return
        }
        if self.isCommittedStackedNavigationFirstFrameReady {
            completion()
            return
        }
        self.pendingBootstrapFirstFrameReadinessCompletions.append(completion)
    }

    internal func resolvePendingBootstrapFirstFrameReadinessCompletionsIfPossible(
        presentationAttempt: ChatInitialFramePresentationAttempt? = nil
    ) {
        guard self.isCommittedStackedNavigationFirstFrameReady,
              self.pendingBootstrapFirstFrameReadinessCompletions.isNotEmpty else {
            return
        }
        let completions = self.pendingBootstrapFirstFrameReadinessCompletions
        self.pendingBootstrapFirstFrameReadinessCompletions.removeAll(keepingCapacity: false)
        for (index, completion) in completions.enumerated() {
            if let presentationAttempt,
               !self.isInitialFramePresentationAttemptSemanticallyCurrent(
                    presentationAttempt
               ) {
                self.pendingBootstrapFirstFrameReadinessCompletions.append(
                    contentsOf: completions[index...]
                )
                return
            }
            completion()
        }
    }

    /// Seals real rows that were prepared before the navigation watchdog fired.
    /// Initial full reloads normally commit synchronously, but this also covers
    /// a targeted collection transaction whose completion crossed the timeout.
    @discardableResult
    internal func commitPreparedRealDatasourceAsFirstFrameSynchronouslyIfNeeded() -> Bool {
        assert(Thread.isMainThread, "First-frame datasource commits must run on main")
        guard self.datasource.contains(where: { !$0.isFakeMessage }),
              !self.hasCommittedRealContentInCurrentLifecycle else {
            return self.isCommittedStackedNavigationFirstFrameReady
        }
        guard !self.isChatDatasourceStructuralTransactionActive else {
            assertionFailure("Navigation fallback cannot nest a datasource reload inside batch updates")
            return false
        }

        let preparedDatasource = self.datasource
        self.cancelBootstrapSkeletonMappingJobs()
        self.appliedBootstrapLoadingState = .content
        self.preservesBootstrapFailureOverlayUntilRetryCommit = false
        self.setBootstrapFailureVisible(false)
        self.setSkeletonVisible(false)
        self.setDatasourceLoadingEnabled(true)
        self.setShouldShowInitialMessage(false)
        let performanceTraceContext = self.chatOpenPerformanceTraceContext
        if let performanceTraceContext {
            _ = self.chatOpenPerformanceTraceLifecycle.beginPresenting(
                context: performanceTraceContext
            )
        }
        self.performChatOpenPerformancePresentationTransaction(
            receipt: .content,
            context: performanceTraceContext,
            schedulesStableFrame: true
        ) {
            self.applyChatDatasource(
                preparedDatasource,
                mode: .fullReload(),
                animated: false,
                invalidateLayout: false,
                suppressDefaultBottomScroll: true,
                forceBottomAlignmentTarget: .newestRealMessage,
                presentationCommitMode: .atomicInitialFrame
            )
        }
        return self.isCommittedStackedNavigationFirstFrameReady
    }

    internal func applyBootstrapViewState(
        _ state: ChatBootstrapViewState,
        forceRender: Bool = false,
        synchronousSkeletonCommit: Bool = false
    ) {
        let loadingState: ChatBootstrapLoadingState
        switch state {
        case .skeleton:
            let resolved = currentBootstrapLoadingState()
            loadingState = effectiveInitialPresentationContext == .newlyCreatedGroup
                ? resolved
                : resolved.showsSkeleton ? resolved : .blockingArchive
        case .content:
            loadingState = .content
        case .empty:
            loadingState = .empty
        }
        applyBootstrapLoadingState(
            loadingState,
            forceRender: forceRender,
            synchronousSkeletonCommit: synchronousSkeletonCommit
        )
    }

    /// Activates the committed session's observer once UIKit has finished the
    /// current presentation pass. Realm's synchronous initial delivery then
    /// reconciles writes that landed while activation was being scheduled.
    private func scheduleTimelineStoreObservationActivation(
        authoritativeEmptyBaseline: Bool = false
    ) {
        guard let committedSession = self.timelineSession else {
            return
        }
        DispatchQueue.main.async { [weak self, weak committedSession] in
            guard let self,
                  let committedSession,
                  self.timelineSession === committedSession else {
                return
            }
            committedSession.activateStoreObservation(
                authoritativeEmptyBaseline: authoritativeEmptyBaseline
            )
        }
    }

    /// Publishes the authoritative empty timeline without re-entering local
    /// frame preparation. Once bootstrap committed `rsm-counter=0`, mapping
    /// an older skeleton snapshot is both unnecessary and capable of racing a
    /// late UIKit transaction back onto the screen.
    private func commitConsumedEmptyArchiveTerminalPresentation() {
        guard self.consumedEmptyArchiveTerminalKey ==
                self.initialBootstrapRequestKey,
              !self.datasource.contains(where: { !$0.isFakeMessage }) else {
            return
        }

        self.cancelBootstrapSkeletonMappingJobs()
        self.discardPendingInitialFrameLifecyclePresentation()
        self.revokeActivePostBootstrapInitialFrameAdmission()
        self.timelineSession?.cancelInitialFramePreparations()
        self.initialLocalFirstFrameMappingToken?.cancel()
        self.initialLocalFirstFrameMappingToken = nil
        if let attempt = self.initialLocalFirstFramePresentationOwnership?.attempt {
            self.revokeInitialFramePresentationAttempt(attempt)
        }
        self.initialLocalFirstFramePresentationRetryDescriptor = nil
        let terminalDescriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: self.pendingOpenMessageRequest,
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        self.initialLocalFirstFramePhase = .idle
        self.appliedBootstrapLoadingState = .empty
        self.allowsBootstrapFailureFallback = false
        self.preservesBootstrapFailureOverlayUntilRetryCommit = false
        self.setBootstrapFailureVisible(false)
        self.setSkeletonVisible(false)
        self.setDatasourceLoadingEnabled(true)
        self.setShouldShowInitialMessage(true)
        self.messagesCollectionView.isUserInteractionEnabled = true
        self.timelineInteractionState.unlock()

        if !self.datasource.isEmpty {
            self.performChatOpenPerformancePresentationTransaction(
                receipt: .empty,
                schedulesStableFrame: true
            ) {
                self.applyChatDatasource(
                    [],
                    mode: .fullReload(),
                    animated: false,
                    invalidateLayout: false,
                    suppressDefaultBottomScroll: true,
                    presentationCommitMode: .atomicInitialFrame
                )
            }
        }
        self.hasCommittedTimelinePresentationInCurrentLifecycle = true
        self.initialLocalFirstFramePhase = .committed(terminalDescriptor)
        self.scheduleTimelineStoreObservationActivation(
            authoritativeEmptyBaseline: true
        )
        self.cancelPendingArchiveObserverRefresh(
            reason: "authoritativeEmptyBootstrapTerminal"
        )
        self.resolvePendingBootstrapFirstFrameReadinessCompletionsIfPossible()
        self.finishInitialLocalFirstFramePreparationWhenPresentationIsReady()
    }

    internal func applyBootstrapLoadingState(
        _ requestedState: ChatBootstrapLoadingState,
        forceRender: Bool = false,
        synchronousSkeletonCommit: Bool = false,
        hasTrustedPersistedBootstrapPage: Bool = false,
        replacingConversationDatasource: Bool = false
    ) {
        let contextualRequestedState =
            ChatInitialPresentationContextPolicy.loadingState(
                standard: requestedState,
                context: self.effectiveInitialPresentationContext,
                localMessageCount: self.localHistoryMessageCountForBootstrap()
            )
        let archiveReadiness = ChatInitialBootstrapRequestCoordinator.shared
            .readiness(for: self.initialBootstrapRequestKey)
        let hasMaterializedContent =
            self.localHistoryMessageCountForBootstrap() > 0
        let hasConsumedDurableEmptyTerminal =
            self.consumedEmptyArchiveTerminalKey ==
                self.initialBootstrapRequestKey
        let terminalResolvedState =
            ChatCommittedArchiveTerminalPresentationPolicy.resolvedState(
                requested: contextualRequestedState,
                readiness: archiveReadiness,
                committedBoundaryMatchesCurrent: archiveReadiness.map(
                    self.committedArchiveReceiptMatchesCurrentBoundary
                ) ?? false,
                hasMaterializedContent: hasMaterializedContent,
                hasConsumedDurableEmptyTerminal:
                    hasConsumedDurableEmptyTerminal
            )
        let state = ChatBootstrapTerminalPresentationInvariant.resolvedState(
            requested: terminalResolvedState,
            hasCommittedTerminalPresentation:
                self.hasCommittedTimelinePresentationInCurrentLifecycle,
            hasMaterializedContent: hasMaterializedContent,
            isReplacingConversation: replacingConversationDatasource
        )
        if hasConsumedDurableEmptyTerminal {
            self.allowsBootstrapFailureFallback = false
            self.preservesBootstrapFailureOverlayUntilRetryCommit = false
        }
        if hasConsumedDurableEmptyTerminal,
           state == .empty {
            self.commitConsumedEmptyArchiveTerminalPresentation()
            return
        }
        if (contextualRequestedState.showsSkeleton || contextualRequestedState.showsRetry),
           !state.showsSkeleton,
           !state.showsRetry {
            // A terminal frame for this conversation is monotonic. Archive
            // boundary repair may continue, but it is nonblocking and cannot
            // acquire a second skeleton presentation. Reconcile every output
            // here even when the high-level state is already equal, because a
            // stale relay was the independent entrance behind the regression.
            ChatArchiveDebugTrace.log("bootstrapSkeletonSuppressedAfterTerminal", [
                ("hasMaterializedContent", state == .content),
                ("requestedTarget", contextualRequestedState == .blockingTarget)
            ])
            self.cancelBootstrapSkeletonMappingJobs()
            self.appliedBootstrapLoadingState = state
            self.preservesBootstrapFailureOverlayUntilRetryCommit = false
            self.setBootstrapFailureVisible(false)
            self.setSkeletonVisible(false)
            self.setDatasourceLoadingEnabled(true)
            self.setShouldShowInitialMessage(false)
            self.messagesCollectionView.isUserInteractionEnabled = true
            self.timelineInteractionState.unlock()
            if ChatArchiveWindowPresentationPolicy.shouldRunLegacyBootstrapRematerialization(
                    isArchiveEnginePresentationActive:
                        archiveEnginePresentationActive
               ),
               state == .content,
               !self.datasource.contains(where: { !$0.isFakeMessage }) {
                self.reloadInitialWindowAfterBootstrapIfNeeded(
                    force: true,
                    hasTrustedPersistedBootstrapPage:
                        hasTrustedPersistedBootstrapPage
                )
            }
            return
        }
        if ChatCommittedSkeletonBlockingTransitionPolicy.shouldApplyStateOnly(
            previous: appliedBootstrapLoadingState,
            next: state,
            hasCommittedExactSkeletonRows: hasCommittedExactBootstrapSkeletonRows,
            hasCommittedRealContent: hasCommittedRealContentInCurrentLifecycle
        ) {
            // The committed 30-row skeleton already owns the first frame.
            // A changed blocking reason is semantic state only: mapping,
            // layout, visibility and the viewport remain under that receipt.
            appliedBootstrapLoadingState = state
            return
        }
        guard ChatBootstrapStateApplicationPolicy.decision(
            previous: appliedBootstrapLoadingState,
            next: state,
            hasCommittedContent: hasCommittedRealContentInCurrentLifecycle,
            forceRender: forceRender,
            hasCommittedSkeletonRows: hasCommittedBootstrapSkeletonRows
        ) == .apply else {
            return
        }
        if state.showsRetry {
            allowsBootstrapFailureFallback = true
        }
        appliedBootstrapLoadingState = state
        let preservesRetryOverlay =
            preservesBootstrapFailureOverlayUntilRetryCommit &&
            !bootstrapFailureView.isHidden &&
            !state.showsRetry
        if !preservesRetryOverlay {
            setBootstrapFailureVisible(state.showsRetry)
        }

#if DEBUG || CHAT_PERFORMANCE_LAB
        if state.showsRetry,
           self.performanceFixtureAllowsSkeletonStableFrame,
           self.hasCommittedExactBootstrapSkeletonRows {
            // E11 exercises the real typed MAM failure reducer while proving
            // that the already committed placeholder is not remapped into an
            // empty/content datasource. Retry is an overlay on the identical
            // 30-row skeleton in this closed performance fixture only.
            self.setShouldShowInitialMessage(false)
            self.setSkeletonVisible(true)
            self.setDatasourceLoadingEnabled(false)
            self.messagesCollectionView.isUserInteractionEnabled = true
            self.timelineInteractionState.unlock()
            self.performOnMain { [weak self] in
                self?.resolvePendingBootstrapFirstFrameReadinessCompletionsIfPossible()
            }
            return
        }
#endif

        switch state.viewState {
        case .skeleton:
            self.setDatasourceLoadingEnabled(false)
            self.setShouldShowInitialMessage(false)
            self.setSkeletonVisible(true)
            if ChatBootstrapSkeletonRenderPolicy.shouldRenderSkeletonDatasource(
                forceRender: forceRender,
                isDatasourceEmpty: self.datasource.isEmpty,
                isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
            ) {
                if synchronousSkeletonCommit {
                    self.commitBootstrapSkeletonDatasourceSynchronously(
                        replacingConversationDatasource:
                            replacingConversationDatasource
                    )
                    break
                }
                let mappingJob = self.beginBootstrapSkeletonMappingJob()
                let generation = mappingJob.generation
                let cancellationToken = mappingJob.token
                let mappingContext = self.captureDatasourceMappingContext(
                    purpose: .bootstrapSkeleton
                )
                let animated = self.shouldAnimateInitialHistoryAppearance
                let conversationKey = self.chatTimelineConversationKey
                self.datasetMappingQueue.async { [weak self] in
                    guard let self, !cancellationToken.isCancelled else { return }
                    let mappingResult = self.mapDataset(
                        dataset: [],
                        context: mappingContext,
                        cancellationToken: cancellationToken
                    )
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              !mappingResult.wasCancelled,
                              !cancellationToken.isCancelled,
                              ChatBootstrapMappedSkeletonApplyPolicy.shouldApply(
                                generationMatches: generation == self.bootstrapSkeletonMappingGeneration,
                                conversationMatches: conversationKey == self.chatTimelineConversationKey,
                                loadingShowsSkeleton: self.appliedBootstrapLoadingState?.showsSkeleton == true,
                                skeletonVisibilityRequested: self.showSkeletonObserver.value,
                                hasCommittedRealContent: self.hasCommittedRealContentInCurrentLifecycle,
                                hasRealDatasourceRows: self.datasource.contains { !$0.isFakeMessage },
                                hasCommittedSkeletonRows: self.hasCommittedBootstrapSkeletonRows
                              ) else { return }
                        var schedulesStableFrame = false
#if DEBUG || CHAT_PERFORMANCE_LAB
                        schedulesStableFrame =
                            self.performanceFixtureAllowsSkeletonStableFrame
#endif
                        self.performChatOpenPerformancePresentationTransaction(
                            receipt: .skeleton,
                            schedulesStableFrame: schedulesStableFrame
                        ) {
                            self.applyChatDatasource(
                                mappingResult.datasource,
                                mode: .fullReload(),
                                animated: animated,
                                preparedLayouts: mappingResult.layoutSnapshot
                            )
                        }
                    }
                }
            }
        case .content, .empty:
            self.cancelBootstrapSkeletonMappingJobs()
            if state.showsRetry {
                self.setSkeletonVisible(false)
                self.setShouldShowInitialMessage(false)
                self.setDatasourceLoadingEnabled(true)
                self.messagesCollectionView.isUserInteractionEnabled = true
                self.timelineInteractionState.unlock()
            }
            // An empty retry fallback is already a complete, interactive
            // presentation. Starting a local first-frame preparation here
            // can replace it with skeleton while the timeline session is
            // still being installed. Content fallback still materializes its
            // stale local rows, with the retry overlay retained at commit.
            if !state.showsRetry || state.viewState == .content {
                self.reloadInitialWindowAfterBootstrapIfNeeded(
                    force: forceRender,
                    hasTrustedPersistedBootstrapPage: hasTrustedPersistedBootstrapPage
                )
            }
        }
        if state.showsRetry {
            self.performOnMain { [weak self] in
                self?.resolvePendingBootstrapFirstFrameReadinessCompletionsIfPossible()
            }
        }
    }

    @discardableResult
    internal func commitNewlyCreatedGroupEmptyFirstFrameSynchronouslyIfNeeded()
        -> Bool {
        assert(Thread.isMainThread, "First-frame datasource commits must run on main")
        guard effectiveInitialPresentationContext == .newlyCreatedGroup,
              !datasource.contains(where: { !$0.isFakeMessage }) else {
            return isCommittedStackedNavigationFirstFrameReady
        }

        cancelBootstrapSkeletonMappingJobs()
        appliedBootstrapLoadingState = .empty
        preservesBootstrapFailureOverlayUntilRetryCommit = false
        setBootstrapFailureVisible(false)
        setSkeletonVisible(false)
        setDatasourceLoadingEnabled(true)
        setShouldShowInitialMessage(true)
        messagesCollectionView.isUserInteractionEnabled = true
        timelineInteractionState.unlock()
        performChatOpenPerformancePresentationTransaction(
            receipt: .empty,
            schedulesStableFrame: true
        ) {
            applyChatDatasource(
                [],
                mode: .fullReload(),
                animated: false,
                invalidateLayout: false,
                suppressDefaultBottomScroll: true,
                presentationCommitMode: .standard
            )
        }
        hasCommittedTimelinePresentationInCurrentLifecycle = true
        hasCommittedBootstrapSkeletonPresentationInCurrentLifecycle = false
        scheduleTimelineStoreObservationActivation()
        resolvePendingBootstrapFirstFrameReadinessCompletionsIfPossible()
        return isCommittedStackedNavigationFirstFrameReady
    }

    private func commitBootstrapSkeletonDatasourceSynchronously(
        replacingConversationDatasource: Bool = false
    ) {
        assert(Thread.isMainThread, "First-frame skeleton commits must run on main")
        self.cancelBootstrapSkeletonMappingJobs()

        if !replacingConversationDatasource {
            // Navigation preparation has already installed the destination
            // bounds. Resolve them before prewarming ordinary first-frame
            // rows. A conversation replacement deliberately skips this pass:
            // laying out here would expose A once after B owns the controller.
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            self.messagesCollectionView.setNeedsLayout()
            self.messagesCollectionView.layoutIfNeeded()
        }

        let mappingContext = self.captureDatasourceMappingContext(
            purpose: .bootstrapSkeleton
        )
        let mappingResult = self.mapDataset(dataset: [], context: mappingContext)
        guard ChatBootstrapMappedSkeletonApplyPolicy.shouldApply(
            generationMatches: true,
            conversationMatches: true,
            loadingShowsSkeleton: self.appliedBootstrapLoadingState?.showsSkeleton == true,
            skeletonVisibilityRequested: self.showSkeletonObserver.value,
            hasCommittedRealContent: self.hasCommittedRealContentInCurrentLifecycle,
            hasRealDatasourceRows: !replacingConversationDatasource &&
                self.datasource.contains { !$0.isFakeMessage },
            hasCommittedSkeletonRows: self.hasCommittedBootstrapSkeletonRows
        ) else {
            return
        }
        var schedulesStableFrame = false
#if DEBUG || CHAT_PERFORMANCE_LAB
        schedulesStableFrame = self.performanceFixtureAllowsSkeletonStableFrame
#endif
        self.performChatOpenPerformancePresentationTransaction(
            receipt: .skeleton,
            schedulesStableFrame: schedulesStableFrame
        ) {
            self.applyChatDatasource(
                mappingResult.datasource,
                mode: .fullReload(),
                animated: false,
                invalidateLayout: false,
                preparedLayouts: mappingResult.layoutSnapshot,
                suppressDefaultBottomScroll: true,
                presentationCommitMode: replacingConversationDatasource
                    ? .atomicInitialFrame
                    : .standard
            )
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

    internal final func beginBootstrapSkeletonMappingJob() -> (
        generation: Int,
        token: ChatDatasetMappingCancellationToken
    ) {
        self.bootstrapSkeletonMappingGeneration += 1
        let generation = self.bootstrapSkeletonMappingGeneration
        return (
            generation,
            self.bootstrapSkeletonMappingJobCoordinator.begin(generation: generation)
        )
    }

    internal final func cancelBootstrapSkeletonMappingJobs() {
        self.bootstrapSkeletonMappingGeneration += 1
        self.bootstrapSkeletonMappingJobCoordinator.cancelAll()
    }

    /// Memory pressure may cancel only replaceable dataset work. An initial
    /// frame that is being prepared, authorized as a compound post-bootstrap
    /// commit, or waiting for foreground publication owns a one-shot bootstrap
    /// receipt and therefore has no equivalent replay after cancellation.
    internal var shouldPreserveInitialFramePipelineDuringMemoryPressure: Bool {
        if self.pendingInitialFrameLifecyclePresentation != nil ||
            self.activePostBootstrapInitialFrameAdmission != nil ||
            self.activeAnchorPersistenceMaterializationAdmission != nil {
            return true
        }
        switch self.initialLocalFirstFramePhase {
        case .preparing, .presenting:
            return true
        case .idle,
             .committed,
             .blockedArchiveBootstrap,
             .blockedMissingTarget,
             .failedPresentation:
            return false
        }
    }

    internal final func cancelDatasetMappingJobs() {
        self.revokeActivePostBootstrapInitialFrameAdmission()
        self.revokeActiveAnchorPersistenceMaterializationAdmission()
        self.discardPendingInitialFrameLifecyclePresentation()
        self.datasetMappingGeneration += 1
        self.datasetMappingJobCoordinator.cancelAll()
        self.cancelBootstrapSkeletonMappingJobs()
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

        if context.purpose.rendersBootstrapSkeleton {
            var datasource: [Datasource] = []
            for descriptor in context.skeletonDescriptors {
                guard cancellationToken?.shouldProcessNextRow() ?? true else { break }
                let skeletonText = NSMutableAttributedString(attributedString: descriptor.text)
                skeletonText.addAttributes(
                    context.bodyTextAttributes,
                    range: NSRange(location: 0, length: skeletonText.length)
                )
                datasource.append(Datasource(
                    primary: descriptor.primary,
                    jid: context.jid,
                    owner: context.owner,
                    outgoing: descriptor.outgoing,
                    sender: context.opponentSender,
                    messageId: descriptor.messageId,
                    sentDate: descriptor.sentDate,
                    editDate: nil,
                    kind: .skeleton(skeletonText),
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
                ))
            }
            if cancellationToken?.isCancelled == true {
                return ChatDatasourceMappingResult(
                    datasource: datasource,
                    editedMessagePrimariesNeedingLayoutInvalidation: [],
                    layoutSnapshot: context.layoutReuseSnapshot,
                    wasCancelled: true
                )
            }
            let layoutSnapshot = ChatMessageLayoutPrewarmer.prewarm(
                items: datasource,
                context: context.layoutContext,
                reuse: context.layoutReuseSnapshot,
                capacity: context.layoutCacheCapacity,
                operationCounter: context.layoutOperationCounter,
                shouldContinue: { cancellationToken?.isCancelled != true }
            )
            return ChatDatasourceMappingResult(
                datasource: datasource,
                editedMessagePrimariesNeedingLayoutInvalidation: [],
                layoutSnapshot: cancellationToken?.isCancelled == true
                    ? context.layoutReuseSnapshot
                    : layoutSnapshot,
                wasCancelled: cancellationToken?.isCancelled == true
            )
        }
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

    internal final func performInteractiveHistoryPaging(direction: ChatHistoryPageDirection) {
        guard self.timelineInteractionState.isUnlocked,
              self.canAdmitBoundaryPagingAfterInitialFrame else {
            return
        }
        _ = self.startLocalHistoryPagingPreparation(
            direction: direction,
            motionState: .resting,
            trigger: "direct",
            boundaryVisibilityRequirement: .visibleBoundary
        )
    }

    #if DEBUG || CHAT_PERFORMANCE_LAB
    /// The performance fixture owns an explicit Load older/newer action. It
    /// exercises the same production preparation and persistence pipeline,
    /// but does not pretend that the scroll boundary which motivated an
    /// ordinary prefetch is currently visible.
    @discardableResult
    internal final func performPerformanceFixtureInteractiveHistoryPaging(
        direction: ChatHistoryPageDirection
    ) -> Bool {
        guard self.timelineInteractionState.isUnlocked,
              self.canAdmitBoundaryPagingAfterInitialFrame else {
            return false
        }
        return self.startLocalHistoryPagingPreparation(
            direction: direction,
            motionState: .resting,
            trigger: "performance-fixture-explicit",
            boundaryVisibilityRequirement: .explicitFixtureAction
        ) != .none
    }
    #endif

    internal final func performInteractiveHistoryPaging(
        preparation: ChatInteractiveHistoryPagingPreparation
    ) {
        guard self.timelineInteractionState.isUnlocked,
              self.canAdmitBoundaryPagingAfterInitialFrame else {
            return
        }
        FeedbackManager.shared.generate(feedback: .success)
        self.setDatasourceLoadingEnabled(false)
        self.timelineInteractionState.locked = true
        self.loadDatasource(preparation: preparation) { _ in
            let window = self.visibleWindow()
            self.finishPagingInteraction(
                window: window,
                shouldApplyWindow: false,
                direction: preparation.direction,
                animated: false
            )
        }
    }

    internal final func onTouchStartPage(direction: ChatHistoryPageDirection) {
        self.performInteractiveHistoryPaging(direction: direction)
    }

    internal final func onTouchEndPage(direction: ChatHistoryPageDirection) {
        self.performInteractiveHistoryPaging(direction: direction)
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

    internal var isArchiveObserverRefreshPressureActive: Bool {
        if case .presenting = self.initialLocalFirstFramePhase {
            return true
        }
        let blocksForInitialBootstrap =
            self.isInitialBootstrapInFlight &&
            !self.hasCommittedRealContentInCurrentLifecycle
        return blocksForInitialBootstrap ||
        self.timelineInteractionState.isLoading ||
        self.interactiveHistoryPageLoadContext != nil ||
        self.virtualTimelineState.activeRemoteLoad != nil ||
        self.activeChatHistoryLoadActivityKeys.isNotEmpty
    }

    internal var canAdmitBoundaryPagingAfterInitialFrame: Bool {
        ChatInitialFrameBoundaryPagingAdmissionPolicy.shouldAdmit(
            phase: self.initialLocalFirstFramePhase,
            hasCommittedTimelinePresentation:
                self.hasCommittedTimelinePresentationInCurrentLifecycle,
            hasRealDatasourceRows:
                self.datasource.contains { !$0.isFakeMessage },
            isShowingSkeleton: self.showSkeletonObserver.value
        )
    }

    internal var hasActiveSearchNavigationTransaction: Bool {
        self.pendingOpenMessageRequest != nil ||
        self.activeAnchorExecutionState != nil ||
        self.searchResultNavigationState.isBusy
    }

    internal func handleTimelineSessionRefresh(
        observedGeneration: UInt64? = nil
    ) {
        if let observedGeneration,
           var executionState = self.activeAnchorExecutionState {
            let barrierBaselineGeneration = [
                executionState.remoteFetchSnapshotGenerationAtStart,
                executionState.contextPrefetchSnapshotGenerationAtStart
            ].compactMap { $0 }.max()
            if let barrierBaselineGeneration,
               observedGeneration <= barrierBaselineGeneration {
                self.logArchiveObserverRefreshBackpressure(
                    action: "ignoreAnchorBaselineGeneration"
                )
                return
            }
            if executionState.isWaitingForObserverSync,
               let remoteBaselineGeneration =
                executionState.remoteFetchSnapshotGenerationAtStart,
               observedGeneration > remoteBaselineGeneration {
                executionState.isWaitingForObserverSync = false
                self.activeAnchorExecutionState = executionState
                self.syncAnchorExecutionFlags()
            }
        }
        if case .presenting = self.initialLocalFirstFramePhase {
            if let observedGeneration {
                let disposition =
                    self.observerRefreshGenerationCoalescer.receive(
                        generation: observedGeneration,
                        motionState: .tracking
                    )
                guard disposition != .ignored else {
                    return
                }
            }
            self.pendingArchiveObserverRefresh = true
            self.archiveObserverRefreshWorkItem?.cancel()
            self.archiveObserverRefreshWorkItem = nil
            self.logArchiveObserverRefreshBackpressure(action: "deferUntilInitialFrameCommit")
            return
        }
        let motionState = self.currentScrollMotionState()
        if let observedGeneration {
            let flushedGeneration =
                self.observerRefreshGenerationCoalescer.flush(
                    motionState: motionState
                )
            if flushedGeneration != nil {
                self.pendingArchiveObserverRefresh = false
                self.archiveObserverRefreshWorkItem?.cancel()
                self.archiveObserverRefreshWorkItem = nil
                self.scrollFrameOperationCounter.record(.observerRefreshCommits)
            }
            let disposition = self.observerRefreshGenerationCoalescer.receive(
                generation: observedGeneration,
                motionState: motionState
            )
            switch disposition {
            case .ignored where flushedGeneration == nil:
                return
            case .deferred:
                self.pendingArchiveObserverRefresh = true
                self.archiveObserverRefreshWorkItem?.cancel()
                self.archiveObserverRefreshWorkItem = nil
                self.logArchiveObserverRefreshBackpressure(
                    action: "deferNewestGenerationUntilScrollRest"
                )
                return
            case .applyImmediately, .ignored:
                break
            }
        } else {
            if !self.showSkeletonObserver.value,
               motionState.isMoving {
                let generation = self.timelineSession?.snapshot.generation ?? 0
                let disposition = self.observerRefreshGenerationCoalescer.receive(
                    generation: generation,
                    motionState: motionState
                )
                guard disposition == .deferred else {
                    return
                }
                self.pendingArchiveObserverRefresh = true
                self.archiveObserverRefreshWorkItem?.cancel()
                self.archiveObserverRefreshWorkItem = nil
                self.logArchiveObserverRefreshBackpressure(
                    action: "deferNewestGenerationUntilScrollRest"
                )
                return
            }
            if self.observerRefreshGenerationCoalescer.flush(
                motionState: motionState
            ) != nil {
                self.pendingArchiveObserverRefresh = false
                self.archiveObserverRefreshWorkItem?.cancel()
                self.archiveObserverRefreshWorkItem = nil
                self.scrollFrameOperationCounter.record(.observerRefreshCommits)
            }
        }
        if let snapshot = self.timelineSession?.snapshot,
           case .preserveViewport(let showNewMessageBadge) = ChatIncrementalViewportPolicy.decision(
               insertedItems: [],
               wasNearBottom: false,
               isResidentAtLiveTail: snapshot.state.isResidentAtLiveTail,
               nonResidentIncomingCount: snapshot.residentChangeSet?.nonResidentIncomingPrimaries.count ?? 0
           ),
           showNewMessageBadge,
           !self.shouldShowScrollDownButton.value {
            self.shouldShowScrollDownButton.accept(true)
        }
        self.refreshPinnedMessagePanelIfNeeded()
        if self.showSkeletonObserver.value {
            let didRevealBootstrapContent = self.revealInitialBootstrapContentIfAvailable()
            _ = self.completeInitialBootstrapIfNeeded()
            if !didRevealBootstrapContent {
                self.scheduleInitialBootstrapLocalHistoryFallbackIfNeeded()
            }
            self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
            return
        }
        if self.hasActiveSearchNavigationTransaction,
           self.applyObserverRefreshBackpressureIfNeeded() {
            return
        }
        if self.timelineInteractionState.locked {
            _ = self.tryFinishInteractiveHistoryPageLoadIfReady()
            return
        }
        if self.applyObserverRefreshBackpressureIfNeeded() {
            return
        }
        self.didReceiveChangeset()
    }

    @discardableResult
    internal func applyObserverRefreshBackpressureIfNeeded() -> Bool {
        let action = ChatObserverRefreshBackpressurePolicy.action(
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder,
            isHistoryPressureActive: self.isArchiveObserverRefreshPressureActive,
            motionState: self.currentScrollMotionState(),
            hasScheduledRefresh: self.archiveObserverRefreshWorkItem != nil,
            isBlockedBySearchNavigation: self.hasActiveSearchNavigationTransaction
        )

        switch action {
        case .applyImmediately:
            return false
        case .deferUntilScrollRest:
            self.pendingArchiveObserverRefresh = true
            self.archiveObserverRefreshWorkItem?.cancel()
            self.archiveObserverRefreshWorkItem = nil
            self.logArchiveObserverRefreshBackpressure(action: "deferUntilScrollRest")
            return true
        case .deferUntilSearchNavigationCommit:
            self.pendingArchiveObserverRefresh = true
            self.archiveObserverRefreshWorkItem?.cancel()
            self.archiveObserverRefreshWorkItem = nil
            self.logArchiveObserverRefreshBackpressure(action: "deferUntilSearchNavigationCommit")
            self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
            return true
        case .keepCoalesced:
            self.pendingArchiveObserverRefresh = true
            self.logArchiveObserverRefreshBackpressure(action: "keepCoalesced")
            return true
        case .scheduleCoalesced:
            self.pendingArchiveObserverRefresh = true
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.archiveObserverRefreshWorkItem = nil
                self.flushPendingArchiveObserverRefreshIfPossible(reason: "coalescedTimer")
            }
            self.archiveObserverRefreshWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + ChatObserverRefreshBackpressurePolicy.coalescingDelay,
                execute: workItem
            )
            self.logArchiveObserverRefreshBackpressure(action: "scheduleCoalesced")
            return true
        }
    }

    @discardableResult
    internal func flushPendingArchiveObserverRefreshIfPossible(reason: String) -> Bool {
        if ChatInitialFrameObserverRefreshBarrierPolicy.shouldDefer(
            phase: self.initialLocalFirstFramePhase,
            hasCommittedTimelinePresentation:
                self.hasCommittedTimelinePresentationInCurrentLifecycle
        ) {
            self.pendingArchiveObserverRefresh = true
            self.logArchiveObserverRefreshBackpressure(
                action: "flushDeferredForInitialFrame:\(reason)"
            )
            return false
        }
        let motionState = self.currentScrollMotionState()
        let action = ChatObserverRefreshBackpressurePolicy.flushAction(
            hasPendingRefresh: self.pendingArchiveObserverRefresh,
            motionState: motionState,
            isBlockedBySearchNavigation: self.hasActiveSearchNavigationTransaction
        )

        switch action {
        case .none:
            return false
        case .keepPending:
            self.logArchiveObserverRefreshBackpressure(action: "flushDeferred:\(reason)")
            return false
        case .flush:
            if self.observerRefreshGenerationCoalescer.flush(motionState: motionState) != nil {
                self.scrollFrameOperationCounter.record(.observerRefreshCommits)
                self.refreshPinnedMessagePanelIfNeeded()
            }
            self.archiveObserverRefreshWorkItem?.cancel()
            self.archiveObserverRefreshWorkItem = nil
            self.pendingArchiveObserverRefresh = false
            self.logArchiveObserverRefreshBackpressure(action: "flush:\(reason)")
            if self.timelineInteractionState.locked {
                _ = self.tryFinishInteractiveHistoryPageLoadIfReady()
                return true
            }
            self.didReceiveChangeset()
            return true
        }
    }

    internal func cancelPendingArchiveObserverRefresh(reason: String) {
        guard self.pendingArchiveObserverRefresh || self.archiveObserverRefreshWorkItem != nil else {
            return
        }
        self.archiveObserverRefreshWorkItem?.cancel()
        self.archiveObserverRefreshWorkItem = nil
        self.pendingArchiveObserverRefresh = false
        self.observerRefreshGenerationCoalescer.cancel()
        self.logArchiveObserverRefreshBackpressure(action: "cancel:\(reason)")
    }

    private func logArchiveObserverRefreshBackpressure(action: String) {
        ChatArchiveDebugTrace.log("observerRefreshBackpressure", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("action", action),
            ("isInitialBootstrapInFlight", self.isInitialBootstrapInFlight),
            ("isPageLoading", self.timelineInteractionState.isLoading),
            ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
            ("interactiveQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
            ("scrollMotionState", self.currentScrollMotionState().rawValue),
            ("pendingRefresh", self.pendingArchiveObserverRefresh),
            ("scheduledRefresh", self.archiveObserverRefreshWorkItem != nil),
            ("datasourceCount", self.datasource.count),
            ("residentCount", self.timelineSession?.snapshot.items.count ?? -1)
        ])
    }

    internal final func loadInitialDatasource(
        performPendingOpenMessageRequest: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        if self.archiveEnginePresentationActive {
            self.startArchiveEnginePresentationIfNeeded()
            completion?()
            return
        }
        self.recordChatOpenTimingInitialDatasourceLoadStarted(
            performPendingOpenMessageRequest: performPendingOpenMessageRequest
        )
        self.prepareInitialLocalFirstFrame(
            chatInstance: nil,
            performPendingOpenMessageRequest: performPendingOpenMessageRequest
        ) { [weak self] in
            guard let self else {
                completion?()
                return
            }
            let finalState: ChatBootstrapViewState
            if self.showSkeletonObserver.value {
                finalState = .skeleton
            } else if self.datasource.contains(where: { !$0.isFakeMessage }) {
                finalState = .content
            } else {
                finalState = .empty
            }
            self.recordChatOpenTimingInitialDatasourceLoadFinished(
                bootstrapState: finalState,
                performPendingOpenMessageRequest: performPendingOpenMessageRequest
            )
            completion?()
        }
    }

    private func armedRemoteSnapshot(
        from snapshot: ChatTimelineSnapshot,
        queryId: String,
        direction: ChatHistoryPageDirection,
        decision: ChatHistoryPagingLoadDecision,
        cursorId: String?
    ) -> ChatTimelineSnapshot {
        let stateWithoutPlaceholder = snapshot.state.withRuntimePlaceholder(nil)
        let armedState = ChatVirtualTimelineState(
            conversationKey: stateWithoutPlaceholder.conversationKey,
            segments: stateWithoutPlaceholder.segments,
            oldest: stateWithoutPlaceholder.oldest,
            newest: stateWithoutPlaceholder.newest,
            residentPrimaryKeys: stateWithoutPlaceholder.residentPrimaryKeys,
            residentArchivedIds: stateWithoutPlaceholder.residentArchivedIds,
            activeRemoteLoad: ChatTimelineRemoteLoad(
                queryId: queryId,
                direction: direction,
                decision: decision,
                cursorId: cursorId
            ),
            activePlaceholder: nil,
            isResidentAtLiveTail: stateWithoutPlaceholder.isResidentAtLiveTail
        )
        return ChatTimelineSnapshot(
            items: snapshot.items,
            state: armedState,
            loadingState: .none,
            loadDecision: decision,
            anchorRestore: snapshot.anchorRestore,
            localOlderCandidateCount: snapshot.localOlderCandidateCount,
            pageSize: snapshot.pageSize,
            shortLocalRemainderRemoteFirst: snapshot.shortLocalRemainderRemoteFirst
        )
    }

    private func makeLocalHistoryPagingIntent(
        direction: ChatHistoryPageDirection,
        motionState: ChatScrollMotionState,
        boundaryVisibilityRequirement:
            ChatBoundaryPagingVisibilityRequirement
    ) -> ChatLocalHistoryPagingIntent? {
        guard let residentSnapshot = self.timelineSession?.snapshot,
              residentSnapshot.state.activeRemoteLoad == nil else {
            return nil
        }
        let currentWindow = self.visibleWindow()
        let requestedWindow = self.datasetCoordinator.nextWindow(
            from: currentWindow,
            direction: direction
        )
        guard !requestedWindow.isEmpty else {
            return nil
        }
        return ChatLocalHistoryPagingIntent(
            id: "local-page-intent-\(NanoID.new(6))",
            direction: direction,
            conversationKey: self.chatTimelineConversationKey,
            baseGeneration: residentSnapshot.generation,
            baseVirtualState: residentSnapshot.state,
            currentWindow: currentWindow,
            requestedWindow: requestedWindow,
            deferUntilScrollRest: motionState.isMoving,
            boundaryVisibilityRequirement: boundaryVisibilityRequirement
        )
    }

    @discardableResult
    private func startLocalHistoryPagingPreparation(
        direction: ChatHistoryPageDirection,
        motionState: ChatScrollMotionState,
        trigger: String,
        boundaryVisibilityRequirement:
            ChatBoundaryPagingVisibilityRequirement
    ) -> ChatBoundaryPagingExecutionAction {
        guard let session = self.timelineSession,
              let intent = self.makeLocalHistoryPagingIntent(
                direction: direction,
                motionState: motionState,
                boundaryVisibilityRequirement:
                    boundaryVisibilityRequirement
              ) else {
            self.clearPendingLocalHistoryPagingPreparation()
            return .none
        }

        if let pending = self.pendingLocalHistoryPagingIntent,
           pending.direction == intent.direction,
           pending.conversationKey == intent.conversationKey,
           pending.baseGeneration == intent.baseGeneration,
           pending.boundaryVisibilityRequirement ==
                intent.boundaryVisibilityRequirement {
            return .prepareLocal(direction)
        }
        if let prepared = self.pendingPreparedLocalHistoryPage,
           prepared.direction == direction,
           prepared.conversationKey == intent.conversationKey,
           prepared.preparedPage.baseGeneration == intent.baseGeneration,
           prepared.boundaryVisibilityRequirement ==
                intent.boundaryVisibilityRequirement {
            return .prepareLocal(direction)
        }
        if self.pendingDeferredRemoteHistoryDirection == direction,
           self.pendingDeferredRemoteHistoryPreparation?.preparedPage.baseGeneration == intent.baseGeneration,
           self.pendingDeferredRemoteHistoryPreparation?
                .boundaryVisibilityRequirement ==
                    intent.boundaryVisibilityRequirement {
            return motionState.isMoving ? .deferRemote(direction) : .applyNow(direction)
        }

        self.clearPendingLocalHistoryPagingPreparation()
        self.pendingLocalHistoryPagingIntent = intent
        let hasConfirmedArchiveEnd = self.hasConfirmedArchiveEndThisSession
        let hasUsedArchiveEndVerificationProbe = self.hasUsedArchiveEndVerificationProbe
        let fallbackArchiveState = ChatArchiveStateSnapshot(
            primaryKey: LastChatsStorageItem.genPrimary(
                jid: intent.conversationKey.jid,
                owner: intent.conversationKey.owner,
                conversationType: intent.conversationKey.conversationType
            ),
            persistedCursorId: nil,
            fullArchiveLoaded: false
        )
        let archiveContextProvider: () -> ChatTimelineLocalPageArchiveContext = { [weak self] in
            guard let self else {
                return ChatTimelineLocalPageArchiveContext(
                    persisted: fallbackArchiveState,
                    paging: fallbackArchiveState
                )
            }
            let persisted = self.loadChatArchiveStateSnapshot()
            let shouldProbe = ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
                persistedArchiveEnded: persisted.fullArchiveLoaded,
                hasConfirmedArchiveEndThisSession: hasConfirmedArchiveEnd,
                hasUsedVerificationProbe: hasUsedArchiveEndVerificationProbe
            )
            let paging = ChatArchiveStateSnapshot(
                primaryKey: persisted.primaryKey,
                persistedCursorId: persisted.persistedCursorId,
                fullArchiveLoaded: ChatArchiveEndVerificationPolicy.effectiveArchiveEnded(
                    persistedArchiveEnded: persisted.fullArchiveLoaded,
                    shouldProbePersistedArchiveEnd: shouldProbe
                ),
                newestCursorId: persisted.newestCursorId,
                newerLiveEdgeReached: persisted.newerLiveEdgeReached,
                hasKnownNewerGap: persisted.hasKnownNewerGap,
                knownGaps: persisted.knownGaps
            )
            return ChatTimelineLocalPageArchiveContext(persisted: persisted, paging: paging)
        }
        let completion: (ChatTimelineLocalPagePreparationResult) -> Void = { [weak self, weak session] result in
            guard let self, let session, self.timelineSession === session else { return }
            self.completeLocalHistoryPagingPreparation(
                result,
                intent: intent,
                trigger: trigger
            )
        }
        let disposition: ChatTimelineLocalPageLoadDisposition
        switch direction {
        case .older:
            guard let boundary = session.snapshot.oldest else {
                self.clearPendingLocalHistoryPagingPreparation()
                return .none
            }
            disposition = session.loadOlder(
                before: boundary,
                archiveContextProvider: archiveContextProvider,
                expectedGeneration: intent.baseGeneration,
                completion: completion
            )
        case .newer:
            guard let boundary = session.snapshot.newest else {
                self.clearPendingLocalHistoryPagingPreparation()
                return .none
            }
            disposition = session.loadNewer(
                after: boundary,
                archiveContextProvider: archiveContextProvider,
                expectedGeneration: intent.baseGeneration,
                completion: completion
            )
        }
        guard disposition != .rejectedStale else {
            self.clearPendingLocalHistoryPagingPreparation()
            return .none
        }
        ChatArchiveDebugTrace.log("boundaryPagingPrepareLocalStart", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("trigger", trigger),
            ("direction", direction),
            ("preparedLocalPageId", intent.id),
            ("scrollMotionState", motionState.rawValue),
            ("baseGeneration", intent.baseGeneration),
            ("disposition", "\(disposition)")
        ])
        return .prepareLocal(direction)
    }

    private func completeLocalHistoryPagingPreparation(
        _ result: ChatTimelineLocalPagePreparationResult,
        intent: ChatLocalHistoryPagingIntent,
        trigger: String
    ) {
        guard let pending = self.pendingLocalHistoryPagingIntent,
              pending.id == intent.id,
              self.chatTimelineConversationKey == intent.conversationKey else {
            return
        }
        let releaseWhenPrepared = self.pendingLocalHistoryPagingReleaseWhenPrepared
        self.pendingLocalHistoryPagingIntent = nil
        self.pendingLocalHistoryPagingReleaseWhenPrepared = false
        guard case .prepared(let page) = result,
              page.baseGeneration == intent.baseGeneration else {
            self.clearPendingLocalHistoryPagingPreparation()
            return
        }
        let pagingPlan = ChatInteractiveHistoryPagingPlanPolicy.plan(for: page.snapshot.loadDecision)
        let preparation = ChatInteractiveHistoryPagingPreparation(
            direction: intent.direction,
            currentWindow: intent.currentWindow,
            requestedWindow: intent.requestedWindow,
            archiveState: page.archiveContext.persisted,
            virtualArchiveState: page.archiveContext.paging,
            preparedPage: page,
            pagingPlan: pagingPlan,
            boundaryVisibilityRequirement:
                intent.boundaryVisibilityRequirement
        )
        ChatArchiveDebugTrace.log("timelinePagingDecision", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("direction", intent.direction),
            ("decision", "\(page.snapshot.loadDecision)"),
            ("snapshotItems", page.snapshot.items.count),
            ("snapshotOldest", page.snapshot.state.oldest?.archivedId ?? "-"),
            ("snapshotNewest", page.snapshot.state.newest?.archivedId ?? "-"),
            ("snapshotResident", page.snapshot.state.residentPrimaryKeys.count),
            ("localOlderCandidateCount", page.snapshot.localOlderCandidateCount ?? -1),
            ("pageSize", page.snapshot.pageSize ?? self.datasourcePageSize),
            ("shortLocalRemainderRemoteFirst", page.snapshot.shortLocalRemainderRemoteFirst),
            ("preparedLocalPageId", page.id),
            ("preparedOnMainThread", page.preparedOnMainThread)
        ])
        switch pagingPlan {
        case .local:
            self.pendingPreparedLocalHistoryPage = ChatPreparedLocalHistoryPage(
                preparedPage: page,
                baseVirtualState: intent.baseVirtualState,
                baseWindow: intent.currentWindow,
                boundaryVisibilityRequirement:
                    intent.boundaryVisibilityRequirement
            )
            self.pendingDeferredRemoteHistoryDirection = nil
            self.pendingDeferredRemoteHistoryPreparation = nil
        case .remote:
            self.pendingPreparedLocalHistoryPage = nil
            self.pendingDeferredRemoteHistoryDirection = intent.direction
            self.pendingDeferredRemoteHistoryPreparation = preparation
        case .endReached, .noOp:
            self.clearPendingLocalHistoryPagingPreparation()
            return
        }
        if !pagingPlan.shouldShowOverlay {
            self.logInteractiveHistoryPagingPlan(
                direction: intent.direction,
                plan: pagingPlan,
                localItemCount: page.snapshot.items.count,
                localOlderCandidateCount: page.snapshot.localOlderCandidateCount,
                pageSize: page.snapshot.pageSize,
                shortLocalRemainderRemoteFirst: page.snapshot.shortLocalRemainderRemoteFirst
            )
        }
        ChatArchiveDebugTrace.log("boundaryPagingPrepareLocalFinish", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("trigger", trigger),
            ("direction", intent.direction),
            ("preparedLocalPageId", page.id),
            ("pagingPlan", "\(pagingPlan)"),
            ("releaseWhenPrepared", releaseWhenPrepared)
        ])
        if !intent.deferUntilScrollRest || releaseWhenPrepared {
            _ = self.applyPendingBoundaryPagingAfterScrollRest(trigger: "\(trigger)-prepared")
        }
    }

    @discardableResult
    internal func handleBoundaryPagingCandidate(
        direction: ChatHistoryPageDirection,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        motionState: ChatScrollMotionState,
        trigger: String
    ) -> ChatBoundaryPagingExecutionAction {
        guard self.canAdmitBoundaryPagingAfterInitialFrame else {
            let action = ChatBoundaryPagingExecutionAction.none
            self.logBoundaryPagingExecution(
                trigger: trigger,
                direction: direction,
                boundaryContext: boundaryContext,
                motionState: motionState,
                action: action,
                discardReason: "initialFrameNotCommitted"
            )
            return action
        }
        let action = self.startLocalHistoryPagingPreparation(
            direction: direction,
            motionState: motionState,
            trigger: trigger,
            boundaryVisibilityRequirement: .visibleBoundary
        )
        self.logBoundaryPagingExecution(
            trigger: trigger,
            direction: direction,
            boundaryContext: boundaryContext,
            motionState: motionState,
            action: action,
            discardReason: action == .none ? "planningFailed" : nil
        )
        return action
    }

    @discardableResult
    internal func applyPendingBoundaryPagingAfterScrollRest(trigger: String) -> Bool {
        guard self.canAdmitBoundaryPagingAfterInitialFrame else {
            self.clearPendingLocalHistoryPagingPreparation()
            return false
        }
        let motionState = self.currentScrollMotionState()
        guard motionState == .resting else {
            return false
        }

        if self.pendingLocalHistoryPagingIntent != nil {
            self.pendingLocalHistoryPagingReleaseWhenPrepared = true
            return false
        }

        if let prepared = self.pendingPreparedLocalHistoryPage {
            if let discardReason = self.preparedLocalHistoryPageDiscardReason(prepared) {
                self.discardPreparedBoundaryPaging(reason: discardReason, trigger: trigger)
                return false
            }

            self.pendingPreparedLocalHistoryPage = nil
            self.pendingDeferredRemoteHistoryDirection = nil
            self.pendingDeferredRemoteHistoryPreparation = nil
            self.setDatasourceLoadingEnabled(false)
            self.timelineInteractionState.locked = true
            ChatArchiveDebugTrace.log("boundaryPagingApplyPreparedLocal", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("trigger", trigger),
                ("direction", prepared.direction),
                ("preparedLocalPageId", prepared.id),
                ("snapshotItems", prepared.snapshot.items.count),
                ("snapshotOldest", prepared.snapshot.state.oldest?.archivedId ?? "-"),
                ("snapshotNewest", prepared.snapshot.state.newest?.archivedId ?? "-")
            ])
            self.finishPagingInteraction(
                preparedPage: prepared,
                animated: false
            )
            return true
        }

        if let direction = self.pendingDeferredRemoteHistoryDirection,
           let preparation = self.pendingDeferredRemoteHistoryPreparation {
            let boundaryContext = self.pagingBoundaryContext(
                visibleSections: self.messagesCollectionView.indexPathsForVisibleItems.map(\.section)
            )
            guard ChatPendingBoundaryPagingValidationPolicy.shouldProceed(
                visibilityRequirement:
                    preparation.boundaryVisibilityRequirement,
                direction: direction,
                boundaryContext: boundaryContext
            ) else {
                self.pendingDeferredRemoteHistoryDirection = nil
                self.pendingDeferredRemoteHistoryPreparation = nil
                ChatArchiveDebugTrace.log("boundaryPagingDiscardPrepared", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("trigger", trigger),
                    ("direction", direction),
                    ("discardReason", "remoteBoundaryNoLongerVisible")
                ])
                return false
            }

            self.pendingDeferredRemoteHistoryDirection = nil
            self.pendingDeferredRemoteHistoryPreparation = nil
            ChatArchiveDebugTrace.log("boundaryPagingDeferRemote", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("trigger", "\(trigger)-apply"),
                ("direction", direction),
                ("duplicate", false),
                ("scrollMotionState", motionState.rawValue)
            ])
            self.performInteractiveHistoryPaging(preparation: preparation)
            return true
        }

        return false
    }

    private func preparedLocalHistoryPageDiscardReason(_ prepared: ChatPreparedLocalHistoryPage) -> String? {
        let conversationKey = self.chatTimelineConversationKey
        guard prepared.conversationKey == conversationKey else {
            return "conversationChanged"
        }

        let normalizedState = self.virtualTimelineState.normalized(
            owner: conversationKey.owner,
            jid: conversationKey.jid,
            conversationType: conversationKey.conversationType
        )
        guard normalizedState == prepared.baseVirtualState else {
            return "virtualStateChanged"
        }
        guard normalizedState.activeRemoteLoad == nil else {
            return "remoteInFlight"
        }
        guard self.timelineInteractionState.isUnlocked else {
            return "pageLocked"
        }
        guard self.visibleWindow() == prepared.baseWindow else {
            return "windowChanged"
        }
        guard self.currentScrollMotionState() == .resting else {
            return "scrollMoving"
        }

        let boundaryContext = self.pagingBoundaryContext(
            visibleSections: self.messagesCollectionView.indexPathsForVisibleItems.map(\.section)
        )
        guard ChatPendingBoundaryPagingValidationPolicy.shouldProceed(
            visibilityRequirement:
                prepared.boundaryVisibilityRequirement,
            direction: prepared.direction,
            boundaryContext: boundaryContext
        ) else {
            return "boundaryNoLongerVisible"
        }
        return nil
    }

    private func discardPreparedBoundaryPaging(reason: String, trigger: String) {
        let preparedDirection = self.pendingPreparedLocalHistoryPage?.direction
        let preparedId = self.pendingPreparedLocalHistoryPage?.id
        self.pendingPreparedLocalHistoryPage = nil
        ChatArchiveDebugTrace.log("boundaryPagingDiscardPrepared", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("trigger", trigger),
            ("direction", preparedDirection.map { "\($0)" } ?? "-"),
            ("preparedLocalPageId", preparedId ?? "-"),
            ("discardReason", reason)
        ])
    }

    internal func clearPendingLocalHistoryPagingPreparation() {
        self.pendingLocalHistoryPagingIntent = nil
        self.pendingLocalHistoryPagingReleaseWhenPrepared = false
        self.pendingPreparedLocalHistoryPage = nil
        self.pendingDeferredRemoteHistoryDirection = nil
        self.pendingDeferredRemoteHistoryPreparation = nil
    }

    private func logBoundaryPagingExecution(
        trigger: String,
        direction: ChatHistoryPageDirection,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        motionState: ChatScrollMotionState,
        action: ChatBoundaryPagingExecutionAction,
        discardReason: String?
    ) {
        ChatArchiveDebugTrace.log("boundaryPagingExecutionDecision", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("trigger", trigger),
            ("direction", direction),
            ("firstRealSection", boundaryContext.firstRealSection ?? -1),
            ("lastRealSection", boundaryContext.lastRealSection ?? -1),
            ("visibleRealSections", boundaryContext.visibleRealSections.map(String.init).joined(separator: ",")),
            ("scrollMotionState", motionState.rawValue),
            ("executionAction", action.diagnosticName),
            ("preparedLocalPageId", self.pendingPreparedLocalHistoryPage?.id ?? "-"),
            ("pendingDirection", self.pendingDeferredRemoteHistoryDirection.map { "\($0)" } ?? "-"),
            ("discardReason", discardReason ?? "-")
        ])
    }

    private func applyVirtualTimelineSnapshotState(_ snapshot: ChatTimelineSnapshot) {
        let oldState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        ChatArchiveDebugTrace.log("virtualTimelineStateApply", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("oldOldest", oldState.oldest?.archivedId ?? "-"),
            ("newOldest", snapshot.state.oldest?.archivedId ?? "-"),
            ("oldNewest", oldState.newest?.archivedId ?? "-"),
            ("newNewest", snapshot.state.newest?.archivedId ?? "-"),
            ("oldResident", oldState.residentPrimaryKeys.count),
            ("newResident", snapshot.state.residentPrimaryKeys.count),
            ("oldActiveRemoteLoad", oldState.activeRemoteLoad?.queryId ?? "-"),
            ("newActiveRemoteLoad", snapshot.state.activeRemoteLoad?.queryId ?? "-"),
            ("itemCount", snapshot.items.count)
        ])
        _ = self.timelineSession?.commit(snapshot)
        self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: snapshot.items.count))
    }

    internal func registerRemoteHistoryPersistenceSource(
        _ manager: MessageManager?,
        archiveManager: MessageArchiveManager? = nil,
        queryId: String
    ) {
        guard let manager,
              queryId.isNotEmpty else {
            return
        }

        ChatRemoteHistoryCompletionCoordinator.registerPersistenceSource(
            manager,
            archiveManager: archiveManager,
            owner: self.owner,
            queryId: queryId
        )
    }

    internal func registerRemoteHistoryEndPageDispatcher(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }

        if let token = self.remoteHistoryEndPageDispatcherTokens.removeValue(forKey: queryId) {
            MessageArchiveEndPageDispatcher.unregister(token)
        }
        self.completedRemoteHistoryEndPageQueryIds.remove(queryId)
        let token = MessageArchiveEndPageDispatcher.register(owner: self.owner, queryId: queryId) { [weak self] event in
            self?.didReceiveEndPage(
                queryId: event.queryId,
                state: event.state,
                first: event.first,
                last: event.last,
                count: event.count
            )
        }
        self.remoteHistoryEndPageDispatcherTokens[queryId] = token
    }

    internal func registerRemoteHistoryFailureDispatcher(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }

        if let token = self.remoteHistoryFailureDispatcherTokens.removeValue(forKey: queryId) {
            MessageArchiveRequestFailureDispatcher.unregister(token)
        }
        self.abortedRemoteHistoryQueryIds.remove(queryId)
        let token = MessageArchiveRequestFailureDispatcher.register(owner: self.owner, queryId: queryId) { [weak self] event in
            guard let self else {
                return
            }
            if self.handleAnchorRemoteFailureIfNeeded(
                queryId: event.queryId,
                reason: event.reason
            ) {
                return
            }
            if self.handleInChatSearchQueryFailure(queryId: event.queryId) {
                return
            }
            if self.initialBootstrapQueryId == event.queryId {
                self.handleInitialBootstrapRemoteArchiveFailure(
                    queryId: event.queryId,
                    reason: event.reason,
                    streamKind: event.streamKind,
                    errorDescription: event.errorDescription
                )
                return
            }
            self.handleInteractiveRemoteArchiveFailure(
                queryId: event.queryId,
                reason: event.reason,
                streamKind: event.streamKind,
                errorDescription: event.errorDescription
            )
        }
        self.remoteHistoryFailureDispatcherTokens[queryId] = token
    }

    internal func unregisterRemoteHistoryEndPageDispatcher(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }

        if let token = self.remoteHistoryEndPageDispatcherTokens.removeValue(forKey: queryId) {
            MessageArchiveEndPageDispatcher.unregister(token)
        }
    }

    internal func unregisterRemoteHistoryFailureDispatcher(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }

        if let token = self.remoteHistoryFailureDispatcherTokens.removeValue(forKey: queryId) {
            MessageArchiveRequestFailureDispatcher.unregister(token)
        }
    }

    internal func clearRemoteHistoryEndPageDispatchers() {
        self.remoteHistoryEndPageDispatcherTokens.values.forEach {
            MessageArchiveEndPageDispatcher.unregister($0)
        }
        self.remoteHistoryEndPageDispatcherTokens.removeAll()
        self.completedRemoteHistoryEndPageQueryIds.removeAll()
        self.remoteHistoryFailureDispatcherTokens.values.forEach {
            MessageArchiveRequestFailureDispatcher.unregister($0)
        }
        self.remoteHistoryFailureDispatcherTokens.removeAll()
        self.abortedRemoteHistoryQueryIds.removeAll()
        self.remoteHistoryQueryCoordinator.cancelAll(reason: .cancelled)
        self.cancelInitialBootstrapTimeout()
        self.cancelInteractiveRemoteArchiveRequestStartWatchdog()
        self.cancelInteractiveRemoteArchiveTimeout()
    }

    internal func markRemoteHistoryEndPageCompletionIfNeeded(queryId: String) -> Bool {
        guard queryId.isNotEmpty else {
            return false
        }

        if self.completedRemoteHistoryEndPageQueryIds.contains(queryId) {
            return false
        }

        self.completedRemoteHistoryEndPageQueryIds.insert(queryId)
        self.unregisterRemoteHistoryEndPageDispatcher(queryId: queryId)
        return true
    }

    internal func unregisterRemoteHistoryPersistenceSource(queryId: String) {
        self.unregisterRemoteHistoryEndPageDispatcher(queryId: queryId)
        self.unregisterRemoteHistoryFailureDispatcher(queryId: queryId)
        self.cancelInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)
        self.cancelInteractiveRemoteArchiveTimeout(queryId: queryId)
        self.remoteHistoryRequestStartedAtByQueryId.removeValue(forKey: queryId)
        ChatRemoteHistoryCompletionCoordinator.unregisterPersistenceSource(
            owner: self.owner,
            queryId: queryId
        )
    }

    internal func scheduleInteractiveRemoteArchiveRequestStartWatchdog(queryId: String) {
        guard queryId.isNotEmpty,
              let context = self.interactiveHistoryPageLoadContext,
              context.queryId == queryId else {
            return
        }

        self.cancelInteractiveRemoteArchiveRequestStartWatchdog()
        let didSchedule = self.remoteHistoryQueryCoordinator.scheduleTimeout(
            queryId: queryId,
            generation: context.generation,
            after: ChatInteractiveRemoteArchiveTimeoutPolicy.requestStartTimeout,
            terminalReason: .cancelled
        ) { [weak self] in
            self?.handleInteractiveRemoteArchiveRequestStartTimeout(queryId: queryId)
        }
        guard didSchedule else {
            assertionFailure("Unable to schedule request-start timeout for \(queryId)")
            return
        }
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartWatchdogScheduled", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId),
            ("timeoutMs", Int(ChatInteractiveRemoteArchiveTimeoutPolicy.requestStartTimeout * 1000)),
            ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
            ("interactiveQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-")
        ])
    }

    internal func cancelInteractiveRemoteArchiveRequestStartWatchdog(queryId: String? = nil) {
        guard let activeQueryId = self.interactiveHistoryPageLoadContext?.queryId else {
            return
        }

        if let queryId = queryId,
           queryId != activeQueryId {
            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartWatchdogCancelSkipped", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("activeStartQueryId", activeQueryId),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                ("interactiveQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-")
            ])
            return
        }

        guard self.remoteHistoryQueryCoordinator.cancelTimeout(queryId: activeQueryId) else {
            return
        }
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartWatchdogCancelled", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId ?? activeQueryId),
            ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
            ("interactiveQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-")
        ])
    }

    private func shouldDispatchInteractiveRemoteArchiveRequest(queryId: String) -> Bool {
        guard let context = self.interactiveHistoryPageLoadContext,
              context.queryId == queryId else {
            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestDispatchSkipped", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("reason", "inactiveContext"),
                ("activeQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                ("aborted", self.abortedRemoteHistoryQueryIds.contains(queryId))
            ])
            return false
        }

        guard !context.remoteFetchStarted else {
            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestDispatchSkipped", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("reason", "alreadyStarted"),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-")
            ])
            return false
        }

        return true
    }

    @discardableResult
    internal func markInteractiveRemoteArchiveRequestSent(
        queryId: String,
        direction: ChatHistoryPageDirection,
        cursorId: String?,
        pageSize: Int,
        streamKind: MessageArchiveEndPageEvent.StreamKind,
        resource: String?,
        bootstrapActive: Bool,
        cursorSource: ChatInteractiveOlderCursorSelectionSource? = nil,
        timelineOldestCursorId: String? = nil,
        boundedOldestCursorId: String? = nil,
        persistedCursorId: String? = nil
    ) -> Bool {
        guard queryId.isNotEmpty else {
            return false
        }

        guard var context = self.interactiveHistoryPageLoadContext,
              context.queryId == queryId else {
            ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStartSkipped", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("reason", "inactiveContext"),
                ("activeQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                ("streamKind", streamKind.rawValue)
            ])
            return false
        }

        self.cancelInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)
        let didScheduleTimeout = self.remoteHistoryQueryCoordinator.scheduleTimeout(
            queryId: queryId,
            generation: context.generation,
            after: ChatInteractiveRemoteArchiveTimeoutPolicy.timeout,
            terminalReason: .timeout
        ) { [weak self] in
            self?.handleInteractiveRemoteArchiveFailure(
                queryId: queryId,
                reason: .timeout,
                streamKind: streamKind,
                errorDescription: nil
            )
        }
        guard didScheduleTimeout else {
            assertionFailure("Unable to schedule response timeout for \(queryId)")
            return false
        }

        context.remoteFetchStarted = true
        self.interactiveHistoryPageLoadContext = context
        let startedAt = Date()
        self.remoteHistoryRequestStartedAtByQueryId[queryId] = startedAt
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestStart", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId),
            ("direction", direction),
            ("cursor", cursorId ?? "-"),
            ("requestedCursor", cursorId ?? "-"),
            ("cursorSource", cursorSource?.rawValue ?? "-"),
            ("timelineOldest", timelineOldestCursorId ?? "-"),
            ("boundedOldest", boundedOldestCursorId ?? "-"),
            ("persistedCursor", persistedCursorId ?? "-"),
            ("cursorDiffersFromPersisted", cursorId != persistedCursorId),
            ("pageSize", pageSize),
            ("streamKind", streamKind.rawValue),
            ("resource", resource ?? "-"),
            ("bootstrapActive", bootstrapActive),
            ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count)
        ])
        return true
    }

    internal func remoteArchiveStreamKind(for stream: XMPPStream) -> MessageArchiveEndPageEvent.StreamKind {
        guard let resource = stream.myJID?.resource else {
            return .unknown
        }
        if resource.contains("_ui_upgrade_task") {
            return .uiAction
        }
        return .primary
    }

    internal func cancelInteractiveRemoteArchiveTimeout(queryId: String? = nil) {
        if let queryId {
            self.remoteHistoryRequestStartedAtByQueryId.removeValue(forKey: queryId)
            _ = self.remoteHistoryQueryCoordinator.cancelTimeout(queryId: queryId)
        } else {
            self.remoteHistoryRequestStartedAtByQueryId.removeAll()
            self.remoteHistoryQueryCoordinator.cancelAllTimeouts()
        }
    }

    private func finishVirtualTimelineRemoteLoad(
        queryId: String,
        archiveState: ChatArchiveStateSnapshot,
        refetchDirection: ChatHistoryPageDirection? = nil
    ) {
        guard let session = self.timelineSession else { return }
        session.updateArchiveState(archiveState)
        let snapshot = session.finishRemoteLoad(
            queryId: queryId,
            refetchDirection: refetchDirection
        )
        self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: snapshot.items.count))
    }

    private func commitRemoteHistoryArchiveStateAfterApply(
        context: ChatInteractiveHistoryPageLoadContext,
        applyResult: ChatRemoteHistoryApplyResult,
        baseArchiveState: ChatArchiveStateSnapshot
    ) {
        let coverageDecision = ChatArchiveCoverageCommitPolicy.resolve(
            direction: context.direction,
            snapshot: baseArchiveState,
            requestedCursorId: context.requestedCursorId,
            observedCursorId: applyResult.newOldestArchivedId,
            transportFirst: context.resultFirst,
            transportLast: context.resultLast,
            resultCount: context.resultCount,
            persistedRowsForQuery: context.persistedRowsForQuery,
            visibleRowsForConversation: context.visibleRowsForConversation,
            queryExhausted: context.queryExhausted,
            canMutateOlderArchiveEnd: context.canMutateOlderArchiveEnd,
            coverageUpdateKind: context.coverageUpdateKind
        )

        if coverageDecision.shouldCommitCoverage {
            self.applyConversationArchiveLoadedRangeIfNeeded(
                first: context.resultFirst,
                last: context.resultLast,
                updateKind: context.coverageUpdateKind
            )
        } else if let emptyGapCoverage =
                    coverageDecision.authoritativeEmptyGapCoverage {
            self.applyConversationArchiveLoadedRangeIfNeeded(
                first: emptyGapCoverage.first,
                last: emptyGapCoverage.last,
                updateKind: emptyGapCoverage.updateKind
            )
        }

        let archiveStateForMutation = (
            coverageDecision.shouldCommitCoverage ||
                coverageDecision.authoritativeEmptyGapCoverage != nil
        )
            ? self.loadChatArchiveStateSnapshot()
            : baseArchiveState
        let effectiveResolvedCursorId = coverageDecision.shouldAdvanceOlderCursor
            ? coverageDecision.resolvedCursorId
            : archiveStateForMutation.persistedCursorId

        if context.direction == .older,
           coverageDecision.nextFullArchiveLoaded,
           context.canMutateOlderArchiveEnd {
            self.hasConfirmedArchiveEndThisSession = true
        } else if context.direction == .older,
                  coverageDecision.hasPersistenceProof,
                  coverageDecision.shouldAdvanceOlderCursor {
            self.hasConfirmedArchiveEndThisSession = false
        }
        if context.isArchiveEndVerificationProbe {
            self.hasUsedArchiveEndVerificationProbe = true
        }

        let archiveStatePlan = ChatArchiveStateMutationPolicy.resolvePlan(
            snapshot: archiveStateForMutation,
            resolvedCursorId: effectiveResolvedCursorId,
            nextFullArchiveLoaded: coverageDecision.nextFullArchiveLoaded
        )
        ChatArchiveDebugTrace.log("remoteHistoryArchiveCommitDecision", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", context.queryId),
            ("direction", context.direction),
            ("requestedCursor", context.requestedCursorId ?? "-"),
            ("observedCursor", applyResult.newOldestArchivedId ?? "-"),
            ("transportFirst", context.resultFirst),
            ("transportLast", context.resultLast),
            ("persistedRowsForQuery", context.persistedRowsForQuery),
            ("visibleRows", context.visibleRowsForConversation),
            ("resultCount", context.resultCount),
            ("queryExhausted", context.queryExhausted),
            ("hasPersistenceProof", coverageDecision.hasPersistenceProof),
            ("commitCoverage", coverageDecision.shouldCommitCoverage),
            (
                "commitEmptyGapCoverage",
                coverageDecision.authoritativeEmptyGapCoverage != nil
            ),
            ("advanceOlderCursor", coverageDecision.shouldAdvanceOlderCursor),
            ("resolvedCursor", effectiveResolvedCursorId ?? "-"),
            ("previousCursor", archiveStateForMutation.persistedCursorId ?? "-"),
            ("nextFullArchiveLoaded", coverageDecision.nextFullArchiveLoaded),
            ("markNewerLiveEdge", coverageDecision.shouldMarkNewerLiveEdgeReached),
            ("cursorRepeatedAfterCompletion", coverageDecision.cursorRepeatedAfterCompletion),
            ("duplicateCursorSuppressed", coverageDecision.duplicateCursorSuppressed)
        ])
        _ = self.applyChatArchiveStateIfNeeded(
            snapshot: archiveStateForMutation,
            plan: archiveStatePlan,
            markNewerLiveEdgeReached: coverageDecision.shouldMarkNewerLiveEdgeReached
        )
    }

    private func clearFinishedRemoteLoadRuntimeStateIfNeeded(
        queryId: String,
        conversationKey: ChatTimelineConversationKey
    ) {
        let currentConversationKey = ChatTimelineConversationKey(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        guard currentConversationKey == conversationKey else {
            DDLogDebug(
                "ChatViewController.remoteHistoryApplyCancelled queryId=\(queryId) reason=conversationChanged requestJid=\(conversationKey.jid) currentJid=\(currentConversationKey.jid)"
            )
            return
        }

        let normalizedState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        guard normalizedState.activeRemoteLoad?.queryId == queryId ||
              self.remoteHistoryFinishingQueryId == queryId else {
            DDLogDebug(
                "ChatViewController.remoteHistoryApplyCancelled queryId=\(queryId) reason=queryMismatch active=\(normalizedState.activeRemoteLoad?.queryId ?? "-")"
            )
            return
        }

        self.activeHistoryBoundaryPlaceholder = nil
        let clearedSnapshot = self.timelineSession?.abortRemoteLoad(queryId: queryId)
        self.refreshScrollBoundaryAvailabilityCache(reason: "remoteLoadCleared")
        DDLogDebug(
            "ChatViewController.remoteHistoryApplyCancelled queryId=\(queryId) reason=clearedRuntimeState oldest=\(clearedSnapshot?.state.oldest?.archivedId ?? "-") newest=\(clearedSnapshot?.state.newest?.archivedId ?? "-")"
        )
    }

    private func mapAndApplyFinishedVirtualTimelineRemoteLoad(
        queryId: String,
        performanceTraceContext: ChatOpenPerformanceTraceContext?,
        archiveState: ChatArchiveStateSnapshot,
        refetchDirection: ChatHistoryPageDirection,
        refetchLimit: Int? = nil,
        visibleRows: Int,
        resultCount: Int,
        queryExhausted: Bool,
        mode: ChatDatasourceApplyMode,
        animated: Bool,
        applyCategory: ChatDatasourceApplyCategory = .default,
        anchorRestorePhase: ChatHistoryPageAnchorRestorePhase = .none,
        anchorPrimary: String? = nil,
        restoreAnchor: ChatHistoryPageAnchor? = nil,
        completion: ((ChatRemoteHistoryApplyResult) -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        let requestOwner = self.owner
        let acceptedPerformanceTraceContext = performanceTraceContext.flatMap {
            ChatArchivePerformanceTraceRegistry.shared.permitsPagePresentation(
                owner: requestOwner,
                queryID: queryId,
                context: $0
            ) ? $0 : nil
        }
        guard performanceTraceContext == nil ||
                acceptedPerformanceTraceContext != nil else {
            cancelledCompletion?()
            return
        }
        let pageApplyInterval = acceptedPerformanceTraceContext.map {
            ChatPerformanceSignposts.begin(.pageApply, context: $0)
        }
        let finishPageApply: (ChatPerformanceIntervalTerminal) -> Void = {
            terminal in
            var interval = pageApplyInterval
            interval?.end(terminal: terminal)
        }
        guard let session = self.timelineSession else {
            finishPageApply(.cancelled)
            cancelledCompletion?()
            return
        }
        let enqueuedAt = Date()
        let requestJid = self.jid
        let requestConversationType = self.conversationType
        let requestConversationKey = ChatTimelineConversationKey(
            owner: requestOwner,
            jid: requestJid,
            conversationType: requestConversationType
        )
        let currentTimelineState = session.snapshot.state.normalized(
            owner: requestOwner,
            jid: requestJid,
            conversationType: requestConversationType
        )
        let previousOldestArchivedId = currentTimelineState.oldest?.archivedId
        let previousNewestArchivedId = currentTimelineState.newest?.archivedId
        let mappingContext = self.captureDatasourceMappingContext()
        let mappingJob = self.beginDatasetMappingJob()
        let mappingGeneration = mappingJob.generation
        let cancellationToken = mappingJob.token
        DDLogDebug(
            "ChatViewController.remoteHistoryApplyStart queryId=\(queryId) direction=\(refetchDirection) visibleRows=\(visibleRows) count=\(resultCount) oldest=\(previousOldestArchivedId ?? "-") newest=\(previousNewestArchivedId ?? "-")"
        )

        self.remoteHistoryApplyQueue.async { [weak self, weak session] in
            guard let self, let session, !cancellationToken.isCancelled else {
                finishPageApply(.cancelled)
                DispatchQueue.main.async { cancelledCompletion?() }
                return
            }
            guard acceptedPerformanceTraceContext.map({
                ChatArchivePerformanceTraceRegistry.shared.permitsPagePresentation(
                    owner: requestOwner,
                    queryID: queryId,
                    context: $0
                )
            }) ?? true else {
                finishPageApply(.cancelled)
                DispatchQueue.main.async { cancelledCompletion?() }
                return
            }
            let startedAt = Date()
            let queueWaitMs = Int(startedAt.timeIntervalSince(enqueuedAt) * 1000)
            ChatArchiveDebugTrace.log("remoteHistoryApplyWorkerStart", [
                    ("owner", requestOwner),
                    ("jid", requestJid),
                    ("conversationType", requestConversationType.rawValue),
                    ("queryId", queryId),
                    ("direction", refetchDirection),
                    ("queueWaitMs", queueWaitMs),
                    ("oldOldest", previousOldestArchivedId ?? "-"),
                    ("oldNewest", previousNewestArchivedId ?? "-")
            ])
            let refetchStartedAt = Date()
            session.updateArchiveState(archiveState)
            let snapshot = session.finishRemoteLoad(
                queryId: queryId,
                refetchDirection: refetchDirection,
                refetchLimit: refetchLimit
            )
#if DEBUG || CHAT_PERFORMANCE_LAB
            self.remoteHistoryQueryCoordinator.remoteApplyWorkerObserverForTests?(
                queryId,
                .refetch,
                Thread.isMainThread
            )
#endif
            let refetchMs = ChatArchiveDebugTrace.milliseconds(since: refetchStartedAt)
            let frozenItems = snapshot.items
            let nextVirtualState = snapshot.state
            let mapStartedAt = Date()
            let mappingResult = self.mapDataset(
                dataset: frozenItems,
                context: mappingContext,
                cancellationToken: cancellationToken,
                performanceTraceContext: acceptedPerformanceTraceContext
            )
#if DEBUG || CHAT_PERFORMANCE_LAB
            self.remoteHistoryQueryCoordinator.remoteApplyWorkerObserverForTests?(
                queryId,
                .map,
                Thread.isMainThread
            )
#endif
            let mapDurationMs = ChatArchiveDebugTrace.milliseconds(since: mapStartedAt)
            let workerDurationMs = ChatArchiveDebugTrace.milliseconds(since: startedAt)
            ChatArchiveDebugTrace.log("remoteHistoryApplyRefetchDone", [
                    ("owner", requestOwner),
                    ("jid", requestJid),
                    ("conversationType", requestConversationType.rawValue),
                    ("queryId", queryId),
                    ("direction", refetchDirection),
                    ("refetchMs", refetchMs),
                    ("items", frozenItems.count),
                    ("newOldest", nextVirtualState.oldest?.archivedId ?? "-"),
                    ("newNewest", nextVirtualState.newest?.archivedId ?? "-"),
                    ("activeRemoteLoad", nextVirtualState.activeRemoteLoad?.queryId ?? "-")
            ])
            let mainEnqueuedAt = Date()
            DispatchQueue.main.async {
                    ChatArchiveDebugTrace.log("remoteHistoryApplyMainStart", [
                        ("owner", requestOwner),
                        ("jid", requestJid),
                        ("conversationType", requestConversationType.rawValue),
                        ("queryId", queryId),
                        ("direction", refetchDirection),
                        ("mainWaitMs", ChatArchiveDebugTrace.milliseconds(since: mainEnqueuedAt)),
                        ("currentOldest", self.virtualTimelineState.oldest?.archivedId ?? "-"),
                        ("currentNewest", self.virtualTimelineState.newest?.archivedId ?? "-"),
                        ("currentResident", self.virtualTimelineState.residentPrimaryKeys.count),
                        ("datasourceCount", self.datasource.count)
                    ])
                    let currentConversationKey = ChatTimelineConversationKey(
                        owner: self.owner,
                        jid: self.jid,
                        conversationType: self.conversationType
                    )
                    guard !mappingResult.wasCancelled,
                          !cancellationToken.isCancelled,
                          ChatDatasourceApplyGenerationPolicy.shouldApply(
                            requestGeneration: mappingGeneration,
                            currentGeneration: self.datasetMappingGeneration
                          ),
                          self.timelineSession === session,
                          acceptedPerformanceTraceContext.map({
                            ChatArchivePerformanceTraceRegistry.shared
                                .permitsPagePresentation(
                                owner: requestOwner,
                                queryID: queryId,
                                context: $0
                            )
                          }) ?? true,
                          ChatRemoteHistoryApplyGuardPolicy.shouldApply(
                        requestConversationKey: requestConversationKey,
                        currentConversationKey: currentConversationKey,
                        requestQueryId: queryId,
                        finishingQueryId: self.remoteHistoryFinishingQueryId
                    ) else {
                        DDLogDebug(
                            "ChatViewController.remoteHistoryApplyCancelled queryId=\(queryId) reason=guard requestJid=\(requestJid) currentJid=\(currentConversationKey.jid) finishing=\(self.remoteHistoryFinishingQueryId ?? "-")"
                        )
                        finishPageApply(.cancelled)
                        cancelledCompletion?()
                        return
                    }

                    let mappedDatasource = mappingResult.datasource
                    let applyResult = ChatRemoteHistoryApplyResult(
                        queryId: queryId,
                        direction: refetchDirection,
                        visibleRows: visibleRows,
                        resultCount: resultCount,
                        queryExhausted: queryExhausted,
                        previousOldestArchivedId: previousOldestArchivedId,
                        previousNewestArchivedId: previousNewestArchivedId,
                        newOldestArchivedId: nextVirtualState.oldest?.archivedId,
                        newNewestArchivedId: nextVirtualState.newest?.archivedId,
                        itemCount: frozenItems.count,
                        queueWaitMs: queueWaitMs,
                        mapDurationMs: mapDurationMs
                    )
                    ChatArchiveDebugTrace.log("remoteHistoryApplyMapDone", [
                        ("owner", requestOwner),
                        ("jid", requestJid),
                        ("conversationType", requestConversationType.rawValue),
                        ("queryId", queryId),
                        ("direction", refetchDirection),
                        ("mapMs", mapDurationMs),
                        ("workerDurationMs", workerDurationMs),
                        ("datasourceItems", mappedDatasource.count)
                    ])
                    self.activeHistoryBoundaryPlaceholder = nil
                    self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: frozenItems.count))
                    self.invalidateEditedMessageLayoutCache(
                        primaries: mappingResult.editedMessagePrimariesNeedingLayoutInvalidation
                    )
                    ChatArchiveDebugTrace.log("remoteHistoryApplyStateAssigned", [
                        ("owner", requestOwner),
                        ("jid", requestJid),
                        ("conversationType", requestConversationType.rawValue),
                        ("queryId", queryId),
                        ("direction", refetchDirection),
                        ("newOldest", self.virtualTimelineState.oldest?.archivedId ?? "-"),
                        ("newNewest", self.virtualTimelineState.newest?.archivedId ?? "-"),
                        ("oldestChanged", previousOldestArchivedId != nextVirtualState.oldest?.archivedId),
                        ("newestChanged", previousNewestArchivedId != nextVirtualState.newest?.archivedId),
                        ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count),
                        ("datasourceCount", mappedDatasource.count)
                    ])
                    DDLogDebug(
                        "ChatViewController.remoteHistoryApply queryId=\(queryId) direction=\(refetchDirection) items=\(frozenItems.count) oldOldest=\(previousOldestArchivedId ?? "-") newOldest=\(nextVirtualState.oldest?.archivedId ?? "-") oldNewest=\(previousNewestArchivedId ?? "-") newNewest=\(nextVirtualState.newest?.archivedId ?? "-") queueWaitMs=\(queueWaitMs) mapMs=\(mapDurationMs)"
                    )
                    self.applyChatDatasource(
                        mappedDatasource,
                        mode: mode,
                        animated: animated,
                        invalidateLayout: false,
                        preparedLayouts: mappingResult.layoutSnapshot,
                        applyCategory: applyCategory,
                        anchorRestorePhase: anchorRestorePhase,
                        anchorPrimary: anchorPrimary,
                        restoreAnchor: restoreAnchor,
                        completion: {
                            finishPageApply(.committed)
                            completion?(applyResult)
                        }
                    )
            }
        }
    }

    private func logInteractiveHistoryPagingPlan(
        direction: ChatHistoryPageDirection,
        plan: ChatInteractiveHistoryPagingPlan,
        localItemCount: Int,
        localOlderCandidateCount: Int? = nil,
        pageSize: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false,
        queryId: String? = nil
    ) {
        let normalizedState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        let boundedState = self.boundedTimelineWindowState
        DDLogDebug(
            "ChatViewController.interactivePaging direction=\(direction) plan=\(plan) localItems=\(localItemCount) resident=\(self.virtualTimelineState.residentPrimaryKeys.count) oldest=\(self.virtualTimelineState.oldest?.archivedId ?? "-") newest=\(self.virtualTimelineState.newest?.archivedId ?? "-") queryId=\(queryId ?? "-")"
        )
        ChatArchiveDebugTrace.log("interactivePagingPlan", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("direction", direction),
            ("plan", "\(plan)"),
            ("queryId", queryId ?? "-"),
            ("localItems", localItemCount),
            ("localOlderCandidateCount", localOlderCandidateCount ?? -1),
            ("pageSize", pageSize ?? self.datasourcePageSize),
            ("shortLocalRemainderRemoteFirst", shortLocalRemainderRemoteFirst),
            ("virtualOldest", normalizedState.oldest?.archivedId ?? "-"),
            ("virtualNewest", normalizedState.newest?.archivedId ?? "-"),
            ("virtualResident", normalizedState.residentPrimaryKeys.count),
            ("boundedOldest", boundedState.oldest?.archivedId ?? "-"),
            ("boundedNewest", boundedState.newest?.archivedId ?? "-"),
            ("datasourceFirst", self.datasource.first?.archivedId ?? "-"),
            ("datasourceLast", self.datasource.last?.archivedId ?? "-"),
            ("datasourceCount", self.datasource.count),
            ("residentCount", self.timelineSession?.snapshot.items.count ?? -1),
            ("activeRemoteLoad", normalizedState.activeRemoteLoad?.queryId ?? "-"),
            ("activePlaceholder", self.activeHistoryBoundaryPlaceholder != nil),
            ("currentPageLocked", self.timelineInteractionState.locked),
            ("canLoadDatasource", self.canLoadDatasource)
        ])
    }

    @discardableResult
    private func armRemoteInteractiveHistoryRequest(
        direction: ChatHistoryPageDirection,
        decision: ChatHistoryPagingLoadDecision,
        queryId: String,
        schedulerLease: ChatInteractiveRemoteArchiveSchedulerLease,
        localItemCount: Int,
        localOlderCandidateCount: Int? = nil,
        pageSize: Int? = nil,
        shortLocalRemainderRemoteFirst: Bool = false
    ) -> Bool {
        self.logInteractiveHistoryPagingPlan(
            direction: direction,
            plan: .remote(decision),
            localItemCount: localItemCount,
            localOlderCandidateCount: localOlderCandidateCount,
            pageSize: pageSize,
            shortLocalRemainderRemoteFirst: shortLocalRemainderRemoteFirst,
            queryId: queryId
        )
        guard let context = self.interactiveHistoryPageLoadContext,
              context.queryId == queryId else {
            assertionFailure("Remote MAM request must have a typed context before arming")
            schedulerLease.complete()
            self.timelineInteractionState.unlock()
            return false
        }
        self.remoteHistoryQueryCoordinator.cancelAll(reason: .superseded)
        let descriptor = ChatRemoteHistoryQueryDescriptor(
            conversationKey: self.chatTimelineConversationKey,
            queryId: queryId,
            direction: direction,
            cursorId: context.requestedCursorId,
            generation: context.generation
        )
        let owner = self.owner
        let jid = self.jid
        let conversationType = self.conversationType
        let didRegister = self.remoteHistoryQueryCoordinator.register(
            descriptor,
            wireTerminal: schedulerLease.complete,
            persistenceCleanup: {
                ChatInteractiveRemoteArchiveTerminalCleanup.perform(
                    flushPersistence: { completion in
                        ChatRemoteHistoryCompletionCoordinator.unregisterPersistenceSource(
                            owner: owner,
                            queryId: queryId,
                            completion: completion
                        )
                    },
                    cancelPendingRequest: {
                        _ = AccountManager.shared.find(for: owner)?
                            .mam
                            .cancelPendingArchiveRequest(queryId: queryId)
                    },
                    completeSchedulerLease: schedulerLease.complete
                )
            }
        ) { page, completion in
            ChatRemoteHistoryCompletionCoordinator.flushQueryMessagesAsync(
                owner: owner,
                queryId: queryId,
                state: page.state,
                conversationJid: jid,
                conversationType: conversationType
            ) { result in
                if result.persistenceSummary.failed > 0,
                   result.persistenceSummary.persistedRows == 0,
                   result.persistenceSummary.received > 0 {
                    completion(.failure(ChatRemoteHistoryPersistenceBarrierError(
                        failedRows: result.persistenceSummary.failed
                    )))
                } else {
                    completion(.success(result))
                }
            }
        }
        guard didRegister else {
            assertionFailure("Duplicate remote MAM query registration: \(queryId)")
            schedulerLease.complete()
            self.timelineInteractionState.unlock()
            return false
        }
        self.timelineInteractionState.locked = true
        return true
    }

    private func beginVisibleRemoteHistoryLoading(
        direction: ChatHistoryPageDirection,
        decision: ChatHistoryPagingLoadDecision,
        queryId: String,
        currentWindow: ChatDatasetWindow
    ) {
        ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestSendStarted", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId),
            ("direction", direction),
            ("decision", "\(decision)"),
            ("cursor", self.interactiveHistoryPageLoadContext?.requestedCursorId ?? "-"),
            ("visibleLoaderBefore", self.timelineInteractionState.isLoading),
            ("placeholderBefore", self.activeHistoryBoundaryPlaceholder != nil || self.virtualTimelineState.activePlaceholder != nil)
        ])
        self.beginHistoryLoadingUI(queryId: queryId)
        self.showHistoryBoundaryPlaceholder(direction: direction, currentWindow: currentWindow)
    }

    private func shouldDispatchInteractiveRemoteArchiveRequestOnMain(queryId: String) -> Bool {
        if Thread.isMainThread {
            return self.shouldDispatchInteractiveRemoteArchiveRequest(queryId: queryId)
        }
        return DispatchQueue.main.sync {
            self.shouldDispatchInteractiveRemoteArchiveRequest(queryId: queryId)
        }
    }

    private func enqueueInteractiveRemoteArchiveRequest(
        queryId: String,
        direction: ChatHistoryPageDirection,
        decision: ChatHistoryPagingLoadDecision,
        schedulerLease: ChatInteractiveRemoteArchiveSchedulerLease,
        cursorId: String?,
        pageSize: Int,
        currentWindow: ChatDatasetWindow,
        cursorSource: ChatInteractiveOlderCursorSelectionSource? = nil,
        timelineOldestCursorId: String? = nil,
        boundedOldestCursorId: String? = nil,
        persistedCursorId: String? = nil,
        send: @escaping (_ stream: XMPPStream, _ mam: MessageArchiveManager) -> String
    ) {
        let request = ChatInteractiveRemoteArchiveDispatchRequest(
            owner: self.owner,
            queryId: queryId,
            direction: direction,
            cursorId: cursorId,
            pageSize: pageSize,
            priority: .interactive,
            resource: .mamArchive,
            deduplicationKey: "chat.interactive-history.\(queryId)",
            schedulerLease: schedulerLease,
            shouldDispatch: { [weak self] in
                self?.shouldDispatchInteractiveRemoteArchiveRequestOnMain(queryId: queryId) ?? false
            },
            send: { [weak self] account, stream in
                guard let self else {
                    return nil
                }
                self.registerRemoteHistoryPersistenceSource(
                    account.messages,
                    archiveManager: account.mam,
                    queryId: queryId
                )
                return send(stream, account.mam)
            },
            transportStarted: { [weak self] sentQueryId, streamKind, resource in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    guard self.markInteractiveRemoteArchiveRequestSent(
                        queryId: sentQueryId,
                        direction: direction,
                        cursorId: cursorId,
                        pageSize: pageSize,
                        streamKind: streamKind,
                        resource: resource,
                        bootstrapActive: self.isInitialBootstrapInFlight,
                        cursorSource: cursorSource,
                        timelineOldestCursorId: timelineOldestCursorId,
                        boundedOldestCursorId: boundedOldestCursorId,
                        persistedCursorId: persistedCursorId
                    ) else {
                        return
                    }
                    self.beginVisibleRemoteHistoryLoading(
                        direction: direction,
                        decision: decision,
                        queryId: sentQueryId,
                        currentWindow: currentWindow
                    )
                }
            },
            performanceFixtureSend: { [weak self] stream, mam, messages in
                guard let self else { return nil }
                self.registerRemoteHistoryPersistenceSource(
                    messages,
                    archiveManager: mam,
                    queryId: queryId
                )
                return send(stream, mam)
            },
            dispatchUnavailable: { [weak self] reason in
                DispatchQueue.main.async {
                    guard let self,
                          self.shouldDispatchInteractiveRemoteArchiveRequest(queryId: queryId) else {
                        return
                    }
                    ChatArchiveDebugTrace.log("interactiveRemoteArchiveRequestDispatchUnavailable", [
                        ("owner", self.owner),
                        ("jid", self.jid),
                        ("conversationType", self.conversationType.rawValue),
                        ("queryId", queryId),
                        ("direction", direction),
                        ("cursor", cursorId ?? "-"),
                        ("reason", reason),
                        ("visibleLoader", self.timelineInteractionState.isLoading),
                        ("placeholderState", self.activeHistoryBoundaryPlaceholder != nil || self.virtualTimelineState.activePlaceholder != nil)
                    ])
                    self.abortInteractiveHistoryPageLoad()
                }
            }
        )
        self.interactiveRemoteArchiveRequestDispatcher.enqueue(request)
    }

    private func registerInteractiveHistoryPagePerformanceTrace(
        queryId: String,
        direction: ChatHistoryPageDirection
    ) -> ChatOpenPerformanceTraceContext? {
        let purpose = self.chatOpenPerformanceTraceContext.flatMap {
            ChatOpenPerformanceTracePurpose(rawValue: $0.purposeCode)
        } ?? .normalRoute
        let context = ChatOpenPerformanceTraceContextFactory.make(
            kind: .paging,
            purpose: purpose
        )
        let operation: ChatArchivePerformanceTraceOperation =
            direction == .older ? .olderPage : .newerPage
        guard ChatArchivePerformanceTraceRegistry.shared.register(
            owner: self.owner,
            queryID: queryId,
            context: context,
            operation: operation
        ) != .rejected else {
            return nil
        }
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.performanceFixtureLinkedPageTraceContextHandler?(context)
#endif
        return context
    }

    private func cancelInteractiveHistoryPagePerformanceTrace(
        queryId: String,
        context: ChatOpenPerformanceTraceContext?
    ) {
        guard let context else {
            return
        }
        _ = ChatArchivePerformanceTraceRegistry.shared.terminate(
            owner: self.owner,
            queryID: queryId,
            context: context,
            terminal: .cancelled
        )
    }
    
    internal final func loadDatasource(
        preparation: ChatInteractiveHistoryPagingPreparation,
        callback: @escaping ((ChatTimelineSnapshot?) -> Void)
    ) {
        if self.archiveEnginePresentationActive {
            self.submitArchiveEnginePage(direction: preparation.direction)
            self.timelineInteractionState.unlock()
            callback(nil)
            return
        }
        guard let residentSnapshot = self.timelineSession?.snapshot,
              residentSnapshot.generation == preparation.preparedPage.baseGeneration,
              preparation.preparedPage.conversationKey == self.chatTimelineConversationKey else {
            self.setDatasourceLoadingEnabled(true)
            self.timelineInteractionState.unlock()
            callback(nil)
            return
        }
        let direction = preparation.direction
        let currentWindow = preparation.currentWindow
        let requestedWindow = preparation.requestedWindow
        let chatArchiveState = preparation.archiveState
        let persistedArchiveEnded = chatArchiveState.fullArchiveLoaded
        let effectiveArchiveEnded = preparation.virtualArchiveState.fullArchiveLoaded
        let shouldProbePersistedArchiveEnd = persistedArchiveEnded && !effectiveArchiveEnded
        let virtualSnapshot = preparation.snapshot
        let decision = virtualSnapshot.loadDecision
        ChatArchiveDebugTrace.log("timelinePagingDecision", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("direction", direction),
            ("decision", "\(decision)"),
            ("snapshotItems", virtualSnapshot.items.count),
            ("snapshotOldest", virtualSnapshot.state.oldest?.archivedId ?? "-"),
            ("snapshotNewest", virtualSnapshot.state.newest?.archivedId ?? "-"),
            ("snapshotResident", virtualSnapshot.state.residentPrimaryKeys.count),
            ("localOlderCandidateCount", virtualSnapshot.localOlderCandidateCount ?? -1),
            ("pageSize", virtualSnapshot.pageSize ?? self.datasourcePageSize),
            ("shortLocalRemainderRemoteFirst", virtualSnapshot.shortLocalRemainderRemoteFirst),
            ("currentOldest", self.virtualTimelineState.oldest?.archivedId ?? "-"),
            ("currentNewest", self.virtualTimelineState.newest?.archivedId ?? "-"),
            ("currentResident", self.virtualTimelineState.residentPrimaryKeys.count),
            ("boundedOldest", self.boundedTimelineWindowState.oldest?.archivedId ?? "-"),
            ("boundedNewest", self.boundedTimelineWindowState.newest?.archivedId ?? "-"),
            ("datasourceFirst", self.datasource.first?.archivedId ?? "-"),
            ("datasourceLast", self.datasource.last?.archivedId ?? "-"),
            ("residentCount", self.timelineSession?.snapshot.items.count ?? -1)
        ])

        let pagingPlan = preparation.pagingPlan
        if !pagingPlan.shouldShowOverlay {
            self.logInteractiveHistoryPagingPlan(
                direction: direction,
                plan: pagingPlan,
                localItemCount: virtualSnapshot.items.count,
                localOlderCandidateCount: virtualSnapshot.localOlderCandidateCount,
                pageSize: virtualSnapshot.pageSize,
                shortLocalRemainderRemoteFirst: virtualSnapshot.shortLocalRemainderRemoteFirst
            )
        }

        switch pagingPlan {
        case .local:
            let context = ChatOpenPerformanceTraceContextFactory.make(
                kind: .paging,
                purpose: self.chatOpenPerformanceTraceContext.flatMap {
                    ChatOpenPerformanceTracePurpose(rawValue: $0.purposeCode)
                } ?? .normalRoute
            )
            _ = ChatArchivePerformanceTraceRegistry.shared.recordLocalPagePlan(
                context: context,
                directionCode: direction == .older ? 1 : 2
            )
            callback(virtualSnapshot)
        case .remote(.remoteOlderPage):
            let cursorSelection = self.interactiveOlderPagingCursorSelection(
                in: currentWindow,
                persistedCursorId: chatArchiveState.persistedCursorId
            )
            let archivedId = cursorSelection.cursorId
            ChatArchiveDebugTrace.log("remoteOlderCursorSelection", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("requestedCursor", archivedId ?? "-"),
                ("cursorSource", cursorSelection.source.rawValue),
                ("timelineOldest", self.virtualTimelineState.oldest?.archivedId ?? "-"),
                ("boundedOldest", self.boundedTimelineWindowState.oldest?.archivedId ?? "-"),
                ("observedOldest", self.observedArchivedIds(in: currentWindow).first(where: { $0.isNotEmpty }) ?? "-"),
                ("persistedCursor", chatArchiveState.persistedCursorId ?? "-"),
                ("cursorDiffersFromPersisted", archivedId != chatArchiveState.persistedCursorId)
            ])
            let queryId = "MAM next history: \(NanoID.new(6))"
            let performanceTraceContext =
                self.registerInteractiveHistoryPagePerformanceTrace(
                    queryId: queryId,
                    direction: direction
                )
            self.registerRemoteHistoryEndPageDispatcher(queryId: queryId)
            self.registerRemoteHistoryFailureDispatcher(queryId: queryId)
            let armedSnapshot = self.armedRemoteSnapshot(
                from: virtualSnapshot,
                queryId: queryId,
                direction: direction,
                decision: .remoteOlderPage,
                cursorId: archivedId
            )
            self.applyVirtualTimelineSnapshotState(armedSnapshot)
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: nil,
                onEndPage: { [weak self] queryId, state, first, last, count in
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                }
            )
            self.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
                queryId: queryId,
                performanceTraceOwner: self.owner,
                performanceTraceContext: performanceTraceContext,
                generation: Int(self.timelineSession?.snapshot.generation ?? 0),
                direction: direction,
                chatPrimaryKey: chatArchiveState.primaryKey,
                persistedCursorId: chatArchiveState.persistedCursorId,
                persistedFullArchiveLoaded: chatArchiveState.fullArchiveLoaded,
                requestedCursorId: archivedId,
                requestedWindow: requestedWindow,
                preLoadObserverCount: residentSnapshot.items.count,
                preLoadOldestArchivedId: self.observedOldestArchivedId(),
                preLoadNewestArchivedId: self.observedNewestArchivedId(),
                preLoadFullArchiveLoaded: shouldProbePersistedArchiveEnd ? false : persistedArchiveEnded,
                preLoadNewerLiveEdgeReached: chatArchiveState.newerLiveEdgeReached,
                remoteFetchStarted: false,
                isArchiveEndVerificationProbe: shouldProbePersistedArchiveEnd,
                canMutateOlderArchiveEnd: true,
                expectedWindowMaxIndex: requestedWindow.maxIndex,
                coverageUpdateKind: .pageOlder(cursorArchiveId: archivedId)
            )
            let schedulerLease = ChatInteractiveRemoteArchiveSchedulerLease()
            guard self.armRemoteInteractiveHistoryRequest(
                direction: direction,
                decision: .remoteOlderPage,
                queryId: queryId,
                schedulerLease: schedulerLease,
                localItemCount: armedSnapshot.items.count,
                localOlderCandidateCount: armedSnapshot.localOlderCandidateCount,
                pageSize: armedSnapshot.pageSize,
                shortLocalRemainderRemoteFirst: armedSnapshot.shortLocalRemainderRemoteFirst
            ) else {
                self.cancelInteractiveHistoryPagePerformanceTrace(
                    queryId: queryId,
                    context: performanceTraceContext
                )
                callback(nil)
                return
            }
            self.scheduleInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)

            let requestRemoteHistory: (XMPPStream, MessageArchiveManager) -> String = { stream, mam in
                mam.requestOlderHistoryPage(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    messageId: archivedId,
                    pageSize: self.datasourcePageSize,
                    queryId: queryId,
                    callback: nil,
                    requestCallbacks: requestCallbacks,
                    deferCoverageCommitUntilConsumerProof: true
                )
            }

            self.enqueueInteractiveRemoteArchiveRequest(
                queryId: queryId,
                direction: direction,
                decision: .remoteOlderPage,
                schedulerLease: schedulerLease,
                cursorId: archivedId,
                pageSize: self.datasourcePageSize,
                currentWindow: currentWindow,
                cursorSource: cursorSelection.source,
                timelineOldestCursorId: self.virtualTimelineState.oldest?.archivedId,
                boundedOldestCursorId: self.boundedTimelineWindowState.oldest?.archivedId,
                persistedCursorId: chatArchiveState.persistedCursorId,
                send: requestRemoteHistory
            )
        case .remote(.remoteNewerPage):
            guard let archivedId = self.visibleNewerPagingCursorId(in: currentWindow, persistedCursorId: chatArchiveState.newestCursorId),
                  archivedId.isNotEmpty else {
                self.setDatasourceLoadingEnabled(true)
                self.timelineInteractionState.unlock()
                callback(nil)
                return
            }
            let queryId = "MAM prev history: \(NanoID.new(6))"
            let performanceTraceContext =
                self.registerInteractiveHistoryPagePerformanceTrace(
                    queryId: queryId,
                    direction: direction
                )
            self.registerRemoteHistoryEndPageDispatcher(queryId: queryId)
            self.registerRemoteHistoryFailureDispatcher(queryId: queryId)
            let armedSnapshot = self.armedRemoteSnapshot(
                from: virtualSnapshot,
                queryId: queryId,
                direction: direction,
                decision: .remoteNewerPage,
                cursorId: archivedId
            )
            self.applyVirtualTimelineSnapshotState(armedSnapshot)
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: nil,
                onEndPage: { [weak self] queryId, state, first, last, count in
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                }
            )
            self.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
                queryId: queryId,
                performanceTraceOwner: self.owner,
                performanceTraceContext: performanceTraceContext,
                generation: Int(self.timelineSession?.snapshot.generation ?? 0),
                direction: direction,
                chatPrimaryKey: chatArchiveState.primaryKey,
                persistedCursorId: chatArchiveState.newestCursorId,
                persistedFullArchiveLoaded: chatArchiveState.fullArchiveLoaded,
                requestedCursorId: archivedId,
                requestedWindow: requestedWindow,
                preLoadObserverCount: residentSnapshot.items.count,
                preLoadOldestArchivedId: self.observedOldestArchivedId(),
                preLoadNewestArchivedId: self.observedNewestArchivedId(),
                preLoadFullArchiveLoaded: effectiveArchiveEnded,
                preLoadNewerLiveEdgeReached: chatArchiveState.newerLiveEdgeReached,
                remoteFetchStarted: false,
                isArchiveEndVerificationProbe: false,
                canMutateOlderArchiveEnd: false,
                expectedWindowMaxIndex: requestedWindow.maxIndex,
                coverageUpdateKind: .pageNewer(cursorArchiveId: archivedId)
            )
            let schedulerLease = ChatInteractiveRemoteArchiveSchedulerLease()
            guard self.armRemoteInteractiveHistoryRequest(
                direction: direction,
                decision: .remoteNewerPage,
                queryId: queryId,
                schedulerLease: schedulerLease,
                localItemCount: armedSnapshot.items.count
            ) else {
                self.cancelInteractiveHistoryPagePerformanceTrace(
                    queryId: queryId,
                    context: performanceTraceContext
                )
                callback(nil)
                return
            }
            self.scheduleInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)

            let requestRemoteHistory: (XMPPStream, MessageArchiveManager) -> String = { stream, mam in
                mam.requestNewerHistoryPage(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    messageId: archivedId,
                    pageSize: self.datasourcePageSize,
                    queryId: queryId,
                    callback: nil,
                    requestCallbacks: requestCallbacks,
                    deferCoverageCommitUntilConsumerProof: true
                )
            }

            self.enqueueInteractiveRemoteArchiveRequest(
                queryId: queryId,
                direction: direction,
                decision: .remoteNewerPage,
                schedulerLease: schedulerLease,
                cursorId: archivedId,
                pageSize: self.datasourcePageSize,
                currentWindow: currentWindow,
                send: requestRemoteHistory
            )
        case .remote(.remoteGapRepairOlder(let gap)):
            let archivedId = gap.newerRangeOldestArchiveId
            let queryId = "MAM gap repair history: \(NanoID.new(6))"
            let performanceTraceContext =
                self.registerInteractiveHistoryPagePerformanceTrace(
                    queryId: queryId,
                    direction: direction
                )
            self.registerRemoteHistoryEndPageDispatcher(queryId: queryId)
            self.registerRemoteHistoryFailureDispatcher(queryId: queryId)
            let armedSnapshot = self.armedRemoteSnapshot(
                from: virtualSnapshot,
                queryId: queryId,
                direction: direction,
                decision: .remoteGapRepairOlder(gap),
                cursorId: archivedId
            )
            self.applyVirtualTimelineSnapshotState(armedSnapshot)
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: nil,
                onEndPage: { [weak self] queryId, state, first, last, count in
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                }
            )
            self.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
                queryId: queryId,
                performanceTraceOwner: self.owner,
                performanceTraceContext: performanceTraceContext,
                generation: Int(self.timelineSession?.snapshot.generation ?? 0),
                direction: direction,
                chatPrimaryKey: chatArchiveState.primaryKey,
                persistedCursorId: chatArchiveState.persistedCursorId,
                persistedFullArchiveLoaded: chatArchiveState.fullArchiveLoaded,
                requestedCursorId: archivedId,
                requestedWindow: requestedWindow,
                preLoadObserverCount: residentSnapshot.items.count,
                preLoadOldestArchivedId: self.observedOldestArchivedId(),
                preLoadNewestArchivedId: self.observedNewestArchivedId(),
                preLoadFullArchiveLoaded: effectiveArchiveEnded,
                preLoadNewerLiveEdgeReached: chatArchiveState.newerLiveEdgeReached,
                remoteFetchStarted: false,
                isArchiveEndVerificationProbe: false,
                canMutateOlderArchiveEnd: false,
                expectedWindowMaxIndex: requestedWindow.maxIndex,
                coverageUpdateKind: .gapRepairOlder(cursorArchiveId: archivedId)
            )
            let schedulerLease = ChatInteractiveRemoteArchiveSchedulerLease()
            guard self.armRemoteInteractiveHistoryRequest(
                direction: direction,
                decision: .remoteGapRepairOlder(gap),
                queryId: queryId,
                schedulerLease: schedulerLease,
                localItemCount: armedSnapshot.items.count
            ) else {
                self.cancelInteractiveHistoryPagePerformanceTrace(
                    queryId: queryId,
                    context: performanceTraceContext
                )
                callback(nil)
                return
            }
            self.scheduleInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)

            let requestRemoteHistory: (XMPPStream, MessageArchiveManager) -> String = { stream, mam in
                mam.getGapRepairHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    gap: gap,
                    direction: .older,
                    pageSize: self.datasourcePageSize,
                    queryId: queryId,
                    callback: nil,
                    requestCallbacks: requestCallbacks,
                    deferCoverageCommitUntilConsumerProof: true
                )
            }

            self.enqueueInteractiveRemoteArchiveRequest(
                queryId: queryId,
                direction: direction,
                decision: .remoteGapRepairOlder(gap),
                schedulerLease: schedulerLease,
                cursorId: archivedId,
                pageSize: self.datasourcePageSize,
                currentWindow: currentWindow,
                send: requestRemoteHistory
            )
        case .remote(.remoteGapRepairNewer(let gap)):
            let archivedId = gap.olderRangeNewestArchiveId
            let queryId = "MAM gap repair history: \(NanoID.new(6))"
            let performanceTraceContext =
                self.registerInteractiveHistoryPagePerformanceTrace(
                    queryId: queryId,
                    direction: direction
                )
            self.registerRemoteHistoryEndPageDispatcher(queryId: queryId)
            self.registerRemoteHistoryFailureDispatcher(queryId: queryId)
            let armedSnapshot = self.armedRemoteSnapshot(
                from: virtualSnapshot,
                queryId: queryId,
                direction: direction,
                decision: .remoteGapRepairNewer(gap),
                cursorId: archivedId
            )
            self.applyVirtualTimelineSnapshotState(armedSnapshot)
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: nil,
                onEndPage: { [weak self] queryId, state, first, last, count in
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                }
            )
            self.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
                queryId: queryId,
                performanceTraceOwner: self.owner,
                performanceTraceContext: performanceTraceContext,
                generation: Int(self.timelineSession?.snapshot.generation ?? 0),
                direction: direction,
                chatPrimaryKey: chatArchiveState.primaryKey,
                persistedCursorId: chatArchiveState.newestCursorId,
                persistedFullArchiveLoaded: chatArchiveState.fullArchiveLoaded,
                requestedCursorId: archivedId,
                requestedWindow: requestedWindow,
                preLoadObserverCount: residentSnapshot.items.count,
                preLoadOldestArchivedId: self.observedOldestArchivedId(),
                preLoadNewestArchivedId: self.observedNewestArchivedId(),
                preLoadFullArchiveLoaded: effectiveArchiveEnded,
                preLoadNewerLiveEdgeReached: chatArchiveState.newerLiveEdgeReached,
                remoteFetchStarted: false,
                isArchiveEndVerificationProbe: false,
                canMutateOlderArchiveEnd: false,
                expectedWindowMaxIndex: requestedWindow.maxIndex,
                coverageUpdateKind: .gapRepairNewer(cursorArchiveId: archivedId)
            )
            let schedulerLease = ChatInteractiveRemoteArchiveSchedulerLease()
            guard self.armRemoteInteractiveHistoryRequest(
                direction: direction,
                decision: .remoteGapRepairNewer(gap),
                queryId: queryId,
                schedulerLease: schedulerLease,
                localItemCount: armedSnapshot.items.count
            ) else {
                self.cancelInteractiveHistoryPagePerformanceTrace(
                    queryId: queryId,
                    context: performanceTraceContext
                )
                callback(nil)
                return
            }
            self.scheduleInteractiveRemoteArchiveRequestStartWatchdog(queryId: queryId)

            let requestRemoteHistory: (XMPPStream, MessageArchiveManager) -> String = { stream, mam in
                mam.getGapRepairHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    gap: gap,
                    direction: .newer,
                    pageSize: self.datasourcePageSize,
                    queryId: queryId,
                    callback: nil,
                    requestCallbacks: requestCallbacks,
                    deferCoverageCommitUntilConsumerProof: true
                )
            }

            self.enqueueInteractiveRemoteArchiveRequest(
                queryId: queryId,
                direction: direction,
                decision: .remoteGapRepairNewer(gap),
                schedulerLease: schedulerLease,
                cursorId: archivedId,
                pageSize: self.datasourcePageSize,
                currentWindow: currentWindow,
                send: requestRemoteHistory
            )
        case .endReached, .noOp, .remote(.localOnly), .remote(.endReached):
            self.setDatasourceLoadingEnabled(true)
            self.timelineInteractionState.unlock()
            callback(nil)
            return
        }
    }

    
    func didReceiveChangeset() {
        if self.archiveEnginePresentationActive {
            return
        }
        if ChatInitialFrameObserverRefreshBarrierPolicy.shouldDefer(
            phase: self.initialLocalFirstFramePhase,
            hasCommittedTimelinePresentation:
                self.hasCommittedTimelinePresentationInCurrentLifecycle
        ) {
            self.pendingArchiveObserverRefresh = true
            self.archiveObserverRefreshWorkItem?.cancel()
            self.archiveObserverRefreshWorkItem = nil
            self.logArchiveObserverRefreshBackpressure(
                action: "changesetDeferredForInitialFrame"
            )
            return
        }
        var observerRefreshSignpost = ChatPerformanceSignposts.begin(.observerRefresh)
        defer {
            observerRefreshSignpost.end()
        }
        let startedAt = Date()
        if self.datasource.isNotEmpty {
            self.setShouldShowInitialMessage(false)
        }
        let normalizedState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        let wasNearBottom = self.isNearBottom()
        let isSearchModeActive = self.isChatSearchInputKeyboardOwned
        let hasSearchAnchorWork = self.pendingOpenMessageRequest != nil ||
            self.activeAnchorExecutionState != nil ||
            self.searchResultNavigationState.isBusy
        if hasSearchAnchorWork {
            self.rebuildUnreadMentionItems()
            self.pendingArchiveObserverRefresh = true
            self.archiveObserverRefreshWorkItem?.cancel()
            self.archiveObserverRefreshWorkItem = nil
            ChatArchiveDebugTrace.log("observerRefreshDecision", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("action", "deferSearchNavigation"),
                ("hasSearchAnchorWork", true),
                ("datasourceFirst", self.datasource.first?.archivedId ?? "-"),
                ("datasourceLast", self.datasource.last?.archivedId ?? "-"),
                ("datasourceCount", self.datasource.count)
            ])
            self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
            return
        }
        let completion = {
            ChatArchiveDebugTrace.log("observerRefreshCompletion", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt)),
                ("oldest", self.virtualTimelineState.oldest?.archivedId ?? "-"),
                ("newest", self.virtualTimelineState.newest?.archivedId ?? "-"),
                ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count),
                ("datasourceCount", self.datasource.count),
                ("hasSearchAnchorWork", hasSearchAnchorWork)
            ])
            if hasSearchAnchorWork {
                self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
                return
            }
            if self.pendingForceLatestOpen {
                self.finishLatestBottomScroll(
                    animated: self.pendingForceLatestOpenAnimated && !self.initialHistoryAppearancePending,
                    consumePendingForceLatest: true
                )
                return
            }
            self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
        }
        let shouldSuppressOpenLatestForSearchPosition = ChatObserverRefreshAnchorRestorePolicy.shouldSuppressOpenLatest(
            isSearchModeActive: isSearchModeActive,
            isNearBottom: wasNearBottom,
            hasPendingForceLatestOpen: self.pendingForceLatestOpen
        )
        let baseShouldOpenLatest = !hasSearchAnchorWork && !shouldSuppressOpenLatestForSearchPosition && (
            ChatTimelineObserverRefreshPolicy.shouldOpenLatest(
                isTimelineEmpty: normalizedState.isEmpty,
                isResidentAtLiveTail: normalizedState.isResidentAtLiveTail,
                isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder,
                hasActiveRemoteLoad: normalizedState.activeRemoteLoad != nil,
                hasInteractiveRemoteContext: self.interactiveHistoryPageLoadContext != nil,
                hasSearchAnchorWork: hasSearchAnchorWork
            ) || self.pendingForceLatestOpen
        )
        let stabilizationAction = self.initialLatestObserverRefreshAction(baseShouldOpenLatest: baseShouldOpenLatest)
        let shouldOpenLatest = stabilizationAction == .openLatestNonAnimated ||
            (stabilizationAction == .followDefault && baseShouldOpenLatest)
        let observerRefreshAnchorDirection = ChatObserverRefreshAnchorRestorePolicy.visibleAnchorDirection(
            isSearchModeActive: isSearchModeActive,
            isNearBottom: wasNearBottom,
            willOpenLatest: shouldOpenLatest,
            hasSearchAnchorWork: hasSearchAnchorWork,
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
        )
        let observerRefreshAnchor = observerRefreshAnchorDirection.flatMap {
            self.capturePagingAnchorIfNeeded(direction: $0)
        }
        let observerRefreshAnchorRestorePhase = ChatObserverRefreshAnchorRestorePolicy.restorePhase(
            hasCapturedAnchor: observerRefreshAnchor != nil
        )
        let currentWindowCompletion = completion
        ChatArchiveDebugTrace.log("observerRefreshDecision", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("action", shouldOpenLatest ? "openLatest" : "current"),
            ("stabilizationAction", "\(stabilizationAction)"),
            ("suppressSearchOpenLatest", shouldSuppressOpenLatestForSearchPosition),
            ("observerAnchorDirection", observerRefreshAnchorDirection.map { "\($0)" } ?? "-"),
            ("observerAnchorPrimary", observerRefreshAnchor?.primary ?? "-"),
            ("isTimelineEmpty", normalizedState.isEmpty),
            ("isResidentAtLiveTail", normalizedState.isResidentAtLiveTail),
            ("isShowingBootstrapPlaceholder", self.isShowingBootstrapPlaceholder),
            ("activeRemoteLoad", normalizedState.activeRemoteLoad?.queryId ?? "-"),
            ("interactiveQueryId", self.interactiveHistoryPageLoadContext?.queryId ?? "-"),
            ("hasSearchAnchorWork", hasSearchAnchorWork),
            ("oldest", normalizedState.oldest?.archivedId ?? "-"),
            ("newest", normalizedState.newest?.archivedId ?? "-"),
            ("residentCount", normalizedState.residentPrimaryKeys.count),
            ("datasourceFirst", self.datasource.first?.archivedId ?? "-"),
            ("datasourceLast", self.datasource.last?.archivedId ?? "-"),
            ("datasourceCount", self.datasource.count)
        ])
        switch stabilizationAction {
        case .keepCurrentNoScroll:
            self.mapAndApplyTimelineCurrent(
                mode: .targetedDiff,
                isObserverCurrentRoute: true,
                animated: false,
                invalidateLayout: false,
                suppressDefaultBottomScroll: true,
                anchorRestorePhase: observerRefreshAnchorRestorePhase,
                anchorPrimary: observerRefreshAnchor?.primary,
                restoreAnchor: observerRefreshAnchor,
                completion: currentWindowCompletion
            )
        case .openLatestNonAnimated:
            let applyCompletion = {
                completion()
                self.finishLatestBottomScroll(
                    animated: false,
                    consumePendingForceLatest: self.pendingForceLatestOpen
                )
            }
            self.mapAndApplyTimelineLatest(
                mode: .targetedDiff,
                animated: false,
                invalidateLayout: false,
                limit: self.initialFirstFramePageSize,
                suppressDefaultBottomScroll: true,
                forceBottomAlignmentTarget: .newestRealMessage,
                completion: applyCompletion
            )
        case .followDefault where shouldOpenLatest:
            if ChatTimelineObserverRefreshWindowPolicy.shouldReuseCurrentBoundedWindow(
                isTimelineEmpty: normalizedState.isEmpty,
                isResidentAtLiveTail: normalizedState.isResidentAtLiveTail,
                isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder,
                hasPendingForceLatestOpen: self.pendingForceLatestOpen
            ) {
                self.mapAndApplyTimelineCurrent(
                    mode: .targetedDiff,
                    isObserverCurrentRoute: true,
                    animated: self.shouldAnimateInitialHistoryAppearance,
                    invalidateLayout: false,
                    completion: completion
                )
            } else {
                self.mapAndApplyTimelineLatest(
                    mode: .targetedDiff,
                    animated: self.shouldAnimateInitialHistoryAppearance,
                    invalidateLayout: false,
                    completion: completion
                )
            }
        case .followDefault:
            self.mapAndApplyTimelineCurrent(
                mode: .targetedDiff,
                isObserverCurrentRoute: true,
                animated: self.shouldAnimateInitialHistoryAppearance,
                invalidateLayout: false,
                anchorRestorePhase: observerRefreshAnchorRestorePhase,
                anchorPrimary: observerRefreshAnchor?.primary,
                restoreAnchor: observerRefreshAnchor,
                completion: currentWindowCompletion
            )
        }
    }
    
    internal func scrollToLastOrUnreadItem() {
        if ChatInitialScrollPolicy.shouldDeferDefaultScroll(
            hasPendingAnchorRequest: self.pendingOpenMessageRequest != nil,
            isAnchorNavigationInFlight: self.isMessageAnchorNavigationInFlight
        ) {
            self.performPendingOpenMessageRequestIfNeeded()
            return
        }
        let shouldAnimateScroll = !self.initialHistoryAppearancePending

        if ChatOpenMessageRequestHandlingPolicy.shouldForceLatestOnOpen() {
            self.requestForceLatestOpen(animated: shouldAnimateScroll)
            return
        }

        self.scrollToLatestTimeline(animated: shouldAnimateScroll)
    }
}
