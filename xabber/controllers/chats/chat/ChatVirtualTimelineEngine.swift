import Foundation

/// Immutable admission proof for one continuous archive segment.
///
/// The virtual timeline may materialize Realm rows only while this exact proof
/// is current. It never infers coverage from cached messages themselves.
struct ChatTimelineVerifiedScope: Equatable, Sendable {
    let conversationKey: ChatTimelineConversationKey
    let oldest: ArchiveCursor
    let newest: ArchiveCursor
    let reachesArchiveStart: Bool
    let reachesLiveEdge: Bool
    let coverageGeneration: UInt64
    let connectionGeneration: UInt64
    let freshnessFingerprint: String

    init?(
        conversationKey: ChatTimelineConversationKey,
        segment: ArchiveCoverageSegment,
        coverageGeneration: UInt64,
        freshnessToken: ArchiveFreshnessToken
    ) {
        guard case .sessionMAM(let connectionGeneration, _) = freshnessToken,
              segment.isVerified,
              segment.fingerprint == freshnessToken.fingerprint,
              conversationKey.owner.isNotEmpty,
              conversationKey.jid.isNotEmpty else {
            return nil
        }
        self.conversationKey = conversationKey
        self.oldest = segment.oldest
        self.newest = segment.newest
        self.reachesArchiveStart = segment.reachesArchiveStart
        self.reachesLiveEdge = segment.reachesLiveEdge
        self.coverageGeneration = coverageGeneration
        self.connectionGeneration = connectionGeneration
        self.freshnessFingerprint = freshnessToken.fingerprint
    }

    func contains(_ cursor: ArchiveCursor) -> Bool {
        cursor >= oldest && cursor <= newest
    }

    func contains(_ message: MessageStorageItem) -> Bool {
        guard !message.isDeleted,
              !message.isLocallyHiddenByReport,
              let cursor = archiveCursor(for: message) else {
            return false
        }
        return contains(cursor)
    }

    func archiveCursor(for message: MessageStorageItem) -> ArchiveCursor? {
        guard message.owner == conversationKey.owner,
              message.opponent == conversationKey.jid,
              message.conversationType == conversationKey.conversationType else {
            return nil
        }
        return ArchiveCursor(rawValue: message.archivedId)
    }

    func canExtend(
        _ previous: ChatTimelineVerifiedScope,
        direction: ChatHistoryPageDirection
    ) -> Bool {
        guard conversationKey == previous.conversationKey,
              freshnessFingerprint == previous.freshnessFingerprint,
              coverageGeneration >= previous.coverageGeneration else {
            return false
        }
        switch direction {
        case .older:
            return oldest <= previous.oldest && newest >= previous.newest
        case .newer:
            return oldest <= previous.oldest && newest >= previous.newest
        }
    }
}

/// A local boundary operation reports only what the local timeline can prove.
/// Request construction and remote archive orchestration intentionally live
/// outside this type.
enum ChatVirtualTimelineBoundaryOutcome<Snapshot> {
    case local(Snapshot)
    case needsArchiveExpansion(ChatHistoryPageDirection)
    case endReached(Snapshot)
    case invalidProof
}

/// A target jump stays local only while its archive cursor is covered by the
/// current immutable proof. The caller owns construction of any remote target
/// request when the cursor is outside that scope.
enum ChatVirtualTimelineTargetOutcome<Snapshot> {
    case local(Snapshot)
    case needsArchiveTarget(ArchiveCursor)
    case invalidProof
}

/// Pure resident-window reducer over a bounded local page provider.
///
/// It owns no MAM identifiers, archive requests, placeholders, retries or gap
/// policy. The only archive input is the immutable verified scope used to
/// admit locally persisted rows.
struct ChatVirtualTimelineEngine {
    private let provider: ChatTimelinePageProviding
    private let pageSize: Int
    private(set) var state: ChatVirtualTimelineState
    private(set) var verifiedScope: ChatTimelineVerifiedScope

    init(
        provider: ChatTimelinePageProviding,
        pageSize: Int,
        state: ChatVirtualTimelineState,
        verifiedScope: ChatTimelineVerifiedScope
    ) {
        self.provider = provider
        self.pageSize = max(1, pageSize)
        self.state = state
        self.verifiedScope = verifiedScope
    }

