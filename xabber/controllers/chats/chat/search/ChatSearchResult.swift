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

/// Namespaced in-chat-search selection identities. The string is stored by
/// legacy UIKit state, so its namespace keeps a raw stanza ID from colliding
/// with an explicit outer MAM result ID or a local primary key.
enum ChatSearchSelectionIdentity {
    private static let mamPrefix = "mam:"
    private static let primaryPrefix = "primary:"
    private static let rawPrefix = "raw:"

    static func make(
        mamArchiveId: String?,
        primary: String?,
        archivedId: String?
    ) -> String? {
        if let mamArchiveId = normalizedMAMArchiveID(mamArchiveId) {
            return mamPrefix + mamArchiveId
        }
        if let primary, primary.isNotEmpty {
            return primaryPrefix + primary
        }
        if let archivedId, archivedId.isNotEmpty {
            return rawPrefix + archivedId
        }
        return nil
    }

    static func matches(
        _ selectedID: String?,
        mamArchiveId: String?,
        primary: String?,
        archivedId: String?
    ) -> Bool {
        guard let selectedID, selectedID.isNotEmpty else {
            return false
        }
        if let payload = payload(in: selectedID, prefix: primaryPrefix) {
            return primary == payload
        }
        if let payload = payload(in: selectedID, prefix: mamPrefix) {
            return mamArchiveId.flatMap(ArchiveCursor.init(rawValue:)) == ArchiveCursor(rawValue: payload)
        }
        if let payload = payload(in: selectedID, prefix: rawPrefix) {
            return archivedId == payload
        }

        // Read transient pre-namespace selection state deterministically while
        // all newly created identities remain namespaced.
        return primary == selectedID ||
            mamArchiveId.flatMap(ArchiveCursor.init(rawValue:)) == ArchiveCursor(rawValue: selectedID) ||
            archivedId == selectedID
    }

    private static func normalizedMAMArchiveID(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.isNotEmpty ? value : nil
    }

    private static func payload(in value: String, prefix: String) -> String? {
        guard value.hasPrefix(prefix) else { return nil }
        let payload = String(value.dropFirst(prefix.count))
        return payload.isNotEmpty ? payload : nil
    }
}

struct ChatSearchResult: Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case archived(String)
        case primary(String)

        static func == (lhs: ID, rhs: ID) -> Bool {
            switch (lhs, rhs) {
            case let (.archived(a), .archived(b)):
                return a.utf8.elementsEqual(b.utf8)
            case let (.primary(a), .primary(b)):
                return a == b
            default:
                return false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .archived(let value):
                hasher.combine(0)
                hasher.combine(value.utf8.count)
                for byte in value.utf8 { hasher.combine(byte) }
            case .primary(let value):
                hasher.combine(1)
                hasher.combine(value)
            }
        }
    }

    struct Scope: Equatable, Sendable {
        let owner: String
        let jid: String
        let conversationTypeRawValue: String
    }

    struct Anchor: Equatable, Sendable {
        let primary: String
        /// Opaque local/protocol identity retained for local resolution.
        let archivedId: String
        /// Verified outer MAM result ID, when this result originated from a
        /// current archive row or archive-search response. It is intentionally
        /// absent for legacy rows that only have a protocol stanza ID.
        let archiveCursorID: String?
        let messageId: String
        let authorId: String?
        let date: Date

        init(
            primary: String,
            archivedId: String,
            archiveCursorID: String? = nil,
            messageId: String,
            authorId: String?,
            date: Date
        ) {
            self.primary = primary
            self.archivedId = archivedId
            self.archiveCursorID = archiveCursorID
            self.messageId = messageId
            self.authorId = authorId
            self.date = date
        }
    }

    enum DeliveryState: Equatable, Sendable {
        case sent
        case delivered
        case read
        case failed
        case pending
    }

    struct Avatar: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            case contact(jid: String, owner: String)
            case group(userId: String, conversationJID: String, owner: String)
        }

        let identity: String
        let fallbackTitle: String
        let url: String?
        let source: Source
    }

    let id: ID
    let scope: Scope
    let anchor: Anchor
    let outgoing: Bool
    let senderTitle: String
    let body: String
    let snippet: String
    let deliveryState: DeliveryState
    let avatar: Avatar
}

struct ChatSearchResultMappingContext: Equatable, Sendable {
    let scope: ChatSearchResult.Scope
    let localizedYou: String
    let contactDisplayName: String
    let ownerAvatarURL: String?
    let contactAvatarURL: String?

    init(
        scope: ChatSearchResult.Scope,
        localizedYou: String,
        contactDisplayName: String,
        ownerAvatarURL: String? = nil,
        contactAvatarURL: String? = nil
    ) {
        self.scope = scope
        self.localizedYou = localizedYou
        self.contactDisplayName = contactDisplayName
        self.ownerAvatarURL = ownerAvatarURL
        self.contactAvatarURL = contactAvatarURL
    }
}

