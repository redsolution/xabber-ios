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

struct ChatSearchResult: Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case archived(String)
        case primary(String)
    }

    struct Scope: Equatable, Sendable {
        let owner: String
        let jid: String
        let conversationTypeRawValue: String
    }

    struct Anchor: Equatable, Sendable {
        let primary: String
        let archivedId: String
        let messageId: String
        let authorId: String?
        let date: Date
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
        let archivedId = item.archivedId
        let id: ChatSearchResult.ID
        if archivedId.isNotEmpty {
            id = .archived(archivedId)
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
                archivedId: archivedId,
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

    private static func avatar(
        for item: MessageStorageItem,
        senderTitle: String,
        context: ChatSearchResultMappingContext
    ) -> ChatSearchResult.Avatar {
        switch item.conversationType {
        case .group, .channel:
            let userId = nonEmpty(item.groupchatAuthorId)
                ?? (item.outgoing ? context.scope.owner : senderTitle)
            let url = nonEmpty(item.groupchatCard?.avatarUrl)
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
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
        for result in results {
            if let existing = uniqueById[result.id] {
                uniqueById[result.id] = preferred(existing, result)
            } else {
                uniqueById[result.id] = result
            }
        }
        return uniqueById.values.sorted(by: sortsBefore)
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

        switch (lhs.id, rhs.id) {
        case let (.archived(lhsId), .archived(rhsId)):
            if let lhsNumber = Int64(lhsId),
               let rhsNumber = Int64(rhsId),
               lhsNumber != rhsNumber {
                return lhsNumber > rhsNumber
            }
            return lhsId > rhsId
        case (.archived, .primary):
            return true
        case (.primary, .archived):
            return false
        case let (.primary(lhsId), .primary(rhsId)):
            return lhsId > rhsId
        }
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