    @discardableResult
    mutating func installVerified(
        items: [MessageStorageItem],
        expectedPrimaryIDs: [String],
        direction: ChatHistoryPageDirection?,
        scope: ChatTimelineVerifiedScope
    ) -> ChatTimelineSnapshot? {
        let expectedSet = Set(expectedPrimaryIDs)
        guard expectedSet.count == expectedPrimaryIDs.count,
              items.count == expectedPrimaryIDs.count,
              Set(items.map(\.primary)) == expectedSet,
              items.allSatisfy({ scope.contains($0) }) else {
            return nil
        }

        let currentItems: [MessageStorageItem]
        if let direction {
            guard scope.canExtend(verifiedScope, direction: direction),
                  let materialized = materializedResidentItems(
                      scope: scope
                  ) else {
                return nil
            }
            currentItems = materialized
        } else {
            currentItems = []
        }

        let candidates: [MessageStorageItem]
        switch direction {
        case .older:
            candidates = items + currentItems
        case .newer:
            candidates = currentItems + items
        case .none:
            candidates = items
        }

        verifiedScope = scope
        return apply(items: candidates, direction: direction)
    }

    mutating func page(
        _ direction: ChatHistoryPageDirection
    ) -> ChatVirtualTimelineBoundaryOutcome<ChatTimelineSnapshot> {
        guard let currentItems = materializedResidentItems(
            scope: verifiedScope
        ) else {
            return .invalidProof
        }
        guard let boundary = direction == .older
                ? state.oldest
                : state.newest,
              let boundaryArchiveID = boundary.archivedId,
              let boundaryCursor = ArchiveCursor(rawValue: boundaryArchiveID),
              verifiedScope.contains(boundaryCursor) else {
            return .invalidProof
        }

        let candidates: [MessageStorageItem]
        switch direction {
        case .older:
            candidates = provider.older(before: boundary, limit: pageSize)
        case .newer:
            candidates = provider.newer(after: boundary, limit: pageSize)
        }
        let admitted = ChatTimelineOrdering.deduplicatedChronological(
            candidates.filter { verifiedScope.contains($0) }
        )

        guard admitted.isNotEmpty else {
            let scannedCursors = candidates.compactMap {
                verifiedScope.archiveCursor(for: $0)
            }
            let exhaustedVerifiedScope: Bool
            switch direction {
            case .older:
                exhaustedVerifiedScope = candidates.isEmpty ||
                    scannedCursors.min().map { $0 <= verifiedScope.oldest } == true
            case .newer:
                exhaustedVerifiedScope = candidates.isEmpty ||
                    scannedCursors.max().map { $0 >= verifiedScope.newest } == true
            }
            return boundaryOutcome(
                direction: direction,
                boundaryCursor: boundaryCursor,
                exhaustedVerifiedScope: exhaustedVerifiedScope
            )
        }

        let combined: [MessageStorageItem]
        switch direction {
        case .older:
            combined = admitted + currentItems
        case .newer:
            combined = currentItems + admitted
        }
        return .local(apply(items: combined, direction: direction))
    }

    mutating func openAround(
        primary: String?,
        archiveCursor: ArchiveCursor,
        before: Int,
        after: Int
    ) -> ChatVirtualTimelineTargetOutcome<ChatTimelineSnapshot> {
        guard verifiedScope.contains(archiveCursor) else {
            return .needsArchiveTarget(archiveCursor)
        }
        let normalizedPrimary = primary.flatMap { $0.isNotEmpty ? $0 : nil }
        guard let anchor = provider.message(
            primary: normalizedPrimary,
            archivedId: archiveCursor.rawValue,
            messageId: nil
        ),
        verifiedScope.contains(anchor),
        ArchiveCursor(rawValue: anchor.archivedId) == archiveCursor,
        normalizedPrimary.map({ anchor.primary == $0 }) ?? true else {
            return .invalidProof
        }

        let boundedBefore = min(max(0, before), pageSize)
        let boundedAfter = min(max(0, after), pageSize)
        let admitted = ChatTimelineOrdering.deduplicatedChronological(
            provider.around(
                anchor: anchor,
                before: boundedBefore,
                after: boundedAfter
            ).filter { verifiedScope.contains($0) }
        )
        guard admitted.contains(where: { $0.primary == anchor.primary }) else {
            return .invalidProof
        }
        let candidate = apply(items: admitted, direction: nil)
        guard candidate.items.contains(where: { $0.primary == anchor.primary }) else {
            return .invalidProof
        }
        return .local(candidate)
    }

