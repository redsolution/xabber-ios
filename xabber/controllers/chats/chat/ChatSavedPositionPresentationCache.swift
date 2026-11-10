import Foundation
import RealmSwift

enum ChatSavedPositionPresentationProvenance: Equatable {
    case verifiedSegment(ArchiveCoverageSegment, coverageGeneration: Int64)
    case localAdjacency(indexVersion: Int, orderedPrimaries: [String])
}

/// A durable, exact saved window is usable for presentation across launches.
/// It is deliberately not ArchiveRepositoryAdmission: it grants neither this
/// connection's read authority nor permission to page from an old proof.
struct ChatSavedPositionPresentationWindow {
    let request: ChatOpenMessageRequest
    let rows: [MessageStorageItem]
    let anchorPrimary: String
    let provenance: ChatSavedPositionPresentationProvenance

    var segment: ArchiveCoverageSegment? {
        guard case .verifiedSegment(let segment, _) = provenance else { return nil }
        return segment
    }

    var coverageGeneration: Int64 {
        guard case .verifiedSegment(_, let generation) = provenance else { return 0 }
        return generation
    }

    init(request: ChatOpenMessageRequest, rows: [MessageStorageItem], anchorPrimary: String,
         segment: ArchiveCoverageSegment, coverageGeneration: Int64) {
        self.request = request; self.rows = rows; self.anchorPrimary = anchorPrimary
        self.provenance = .verifiedSegment(segment, coverageGeneration: coverageGeneration)
    }

    init(request: ChatOpenMessageRequest, rows: [MessageStorageItem], anchorPrimary: String,
         provenance: ChatSavedPositionPresentationProvenance) {
        self.request = request; self.rows = rows; self.anchorPrimary = anchorPrimary
        self.provenance = provenance
    }
}