enum ChatSearchResultMapper {
    static func map(
        _ item: MessageStorageItem,
        context: ChatSearchResultMappingContext
    ) -> ChatSearchResult? {
        guard item.owner == context.scope.owner,
              item.opponent == context.scope.jid,
              item.conversationType.rawValue == context.scope.conversationTypeRawValue else {
            return nil
        }

        let primary = item.primary
        // Only an explicit outer MAM result ID may define the diffable
        // archive identity. `mamArchiveCursorID` falls back to the raw stanza
        // ID, which can numerically collide with another message's MAM ID.
        let selectionArchiveID = item.mamArchiveId
        let id: ChatSearchResult.ID
        if selectionArchiveID.isNotEmpty {
            id = .archived(selectionArchiveID)
        } else if primary.isNotEmpty {
            id = .primary(primary)
        } else {
            return nil
        }

        let body = item.body
        let senderTitle = senderTitle(for: item, context: context)
        return ChatSearchResult(
            id: id,
            scope: context.scope,
            anchor: ChatSearchResult.Anchor(
                primary: primary,
                // The local anchor must retain the protocol stanza identity.
                // `archiveCursorID` separately carries the verified outer
                // MAM result id when one is present.
                archivedId: item.archivedId,
                archiveCursorID: item.mamArchiveId.isNotEmpty
                    ? item.mamArchiveId
                    : nil,
                messageId: item.messageId,
                authorId: item.groupchatAuthorId,
                date: item.date
            ),
            outgoing: item.outgoing,
            senderTitle: senderTitle,
            body: body,
            snippet: body
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " "),
            deliveryState: deliveryState(for: item.state),
            avatar: avatar(for: item, senderTitle: senderTitle, context: context)
        )
    }

    static func map(
        _ message: ArchiveSearchMessage,
        context: ChatSearchResultMappingContext
    ) -> ChatSearchResult? {
        guard message.owner == context.scope.owner,
              message.conversationJID == context.scope.jid,
              message.conversationTypeRaw ==
                context.scope.conversationTypeRawValue else {
            return nil
        }
        let id: ChatSearchResult.ID
        if message.archiveID.isNotEmpty {
            id = .archived(message.archiveID)
        } else if message.primaryID.isNotEmpty {
            id = .primary(message.primaryID)
        } else {
            return nil
        }
        let conversationType = ClientSynchronizationManager.ConversationType(
            rawValue: message.conversationTypeRaw
        ) ?? .regular
        let senderTitle: String
        if message.outgoing {
            senderTitle = context.localizedYou
        } else if [.group, .channel].contains(conversationType) {
            senderTitle = nonEmpty(message.groupAuthorNickname)
                ?? nonEmpty(message.groupAuthorID)
                ?? nonEmpty(context.contactDisplayName)
                ?? message.conversationJID
        } else {
            senderTitle = nonEmpty(context.contactDisplayName)
                ?? message.conversationJID
        }
        let avatar: ChatSearchResult.Avatar
        if [.group, .channel].contains(conversationType) {
            let userID = nonEmpty(message.groupAuthorID)
                ?? (message.outgoing ? context.scope.owner : senderTitle)
            avatar = ChatSearchResult.Avatar(
                identity: "group:\(context.scope.owner)|\(context.scope.jid)|\(userID)",
                fallbackTitle: senderTitle,
                url: nonEmpty(message.groupAuthorAvatarURL),
                source: .group(
                    userId: userID,
                    conversationJID: context.scope.jid,
                    owner: context.scope.owner
                )
            )
        } else {
            let jid = message.outgoing
                ? context.scope.owner
                : context.scope.jid
            avatar = ChatSearchResult.Avatar(
                identity: "contact:\(context.scope.owner)|\(jid)",
                fallbackTitle: senderTitle,
                url: message.outgoing
                    ? context.ownerAvatarURL
                    : context.contactAvatarURL,
                source: .contact(jid: jid, owner: context.scope.owner)
            )
        }
        let body = message.body
        return ChatSearchResult(
            id: id,
            scope: context.scope,
            anchor: ChatSearchResult.Anchor(
                primary: message.primaryID,
                archivedId: message.archiveID,
                archiveCursorID: message.archiveID.isNotEmpty
                    ? message.archiveID
                    : nil,
                messageId: message.messageID,
                authorId: message.groupAuthorID,
                date: message.date
            ),
            outgoing: message.outgoing,
            senderTitle: senderTitle,
            body: body,
            snippet: body
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " "),
            deliveryState: deliveryState(rawValue: message.deliveryStateRaw),
            avatar: avatar
        )
    }

    private static func avatar(
        for item: MessageStorageItem,
        senderTitle: String,
        context: ChatSearchResultMappingContext
    ) -> ChatSearchResult.Avatar {
        switch item.conversationType {
        case .group, .channel:
            let userId = nonEmpty(item.groupchatAuthorId)
                ?? (item.outgoing ? context.scope.owner : senderTitle)
            let url = nonEmpty(item.groupchatAuthorAvatarURL)
            return ChatSearchResult.Avatar(
                identity: "group:\(context.scope.owner)|\(context.scope.jid)|\(userId)",
                fallbackTitle: senderTitle,
                url: url,
                source: .group(
                    userId: userId,
                    conversationJID: context.scope.jid,
                    owner: context.scope.owner
                )
            )
        default:
            let jid = item.outgoing ? context.scope.owner : context.scope.jid
            return ChatSearchResult.Avatar(
                identity: "contact:\(context.scope.owner)|\(jid)",
                fallbackTitle: senderTitle,
                url: item.outgoing ? context.ownerAvatarURL : context.contactAvatarURL,
                source: .contact(jid: jid, owner: context.scope.owner)
            )
        }
    }

    private static func senderTitle(
        for item: MessageStorageItem,
        context: ChatSearchResultMappingContext
    ) -> String {
        if item.outgoing {
            return context.localizedYou
        }

        switch item.conversationType {
        case .group, .channel:
            if let nickname = nonEmpty(item.groupchatAuthorNickname) {
                return nickname
            }
            if let authorId = nonEmpty(item.groupchatAuthorId) {
                return authorId
            }
            return nonEmpty(context.contactDisplayName) ?? item.opponent
        default:
            return nonEmpty(context.contactDisplayName) ?? item.opponent
        }
    }

    private static func deliveryState(
        for state: MessageStorageItem.MessageSendingState
    ) -> ChatSearchResult.DeliveryState {
        switch state {
        case .sended:
            return .sent
        case .deliver:
            return .delivered
        case .read:
            return .read
        case .error, .notSended:
            return .failed
        case .none, .sending, .uploading:
            return .pending
        }
    }

    private static func deliveryState(
        rawValue: Int
    ) -> ChatSearchResult.DeliveryState {
        guard let state = MessageStorageItem.MessageSendingState(
            rawValue: rawValue
        ) else {
            return .pending
        }
        return deliveryState(for: state)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }
        return value
    }
}