    func currentSnapshot() -> ChatTimelineSnapshot {
        let materialized = materializedResidentItems(scope: verifiedScope) ?? []
        return snapshot(items: materialized, state: state)
    }

    private func boundaryOutcome(
        direction: ChatHistoryPageDirection,
        boundaryCursor: ArchiveCursor,
        exhaustedVerifiedScope: Bool
    ) -> ChatVirtualTimelineBoundaryOutcome<ChatTimelineSnapshot> {
        let snapshot = currentSnapshot()
        switch direction {
        case .older:
            guard boundaryCursor == verifiedScope.oldest ||
                    exhaustedVerifiedScope else {
                return .invalidProof
            }
            return verifiedScope.reachesArchiveStart
                ? .endReached(snapshot)
                : .needsArchiveExpansion(.older)
        case .newer:
            guard boundaryCursor == verifiedScope.newest ||
                    exhaustedVerifiedScope else {
                return .invalidProof
            }
            return verifiedScope.reachesLiveEdge
                ? .endReached(snapshot)
                : .needsArchiveExpansion(.newer)
        }
    }

    private mutating func apply(
        items: [MessageStorageItem],
        direction: ChatHistoryPageDirection?
    ) -> ChatTimelineSnapshot {
        let admitted = items.filter { verifiedScope.contains($0) }
        let ordered = ChatTimelineOrdering.deduplicatedChronological(admitted)
        let bounded = ChatBoundedTimelineWindowPolicy.trimmedItems(
            ordered,
            direction: direction,
            pageSize: pageSize
        )
        let oldest = bounded.first.map(ChatTimelineBoundary.init(message:))
        let newest = bounded.last.map(ChatTimelineBoundary.init(message:))
        let oldestCursor = bounded.first.flatMap {
            ArchiveCursor(rawValue: $0.archivedId)
        }
        let newestCursor = bounded.last.flatMap {
            ArchiveCursor(rawValue: $0.archivedId)
        }
        let isAtArchiveStart = verifiedScope.reachesArchiveStart && (
            bounded.isEmpty || oldestCursor == verifiedScope.oldest
        )
        let isAtLiveTail = verifiedScope.reachesLiveEdge && (
            bounded.isEmpty || newestCursor == verifiedScope.newest
        )

        var segments: [ChatVirtualSegment] = []
        if !isAtArchiveStart {
            segments.append(.unknownOlder)
        }
        segments.append(.loadedRange(
            oldestArchiveId: oldest?.archivedId ?? verifiedScope.oldest.rawValue,
            newestArchiveId: newest?.archivedId ?? verifiedScope.newest.rawValue
        ))
        if isAtLiveTail {
            segments.append(.liveTail)
        } else {
            segments.append(.unknownNewer)
        }

        state = ChatVirtualTimelineState(
            conversationKey: verifiedScope.conversationKey,
            segments: segments,
            oldest: oldest,
            newest: newest,
            residentPrimaryKeys: bounded.map(\.primary),
            residentArchivedIds: bounded.compactMap {
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    $0.archivedId
                )
            },
            isResidentAtLiveTail: isAtLiveTail
        )
        return snapshot(items: bounded, state: state)
    }

    private func materializedResidentItems(
        scope: ChatTimelineVerifiedScope
    ) -> [MessageStorageItem]? {
        guard !state.residentPrimaryKeys.isEmpty else {
            return state.isEmpty ? [] : nil
        }
        let expected = state.residentPrimaryKeys
        let materialized = provider.items(primaryKeys: expected)
        guard materialized.count == expected.count,
              Set(materialized.map(\.primary)) == Set(expected),
              materialized.allSatisfy({ scope.contains($0) }) else {
            return nil
        }
        return ChatTimelineOrdering.deduplicatedChronological(materialized)
    }

    private func snapshot(
        items: [MessageStorageItem],
        state: ChatVirtualTimelineState
    ) -> ChatTimelineSnapshot {
        ChatTimelineSnapshot(
            items: items,
            state: state,
            anchorRestore: nil
        )
    }
}
