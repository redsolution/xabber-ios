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
    private let segment: ArchiveCoverageSegment

    var orderedArchiveIDs: [ArchiveCursor] { segment.orderedArchiveIDs }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Segment identity uses its cached, length-framed ledger digest. Scope
        // checks occur during scrolling and must not walk the archive history.
        lhs.conversationKey == rhs.conversationKey &&
            lhs.coverageGeneration == rhs.coverageGeneration &&
            lhs.connectionGeneration == rhs.connectionGeneration &&
            lhs.freshnessFingerprint == rhs.freshnessFingerprint &&
            lhs.segment == rhs.segment
    }

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
        self.segment = segment
    }

    func contains(_ cursor: ArchiveCursor) -> Bool {
        segment.contains(cursor)
    }

    func index(of cursor: ArchiveCursor) -> Int? {
        segment.index(of: cursor)
    }

    func isBefore(_ lhs: ArchiveCursor, _ rhs: ArchiveCursor) -> Bool {
        segment.isBefore(lhs, rhs)
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
              message.conversationType == conversationKey.conversationType,
              message.mamArchiveId.isNotEmpty else {
            return nil
        }
        return ArchiveCursor(rawValue: message.mamArchiveId)
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
        return segment.containsSegment(previous.segment)
    }

    /// Only the server's recorded page order orders verified rows. Local dates,
    /// stanza IDs and the spelling of an opaque archive UID are not ordinals.
    func ordered(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        var indexed: [(index: Int, sourceIndex: Int, item: MessageStorageItem)] = []
        indexed.reserveCapacity(items.count)
        for (sourceIndex, item) in items.enumerated() {
            guard contains(item),
                  let cursor = archiveCursor(for: item),
                  let index = index(of: cursor) else { continue }
            indexed.append((index, sourceIndex, item))
        }
        indexed.sort {
            $0.index == $1.index
                ? $0.sourceIndex < $1.sourceIndex
                : $0.index < $1.index
        }
        var seen = Set<String>()
        return indexed.compactMap { entry in
            let keys = ChatTimelineMessageIdentity.keys(for: entry.item)
            guard !keys.contains(where: { seen.contains($0) }) else { return nil }
            seen.formUnion(keys)
            return entry.item
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
              let boundaryCursor = boundary.archiveCursor,
              let boundaryIndex = verifiedScope.index(of: boundaryCursor) else {
            return .invalidProof
        }

        // Archive membership includes consumed envelopes that intentionally
        // have no visible Realm row. Advance the ledger slice, rather than a
        // date/UID comparison, until a visible page or its exact edge is found.
        var scanBoundary = boundaryIndex
        while true {
            let range: Range<Int>
            switch direction {
            case .older:
                range = max(0, scanBoundary - pageSize)..<scanBoundary
            case .newer:
                range = (scanBoundary + 1)..<min(verifiedScope.orderedArchiveIDs.count, scanBoundary + 1 + pageSize)
            }
            guard !range.isEmpty else {
                return boundaryOutcome(
                    direction: direction,
                    boundaryCursor: boundaryCursor,
                    exhaustedVerifiedScope: true
                )
            }
            let ids = verifiedScope.orderedArchiveIDs[range].map(\.rawValue)
            let requested = Set(verifiedScope.orderedArchiveIDs[range])
            let candidates = provider.items(archiveCursorIDs: ids)
            guard candidates.allSatisfy({ item in
                verifiedScope.archiveCursor(for: item).map {
                    requested.contains($0)
                } ?? false
            }) else { return .invalidProof }
            let admitted = verifiedScope.ordered(candidates)
            if admitted.isNotEmpty {
                let combined = direction == .older
                    ? admitted + currentItems
                    : currentItems + admitted
                return .local(apply(items: combined, direction: direction))
            }
            scanBoundary = direction == .older
                ? range.lowerBound
                : range.upperBound - 1
        }
    }

    mutating func openAround(
        primary: String?,
        archiveCursor: ArchiveCursor,
        before: Int,
        after: Int
    ) -> ChatVirtualTimelineTargetOutcome<ChatTimelineSnapshot> {
        guard let anchorIndex = verifiedScope.index(of: archiveCursor) else {
            return .needsArchiveTarget(archiveCursor)
        }
        let normalizedPrimary = primary.flatMap { $0.isNotEmpty ? $0 : nil }
        let boundedBefore = min(max(0, before), pageSize)
        let boundedAfter = min(max(0, after), pageSize)
        let lower = max(0, anchorIndex - boundedBefore)
        let upper = min(verifiedScope.orderedArchiveIDs.count, anchorIndex + boundedAfter + 1)
        let ids = verifiedScope.orderedArchiveIDs[lower..<upper].map(\.rawValue)
        let requested = Set(verifiedScope.orderedArchiveIDs[lower..<upper])
        let candidates = provider.items(archiveCursorIDs: ids)
        guard candidates.allSatisfy({ item in
            verifiedScope.archiveCursor(for: item).map { requested.contains($0) } ?? false
        }) else { return .invalidProof }
        let admitted = verifiedScope.ordered(candidates)
        guard let anchor = admitted.first(where: {
            verifiedScope.archiveCursor(for: $0) == archiveCursor
        }), normalizedPrimary.map({ anchor.primary == $0 }) ?? true else {
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
        let ordered = verifiedScope.ordered(items)
        let bounded = ChatBoundedTimelineWindowPolicy.trimmedItems(
            ordered,
            direction: direction,
            pageSize: pageSize
        )
        let oldest = bounded.first.map(ChatTimelineBoundary.init(message:))
        let newest = bounded.last.map(ChatTimelineBoundary.init(message:))
        let oldestCursor = bounded.first.flatMap { verifiedScope.archiveCursor(for: $0) }
        let newestCursor = bounded.last.flatMap { verifiedScope.archiveCursor(for: $0) }
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
            oldestArchiveId: oldestCursor?.rawValue ?? verifiedScope.oldest.rawValue,
            newestArchiveId: newestCursor?.rawValue ?? verifiedScope.newest.rawValue
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
                ArchiveCursor(rawValue: $0.mamArchiveId)?.rawValue
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
        return scope.ordered(materialized)
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