enum ChatSavedPositionPresentationCache {
    static func read(
        request: ChatOpenMessageRequest,
        realm: Realm,
        contextBefore: Int = ArchivePageSizing.anchorBefore,
        contextAfter: Int = ArchivePageSizing.anchorAfter
    ) -> ChatSavedPositionPresentationWindow? {
        guard request.source == .savedVisiblePosition,
              case .anchor = request.targetResolution,
              let primary = ChatInitialPositionPolicy.normalizedId(request.anchor.messagePrimary),
              let chat = realm.object(ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: request.chatJid,
                    owner: request.owner, conversationType: request.conversationType)),
              chat.owner == request.owner, chat.jid == request.chatJid,
              chat.conversationType == request.conversationType else { return nil }
        let saved = ChatSavedVisiblePosition(
            messagePrimary: ChatInitialPositionPolicy.normalizedId(chat.lastVisibleMessagePrimary),
            archivedId: ChatInitialPositionPolicy.normalizedId(chat.lastVisibleMessageArchivedId),
            messageId: ChatInitialPositionPolicy.normalizedId(chat.lastVisibleMessageId),
            sourceDate: chat.lastVisibleMessageDate ?? chat.messageDate)
        let state = ChatInitialPositionPolicy.ChatState(owner: chat.owner, jid: chat.jid,
            conversationType: chat.conversationType, unread: chat.unread,
            syncUnreadCount: chat.syncUnreadCount, syncUnreadAfterId: chat.syncUnreadAfterId,
            lastReadId: chat.lastReadId, lastMessageId: chat.lastMessageId,
            syncSnapshotLastArchiveId: chat.syncSnapshotLastArchiveId, messageDate: chat.messageDate,
            savedPosition: saved.hasAnchor ? saved : nil,
            savedAtLastMessageId: chat.lastVisiblePositionSavedAtLastMessageId,
            savedAtSnapshotLastArchiveId: chat.lastVisiblePositionSavedAtSnapshotLastArchiveId)
        guard case .open(let eligible) = ChatInitialPositionPolicy.decision(for: state, explicitRequest: nil),
              eligible == request,
              let anchor = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
              anchor.owner == request.owner, anchor.opponent == request.chatJid,
              anchor.conversationType == request.conversationType,
              request.anchor.messageId == nil || request.anchor.messageId.map({ Data($0.utf8) }) == Data(anchor.messageId.utf8),
              let cursor = ArchiveCursor(rawValue: anchor.mamArchiveId),
              saved.archivedId == nil || saved.archivedId.flatMap(ArchiveCursor.init(rawValue:)) == cursor,
              isVisible(anchor),
              hasUniqueCursor(cursor, anchorPrimary: primary, request: request, realm: realm) else { return nil }
        let before = min(max(0, contextBefore), ArchivePageSizing.anchorBefore)
        let after = min(max(0, contextAfter), ArchivePageSizing.anchorAfter)
        if let verified = verifiedWindow(request: request, anchor: anchor, cursor: cursor,
            realm: realm, contextBefore: before, contextAfter: after) {
            return verified
        }
        return localAdjacencyWindow(request: request, anchor: anchor, realm: realm,
            contextBefore: before, contextAfter: after)
    }

    private static func scopedRows(request: ChatOpenMessageRequest, realm: Realm) -> Results<MessageStorageItem> {
        realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@",
            request.owner, request.chatJid, request.conversationType.rawValue)
    }

    private static func isVisible(_ row: MessageStorageItem) -> Bool {
        !row.isDeleted && !row.isLocallyHiddenByReport && row.deleteState == .visible &&
            (row.effectiveAutoDeleteExpiresAt <= 0 || row.effectiveAutoDeleteExpiresAt > Date().timeIntervalSince1970)
    }

    private static func hasUniqueCursor(_ cursor: ArchiveCursor, anchorPrimary: String,
        request: ChatOpenMessageRequest, realm: Realm) -> Bool {
        let candidates = Array(scopedRows(request: request, realm: realm)
            .filter("mamArchiveId == %@", cursor.rawValue).prefix(2))
        return candidates.count == 1 && Data(candidates[0].mamArchiveId.utf8) == Data(cursor.rawValue.utf8) &&
            Data(candidates[0].primary.utf8) == Data(anchorPrimary.utf8)
    }

    private static func verifiedWindow(request: ChatOpenMessageRequest, anchor: MessageStorageItem,
        cursor: ArchiveCursor, realm: Realm, contextBefore: Int, contextAfter: Int
    ) -> ChatSavedPositionPresentationWindow? {
        guard let storage = realm.object(ofType: ConversationArchiveCoverageStorageItem.self,
                forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(owner: request.owner,
                    jid: request.chatJid, conversationType: request.conversationType)),
              storage.hasReadableCoverageMetadata, storage.coverageGeneration > 0,
              let fingerprint = storage.archiveFreshnessFingerprint,
              fingerprint.hasPrefix("session:"),
              let sourceGeneration = UInt64(fingerprint.dropFirst("session:".count)),
              sourceGeneration > 0 else { return nil }
        let segments = storage.segments.filter {
            $0.isVerified && $0.fingerprint == fingerprint && $0.contains(cursor)
        }
        guard segments.count == 1, let segment = segments.first,
              let index = segment.orderedArchiveIDs.firstIndex(of: cursor) else { return nil }
        let lowerBound = max(0, index - max(0, contextBefore))
        let upperBound = min(segment.orderedArchiveIDs.count, index + max(0, contextAfter) + 1)
        let ids = Array(segment.orderedArchiveIDs[lowerBound..<upperBound])
        let candidates = scopedRows(request: request, realm: realm)
            .filter("mamArchiveId IN %@", ids.map(\.rawValue))
        var byCursor: [Data: [MessageStorageItem]] = [:]
        // Keep duplicate detection exact while bounding malformed storage work.
        // Up to two matches per requested UID suffice to identify an ambiguous
        // neighbour; larger corruption fails closed rather than truncating it.
        guard candidates.count <= ids.count * 2 else { return nil }
        for row in candidates {
            byCursor[Data(row.mamArchiveId.utf8), default: []].append(row)
        }
        func uniqueRow(at index: Int) -> MessageStorageItem? {
            let matches = byCursor[Data(segment.orderedArchiveIDs[index].rawValue.utf8)]
            return matches?.count == 1 ? matches?.first : nil
        }
        guard let mappedAnchor = uniqueRow(at: index),
              Data(mappedAnchor.primary.utf8) == Data(anchor.primary.utf8) else { return nil }
        // Missing/ambiguous neighbours bound the cached context. Never cross a
        // hole merely to fill the requested count; the exact target remains.
        var lower = index
        var upper = index + 1
        while lower > lowerBound, uniqueRow(at: lower - 1) != nil { lower -= 1 }
        while upper < upperBound, uniqueRow(at: upper) != nil { upper += 1 }
        let visible = (lower..<upper).compactMap { uniqueRow(at: $0) }.filter(isVisible)
        guard visible.contains(where: { Data($0.primary.utf8) == Data(anchor.primary.utf8) }) else { return nil }
        return ChatSavedPositionPresentationWindow(request: request,
            rows: visible.map { $0.freeze() }, anchorPrimary: anchor.primary,
            segment: segment, coverageGeneration: storage.coverageGeneration)
    }

    private static func localAdjacencyWindow(request: ChatOpenMessageRequest, anchor: MessageStorageItem,
        realm: Realm, contextBefore: Int, contextAfter: Int
    ) -> ChatSavedPositionPresentationWindow? {
        let version = ChatLocalHistoryIndexStorageItem.currentVersion
        guard let state = ChatLocalHistoryLinkedIndex.state(owner: request.owner, jid: request.chatJid,
                conversationType: request.conversationType, in: realm),
              state.owner == request.owner, state.jid == request.chatJid,
              state.conversationType_ == request.conversationType.rawValue,
              state.version == version, state.indexedVisibleCount > 0,
              state.oldestMessagePrimary != nil, state.newestMessagePrimary != nil,
              anchor.historyLinkedIndexVersion == version else { return nil }
        var visited = Set<Data>([Data(anchor.primary.utf8)])
        func walk(previous: Bool, limit: Int) -> [MessageStorageItem]? {
            var current = anchor
            var rows: [MessageStorageItem] = []
            for _ in 0..<max(0, limit) {
                let primary = previous ? current.historyPreviousMessagePrimary : current.historyNextMessagePrimary
                guard let primary else {
                    let endpoint = previous ? state.oldestMessagePrimary : state.newestMessagePrimary
                    return endpoint.map { Data($0.utf8) } == Data(current.primary.utf8) ? rows : nil
                }
                guard visited.insert(Data(primary.utf8)).inserted,
                      let row = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
                      row.owner == request.owner, row.opponent == request.chatJid,
                      row.conversationType == request.conversationType,
                      row.historyLinkedIndexVersion == version, !row.isDeleted,
                      ArchiveCursor(rawValue: row.mamArchiveId) != nil,
                      (previous ? row.historyNextMessagePrimary : row.historyPreviousMessagePrimary)
                        .map({ Data($0.utf8) }) == Data(current.primary.utf8) else { return nil }
                // Validate the pre-existing LOCAL index order. No rows are
                // sorted and no spelling/date is promoted into MAM chronology.
                let before = MessageHistoryOrderKey(message: previous ? row : current)
                let after = MessageHistoryOrderKey(message: previous ? current : row)
                guard before < after else { return nil }
                rows.append(row)
                current = row
            }
            return rows
        }
        guard let previous = walk(previous: true, limit: contextBefore),
              let next = walk(previous: false, limit: contextAfter) else { return nil }
        let ordered = Array(previous.reversed()) + [anchor] + next
        guard ordered.count <= state.indexedVisibleCount else { return nil }
        let ids = ordered.map { Data($0.mamArchiveId.utf8) }
        guard Set(ids).count == ids.count else { return nil }
        let candidates = Array(scopedRows(request: request, realm: realm)
            .filter("mamArchiveId IN %@", ordered.map(\.mamArchiveId)).prefix(ids.count + 1))
        guard candidates.count == ids.count else { return nil }
        var identities: [Data: Data] = [:]
        for row in candidates {
            guard identities.updateValue(Data(row.primary.utf8), forKey: Data(row.mamArchiveId.utf8)) == nil else { return nil }
        }
        guard ordered.allSatisfy({ identities[Data($0.mamArchiveId.utf8)] == Data($0.primary.utf8) }) else { return nil }
        let visible = ordered.filter(isVisible)
        guard visible.contains(where: { Data($0.primary.utf8) == Data(anchor.primary.utf8) }) else { return nil }
        return ChatSavedPositionPresentationWindow(request: request,
            rows: visible.map { $0.freeze() }, anchorPrimary: anchor.primary,
            provenance: .localAdjacency(indexVersion: version, orderedPrimaries: ordered.map(\.primary)))
    }
}