enum ChatSearchResultCollection {
    static func orderedAndDeduplicated(
        _ results: [ChatSearchResult]
    ) -> [ChatSearchResult] {
        var uniqueById: [ChatSearchResult.ID: ChatSearchResult] = [:]
        var order: [ChatSearchResult.ID] = []
        for result in results {
            if let existing = uniqueById[result.id] {
                uniqueById[result.id] = preferred(existing, result)
            } else {
                uniqueById[result.id] = result
                order.append(result.id)
            }
        }
        return order.compactMap { uniqueById[$0] }.enumerated().sorted { lhs, rhs in
            if lhs.element.anchor.date != rhs.element.anchor.date {
                return lhs.element.anchor.date > rhs.element.anchor.date
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func preferred(
        _ lhs: ChatSearchResult,
        _ rhs: ChatSearchResult
    ) -> ChatSearchResult {
        let lhsScore = completenessScore(lhs)
        let rhsScore = completenessScore(rhs)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore ? lhs : rhs
        }
        if lhs.anchor.date != rhs.anchor.date {
            return lhs.anchor.date > rhs.anchor.date ? lhs : rhs
        }
        if lhs.anchor.primary != rhs.anchor.primary {
            return lhs.anchor.primary > rhs.anchor.primary ? lhs : rhs
        }
        if lhs.body != rhs.body {
            return lhs.body > rhs.body ? lhs : rhs
        }
        return lhs
    }

    static func sortsBefore(
        _ lhs: ChatSearchResult,
        _ rhs: ChatSearchResult
    ) -> Bool {
        if lhs.anchor.date != rhs.anchor.date {
            return lhs.anchor.date > rhs.anchor.date
        }

        // Equal timestamps do not make opaque archive tokens comparable.
        return false
    }

    private static func completenessScore(_ result: ChatSearchResult) -> Int {
        var score = 0
        score += result.anchor.primary.isNotEmpty ? 1 : 0
        score += result.anchor.archivedId.isNotEmpty ? 2 : 0
        score += result.anchor.messageId.isNotEmpty ? 1 : 0
        score += result.anchor.authorId?.isNotEmpty == true ? 1 : 0
        score += result.senderTitle.isNotEmpty ? 1 : 0
        score += result.body.isNotEmpty ? 2 : 0
        score += result.snippet.isNotEmpty ? 1 : 0
        score += result.deliveryState == .pending ? 0 : 1
        score += result.avatar.url?.isNotEmpty == true ? 1 : 0
        return score
    }
}

final class ChatSearchPreparedResults: @unchecked Sendable, Equatable {
    let results: [ChatSearchResult]
    let resultsByID: [ChatSearchResult.ID: ChatSearchResult]
    let itemIDs: [ChatSearchResult.ID]

    init(_ incoming: [ChatSearchResult]) {
        let results = ChatSearchResultCollection.orderedAndDeduplicated(incoming)
        self.results = results
        resultsByID = Dictionary(
            results.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        itemIDs = results.map(\.id)
    }

    static func == (
        lhs: ChatSearchPreparedResults,
        rhs: ChatSearchPreparedResults
    ) -> Bool {
        lhs === rhs || lhs.results == rhs.results
    }
}

enum ChatSearchResultPositionFormatter {
    static func text(currentIndex: Int?, total: Int) -> String? {
        guard let currentIndex,
              total > 0,
              currentIndex >= 0,
              currentIndex < total else {
            return nil
        }
        return "\(currentIndex + 1) of \(total)"
    }
}
