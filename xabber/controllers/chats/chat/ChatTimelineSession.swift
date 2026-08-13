import Foundation
import RealmSwift
import CocoaLumberjack

enum ChatTimelineStoreChange {
    case latestChanged
    case residentChanged
    case unreadChanged
    case unreadMetadataChanged(ChatTimelineUnreadMetadata)
    case incremental(
        ChatIncrementalMessageMutationBatch<MessageStorageItem>,
        refreshUnread: Bool
    )
    case incrementalWithUnreadMetadata(
        ChatIncrementalMessageMutationBatch<MessageStorageItem>,
        unreadMetadata: ChatTimelineUnreadMetadata
    )
}

struct ChatTimelineStoreObservationBaseline {
    static let unseeded = ChatTimelineStoreObservationBaseline(
        isAuthoritative: false,
        residentItems: [],
        latestMessageFingerprint: nil,
        unreadCount: 0,
        unreadMetadataLimit: 1
    )

    let isAuthoritative: Bool
    let residentItems: [MessageStorageItem]
    let latestMessageFingerprint: ChatTimelineObservedMessageFingerprint?
    let unreadCount: Int
    let unreadMetadataLimit: Int
    let unreadMetadata: ChatTimelineUnreadMetadata

    init(
        isAuthoritative: Bool,
        residentItems: [MessageStorageItem],
        latestMessageFingerprint: ChatTimelineObservedMessageFingerprint?,
        unreadCount: Int,
        unreadMetadataLimit: Int,
        unreadMetadata: ChatTimelineUnreadMetadata = .empty
    ) {
        self.isAuthoritative = isAuthoritative
        self.residentItems = residentItems
        self.latestMessageFingerprint = latestMessageFingerprint
        self.unreadCount = unreadCount
        self.unreadMetadataLimit = unreadMetadataLimit
        self.unreadMetadata = unreadMetadata
    }

    var latestUnreadMentionArchivedId: String? {
        unreadMetadata.latestUnreadMentionArchivedId
    }

    var residentPrimaryKeys: [String] {
        residentItems.map(\.primary)
    }
}

protocol ChatTimelineStoreObservation: AnyObject {
    var activeWorkCount: Int { get }

    func replaceResidentItems(_ items: [MessageStorageItem])
    func authorizesResidentMutation(generation: UInt64) -> Bool
    func invalidate()
}

extension ChatTimelineStoreObservation {
    var activeWorkCount: Int { 0 }

    func authorizesResidentMutation(generation: UInt64) -> Bool { false }
}

struct ChatTimelineStoreObservationDiagnosticsSnapshot: Equatable {
    static let empty = ChatTimelineStoreObservationDiagnosticsSnapshot(
        activationCount: 0,
        realmQueryCount: 0,
        mainThreadRealmQueryCount: 0,
        initialCallbackCount: 0,
        mainThreadInitialCallbackCount: 0,
        maxInitialCandidateCount: 0,
        metadataQueryCount: 0,
        mainThreadMetadataQueryCount: 0,
        metadataFullScanCount: 0,
        maxMetadataCandidateCount: 0,
        catchUpMutationCount: 0,
        pendingWorkCount: 0
    )

    let activationCount: Int
    let realmQueryCount: Int
    let mainThreadRealmQueryCount: Int
    let initialCallbackCount: Int
    let mainThreadInitialCallbackCount: Int
    let maxInitialCandidateCount: Int
    let metadataQueryCount: Int
    let mainThreadMetadataQueryCount: Int
    let metadataFullScanCount: Int
    let maxMetadataCandidateCount: Int
    let catchUpMutationCount: Int
    let pendingWorkCount: Int

    func routeDelta(
        since baseline: ChatTimelineStoreObservationDiagnosticsSnapshot
    ) -> ChatTimelineStoreObservationDiagnosticsSnapshot {
        let routeInitialCallbackCount = max(
            0,
            initialCallbackCount - baseline.initialCallbackCount
        )
        return ChatTimelineStoreObservationDiagnosticsSnapshot(
            activationCount: max(0, activationCount - baseline.activationCount),
            realmQueryCount: max(0, realmQueryCount - baseline.realmQueryCount),
            mainThreadRealmQueryCount: max(
                0,
                mainThreadRealmQueryCount - baseline.mainThreadRealmQueryCount
            ),
            initialCallbackCount: routeInitialCallbackCount,
            mainThreadInitialCallbackCount: max(
                0,
                mainThreadInitialCallbackCount -
                    baseline.mainThreadInitialCallbackCount
            ),
            maxInitialCandidateCount:
                routeInitialCallbackCount > 0 ? maxInitialCandidateCount : 0,
            metadataQueryCount: max(
                0,
                metadataQueryCount - baseline.metadataQueryCount
            ),
            mainThreadMetadataQueryCount: max(
                0,
                mainThreadMetadataQueryCount -
                    baseline.mainThreadMetadataQueryCount
            ),
            metadataFullScanCount: max(
                0,
                metadataFullScanCount - baseline.metadataFullScanCount
            ),
            maxMetadataCandidateCount:
                metadataQueryCount > baseline.metadataQueryCount
                    ? maxMetadataCandidateCount
                    : 0,
            catchUpMutationCount: max(
                0,
                catchUpMutationCount - baseline.catchUpMutationCount
            ),
            // This is an instantaneous liveness gauge, not a monotonic
            // counter. A stable receipt must report the current value even
            // when the session/store was reused across routes.
            pendingWorkCount: pendingWorkCount
        )
    }
}

struct ChatTimelineStoreDiagnosticsSnapshot: Equatable {
    static let empty = ChatTimelineStoreDiagnosticsSnapshot(
        queryCount: 0,
        mainThreadQueryCount: 0,
        fullScanCount: 0,
        maxCandidateCount: 0,
        operationCounts: [:],
        operationCandidateCounts: [:],
        observation: .empty
    )

    let queryCount: Int
    let mainThreadQueryCount: Int
    let fullScanCount: Int
    let maxCandidateCount: Int
    let operationCounts: [String: Int]
    let operationCandidateCounts: [String: Int]
    let observation: ChatTimelineStoreObservationDiagnosticsSnapshot

    func recording(
        operation: String,
        candidateCount: Int,
        wasOnMainThread: Bool = Thread.isMainThread
    ) -> ChatTimelineStoreDiagnosticsSnapshot {
        let boundedCandidateCount = max(0, candidateCount)
        var nextOperationCandidateCounts = operationCandidateCounts
        nextOperationCandidateCounts[operation] = max(
            boundedCandidateCount,
            nextOperationCandidateCounts[operation] ?? 0
        )
        var nextOperationCounts = operationCounts
        nextOperationCounts[operation, default: 0] += 1
        return ChatTimelineStoreDiagnosticsSnapshot(
            queryCount: queryCount + 1,
            mainThreadQueryCount:
                mainThreadQueryCount + (wasOnMainThread ? 1 : 0),
            fullScanCount: fullScanCount,
            maxCandidateCount: max(maxCandidateCount, boundedCandidateCount),
            operationCounts: nextOperationCounts,
            operationCandidateCounts: nextOperationCandidateCounts,
            observation: observation
        )
    }

    /// Returns counters attributable to work after a route-start checkpoint.
    /// Candidate maxima remain lifetime-monotonic, so a reused route cannot
    /// hide an earlier or later over-budget materialization.
    func routeDelta(
        since baseline: ChatTimelineStoreDiagnosticsSnapshot
    ) -> ChatTimelineStoreDiagnosticsSnapshot {
        var routeOperationCounts: [String: Int] = [:]
        for (operation, lifetimeCount) in operationCounts {
            let routeCount = max(
                0,
                lifetimeCount - (baseline.operationCounts[operation] ?? 0)
            )
            if routeCount > 0 {
                routeOperationCounts[operation] = routeCount
            }
        }
        let routeOperationCandidateCounts = operationCandidateCounts.filter {
            routeOperationCounts[$0.key] != nil
        }
        return ChatTimelineStoreDiagnosticsSnapshot(
            queryCount: max(0, queryCount - baseline.queryCount),
            mainThreadQueryCount: max(
                0,
                mainThreadQueryCount - baseline.mainThreadQueryCount
            ),
            fullScanCount: max(0, fullScanCount - baseline.fullScanCount),
            maxCandidateCount:
                routeOperationCandidateCounts.values.max() ?? 0,
            operationCounts: routeOperationCounts,
            operationCandidateCounts: routeOperationCandidateCounts,
            observation: observation.routeDelta(since: baseline.observation)
        )
    }
}

struct ChatTimelineInitialFrameReadinessProof: Equatable {
    let conversationKey: ChatTimelineConversationKey
    let baseGeneration: UInt64
    let materializedLocalMessageCount: Int
    let isSynced: Bool
    let isInitialArchiveLoaded: Bool
    let hasDurableArchiveReadiness: Bool
    let archiveState: ChatArchiveStateSnapshot
    let chatFullArchiveLoaded: Bool
    let loadedRanges: [RegularChatArchiveIDRange]
    let knownGaps: [RegularChatArchiveGap]
    let archiveBoundaryFingerprint:
        MessageArchiveManager.ConversationArchiveBoundaryFingerprint?
    let hasKnownRemoteArchiveBoundary: Bool
    /// Exact LastChats baseline captured with the initial-frame metadata.
    /// The deferred observer compares its Realm `.initial` callback with this
    /// value so a write between frame commit and registration is not lost.
    let latestMessageFingerprint: ChatTimelineObservedMessageFingerprint?
}

struct ChatTimelineUnreadMetadata: Equatable {
    static let empty = ChatTimelineUnreadMetadata(
        unreadCount: 0,
        mentions: [],
        candidateCount: 0,
        initialFrameReadinessProof: nil,
        latestUnreadMentionArchivedId: nil
    )

    let unreadCount: Int
    let mentions: [ChatUnreadMentionItem]
    let candidateCount: Int
    let initialFrameReadinessProof: ChatTimelineInitialFrameReadinessProof?
    let latestUnreadMentionArchivedId: String?

    init(
        unreadCount: Int,
        mentions: [ChatUnreadMentionItem],
        candidateCount: Int,
        initialFrameReadinessProof: ChatTimelineInitialFrameReadinessProof? = nil,
        latestUnreadMentionArchivedId: String? = nil
    ) {
        self.unreadCount = unreadCount
        self.mentions = mentions
        self.candidateCount = candidateCount
        self.initialFrameReadinessProof = initialFrameReadinessProof
        self.latestUnreadMentionArchivedId =
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                latestUnreadMentionArchivedId
            )
    }
}

enum ChatTimelineUnreadMentionMetadataTransition: Equatable {
    case unchanged
    case publish(ChatTimelineUnreadMetadata)
    case resample
}

enum ChatTimelineUnreadMentionMetadataTransitionPolicy {
    static func resolve(
        metadata: ChatTimelineUnreadMetadata,
        previousArchivedId: String?,
        currentArchivedId: String?
    ) -> ChatTimelineUnreadMentionMetadataTransition {
        let previous = RegularChatArchiveSyncStateStorageItem
            .normalizedArchiveId(previousArchivedId)
        let current = RegularChatArchiveSyncStateStorageItem
            .normalizedArchiveId(currentArchivedId)
        guard previous != current else {
            return .unchanged
        }
        guard let previous else {
            return .resample
        }

        let retainedMentions = metadata.mentions.filter {
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                $0.archivedId
            ) != previous
        }
        let removedCount = metadata.mentions.count - retainedMentions.count
        guard removedCount > 0 else {
            return .resample
        }
        return .publish(ChatTimelineUnreadMetadata(
            unreadCount: metadata.unreadCount,
            mentions: retainedMentions,
            candidateCount: max(
                retainedMentions.count,
                max(0, metadata.candidateCount - removedCount)
            ),
            initialFrameReadinessProof:
                metadata.initialFrameReadinessProof,
            latestUnreadMentionArchivedId: current
        ))
    }
}

struct ChatTimelineInitialFrameWindow {
    let target: MessageStorageItem
    let items: [MessageStorageItem]
    let materializedCandidateCount: Int

    init(
        target: MessageStorageItem,
        items: [MessageStorageItem],
        materializedCandidateCount: Int? = nil
    ) {
        self.target = target
        self.items = items
        self.materializedCandidateCount = max(
            items.count,
            materializedCandidateCount ?? items.count
        )
    }

    var resultCount: Int {
        items.count
    }
}

struct ChatTimelineInitialFrameLeaseMaterialization {
    let preparedLatestItems: [MessageStorageItem]?
    let preparedAroundWindow: ChatTimelineInitialFrameWindow?
    let unreadMetadata: ChatTimelineUnreadMetadata
    let searchResolutionProof: ChatTimelineSearchResolutionProof

    var materializedMessageCount: Int {
        preparedAroundWindow?.items.count ?? preparedLatestItems?.count ?? 0
    }
}

enum ChatTimelineSearchResolutionProof: Equatable {
    case notRequested
    case found(primary: String)
    case failed(ChatAnchorTransactionFailure)
}

protocol ChatTimelineSessionStore: ChatTimelinePageProviding, AnyObject {
    var diagnosticsSnapshot: ChatTimelineStoreDiagnosticsSnapshot { get }

    func initialLatestWindow(limit: Int) -> [MessageStorageItem]
    func unreadMetadata(limit: Int) -> ChatTimelineUnreadMetadata
    func initialFrameMetadata(
        limit: Int,
        materializedLocalMessageCount: Int,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64
    ) -> ChatTimelineUnreadMetadata
    func withInitialFrameMetadataConsistencyLease(
        limit: Int,
        materializedLocalMessageCount: Int,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64,
        _ consume: (ChatTimelineUnreadMetadata) -> Void
    )
    func withPostBootstrapInitialFrameConsistencyLease(
        target: ChatTimelineInitialFrameTarget,
        searchAnchor: ChatMessageAnchorRef?,
        limit: Int,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64,
        _ consume: (ChatTimelineInitialFrameLeaseMaterialization?) -> Void
    )
    func messageWindow(
        primary: String?,
        archivedId: String?,
        messageId: String?,
        before: Int,
        after: Int
    ) -> ChatTimelineInitialFrameWindow?
    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem?
    func firstIncomingWindow(
        afterArchiveBoundaryId boundaryArchivedId: String,
        before: Int,
        after: Int
    ) -> ChatTimelineInitialFrameWindow?
    func observe(
        baseline: ChatTimelineStoreObservationBaseline,
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) -> ChatTimelineStoreObservation
}

extension ChatTimelineSessionStore {
    func initialLatestWindow(limit: Int) -> [MessageStorageItem] {
        latest(limit: limit)
    }

    func initialFrameMetadata(
        limit: Int,
        materializedLocalMessageCount: Int,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64
    ) -> ChatTimelineUnreadMetadata {
        unreadMetadata(limit: limit)
    }

    func withInitialFrameMetadataConsistencyLease(
        limit: Int,
        materializedLocalMessageCount: Int,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64,
        _ consume: (ChatTimelineUnreadMetadata) -> Void
    ) {
        consume(
            initialFrameMetadata(
                limit: limit,
                materializedLocalMessageCount: materializedLocalMessageCount,
                conversationKey: conversationKey,
                baseGeneration: baseGeneration
            )
        )
    }

    func withPostBootstrapInitialFrameConsistencyLease(
        target: ChatTimelineInitialFrameTarget,
        searchAnchor: ChatMessageAnchorRef?,
        limit: Int,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64,
        _ consume: (ChatTimelineInitialFrameLeaseMaterialization?) -> Void
    ) {
        let boundedLimit = max(1, limit)
        let effectiveTarget: ChatTimelineInitialFrameTarget
        let searchResolutionProof: ChatTimelineSearchResolutionProof
        if let searchAnchor {
            switch searchMessageResolution(anchor: searchAnchor) {
            case .found(let message):
                searchResolutionProof = .found(primary: message.primary)
                effectiveTarget = .message(ChatTimelineAnchor(
                    primary: message.primary,
                    archivedId: nil,
                    messageId: nil,
                    date: message.date
                ))
            case .failed(let failure):
                consume(ChatTimelineInitialFrameLeaseMaterialization(
                    preparedLatestItems: nil,
                    preparedAroundWindow: nil,
                    unreadMetadata: .empty,
                    searchResolutionProof: .failed(failure)
                ))
                return
            }
        } else {
            searchResolutionProof = .notRequested
            effectiveTarget = target
        }
        let preparedLatestItems: [MessageStorageItem]?
        let preparedAroundWindow: ChatTimelineInitialFrameWindow?
        switch effectiveTarget {
        case .latest:
            preparedLatestItems = initialLatestWindow(limit: boundedLimit)
            preparedAroundWindow = nil
        case .message(let anchor):
            let before = boundedLimit / 2
            preparedLatestItems = nil
            preparedAroundWindow = messageWindow(
                primary: anchor.primary,
                archivedId: anchor.archivedId,
                messageId: anchor.messageId,
                before: before,
                after: max(0, boundedLimit - before - 1)
            )
        case .firstIncomingAfterBoundary(let boundaryArchivedId):
            let before = boundedLimit / 2
            preparedLatestItems = nil
            preparedAroundWindow = firstIncomingWindow(
                afterArchiveBoundaryId: boundaryArchivedId,
                before: before,
                after: max(0, boundedLimit - before - 1)
            )
        }
        guard effectiveTarget == .latest || preparedAroundWindow != nil else {
            consume(nil)
            return
        }
        let materializedMessageCount =
            preparedAroundWindow?.items.count ?? preparedLatestItems?.count ?? 0
        consume(ChatTimelineInitialFrameLeaseMaterialization(
            preparedLatestItems: preparedLatestItems,
            preparedAroundWindow: preparedAroundWindow,
            unreadMetadata: initialFrameMetadata(
                limit: boundedLimit,
                materializedLocalMessageCount: materializedMessageCount,
                conversationKey: conversationKey,
                baseGeneration: baseGeneration
            ),
            searchResolutionProof: searchResolutionProof
        ))
    }

    func messageWindow(
        primary: String?,
        archivedId: String?,
        messageId: String?,
        before: Int,
        after: Int
    ) -> ChatTimelineInitialFrameWindow? {
        guard let target = message(
            primary: primary,
            archivedId: archivedId,
            messageId: messageId
        ) else {
            return nil
        }
        let items = around(
            anchor: target,
            before: max(0, before),
            after: max(0, after)
        )
        guard items.contains(where: { $0.primary == target.primary }) else {
            return nil
        }
        return ChatTimelineInitialFrameWindow(target: target, items: items)
    }

    func firstIncomingWindow(
        afterArchiveBoundaryId boundaryArchivedId: String,
        before: Int,
        after: Int
    ) -> ChatTimelineInitialFrameWindow? {
        guard let target = firstIncoming(afterArchiveBoundaryId: boundaryArchivedId) else {
            return nil
        }
        let items = around(
            anchor: target,
            before: max(0, before),
            after: max(0, after)
        )
        guard items.contains(where: { $0.primary == target.primary }) else {
            return nil
        }
        return ChatTimelineInitialFrameWindow(target: target, items: items)
    }
}

struct ChatTimelineResidentIndex {
    private let primaryPositions: [String: Int]
    private let archivedIdPositions: [String: Int]
    private let messageIdPositions: [String: Int]

    var count: Int {
        primaryPositions.count
    }

    var primaryIndexByID: [String: Int] {
        primaryPositions
    }

    init(items: [MessageStorageItem]) {
        var primaryPositions: [String: Int] = [:]
        var archivedIdPositions: [String: Int] = [:]
        var messageIdPositions: [String: Int] = [:]
        primaryPositions.reserveCapacity(items.count)
        archivedIdPositions.reserveCapacity(items.count)
        messageIdPositions.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            if item.primary.isNotEmpty {
                primaryPositions[item.primary] = index
            }
            if let archivedId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(item.archivedId) {
                archivedIdPositions[archivedId] = index
            }
            if item.messageId.isNotEmpty {
                messageIdPositions[item.messageId] = index
            }
        }

        self.primaryPositions = primaryPositions
        self.archivedIdPositions = archivedIdPositions
        self.messageIdPositions = messageIdPositions
    }

    func index(primary: String?) -> Int? {
        guard let primary, primary.isNotEmpty else { return nil }
        return primaryPositions[primary]
    }

    func index(archivedId: String?) -> Int? {
        guard let archivedId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archivedId) else {
            return nil
        }
        return archivedIdPositions[archivedId]
    }

    func index(messageId: String?) -> Int? {
        guard let messageId, messageId.isNotEmpty else { return nil }
        return messageIdPositions[messageId]
    }

    func index(primary: String?, archivedId: String?, messageId: String?) -> Int? {
        index(primary: primary) ?? index(archivedId: archivedId) ?? index(messageId: messageId)
    }
}

struct ChatTimelineReadBoundary: Equatable {
    let primary: String
    let position: ChatTimelinePositionKey
}

enum ChatTimelineSessionSnapshotCause: Equatable {
    case command
    case storeChange
}

struct ChatTimelineSessionSnapshot {
    let generation: UInt64
    let cause: ChatTimelineSessionSnapshotCause
    let items: [MessageStorageItem]
    let state: ChatVirtualTimelineState
    let loadingState: ChatTimelineLoadingState
    let loadDecision: ChatHistoryPagingLoadDecision?
    let anchorRestore: ChatTimelineAnchorRestoreCommand?
    let localOlderCandidateCount: Int?
    let pageSize: Int
    let shortLocalRemainderRemoteFirst: Bool
    let residentIndex: ChatTimelineResidentIndex
    let readBoundary: ChatTimelineReadBoundary?
    let unreadMetadata: ChatTimelineUnreadMetadata
    let residentHardLimit: Int
    let residentChangeSet: ChatIncrementalResidentChangeSet?

    var oldest: ChatTimelineBoundary? {
        state.oldest
    }

    var newest: ChatTimelineBoundary? {
        state.newest
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    var timelineSnapshot: ChatTimelineSnapshot {
        ChatTimelineSnapshot(
            items: items,
            state: state,
            loadingState: loadingState,
            loadDecision: loadDecision,
            anchorRestore: anchorRestore,
            localOlderCandidateCount: localOlderCandidateCount,
            pageSize: pageSize,
            shortLocalRemainderRemoteFirst: shortLocalRemainderRemoteFirst
        )
    }

    func item(primary: String?, archivedId: String? = nil, messageId: String? = nil) -> MessageStorageItem? {
        guard let index = residentIndex.index(
            primary: primary,
            archivedId: archivedId,
            messageId: messageId
        ), items.indices.contains(index) else {
            return nil
        }
        return items[index]
    }
}

/// Value-only projection of every committed field that can affect the
/// deferred store-observation baseline. Generation, publication cause, and
/// read boundary are intentionally excluded: authority may cross exactly one
/// kind of command publication, a metadata-neutral read-boundary advance.
struct ChatTimelineStoreObservationAuthorityProjection: Equatable {
    let residentFingerprints: [ChatTimelineObservedMessageFingerprint]
    let state: ChatVirtualTimelineState
    let loadingState: ChatTimelineLoadingState
    let loadDecision: ChatHistoryPagingLoadDecision?
    let anchorRestore: ChatTimelineAnchorRestoreCommand?
    let localOlderCandidateCount: Int?
    let pageSize: Int
    let shortLocalRemainderRemoteFirst: Bool
    let unreadMetadata: ChatTimelineUnreadMetadata
    let residentHardLimit: Int
    let residentChangeSet: ChatIncrementalResidentChangeSet?

    static func capture(
        _ snapshot: ChatTimelineSessionSnapshot
    ) -> ChatTimelineStoreObservationAuthorityProjection {
        ChatTimelineStoreObservationAuthorityProjection(
            residentFingerprints: snapshot.items.map(
                ChatTimelineObservedMessageFingerprint.init(message:)
            ),
            state: snapshot.state,
            loadingState: snapshot.loadingState,
            loadDecision: snapshot.loadDecision,
            anchorRestore: snapshot.anchorRestore,
            localOlderCandidateCount: snapshot.localOlderCandidateCount,
            pageSize: snapshot.pageSize,
            shortLocalRemainderRemoteFirst:
                snapshot.shortLocalRemainderRemoteFirst,
            unreadMetadata: snapshot.unreadMetadata,
            residentHardLimit: snapshot.residentHardLimit,
            residentChangeSet: snapshot.residentChangeSet
        )
    }
}

struct ChatTimelineStoreObservationAuthorityLineage: Equatable {
    let conversationKey: ChatTimelineConversationKey
    let proofBaseGeneration: UInt64
    let currentGeneration: UInt64
    let projection: ChatTimelineStoreObservationAuthorityProjection
}

enum ChatTimelineStoreObservationAuthorityPublication {
    case invalidating
    case initialFrameCommit
    case readBoundaryOnly
}

/// Carries initial-frame observation authority across publications only when
/// the complete baseline projection is unchanged and the sole mutation is a
/// valid, strictly advancing resident read boundary.
enum ChatTimelineStoreObservationAuthorityPolicy {
    static func updatedLineage(
        _ lineage: ChatTimelineStoreObservationAuthorityLineage?,
        from previous: ChatTimelineSessionSnapshot,
        to next: ChatTimelineSessionSnapshot,
        conversationKey: ChatTimelineConversationKey,
        publication: ChatTimelineStoreObservationAuthorityPublication
    ) -> ChatTimelineStoreObservationAuthorityLineage? {
        switch publication {
        case .invalidating:
            return nil

        case .initialFrameCommit:
            guard let proof = next.unreadMetadata.initialFrameReadinessProof,
                  proof.conversationKey == conversationKey,
                  proof.baseGeneration == previous.generation,
                  next.generation == previous.generation &+ 1,
                  next.generation == proof.baseGeneration &+ 1,
                  next.cause == .command,
                  next.readBoundary == previous.readBoundary else {
                return nil
            }
            return ChatTimelineStoreObservationAuthorityLineage(
                conversationKey: conversationKey,
                proofBaseGeneration: proof.baseGeneration,
                currentGeneration: next.generation,
                projection: .capture(next)
            )

        case .readBoundaryOnly:
            let previousProjection =
                ChatTimelineStoreObservationAuthorityProjection.capture(previous)
            let nextProjection =
                ChatTimelineStoreObservationAuthorityProjection.capture(next)
            guard let lineage,
                  lineage.conversationKey == conversationKey,
                  lineage.currentGeneration == previous.generation,
                  lineage.projection == previousProjection,
                  next.generation == previous.generation &+ 1,
                  next.cause == .command,
                  nextProjection == previousProjection,
                  isStrictResidentReadBoundaryAdvance(
                      from: previous,
                      to: next
                  ) else {
                return nil
            }
            return ChatTimelineStoreObservationAuthorityLineage(
                conversationKey: lineage.conversationKey,
                proofBaseGeneration: lineage.proofBaseGeneration,
                currentGeneration: next.generation,
                projection: nextProjection
            )
        }
    }

    static func isAuthoritative(
        _ lineage: ChatTimelineStoreObservationAuthorityLineage?,
        for snapshot: ChatTimelineSessionSnapshot,
        conversationKey: ChatTimelineConversationKey
    ) -> Bool {
        guard let lineage,
              let proof = snapshot.unreadMetadata.initialFrameReadinessProof,
              lineage.conversationKey == conversationKey,
              proof.conversationKey == conversationKey,
              lineage.proofBaseGeneration == proof.baseGeneration,
              lineage.currentGeneration == snapshot.generation,
              lineage.projection ==
                ChatTimelineStoreObservationAuthorityProjection.capture(
                    snapshot
                ) else {
            return false
        }
        return true
    }

    private static func isStrictResidentReadBoundaryAdvance(
        from previous: ChatTimelineSessionSnapshot,
        to next: ChatTimelineSessionSnapshot
    ) -> Bool {
        guard let nextBoundary = next.readBoundary,
              next.readBoundary != previous.readBoundary,
              previous.readBoundary.map({
                  nextBoundary.position > $0.position
              }) ?? true,
              let item = next.item(primary: nextBoundary.primary),
              !item.isDeleted,
              ChatTimelinePositionKey(message: item) == nextBoundary.position else {
            return false
        }
        return true
    }
}

enum ChatTimelineLocalPageLoadDisposition: Equatable {
    case started
    case coalesced
    case rejectedStale
}

enum ChatTimelineLocalPagePreparationResult {
    case prepared(ChatTimelinePreparedLocalPage)
    case stale
}

struct ChatTimelineLocalPageArchiveContext {
    let persisted: ChatArchiveStateSnapshot
    let paging: ChatArchiveStateSnapshot
}

final class ChatTimelinePreparedLocalPage {
    let id: String
    let direction: ChatHistoryPageDirection
    let conversationKey: ChatTimelineConversationKey
    let baseGeneration: UInt64
    let boundary: ChatTimelineBoundary
    let archiveContext: ChatTimelineLocalPageArchiveContext
    let snapshot: ChatTimelineSnapshot
    let preparedOnMainThread: Bool

    fileprivate let sessionID: UUID
    private let consumeLock = NSLock()
    private var consumed = false

    fileprivate init(
        id: String,
        sessionID: UUID,
        direction: ChatHistoryPageDirection,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64,
        boundary: ChatTimelineBoundary,
        archiveContext: ChatTimelineLocalPageArchiveContext,
        snapshot: ChatTimelineSnapshot,
        preparedOnMainThread: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.direction = direction
        self.conversationKey = conversationKey
        self.baseGeneration = baseGeneration
        self.boundary = boundary
        self.archiveContext = archiveContext
        self.snapshot = snapshot
        self.preparedOnMainThread = preparedOnMainThread
    }

    fileprivate func consumeOnce() -> Bool {
        consumeLock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }
}

enum ChatTimelineInitialFrameTarget: Equatable {
    case latest
    case message(ChatTimelineAnchor)
    case firstIncomingAfterBoundary(String)
}

enum ChatTimelineInitialFrameAlignment: Equatable {
    case bottom
    case anchor(primary: String, archivedId: String?)
}

enum ChatTimelineInitialFrameBlockingReason: Equatable {
    case targetMissing(ChatTimelineInitialFrameTarget)
    case searchResolutionFailed(ChatAnchorTransactionFailure)
}

struct ChatTimelineInitialFramePreparationMetrics: Equatable {
    let storeQueryCount: Int
    let mainThreadStoreQueryCount: Int
    let fullScanCount: Int
    let maxCandidateCount: Int
    let preparedMessageCount: Int
    let preparedOnMainThread: Bool
}

enum ChatTimelineInitialFrameLoadDisposition: Equatable {
    case started
    case rejectedStale
}

enum ChatTimelineInitialFramePreparationResult {
    case prepared(ChatTimelinePreparedInitialFrame)
    case blocked(ChatTimelineInitialFrameBlockingReason)
    case stale
}

enum ChatTimelineInitialFrameFinalizationCommitResult {
    case committed(
        frame: ChatTimelinePreparedInitialFrame,
        snapshot: ChatTimelineSessionSnapshot
    )
    case rejected(ChatTimelinePreparedInitialFrame)
    case stale
}

enum ChatTimelinePostBootstrapMappedCommitResult<MappedValue> {
    case committed(
        frame: ChatTimelinePreparedInitialFrame,
        snapshot: ChatTimelineSessionSnapshot,
        mapped: ChatFirstFrameMappedValue<MappedValue>
    )
    case blocked(ChatTimelineInitialFrameBlockingReason)
    case rejected
    case stale
}

final class ChatTimelinePreparedInitialFrame {
    fileprivate typealias FinalizationCompletion =
        (ChatTimelineInitialFrameFinalizationCommitResult) -> Void

    /// Only the finalized delta is cached. In particular, this value never
    /// retains the frame whose `finalizationState` owns it.
    private struct FinalizedFramePayload {
        let snapshot: ChatTimelineSnapshot
        let alignment: ChatTimelineInitialFrameAlignment
        let metrics: ChatTimelineInitialFramePreparationMetrics
        let unreadMetadata: ChatTimelineUnreadMetadata
        let searchResolutionProof: ChatTimelineSearchResolutionProof
        let isMetadataFinalized: Bool

        init(frame: ChatTimelinePreparedInitialFrame) {
            snapshot = frame.snapshot
            alignment = frame.alignment
            metrics = frame.metrics
            unreadMetadata = frame.unreadMetadata
            searchResolutionProof = frame.searchResolutionProof
            isMetadataFinalized = frame.isMetadataFinalized
        }

        func replayFrame(
            from source: ChatTimelinePreparedInitialFrame,
            terminalPayload: FinalizationTerminalPayload
        ) -> ChatTimelinePreparedInitialFrame {
            let replay = ChatTimelinePreparedInitialFrame(
                sessionID: source.sessionID,
                target: source.target,
                conversationKey: source.conversationKey,
                baseGeneration: source.baseGeneration,
                snapshot: snapshot,
                alignment: alignment,
                metrics: metrics,
                unreadMetadata: unreadMetadata,
                searchResolutionProof: searchResolutionProof,
                isMetadataFinalized: isMetadataFinalized,
                preparationEpoch: source.preparationEpoch,
                preparationLimit: source.preparationLimit,
                baseSnapshot: source.baseSnapshot,
                preparedLatestItems: source.preparedLatestItems,
                preparedAroundWindow: source.preparedAroundWindow
            )
            replay.installResolvedTerminalPayload(terminalPayload)
            return replay
        }
    }

    private enum FinalizationTerminalPayload {
        case committed(
            frame: FinalizedFramePayload,
            snapshot: ChatTimelineSessionSnapshot
        )
        case rejected(frame: FinalizedFramePayload)
        case stale

        init(result: ChatTimelineInitialFrameFinalizationCommitResult) {
            switch result {
            case .committed(let frame, let snapshot):
                self = .committed(
                    frame: FinalizedFramePayload(frame: frame),
                    snapshot: snapshot
                )
            case .rejected(let frame):
                self = .rejected(frame: FinalizedFramePayload(frame: frame))
            case .stale:
                self = .stale
            }
        }

        func replayResult(
            from source: ChatTimelinePreparedInitialFrame
        ) -> ChatTimelineInitialFrameFinalizationCommitResult {
            switch self {
            case .committed(let frame, let snapshot):
                return .committed(
                    frame: frame.replayFrame(
                        from: source,
                        terminalPayload: self
                    ),
                    snapshot: snapshot
                )
            case .rejected(let frame):
                return .rejected(
                    frame.replayFrame(
                        from: source,
                        terminalPayload: self
                    )
                )
            case .stale:
                return .stale
            }
        }
    }

    private enum FinalizationState {
        case available
        case running
        case resolved(FinalizationTerminalPayload)
    }

    fileprivate enum FinalizationEnqueueDisposition {
        case start
        case wait
        case resolved(ChatTimelineInitialFrameFinalizationCommitResult)
    }

    let target: ChatTimelineInitialFrameTarget
    let conversationKey: ChatTimelineConversationKey
    let baseGeneration: UInt64
    let snapshot: ChatTimelineSnapshot
    let alignment: ChatTimelineInitialFrameAlignment
    let metrics: ChatTimelineInitialFramePreparationMetrics
    let unreadMetadata: ChatTimelineUnreadMetadata
    let searchResolutionProof: ChatTimelineSearchResolutionProof
    let isMetadataFinalized: Bool

    fileprivate let sessionID: UUID
    fileprivate let preparationEpoch: UInt64
    fileprivate let preparationLimit: Int
    fileprivate let baseSnapshot: ChatTimelineSessionSnapshot
    fileprivate let preparedLatestItems: [MessageStorageItem]?
    fileprivate let preparedAroundWindow: ChatTimelineInitialFrameWindow?
    private let consumeLock = NSLock()
    private var consumed = false
    private let finalizationLock = NSLock()
    private var finalizationState: FinalizationState = .available
    private var finalizationWaiters: [FinalizationCompletion] = []

    fileprivate init(
        sessionID: UUID,
        target: ChatTimelineInitialFrameTarget,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64,
        snapshot: ChatTimelineSnapshot,
        alignment: ChatTimelineInitialFrameAlignment,
        metrics: ChatTimelineInitialFramePreparationMetrics,
        unreadMetadata: ChatTimelineUnreadMetadata,
        searchResolutionProof: ChatTimelineSearchResolutionProof = .notRequested,
        isMetadataFinalized: Bool,
        preparationEpoch: UInt64,
        preparationLimit: Int,
        baseSnapshot: ChatTimelineSessionSnapshot,
        preparedLatestItems: [MessageStorageItem]?,
        preparedAroundWindow: ChatTimelineInitialFrameWindow?
    ) {
        self.sessionID = sessionID
        self.target = target
        self.conversationKey = conversationKey
        self.baseGeneration = baseGeneration
        self.snapshot = snapshot
        self.alignment = alignment
        self.metrics = metrics
        self.unreadMetadata = unreadMetadata
        self.searchResolutionProof = searchResolutionProof
        self.isMetadataFinalized = isMetadataFinalized
        self.preparationEpoch = preparationEpoch
        self.preparationLimit = preparationLimit
        self.baseSnapshot = baseSnapshot
        self.preparedLatestItems = preparedLatestItems
        self.preparedAroundWindow = preparedAroundWindow
    }

    fileprivate func consumeOnce() -> Bool {
        consumeLock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }

    fileprivate func enqueueFinalization(
        _ completion: @escaping FinalizationCompletion
    ) -> FinalizationEnqueueDisposition {
        finalizationLock.withLock {
            switch finalizationState {
            case .available:
                finalizationState = .running
                finalizationWaiters = [completion]
                return .start
            case .running:
                finalizationWaiters.append(completion)
                return .wait
            case .resolved(let terminalPayload):
                return .resolved(terminalPayload.replayResult(from: self))
            }
        }
    }

    fileprivate func resolveFinalization(
        _ result: ChatTimelineInitialFrameFinalizationCommitResult
    ) -> [FinalizationCompletion] {
        let terminalPayload = FinalizationTerminalPayload(result: result)
        let resolvedFrame: ChatTimelinePreparedInitialFrame?
        switch result {
        case .committed(let frame, _), .rejected(let frame):
            resolvedFrame = frame
        case .stale:
            resolvedFrame = nil
        }
        let waiters = finalizationLock.withLock { () -> [FinalizationCompletion] in
            guard case .running = finalizationState else { return [] }
            finalizationState = .resolved(terminalPayload)
            let waiters = finalizationWaiters
            finalizationWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        if let resolvedFrame, resolvedFrame !== self {
            resolvedFrame.installResolvedTerminalPayload(terminalPayload)
        }
        return waiters
    }

    private func installResolvedTerminalPayload(
        _ terminalPayload: FinalizationTerminalPayload
    ) {
        finalizationLock.withLock {
            guard case .available = finalizationState else { return }
            finalizationState = .resolved(terminalPayload)
        }
    }
}

struct ChatFirstFrameMappedValue<Value> {
    let value: Value
    let mappedOnMainThread: Bool
}

enum ChatFirstFrameDisplayMappingExecutor {
    static func map<Input, Output>(
        _ input: Input,
        on queue: DispatchQueue,
        transform: @escaping (Input) -> Output,
        completion: @escaping (ChatFirstFrameMappedValue<Output>) -> Void
    ) {
        queue.async {
            let mappedOnMainThread = Thread.isMainThread
            let value = transform(input)
            DispatchQueue.main.async {
                completion(
                    ChatFirstFrameMappedValue(
                        value: value,
                        mappedOnMainThread: mappedOnMainThread
                    )
                )
            }
        }
    }
}

private final class ChatTimelineLocalPagePreparationProvider: ChatTimelinePageProviding {
    private let upstream: ChatTimelinePageProviding
    private var itemsByPrimary: [String: MessageStorageItem]
    private var preparedLatestItems: [MessageStorageItem]?
    private var consumedPreparedLatestItems = false
    private var preparedAroundWindow: ChatTimelineInitialFrameWindow?
    private var consumedPreparedAroundWindowPrimary: String?

    init(
        upstream: ChatTimelinePageProviding,
        residentItems: [MessageStorageItem],
        preparedLatestItems: [MessageStorageItem]? = nil,
        preparedAroundWindow: ChatTimelineInitialFrameWindow? = nil
    ) {
        self.upstream = upstream
        self.preparedLatestItems = preparedLatestItems
        self.preparedAroundWindow = preparedAroundWindow
        self.itemsByPrimary = Dictionary(
            (
                residentItems +
                (preparedLatestItems ?? []) +
                (preparedAroundWindow?.items ?? [])
            ).map { ($0.primary, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    func latest(limit: Int) -> [MessageStorageItem] {
        if let preparedLatestItems {
            self.preparedLatestItems = nil
            consumedPreparedLatestItems = true
            return cache(Array(preparedLatestItems.suffix(max(0, limit))))
        }
        if consumedPreparedLatestItems {
            return []
        }
        return cache(upstream.latest(limit: limit))
    }

    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        cache(upstream.older(before: boundary, limit: limit))
    }

    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        cache(upstream.newer(after: boundary, limit: limit))
    }

    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem] {
        if let preparedAroundWindow,
           preparedAroundWindow.target.primary == anchor.primary,
           preparedAroundWindow.items.count <= max(0, before) + max(0, after) + 1,
           preparedAroundWindow.items.contains(where: { $0.primary == anchor.primary }) {
            self.preparedAroundWindow = nil
            consumedPreparedAroundWindowPrimary = anchor.primary
            return cache(preparedAroundWindow.items)
        }
        if consumedPreparedAroundWindowPrimary == anchor.primary {
            return []
        }
        return cache(upstream.around(anchor: anchor, before: before, after: after))
    }

    func message(
        primary: String?,
        archivedId: String?,
        messageId: String?
    ) -> MessageStorageItem? {
        if let primary, let item = itemsByPrimary[primary] {
            return item
        }
        if let item = itemsByPrimary.values.first(where: {
            (archivedId != nil && $0.archivedId == archivedId)
                || (messageId != nil && $0.messageId == messageId)
        }) {
            return item
        }
        guard let item = upstream.message(
            primary: primary,
            archivedId: archivedId,
            messageId: messageId
        ) else {
            return nil
        }
        itemsByPrimary[item.primary] = item
        return item
    }

    func searchMessage(anchor: ChatMessageAnchorRef) -> MessageStorageItem? {
        searchMessageResolution(anchor: anchor).message
    }

    func searchMessageResolution(
        anchor: ChatMessageAnchorRef
    ) -> ChatTimelineSearchMessageResolution {
        if let primary = anchor.messagePrimary,
           let item = itemsByPrimary[primary] {
            return item.isDeleted ? .failed(.targetDeleted) : .found(item)
        }
        let resolution = upstream.searchMessageResolution(anchor: anchor)
        if case .found(let item) = resolution {
            itemsByPrimary[item.primary] = item
        }
        return resolution
    }

    func items(primaryKeys: [String]) -> [MessageStorageItem] {
        primaryKeys.compactMap { itemsByPrimary[$0] }
    }

    private func cache(_ items: [MessageStorageItem]) -> [MessageStorageItem] {
        for item in items {
            itemsByPrimary[item.primary] = item
        }
        return items
    }
}

final class ChatTimelineSession {
    typealias SnapshotHandler = (ChatTimelineSessionSnapshot) -> Void

    private let lock = NSRecursiveLock()
    private let operationLock = NSRecursiveLock()
    private let store: ChatTimelineSessionStore
    private let pageSize: Int
    private let conversationKey: ChatTimelineConversationKey
    private let sessionID = UUID()
    private let localPagePreparationQueue: DispatchQueue
    private let localPagePreparationLock = NSLock()
    private var activeLocalPagePreparationKeys: Set<String> = []
    private var localPagePreparationEpoch: UInt64 = 0
    private let initialFramePreparationLock = NSLock()
    private var initialFramePreparationEpoch: UInt64 = 0
    private var activeInitialFramePreparationEpoch: UInt64?
    private var archiveState: ChatArchiveStateSnapshot
    private var storedSnapshot: ChatTimelineSessionSnapshot
    private var storeObservationAuthorityLineage:
        ChatTimelineStoreObservationAuthorityLineage?
    private var observation: ChatTimelineStoreObservation?
    private var isInstallingStoreObservation = false
    private var storeObservationEpoch: UInt64 = 0
    private var storedSnapshotHandler: SnapshotHandler?
    private var storeChangeDepth = 0
    private var incrementalResidentReducer = ChatIncrementalResidentReducer()

    var snapshot: ChatTimelineSessionSnapshot {
        lock.withLock { storedSnapshot }
    }

    /// Route-total history diagnostics begin when the production session store
    /// is installed, before controller admission and loading helpers run.
    /// Initial-frame receipts use this absolute snapshot so an accidental
    /// pre-preparation lookup cannot be hidden by a local measurement delta.
    var routeStoreDiagnosticsSnapshot: ChatTimelineStoreDiagnosticsSnapshot {
        store.diagnosticsSnapshot
    }

    var onSnapshot: SnapshotHandler? {
        get { lock.withLock { storedSnapshotHandler } }
        set { lock.withLock { storedSnapshotHandler = newValue } }
    }

    func isConfigured(for conversationKey: ChatTimelineConversationKey) -> Bool {
        self.conversationKey == conversationKey
    }

    init(
        store: ChatTimelineSessionStore,
        pageSize: Int,
        conversationKey: ChatTimelineConversationKey,
        archiveState: ChatArchiveStateSnapshot,
        observesStoreImmediately: Bool = true
    ) {
        self.store = store
        self.pageSize = max(1, pageSize)
        self.conversationKey = conversationKey
        self.localPagePreparationQueue = DispatchQueue(
            label: "com.xabber.chat.timeline.local-page.\(UUID().uuidString)",
            qos: .userInitiated
        )
        self.archiveState = archiveState
        let state = ChatVirtualTimelineState.empty(
            owner: conversationKey.owner,
            jid: conversationKey.jid,
            conversationType: conversationKey.conversationType
        )
        self.storedSnapshot = ChatTimelineSessionSnapshot(
            generation: 0,
            cause: .command,
            items: [],
            state: state,
            loadingState: .none,
            loadDecision: nil,
            anchorRestore: nil,
            localOlderCandidateCount: nil,
            pageSize: self.pageSize,
            shortLocalRemainderRemoteFirst: false,
            residentIndex: ChatTimelineResidentIndex(items: []),
            readBoundary: nil,
            unreadMetadata: .empty,
            residentHardLimit: ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: self.pageSize),
            residentChangeSet: nil
        )
        if observesStoreImmediately {
            activateStoreObservation()
        }
    }

    deinit {
        cancelInitialFramePreparations()
        cancelLocalPagePreparations()
        observation?.invalidate()
    }

    /// Installs the store observer once. An authoritative empty bootstrap has
    /// no committed page lineage, so its explicitly empty snapshot supplies
    /// the trusted baseline for the observer's synchronous initial delivery.
    func activateStoreObservation(
        authoritativeEmptyBaseline: Bool = false
    ) {
        operationLock.withLock {
            let activationEpoch = lock.withLock { () -> UInt64? in
                guard observation == nil, !isInstallingStoreObservation else {
                    return nil
                }
                isInstallingStoreObservation = true
                storeObservationEpoch &+= 1
                return storeObservationEpoch
            }
            guard let activationEpoch else { return }
            let authorityState = lock.withLock {
                (storedSnapshot, storeObservationAuthorityLineage)
            }
            let committed = authorityState.0
            let proof = committed.unreadMetadata.initialFrameReadinessProof
            let hasAuthoritativeBaseline =
                ChatTimelineStoreObservationAuthorityPolicy.isAuthoritative(
                    authorityState.1,
                    for: committed,
                    conversationKey: conversationKey
                ) || (authoritativeEmptyBaseline && committed.items.isEmpty)
            let baseline = ChatTimelineStoreObservationBaseline(
                isAuthoritative: hasAuthoritativeBaseline,
                residentItems: committed.items,
                latestMessageFingerprint: proof?.latestMessageFingerprint,
                unreadCount: committed.unreadMetadata.unreadCount,
                unreadMetadataLimit: committed.residentHardLimit,
                unreadMetadata: committed.unreadMetadata
            )
            let installed = store.observe(baseline: baseline) {
                [weak self] change in
                self?.handleStoreChange(change)
            }
            lock.withLock {
                isInstallingStoreObservation = false
                if observation == nil,
                   storeObservationEpoch == activationEpoch {
                    observation = installed
                } else {
                    installed.invalidate()
                }
            }
        }
    }

    var activeStoreObservationWorkCount: Int {
        lock.withLock {
            (isInstallingStoreObservation ? 1 : 0) +
                (observation?.activeWorkCount ?? 0)
        }
    }

    #if DEBUG || CHAT_PERFORMANCE_LAB
    /// Read-only proof that the production initial-frame commit installed its
    /// Realm observer. A zero work count alone is ambiguous when no observer
    /// exists at all.
    internal var hasActiveStoreObservationForTests: Bool {
        lock.withLock {
            observation != nil && !isInstallingStoreObservation
        }
    }
    #endif

    func deactivateStoreObservation() {
        let installed = lock.withLock { () -> ChatTimelineStoreObservation? in
            storeObservationEpoch &+= 1
            let installed = observation
            observation = nil
            isInstallingStoreObservation = false
            return installed
        }
        installed?.invalidate()
    }

    @discardableResult
    func openLatest(limit: Int? = nil) -> ChatTimelineSessionSnapshot {
        mutateTimeline { engine in
            engine.openLatest(
                limit: min(
                    max(1, limit ?? ChatBoundedTimelineWindowPolicy.targetLimit(pageSize: pageSize)),
                    ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize)
                )
            )
        }
    }

    @discardableResult
    func scrollToLatest(limit: Int? = nil) -> ChatTimelineSessionSnapshot {
        openLatest(limit: limit)
    }

    @discardableResult
    func openAround(anchor: ChatTimelineAnchor) -> ChatTimelineSessionSnapshot {
        mutateTimeline { engine in
            engine.openAround(anchor: anchor)
        }
    }

    @discardableResult
    func pageOlder(queryId: String? = nil) -> ChatTimelineSessionSnapshot {
        mutateTimeline { engine in
            engine.pageOlder(queryId: queryId)
        }
    }

    @discardableResult
    func pageNewer(queryId: String? = nil) -> ChatTimelineSessionSnapshot {
        mutateTimeline { engine in
            engine.pageNewer(queryId: queryId)
        }
    }

    @discardableResult
    func loadOlder(
        before boundary: ChatTimelineBoundary,
        archiveState: ChatArchiveStateSnapshot,
        expectedGeneration: UInt64,
        completion: @escaping (ChatTimelineLocalPagePreparationResult) -> Void
    ) -> ChatTimelineLocalPageLoadDisposition {
        startLocalPagePreparation(
            direction: .older,
            boundary: boundary,
            archiveContextProvider: {
                ChatTimelineLocalPageArchiveContext(
                    persisted: archiveState,
                    paging: archiveState
                )
            },
            expectedGeneration: expectedGeneration,
            completion: completion
        )
    }

    @discardableResult
    func loadOlder(
        before boundary: ChatTimelineBoundary,
        archiveContextProvider: @escaping () -> ChatTimelineLocalPageArchiveContext,
        expectedGeneration: UInt64,
        completion: @escaping (ChatTimelineLocalPagePreparationResult) -> Void
    ) -> ChatTimelineLocalPageLoadDisposition {
        startLocalPagePreparation(
            direction: .older,
            boundary: boundary,
            archiveContextProvider: archiveContextProvider,
            expectedGeneration: expectedGeneration,
            completion: completion
        )
    }

    @discardableResult
    func loadNewer(
        after boundary: ChatTimelineBoundary,
        archiveState: ChatArchiveStateSnapshot,
        expectedGeneration: UInt64,
        completion: @escaping (ChatTimelineLocalPagePreparationResult) -> Void
    ) -> ChatTimelineLocalPageLoadDisposition {
        startLocalPagePreparation(
            direction: .newer,
            boundary: boundary,
            archiveContextProvider: {
                ChatTimelineLocalPageArchiveContext(
                    persisted: archiveState,
                    paging: archiveState
                )
            },
            expectedGeneration: expectedGeneration,
            completion: completion
        )
    }

    @discardableResult
    func prepareInitialFrame(
        target: ChatTimelineInitialFrameTarget,
        limit: Int,
        expectedGeneration: UInt64,
        deferMetadataUntilFinalization: Bool = false,
        performanceTraceContext: ChatOpenPerformanceTraceContext? = nil,
        completion: @escaping (ChatTimelineInitialFramePreparationResult) -> Void
    ) -> ChatTimelineInitialFrameLoadDisposition {
        let base = snapshot
        guard base.generation == expectedGeneration else {
            return .rejectedStale
        }

        let epoch = initialFramePreparationLock.withLock { () -> UInt64 in
            initialFramePreparationEpoch &+= 1
            activeInitialFramePreparationEpoch = initialFramePreparationEpoch
            return initialFramePreparationEpoch
        }
        let boundedLimit = min(
            max(1, limit),
            ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize)
        )

        localPagePreparationQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.stale)
                }
                return
            }
            let prepareResult = {
                self.prepareInitialFrameResult(
                    target: target,
                    limit: boundedLimit,
                    base: base,
                    preparationEpoch: epoch,
                    includesMetadata: !deferMetadataUntilFinalization
                )
            }
            let result: ChatTimelineInitialFramePreparationResult
            if let performanceTraceContext {
                result = ChatPerformanceSignposts.measure(
                    .localHistoryQuery,
                    context: performanceTraceContext,
                    prepareResult
                )
            } else {
                result = prepareResult()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let isCurrent = self.lock.withLock {
                    self.storedSnapshot.generation == expectedGeneration
                }
                let isActive = self.initialFramePreparationLock.withLock { () -> Bool in
                    let isActive = self.initialFramePreparationEpoch == epoch &&
                        self.activeInitialFramePreparationEpoch == epoch
                    if self.activeInitialFramePreparationEpoch == epoch {
                        self.activeInitialFramePreparationEpoch = nil
                    }
                    return isActive
                }
                completion(isCurrent && isActive ? result : .stale)
            }
        }
        return .started
    }

    func finalizeAndCommitPreparedInitialFrame(
        _ preparedFrame: ChatTimelinePreparedInitialFrame,
        shouldCommit: @escaping (ChatTimelinePreparedInitialFrame) -> Bool,
        completion: @escaping (
            ChatTimelineInitialFrameFinalizationCommitResult
        ) -> Void
    ) {
        guard preparedFrame.sessionID == sessionID,
              preparedFrame.conversationKey == conversationKey,
              preparedFrame.baseGeneration == snapshot.generation else {
            completion(.stale)
            return
        }

        switch preparedFrame.enqueueFinalization(completion) {
        case .wait:
            return
        case .resolved(let result):
            completion(result)
            return
        case .start:
            break
        }

        let deliver: (ChatTimelineInitialFrameFinalizationCommitResult) -> Void = {
            result in
            let waiters = preparedFrame.resolveFinalization(result)
            waiters.forEach { $0(result) }
        }

        let expectedGeneration = preparedFrame.baseGeneration
        let expectedEpoch = preparedFrame.preparationEpoch
        if preparedFrame.isMetadataFinalized {
            let result = self.atomicInitialFrameCommitResult(
                frame: preparedFrame,
                expectedGeneration: expectedGeneration,
                expectedEpoch: expectedEpoch,
                shouldCommit: shouldCommit
            )
            deliver(result)
            return
        }

        localPagePreparationQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    deliver(.stale)
                }
                return
            }
            let isStillCurrent = self.initialFramePreparationLock.withLock {
                self.initialFramePreparationEpoch == expectedEpoch
            }
            guard isStillCurrent else {
                DispatchQueue.main.async {
                    deliver(.stale)
                }
                return
            }

            var atomicResult:
                ChatTimelineInitialFrameFinalizationCommitResult = .stale
            self.store.withInitialFrameMetadataConsistencyLease(
                limit: ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: self.pageSize),
                materializedLocalMessageCount: preparedFrame.snapshot.items.count,
                conversationKey: preparedFrame.conversationKey,
                baseGeneration: preparedFrame.baseGeneration
            ) { unreadMetadata in
                guard let readinessProof = unreadMetadata
                        .initialFrameReadinessProof,
                      readinessProof.conversationKey ==
                        preparedFrame.conversationKey,
                      readinessProof.baseGeneration ==
                        preparedFrame.baseGeneration else {
                    return
                }
                let archiveState = readinessProof.archiveState
                guard let rebuilt = self.initialFrameSnapshot(
                    target: preparedFrame.target,
                    limit: preparedFrame.preparationLimit,
                    base: preparedFrame.baseSnapshot,
                    preparedLatestItems: preparedFrame.preparedLatestItems,
                    preparedAroundWindow: preparedFrame.preparedAroundWindow,
                    archiveState: archiveState
                ) else {
                    return
                }
                let diagnosticsAfter = self.store.diagnosticsSnapshot
                let finalizedFrame = ChatTimelinePreparedInitialFrame(
                    sessionID: self.sessionID,
                    target: preparedFrame.target,
                    conversationKey: preparedFrame.conversationKey,
                    baseGeneration: preparedFrame.baseGeneration,
                    snapshot: rebuilt.snapshot,
                    alignment: rebuilt.alignment,
                    metrics: ChatTimelineInitialFramePreparationMetrics(
                        storeQueryCount: diagnosticsAfter.queryCount,
                        mainThreadStoreQueryCount:
                            diagnosticsAfter.mainThreadQueryCount,
                        fullScanCount: diagnosticsAfter.fullScanCount,
                        maxCandidateCount: diagnosticsAfter.maxCandidateCount,
                        preparedMessageCount: rebuilt.snapshot.items.count,
                        preparedOnMainThread:
                            preparedFrame.metrics.preparedOnMainThread ||
                            Thread.isMainThread
                    ),
                    unreadMetadata: unreadMetadata,
                    searchResolutionProof:
                        preparedFrame.searchResolutionProof,
                    isMetadataFinalized: true,
                    preparationEpoch: expectedEpoch,
                    preparationLimit: preparedFrame.preparationLimit,
                    baseSnapshot: preparedFrame.baseSnapshot,
                    preparedLatestItems: preparedFrame.preparedLatestItems,
                    preparedAroundWindow: preparedFrame.preparedAroundWindow
                )

                // The production store keeps its Realm consistency lease open
                // through this session commit. No Realm writer can publish a
                // newer coverage/gap boundary between proof capture and the
                // generation-checked immutable snapshot commit. The caller's
                // authorization closure must therefore be thread-safe and must
                // never perform UI or Realm work.
                atomicResult = self.atomicInitialFrameCommitResult(
                    frame: finalizedFrame,
                    expectedGeneration: expectedGeneration,
                    expectedEpoch: expectedEpoch,
                    shouldCommit: shouldCommit
                )
            }

            DispatchQueue.main.async {
                deliver(atomicResult)
            }
        }
    }

    /// Resumes a target that was absent during op1 after the trusted archive
    /// page has persisted. Production resolves the now-present window, reads
    /// immutable readiness metadata, performs the background display mapping,
    /// and generation-checks the session commit while one op2 consistency
    /// lease is still held.
    func prepareMapAndCommitPostBootstrapInitialFrame<MappedValue>(
        target: ChatTimelineInitialFrameTarget,
        searchAnchor: ChatMessageAnchorRef? = nil,
        limit: Int,
        expectedGeneration: UInt64,
        performanceTraceContext: ChatOpenPerformanceTraceContext? = nil,
        map: @escaping (
            ChatTimelinePreparedInitialFrame
        ) -> ChatFirstFrameMappedValue<MappedValue>?,
        shouldCommit: @escaping (
            ChatTimelinePreparedInitialFrame,
            ChatFirstFrameMappedValue<MappedValue>
        ) -> Bool,
        completion: @escaping (
            ChatTimelinePostBootstrapMappedCommitResult<MappedValue>
        ) -> Void
    ) -> ChatTimelineInitialFrameLoadDisposition {
        let base = snapshot
        guard base.generation == expectedGeneration else {
            ChatArchiveDebugTrace.log(
                "postBootstrapInitialFrameLeaseTerminal",
                [("stageCode", 0)]
            )
            return .rejectedStale
        }
        let epoch = initialFramePreparationLock.withLock { () -> UInt64 in
            initialFramePreparationEpoch &+= 1
            activeInitialFramePreparationEpoch = initialFramePreparationEpoch
            return initialFramePreparationEpoch
        }
        let boundedLimit = min(
            max(1, limit),
            ChatInitialFirstFrameHistoryConfiguration.pageSize,
            ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize)
        )

        localPagePreparationQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(.stale) }
                return
            }
            var result: ChatTimelinePostBootstrapMappedCommitResult<MappedValue> =
                .stale
            var localQueryInterval = performanceTraceContext.map {
                ChatPerformanceSignposts.begin(
                    .localHistoryQuery,
                    context: $0
                )
            }
            self.store.withPostBootstrapInitialFrameConsistencyLease(
                target: target,
                searchAnchor: searchAnchor,
                limit: boundedLimit,
                conversationKey: self.conversationKey,
                baseGeneration: base.generation
            ) { materialization in
                guard let materialization else {
                    ChatArchiveDebugTrace.log(
                        "postBootstrapInitialFrameLeaseTerminal",
                        [("stageCode", 1)]
                    )
                    localQueryInterval?.end(terminal: .failed)
                    result = .blocked(.targetMissing(target))
                    return
                }
                if case .failed(let failure) =
                    materialization.searchResolutionProof {
                    ChatArchiveDebugTrace.log(
                        "postBootstrapInitialFrameLeaseTerminal",
                        [("stageCode", 9)]
                    )
                    localQueryInterval?.end(terminal: .failed)
                    result = .blocked(.searchResolutionFailed(failure))
                    return
                }
                if case .found(let provedPrimary) =
                    materialization.searchResolutionProof,
                   materialization.preparedAroundWindow?.target.primary !=
                    provedPrimary {
                    ChatArchiveDebugTrace.log(
                        "postBootstrapInitialFrameLeaseTerminal",
                        [("stageCode", 10)]
                    )
                    localQueryInterval?.end(terminal: .failed)
                    result = .blocked(.targetMissing(target))
                    return
                }
                let preparedLatestItems = materialization.preparedLatestItems?
                    .map(Self.frozen)
                let preparedAroundWindow = materialization.preparedAroundWindow.map {
                    ChatTimelineInitialFrameWindow(
                        target: Self.frozen($0.target),
                        items: $0.items.map(Self.frozen),
                        materializedCandidateCount: $0.materializedCandidateCount
                    )
                }
                guard let readinessProof = materialization.unreadMetadata
                        .initialFrameReadinessProof,
                      readinessProof.conversationKey == self.conversationKey,
                      readinessProof.baseGeneration == base.generation else {
                    ChatArchiveDebugTrace.log(
                        "postBootstrapInitialFrameLeaseTerminal",
                        [("stageCode", 2)]
                    )
                    localQueryInterval?.end(terminal: .cancelled)
                    result = .rejected
                    return
                }
                let archiveState = readinessProof.archiveState
                guard let prepared = self.initialFrameSnapshot(
                    target: target,
                    limit: boundedLimit,
                    base: base,
                    preparedLatestItems: preparedLatestItems,
                    preparedAroundWindow: preparedAroundWindow,
                    archiveState: archiveState
                ) else {
                    ChatArchiveDebugTrace.log(
                        "postBootstrapInitialFrameLeaseTerminal",
                        [("stageCode", 3)]
                    )
                    localQueryInterval?.end(terminal: .failed)
                    result = .blocked(.targetMissing(target))
                    return
                }
                if case .found(let provedPrimary) =
                    materialization.searchResolutionProof,
                   !prepared.snapshot.items.contains(where: {
                       $0.primary == provedPrimary
                   }) {
                    ChatArchiveDebugTrace.log(
                        "postBootstrapInitialFrameLeaseTerminal",
                        [("stageCode", 11)]
                    )
                    localQueryInterval?.end(terminal: .failed)
                    result = .blocked(.targetMissing(target))
                    return
                }
                let diagnostics = self.store.diagnosticsSnapshot
                let frame = ChatTimelinePreparedInitialFrame(
                    sessionID: self.sessionID,
                    target: target,
                    conversationKey: self.conversationKey,
                    baseGeneration: base.generation,
                    snapshot: prepared.snapshot,
                    alignment: prepared.alignment,
                    metrics: ChatTimelineInitialFramePreparationMetrics(
                        storeQueryCount: diagnostics.queryCount,
                        mainThreadStoreQueryCount:
                            diagnostics.mainThreadQueryCount,
                        fullScanCount: diagnostics.fullScanCount,
                        maxCandidateCount: diagnostics.maxCandidateCount,
                        preparedMessageCount: prepared.snapshot.items.count,
                        preparedOnMainThread: Thread.isMainThread
                    ),
                    unreadMetadata: materialization.unreadMetadata,
                    searchResolutionProof:
                        materialization.searchResolutionProof,
                    isMetadataFinalized: true,
                    preparationEpoch: epoch,
                    preparationLimit: boundedLimit,
                    baseSnapshot: base,
                    preparedLatestItems: preparedLatestItems,
                    preparedAroundWindow: preparedAroundWindow
                )
                localQueryInterval?.end(terminal: .committed)
                guard let mapped = map(frame) else {
                    ChatArchiveDebugTrace.log(
                        "postBootstrapInitialFrameLeaseTerminal",
                        [("stageCode", 4)]
                    )
                    result = .rejected
                    return
                }
                switch self.atomicInitialFrameCommitResult(
                    frame: frame,
                    expectedGeneration: base.generation,
                    expectedEpoch: epoch,
                    shouldCommit: { candidate in
                        shouldCommit(candidate, mapped)
                    }
                ) {
                case .committed(let committedFrame, let snapshot):
                    ChatArchiveDebugTrace.log(
                        "postBootstrapInitialFrameLeaseTerminal",
                        [("stageCode", 5)]
                    )
                    result = .committed(
                        frame: committedFrame,
                        snapshot: snapshot,
                        mapped: mapped
                    )
                case .rejected:
                    ChatArchiveDebugTrace.log(
                        "postBootstrapInitialFrameLeaseTerminal",
                        [("stageCode", 6)]
                    )
                    result = .rejected
                case .stale:
                    ChatArchiveDebugTrace.log(
                        "postBootstrapInitialFrameLeaseTerminal",
                        [("stageCode", 7)]
                    )
                    result = .stale
                }
            }
            localQueryInterval?.end(terminal: .cancelled)

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion(.stale)
                    return
                }
                let isActive = self.initialFramePreparationLock.withLock {
                    () -> Bool in
                    let isActive = self.initialFramePreparationEpoch == epoch &&
                        self.activeInitialFramePreparationEpoch == epoch
                    if self.activeInitialFramePreparationEpoch == epoch {
                        self.activeInitialFramePreparationEpoch = nil
                    }
                    return isActive
                }
                if !isActive {
                    ChatArchiveDebugTrace.log(
                        "postBootstrapInitialFrameLeaseTerminal",
                        [("stageCode", 8)]
                    )
                }
                completion(isActive ? result : .stale)
            }
        }
        return .started
    }

    private func atomicInitialFrameCommitResult(
        frame: ChatTimelinePreparedInitialFrame,
        expectedGeneration: UInt64,
        expectedEpoch: UInt64,
        shouldCommit: (ChatTimelinePreparedInitialFrame) -> Bool
    ) -> ChatTimelineInitialFrameFinalizationCommitResult {
        let hasCurrentGeneration = lock.withLock {
            storedSnapshot.generation == expectedGeneration
        }
        guard hasCurrentGeneration else {
            return .stale
        }

        // Linearize query/token revocation against the final generation
        // commit. Cancellation increments this epoch under the same lock, so
        // a replacement that wins before authorization cannot slip into the
        // tiny interval between an epoch check and `commitPreparedInitialFrame`.
        return initialFramePreparationLock.withLock {
            guard initialFramePreparationEpoch == expectedEpoch else {
                return .stale
            }
            guard shouldCommit(frame) else {
                return .rejected(frame)
            }
            guard let committedSnapshot = commitPreparedInitialFrame(frame) else {
                return .stale
            }
            return .committed(frame: frame, snapshot: committedSnapshot)
        }
    }

    @discardableResult
    func commitPreparedInitialFrame(
        _ preparedFrame: ChatTimelinePreparedInitialFrame
    ) -> ChatTimelineSessionSnapshot? {
        operationLock.withLock {
            let current = snapshot
            guard preparedFrame.sessionID == sessionID,
                  preparedFrame.conversationKey == conversationKey,
                  preparedFrame.baseGeneration == current.generation,
                  preparedFrame.isMetadataFinalized,
                  preparedFrame.consumeOnce() else {
                return nil
            }
            if let readinessProof = preparedFrame.unreadMetadata
                .initialFrameReadinessProof {
                lock.withLock {
                    archiveState = readinessProof.archiveState
                }
            }
            let prepared = preparedFrame.snapshot
            return publish(
                items: prepared.items,
                state: prepared.state,
                loadingState: prepared.loadingState,
                loadDecision: prepared.loadDecision,
                anchorRestore: prepared.anchorRestore,
                localOlderCandidateCount: prepared.localOlderCandidateCount,
                shortLocalRemainderRemoteFirst: prepared.shortLocalRemainderRemoteFirst,
                readBoundary: current.readBoundary,
                unreadMetadata: preparedFrame.unreadMetadata,
                authorityPublication: .initialFrameCommit
            )
        }
    }

    func cancelInitialFramePreparations() {
        initialFramePreparationLock.withLock {
            initialFramePreparationEpoch &+= 1
            activeInitialFramePreparationEpoch = nil
        }
    }

    @discardableResult
    func loadNewer(
        after boundary: ChatTimelineBoundary,
        archiveContextProvider: @escaping () -> ChatTimelineLocalPageArchiveContext,
        expectedGeneration: UInt64,
        completion: @escaping (ChatTimelineLocalPagePreparationResult) -> Void
    ) -> ChatTimelineLocalPageLoadDisposition {
        startLocalPagePreparation(
            direction: .newer,
            boundary: boundary,
            archiveContextProvider: archiveContextProvider,
            expectedGeneration: expectedGeneration,
            completion: completion
        )
    }

    @discardableResult
    func commitPreparedLocalPage(
        _ preparedPage: ChatTimelinePreparedLocalPage
    ) -> ChatTimelineSessionSnapshot? {
        operationLock.withLock {
            let current = snapshot
            guard preparedPage.sessionID == sessionID,
                  preparedPage.conversationKey == conversationKey,
                  preparedPage.baseGeneration == current.generation,
                  preparedPage.snapshot.loadDecision == .localOnly,
                  preparedPage.consumeOnce() else {
                return nil
            }
            let prepared = preparedPage.snapshot
            return publish(
                items: prepared.items,
                state: prepared.state,
                loadingState: prepared.loadingState,
                loadDecision: prepared.loadDecision,
                anchorRestore: prepared.anchorRestore,
                localOlderCandidateCount: prepared.localOlderCandidateCount,
                shortLocalRemainderRemoteFirst: prepared.shortLocalRemainderRemoteFirst,
                readBoundary: current.readBoundary,
                unreadMetadata: current.unreadMetadata
            )
        }
    }

    func cancelLocalPagePreparations() {
        localPagePreparationLock.withLock {
            localPagePreparationEpoch &+= 1
            activeLocalPagePreparationKeys.removeAll(keepingCapacity: false)
        }
    }

    var activePreparationCount: Int {
        let initialCount = initialFramePreparationLock.withLock {
            activeInitialFramePreparationEpoch == nil ? 0 : 1
        }
        let localCount = localPagePreparationLock.withLock {
            activeLocalPagePreparationKeys.count
        }
        return initialCount + localCount
    }

    @discardableResult
    func finishRemoteLoad(
        queryId: String,
        refetchDirection: ChatHistoryPageDirection? = nil,
        refetchLimit: Int? = nil
    ) -> ChatTimelineSessionSnapshot {
        mutateTimeline { engine in
            engine.finishRemoteLoad(
                queryId: queryId,
                refetchDirection: refetchDirection,
                refetchLimit: refetchLimit
            )
        }
    }

    @discardableResult
    func abortRemoteLoad(queryId: String) -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let current = snapshot
            guard current.state.activeRemoteLoad?.queryId == queryId else {
                return current
            }
            return mutateTimeline { engine in
                engine.abortRemoteLoad(queryId: queryId)
            }
        }
    }

    @discardableResult
    func commit(_ snapshot: ChatTimelineSnapshot) -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let base = self.snapshot
            return publish(
                items: snapshot.items,
                state: snapshot.state,
                loadingState: snapshot.loadingState,
                loadDecision: snapshot.loadDecision,
                anchorRestore: snapshot.anchorRestore,
                localOlderCandidateCount: snapshot.localOlderCandidateCount,
                shortLocalRemainderRemoteFirst: snapshot.shortLocalRemainderRemoteFirst,
                readBoundary: base.readBoundary,
                unreadMetadata: base.unreadMetadata
            )
        }
    }

    /// Re-publishes the snapshot whose mapped datasource has won the UI apply race.
    ///
    /// Anchor mapping happens off the main thread. Another command may mutate the
    /// session before that mapped snapshot reaches the collection view. Committing
    /// the winning presentation snapshot keeps the session cursor and the visible
    /// resident window in lockstep for the next paging gesture.
    @discardableResult
    func commitPresentationSnapshot(
        _ candidate: ChatTimelineSessionSnapshot
    ) -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let current = snapshot
            return publish(
                items: candidate.items,
                state: candidate.state,
                loadingState: candidate.loadingState,
                loadDecision: candidate.loadDecision,
                anchorRestore: candidate.anchorRestore,
                localOlderCandidateCount: candidate.localOlderCandidateCount,
                shortLocalRemainderRemoteFirst: candidate.shortLocalRemainderRemoteFirst,
                readBoundary: current.readBoundary,
                unreadMetadata: current.unreadMetadata
            )
        }
    }

    @discardableResult
    func applyRuntimePlaceholder(
        _ placeholder: ChatHistoryBoundaryPlaceholderPosition?
    ) -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let base = snapshot
            return publish(
                items: base.items,
                state: base.state.withRuntimePlaceholder(placeholder),
                loadingState: placeholder.map { .edge($0) } ?? .none,
                loadDecision: base.loadDecision,
                anchorRestore: base.anchorRestore,
                localOlderCandidateCount: base.localOlderCandidateCount,
                shortLocalRemainderRemoteFirst: base.shortLocalRemainderRemoteFirst,
                readBoundary: base.readBoundary,
                unreadMetadata: base.unreadMetadata
            )
        }
    }

    @discardableResult
    func appendLiveMessage(_ message: MessageStorageItem) -> ChatTimelineSessionSnapshot {
        mutateTimeline { engine in
            engine.appendLiveMessage(message)
        }
    }

    func resolvedMessage(
        primary: String?,
        archivedId: String?,
        messageId: String?
    ) -> MessageStorageItem? {
        if let resident = snapshot.item(
            primary: primary,
            archivedId: archivedId,
            messageId: messageId
        ) {
            return resident
        }
        return store.message(primary: primary, archivedId: archivedId, messageId: messageId)
    }

    func resolvedSearchMessage(anchor: ChatMessageAnchorRef) -> MessageStorageItem? {
        resolvedSearchMessageResolution(anchor: anchor).message
    }

    func resolvedSearchMessageResolution(
        anchor: ChatMessageAnchorRef
    ) -> ChatTimelineSearchMessageResolution {
        // A post-persistence target-window commit may advance this immutable
        // session before the caller thread's Realm auto-refresh turn. Primary
        // keys are globally unique, so an exact resident primary is already a
        // complete typed search proof; archive/message-id ambiguity continues
        // to be decided by the scoped store resolver below.
        if let primary = anchor.messagePrimary,
           primary.isNotEmpty,
           let resident = snapshot.item(primary: primary) {
            return resident.isDeleted
                ? .failed(.targetDeleted)
                : .found(resident)
        }
        return store.searchMessageResolution(anchor: anchor)
    }

    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem? {
        let normalizedBoundaryArchivedId =
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                boundaryArchivedId
            )
        if let normalizedBoundaryArchivedId,
           let boundaryDate = ChatInitialPositionPolicy.archiveDate(
               from: normalizedBoundaryArchivedId
           ) {
            let boundaryPosition = ChatTimelinePositionKey(
                boundary: ChatTimelineBoundary(
                    primary: normalizedBoundaryArchivedId,
                    archivedId: normalizedBoundaryArchivedId,
                    messageId: nil,
                    date: boundaryDate
                )
            )
            if let resident = snapshot.items.first(where: {
                !$0.isDeleted &&
                    !$0.outgoing &&
                    RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                        $0.archivedId
                    ) != normalizedBoundaryArchivedId &&
                    ChatTimelinePositionKey(message: $0) > boundaryPosition
            }) {
                return resident
            }
        }
        return store.firstIncoming(
            afterArchiveBoundaryId:
                normalizedBoundaryArchivedId ?? boundaryArchivedId
        )
    }

    func latestMessage() -> MessageStorageItem? {
        store.latest(limit: 1).last
    }

    func hasAnyLocalMessage() -> Bool {
        latestMessage() != nil
    }

    @discardableResult
    func refreshResidentItems() -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let base = snapshot
            let refreshedItems = store.items(primaryKeys: base.state.residentPrimaryKeys)
            return publish(
                items: refreshedItems,
                state: stateByReplacingResidentItems(refreshedItems, in: base.state),
                loadingState: base.loadingState,
                loadDecision: base.loadDecision,
                anchorRestore: base.anchorRestore,
                localOlderCandidateCount: base.localOlderCandidateCount,
                shortLocalRemainderRemoteFirst: base.shortLocalRemainderRemoteFirst,
                readBoundary: base.readBoundary,
                unreadMetadata: base.unreadMetadata
            )
        }
    }

    @discardableResult
    func refreshUnreadMetadata() -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let base = snapshot
            let hardLimit = base.residentHardLimit
            let metadata = store.unreadMetadata(limit: hardLimit)
            let boundedMetadata = ChatTimelineUnreadMetadata(
                unreadCount: max(0, metadata.unreadCount),
                mentions: Array(metadata.mentions.prefix(hardLimit)),
                candidateCount: min(max(0, metadata.candidateCount), hardLimit),
                initialFrameReadinessProof: metadata.initialFrameReadinessProof,
                latestUnreadMentionArchivedId:
                    metadata.latestUnreadMentionArchivedId
            )
            return publish(
                items: base.items,
                state: base.state,
                loadingState: base.loadingState,
                loadDecision: base.loadDecision,
                anchorRestore: base.anchorRestore,
                localOlderCandidateCount: base.localOlderCandidateCount,
                shortLocalRemainderRemoteFirst: base.shortLocalRemainderRemoteFirst,
                readBoundary: base.readBoundary,
                unreadMetadata: boundedMetadata
            )
        }
    }

    @discardableResult
    func advanceReadBoundary(toPrimary primary: String) -> Bool {
        operationLock.withLock {
            let base = snapshot
            guard let item = base.item(primary: primary),
                  !item.isDeleted else {
                return false
            }
            let candidate = ChatTimelineReadBoundary(
                primary: item.primary,
                position: ChatTimelinePositionKey(message: item)
            )
            if let current = base.readBoundary,
               candidate.position <= current.position {
                return false
            }
            _ = publish(
                items: base.items,
                state: base.state,
                loadingState: base.loadingState,
                loadDecision: base.loadDecision,
                anchorRestore: base.anchorRestore,
                localOlderCandidateCount: base.localOlderCandidateCount,
                shortLocalRemainderRemoteFirst: base.shortLocalRemainderRemoteFirst,
                readBoundary: candidate,
                unreadMetadata: base.unreadMetadata,
                authorityPublication: .readBoundaryOnly
            )
            return true
        }
    }

    func updateArchiveState(_ archiveState: ChatArchiveStateSnapshot) {
        operationLock.withLock {
            lock.withLock {
                self.archiveState = archiveState
            }
        }
    }

    private func startLocalPagePreparation(
        direction: ChatHistoryPageDirection,
        boundary: ChatTimelineBoundary,
        archiveContextProvider: @escaping () -> ChatTimelineLocalPageArchiveContext,
        expectedGeneration: UInt64,
        completion: @escaping (ChatTimelineLocalPagePreparationResult) -> Void
    ) -> ChatTimelineLocalPageLoadDisposition {
        let base = snapshot
        guard base.generation == expectedGeneration,
              boundaryMatchesSnapshotEdge(boundary, direction: direction, snapshot: base) else {
            return .rejectedStale
        }

        let key = localPagePreparationKey(
            direction: direction,
            boundary: boundary,
            generation: expectedGeneration
        )
        let epochAndStarted = localPagePreparationLock.withLock { () -> (UInt64, Bool) in
            guard activeLocalPagePreparationKeys.insert(key).inserted else {
                return (localPagePreparationEpoch, false)
            }
            return (localPagePreparationEpoch, true)
        }
        guard epochAndStarted.1 else {
            return .coalesced
        }

        localPagePreparationQueue.async { [weak self] in
            guard let self else { return }
            let preparedOnMainThread = Thread.isMainThread
            let archiveContext = archiveContextProvider()
            let timelineSnapshot = self.prepareLocalPageSnapshot(
                direction: direction,
                base: base,
                archiveState: archiveContext.paging
            )
            let prepared = ChatTimelinePreparedLocalPage(
                id: "local-page-\(NanoID.new(6))",
                sessionID: self.sessionID,
                direction: direction,
                conversationKey: self.conversationKey,
                baseGeneration: expectedGeneration,
                boundary: boundary,
                archiveContext: archiveContext,
                snapshot: timelineSnapshot,
                preparedOnMainThread: preparedOnMainThread
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let isCurrent = self.lock.withLock {
                    self.storedSnapshot.generation == expectedGeneration
                }
                let isActive = self.localPagePreparationLock.withLock { () -> Bool in
                    let epochMatches = self.localPagePreparationEpoch == epochAndStarted.0
                    let keyWasActive = self.activeLocalPagePreparationKeys.remove(key) != nil
                    return epochMatches && keyWasActive
                }
                completion(
                    isCurrent && isActive
                        ? .prepared(prepared)
                        : .stale
                )
            }
        }
        return .started
    }

    private func prepareLocalPageSnapshot(
        direction: ChatHistoryPageDirection,
        base: ChatTimelineSessionSnapshot,
        archiveState: ChatArchiveStateSnapshot
    ) -> ChatTimelineSnapshot {
        let preparationProvider = ChatTimelineLocalPagePreparationProvider(
            upstream: store,
            residentItems: base.items
        )
        var engine = ChatVirtualTimelineEngine(
            provider: preparationProvider,
            pageSize: pageSize,
            state: base.state.normalized(
                owner: conversationKey.owner,
                jid: conversationKey.jid,
                conversationType: conversationKey.conversationType
            ),
            archiveState: archiveState
        )
        let snapshot: ChatTimelineSnapshot
        switch direction {
        case .older:
            snapshot = engine.pageOlder()
        case .newer:
            snapshot = engine.pageNewer()
        }
        return ChatTimelineSnapshot(
            items: snapshot.items.map(Self.frozen),
            state: snapshot.state,
            loadingState: snapshot.loadingState,
            loadDecision: snapshot.loadDecision,
            anchorRestore: snapshot.anchorRestore,
            localOlderCandidateCount: snapshot.localOlderCandidateCount,
            pageSize: snapshot.pageSize,
            shortLocalRemainderRemoteFirst: snapshot.shortLocalRemainderRemoteFirst
        )
    }

    private func prepareInitialFrameResult(
        target: ChatTimelineInitialFrameTarget,
        limit: Int,
        base: ChatTimelineSessionSnapshot,
        preparationEpoch: UInt64,
        includesMetadata: Bool
    ) -> ChatTimelineInitialFramePreparationResult {
        let preparedOnMainThread = Thread.isMainThread
        let resolvedMessage: MessageStorageItem?
        let preparedLatestItems: [MessageStorageItem]?
        let preparedAroundWindow: ChatTimelineInitialFrameWindow?
        switch target {
        case .latest:
            resolvedMessage = nil
            preparedLatestItems = store.initialLatestWindow(limit: limit)
            preparedAroundWindow = nil
        case .message(let anchor):
            let before = limit / 2
            let after = max(0, limit - before - 1)
            preparedAroundWindow = store.messageWindow(
                primary: anchor.primary,
                archivedId: anchor.archivedId,
                messageId: anchor.messageId,
                before: before,
                after: after
            )
            resolvedMessage = preparedAroundWindow?.target
            preparedLatestItems = nil
        case .firstIncomingAfterBoundary(let boundaryArchivedId):
            let before = limit / 2
            let after = max(0, limit - before - 1)
            preparedAroundWindow = store.firstIncomingWindow(
                afterArchiveBoundaryId: boundaryArchivedId,
                before: before,
                after: after
            )
            resolvedMessage = preparedAroundWindow?.target
            preparedLatestItems = nil
        }

        if target != .latest, resolvedMessage == nil {
            return .blocked(.targetMissing(target))
        }

        let frozenPreparedLatestItems = preparedLatestItems?.map(Self.frozen)
        let frozenPreparedAroundWindow = preparedAroundWindow.map {
            ChatTimelineInitialFrameWindow(
                target: Self.frozen($0.target),
                items: $0.items.map(Self.frozen),
                materializedCandidateCount: $0.materializedCandidateCount
            )
        }
        guard let provisional = initialFrameSnapshot(
            target: target,
            limit: limit,
            base: base,
            preparedLatestItems: frozenPreparedLatestItems,
            preparedAroundWindow: frozenPreparedAroundWindow,
            archiveState: lock.withLock { archiveState }
        ) else {
            return .blocked(.targetMissing(target))
        }
        let unreadMetadata = includesMetadata
            ? store.initialFrameMetadata(
                limit: ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize),
                materializedLocalMessageCount: provisional.snapshot.items.count,
                conversationKey: conversationKey,
                baseGeneration: base.generation
            )
            : .empty
        let prepared: (
            snapshot: ChatTimelineSnapshot,
            alignment: ChatTimelineInitialFrameAlignment
        )?
        if let readinessProof = unreadMetadata.initialFrameReadinessProof {
            prepared = initialFrameSnapshot(
                target: target,
                limit: limit,
                base: base,
                preparedLatestItems: frozenPreparedLatestItems,
                preparedAroundWindow: frozenPreparedAroundWindow,
                archiveState: readinessProof.archiveState
            )
        } else {
            prepared = provisional
        }
        guard let prepared else {
            return .blocked(.targetMissing(target))
        }
        let frozenSnapshot = prepared.snapshot
        let alignment = prepared.alignment
        let diagnosticsAfter = store.diagnosticsSnapshot
        let metrics = ChatTimelineInitialFramePreparationMetrics(
            storeQueryCount: diagnosticsAfter.queryCount,
            mainThreadStoreQueryCount: diagnosticsAfter.mainThreadQueryCount,
            fullScanCount: diagnosticsAfter.fullScanCount,
            maxCandidateCount: diagnosticsAfter.maxCandidateCount,
            preparedMessageCount: frozenSnapshot.items.count,
            preparedOnMainThread: preparedOnMainThread
        )

        return .prepared(
            ChatTimelinePreparedInitialFrame(
                sessionID: sessionID,
                target: target,
                conversationKey: conversationKey,
                baseGeneration: base.generation,
                snapshot: frozenSnapshot,
                alignment: alignment,
                metrics: metrics,
                unreadMetadata: unreadMetadata,
                isMetadataFinalized: includesMetadata,
                preparationEpoch: preparationEpoch,
                preparationLimit: limit,
                baseSnapshot: base,
                preparedLatestItems: frozenPreparedLatestItems,
                preparedAroundWindow: frozenPreparedAroundWindow
            )
        )
    }

    private func initialFrameSnapshot(
        target: ChatTimelineInitialFrameTarget,
        limit: Int,
        base: ChatTimelineSessionSnapshot,
        preparedLatestItems: [MessageStorageItem]?,
        preparedAroundWindow: ChatTimelineInitialFrameWindow?,
        archiveState: ChatArchiveStateSnapshot
    ) -> (
        snapshot: ChatTimelineSnapshot,
        alignment: ChatTimelineInitialFrameAlignment
    )? {
        let resolvedMessage = preparedAroundWindow?.target
        let seededItems = base.items + (resolvedMessage.map { [$0] } ?? [])
        let preparationProvider = ChatTimelineLocalPagePreparationProvider(
            upstream: store,
            residentItems: seededItems,
            preparedLatestItems: preparedLatestItems,
            preparedAroundWindow: preparedAroundWindow
        )
        var engine = ChatVirtualTimelineEngine(
            provider: preparationProvider,
            pageSize: limit,
            state: base.state.normalized(
                owner: conversationKey.owner,
                jid: conversationKey.jid,
                conversationType: conversationKey.conversationType
            ),
            archiveState: archiveState
        )

        let snapshot: ChatTimelineSnapshot
        let alignment: ChatTimelineInitialFrameAlignment
        switch target {
        case .latest:
            snapshot = engine.openLatest(limit: limit)
            alignment = .bottom
        case .message, .firstIncomingAfterBoundary:
            guard let resolvedMessage else { return nil }
            snapshot = engine.openAround(
                anchor: ChatTimelineAnchor(
                    primary: resolvedMessage.primary,
                    archivedId: resolvedMessage.archivedId,
                    messageId: resolvedMessage.messageId,
                    date: resolvedMessage.date
                )
            )
            alignment = .anchor(
                primary: resolvedMessage.primary,
                archivedId: RegularChatArchiveSyncStateStorageItem
                    .normalizedArchiveId(resolvedMessage.archivedId)
            )
        }

        return (
            ChatTimelineSnapshot(
                items: snapshot.items.map(Self.frozen),
                state: snapshot.state,
                loadingState: snapshot.loadingState,
                loadDecision: snapshot.loadDecision,
                anchorRestore: snapshot.anchorRestore,
                localOlderCandidateCount: snapshot.localOlderCandidateCount,
                pageSize: snapshot.pageSize,
                shortLocalRemainderRemoteFirst:
                    snapshot.shortLocalRemainderRemoteFirst
            ),
            alignment
        )
    }

    private func boundaryMatchesSnapshotEdge(
        _ boundary: ChatTimelineBoundary,
        direction: ChatHistoryPageDirection,
        snapshot: ChatTimelineSessionSnapshot
    ) -> Bool {
        switch direction {
        case .older:
            return snapshot.oldest == boundary
        case .newer:
            return snapshot.newest == boundary
        }
    }

    private func localPagePreparationKey(
        direction: ChatHistoryPageDirection,
        boundary: ChatTimelineBoundary,
        generation: UInt64
    ) -> String {
        let directionKey = direction == .older ? "older" : "newer"
        return [
            conversationKey.owner,
            conversationKey.jid,
            conversationKey.conversationType.rawValue,
            String(generation),
            directionKey,
            boundary.primary,
            boundary.archivedId ?? "-",
            boundary.messageId ?? "-",
            String(boundary.date.timeIntervalSince1970)
        ].map(String.init(describing:)).joined(separator: "|")
    }

    private func mutateTimeline(
        _ mutation: (inout ChatVirtualTimelineEngine) -> ChatTimelineSnapshot
    ) -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let input = lock.withLock { (storedSnapshot, archiveState) }
            var engine = ChatVirtualTimelineEngine(
                provider: store,
                pageSize: pageSize,
                state: input.0.state.normalized(
                    owner: conversationKey.owner,
                    jid: conversationKey.jid,
                    conversationType: conversationKey.conversationType
                ),
                archiveState: input.1
            )
            let next = mutation(&engine)
            return publish(
                items: next.items,
                state: next.state,
                loadingState: next.loadingState,
                loadDecision: next.loadDecision,
                anchorRestore: next.anchorRestore,
                localOlderCandidateCount: next.localOlderCandidateCount,
                shortLocalRemainderRemoteFirst: next.shortLocalRemainderRemoteFirst,
                readBoundary: input.0.readBoundary,
                unreadMetadata: input.0.unreadMetadata
            )
        }
    }

    @discardableResult
    private func publish(
        items: [MessageStorageItem],
        state: ChatVirtualTimelineState,
        loadingState: ChatTimelineLoadingState,
        loadDecision: ChatHistoryPagingLoadDecision?,
        anchorRestore: ChatTimelineAnchorRestoreCommand?,
        localOlderCandidateCount: Int?,
        shortLocalRemainderRemoteFirst: Bool,
        readBoundary: ChatTimelineReadBoundary?,
        unreadMetadata: ChatTimelineUnreadMetadata,
        residentChangeSet: ChatIncrementalResidentChangeSet? = nil,
        authorityPublication:
            ChatTimelineStoreObservationAuthorityPublication = .invalidating
    ) -> ChatTimelineSessionSnapshot {
        let hardLimit = ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize)
        let immutableItems = items.map(Self.frozen)
        let ordered = ChatTimelineOrdering.deduplicatedChronological(immutableItems)
        let boundedItems = ordered.count > hardLimit ? Array(ordered.suffix(hardLimit)) : ordered
        let boundedState = boundedItems.count == ordered.count
            ? state
            : stateByReplacingResidentItems(boundedItems, in: state)

        let result: (ChatTimelineSessionSnapshot, SnapshotHandler?) = lock.withLock {
            let previous = storedSnapshot
            let next = ChatTimelineSessionSnapshot(
                generation: previous.generation &+ 1,
                cause: storeChangeDepth > 0 ? .storeChange : .command,
                items: boundedItems,
                state: boundedState,
                loadingState: loadingState,
                loadDecision: loadDecision,
                anchorRestore: anchorRestore,
                localOlderCandidateCount: localOlderCandidateCount,
                pageSize: pageSize,
                shortLocalRemainderRemoteFirst: shortLocalRemainderRemoteFirst,
                residentIndex: ChatTimelineResidentIndex(items: boundedItems),
                readBoundary: readBoundary,
                unreadMetadata: unreadMetadata,
                residentHardLimit: hardLimit,
                residentChangeSet: residentChangeSet
            )
            storeObservationAuthorityLineage =
                ChatTimelineStoreObservationAuthorityPolicy.updatedLineage(
                    storeObservationAuthorityLineage,
                    from: previous,
                    to: next,
                    conversationKey: conversationKey,
                    publication: authorityPublication
                )
            storedSnapshot = next
            return (next, storedSnapshotHandler)
        }
        let installedObservation = lock.withLock { observation }
        installedObservation?.replaceResidentItems(result.0.items)
        result.1?(result.0)
        return result.0
    }

    private func stateByReplacingResidentItems(
        _ items: [MessageStorageItem],
        in state: ChatVirtualTimelineState
    ) -> ChatVirtualTimelineState {
        let ordered = ChatTimelineOrdering.deduplicatedChronological(items)
        let hardLimit = ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize)
        let bounded = ordered.count > hardLimit ? Array(ordered.suffix(hardLimit)) : ordered
        let oldest = bounded.first.map(ChatTimelineBoundary.init(message:))
        let newest = bounded.last.map(ChatTimelineBoundary.init(message:))
        let loadedRange = ChatVirtualSegment.loadedRange(
            oldestArchiveId: oldest?.archivedId,
            newestArchiveId: newest?.archivedId
        )
        var replacedLoadedRange = false
        var segments = state.segments.compactMap { segment -> ChatVirtualSegment? in
            if case .loadedRange = segment {
                guard !replacedLoadedRange, !bounded.isEmpty else { return nil }
                replacedLoadedRange = true
                return loadedRange
            }
            return segment
        }
        if !bounded.isEmpty, !replacedLoadedRange {
            let insertionIndex = segments.firstIndex {
                if case .unknownNewer = $0 { return true }
                if case .liveTail = $0 { return true }
                return false
            } ?? segments.endIndex
            segments.insert(loadedRange, at: insertionIndex)
        }
        return ChatVirtualTimelineState(
            conversationKey: state.conversationKey,
            segments: segments,
            oldest: oldest,
            newest: newest,
            residentPrimaryKeys: bounded.map(\.primary),
            residentArchivedIds: bounded.compactMap {
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId($0.archivedId)
            },
            activeRemoteLoad: state.activeRemoteLoad,
            activePlaceholder: state.activePlaceholder,
            isResidentAtLiveTail: state.isResidentAtLiveTail
        )
    }

    private func handleStoreChange(_ change: ChatTimelineStoreChange) {
        lock.withLock { storeChangeDepth += 1 }
        defer { lock.withLock { storeChangeDepth -= 1 } }
        switch change {
        case .latestChanged:
            if snapshot.state.isResidentAtLiveTail {
                let currentResidentCount = snapshot.items.count
                _ = openLatest(limit: currentResidentCount > 0 ? currentResidentCount : nil)
            } else {
                _ = refreshResidentItems()
            }
            _ = refreshUnreadMetadata()
        case .residentChanged:
            _ = refreshResidentItems()
        case .unreadChanged:
            _ = refreshUnreadMetadata()
        case .unreadMetadataChanged(let unreadMetadata):
            _ = publishPreparedUnreadMetadata(unreadMetadata)
        case .incremental(let batch, let refreshUnread):
            _ = applyIncrementalStoreChange(batch, refreshUnread: refreshUnread)
        case .incrementalWithUnreadMetadata(let batch, let unreadMetadata):
            _ = applyIncrementalStoreChange(
                batch,
                preparedUnreadMetadata: unreadMetadata
            )
        }
    }

    private func publishPreparedUnreadMetadata(
        _ unreadMetadata: ChatTimelineUnreadMetadata
    ) -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let base = snapshot
            let bounded = boundedUnreadMetadata(
                unreadMetadata,
                hardLimit: base.residentHardLimit,
                fallbackReadinessProof:
                    base.unreadMetadata.initialFrameReadinessProof
            )
            guard bounded != base.unreadMetadata else { return base }
            return publish(
                items: base.items,
                state: base.state,
                loadingState: base.loadingState,
                loadDecision: base.loadDecision,
                anchorRestore: base.anchorRestore,
                localOlderCandidateCount: base.localOlderCandidateCount,
                shortLocalRemainderRemoteFirst:
                    base.shortLocalRemainderRemoteFirst,
                readBoundary: base.readBoundary,
                unreadMetadata: bounded
            )
        }
    }

    private func applyIncrementalStoreChange(
        _ batch: ChatIncrementalMessageMutationBatch<MessageStorageItem>,
        refreshUnread: Bool
    ) -> ChatTimelineSessionSnapshot {
        applyIncrementalStoreChange(
            batch,
            preparedUnreadMetadata: refreshUnread
                ? store.unreadMetadata(limit: snapshot.residentHardLimit)
                : nil
        )
    }

    private func applyIncrementalStoreChange(
        _ batch: ChatIncrementalMessageMutationBatch<MessageStorageItem>,
        preparedUnreadMetadata: ChatTimelineUnreadMetadata?
    ) -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let input = lock.withLock { (storedSnapshot, archiveState) }
            let base = input.0
            let authorizedBatch = authorizedIncrementalBatch(batch)
            let shouldOpenLatest = Self.shouldOpenLatestForNewOutgoingMutation(
                authorizedBatch.mutations,
                currentItems: base.items,
                isResidentAtLiveTail: base.state.isResidentAtLiveTail
            )
            let result = incrementalResidentReducer.apply(
                currentItems: base.items,
                mutations: authorizedBatch.mutations,
                isResidentAtLiveTail: base.state.isResidentAtLiveTail,
                hardLimit: base.residentHardLimit
            )
            let unreadMetadata: ChatTimelineUnreadMetadata
            if let preparedUnreadMetadata {
                unreadMetadata = boundedUnreadMetadata(
                    preparedUnreadMetadata,
                    hardLimit: base.residentHardLimit,
                    fallbackReadinessProof:
                        base.unreadMetadata.initialFrameReadinessProof
                )
            } else {
                unreadMetadata = base.unreadMetadata
            }
            if shouldOpenLatest {
                var engine = ChatVirtualTimelineEngine(
                    provider: store,
                    pageSize: pageSize,
                    state: base.state.normalized(
                        owner: conversationKey.owner,
                        jid: conversationKey.jid,
                        conversationType: conversationKey.conversationType
                    ),
                    archiveState: input.1
                )
                let next = engine.openLatest(
                    limit: ChatBoundedTimelineWindowPolicy.targetLimit(pageSize: pageSize)
                )
                return publish(
                    items: next.items,
                    state: next.state,
                    loadingState: next.loadingState,
                    loadDecision: next.loadDecision,
                    anchorRestore: next.anchorRestore,
                    localOlderCandidateCount: next.localOlderCandidateCount,
                    shortLocalRemainderRemoteFirst: next.shortLocalRemainderRemoteFirst,
                    readBoundary: base.readBoundary,
                    unreadMetadata: unreadMetadata
                )
            }
            guard !result.changeSet.isEmpty || preparedUnreadMetadata != nil else {
                return base
            }
            return publish(
                items: result.items,
                state: stateByReplacingResidentItems(result.items, in: base.state),
                loadingState: base.loadingState,
                loadDecision: base.loadDecision,
                anchorRestore: base.anchorRestore,
                localOlderCandidateCount: base.localOlderCandidateCount,
                shortLocalRemainderRemoteFirst: base.shortLocalRemainderRemoteFirst,
                readBoundary: base.readBoundary,
                unreadMetadata: unreadMetadata,
                residentChangeSet: result.changeSet
            )
        }
    }

    /// `operationLock` is held by the caller. Structural publication and its
    /// synchronous `replaceResidentItems` therefore linearize either before
    /// this authorization (stale resident revisions are removed) or after the
    /// accepted store change. Revisions without resident provenance come from
    /// the independent latest-message observer and are never filtered here.
    private func authorizedIncrementalBatch(
        _ batch: ChatIncrementalMessageMutationBatch<MessageStorageItem>
    ) -> ChatIncrementalMessageMutationBatch<MessageStorageItem> {
        guard !batch.residentGenerationByRevision.isEmpty else {
            return batch
        }
        let installedObservation = lock.withLock { observation }
        let authorizedMutations = batch.mutations.filter { mutation in
            guard let generation =
                    batch.residentGenerationByRevision[mutation.revision] else {
                return true
            }
            return installedObservation?.authorizesResidentMutation(
                generation: generation
            ) == true
        }
        guard authorizedMutations.count != batch.mutations.count else {
            return batch
        }
        let authorizedRevisions = Set(authorizedMutations.map(\.revision))
        return ChatIncrementalMessageMutationBatch(
            mutations: authorizedMutations,
            enqueuedMutationCount: batch.enqueuedMutationCount,
            residentGenerationByRevision:
                batch.residentGenerationByRevision.filter {
                    authorizedRevisions.contains($0.key)
                }
        )
    }

    private func boundedUnreadMetadata(
        _ metadata: ChatTimelineUnreadMetadata,
        hardLimit: Int,
        fallbackReadinessProof: ChatTimelineInitialFrameReadinessProof?
    ) -> ChatTimelineUnreadMetadata {
        ChatTimelineUnreadMetadata(
            unreadCount: max(0, metadata.unreadCount),
            mentions: Array(metadata.mentions.prefix(hardLimit)),
            candidateCount: min(max(0, metadata.candidateCount), hardLimit),
            initialFrameReadinessProof:
                metadata.initialFrameReadinessProof ?? fallbackReadinessProof,
            latestUnreadMentionArchivedId:
                metadata.latestUnreadMentionArchivedId
        )
    }

    private static func shouldOpenLatestForNewOutgoingMutation(
        _ mutations: [ChatIncrementalMessageMutation<MessageStorageItem>],
        currentItems: [MessageStorageItem],
        isResidentAtLiveTail: Bool
    ) -> Bool {
        guard !isResidentAtLiveTail else { return false }
        return mutations.contains { mutation in
            guard case .upsert(let item) = mutation.operation,
                  item.outgoing else {
                return false
            }
            return !currentItems.contains {
                ChatIncrementalMessageIdentity(message: $0).matches(mutation.identity)
            }
        }
    }

    private static func frozen(_ item: MessageStorageItem) -> MessageStorageItem {
        item.realm == nil || item.isFrozen ? item : item.freeze()
    }
}

enum ChatTimelineStoreObservationRegistrationKind: String, Equatable {
    case lastChats
    case resident
}

struct ChatTimelineStoreObservationRegistrationIdentity: Equatable {
    let kind: ChatTimelineStoreObservationRegistrationKind
    let generation: UInt64
}

private struct ChatTimelineStoreObservedUnreadMetadata {
    let metadata: ChatTimelineUnreadMetadata
    let queryCount: Int
    let fullScanCount: Int
    let maxCandidateCount: Int
}

struct ChatTimelineStoreObservationTestHooks {
    static let none = ChatTimelineStoreObservationTestHooks()

    var beforeRealmQuery:
        ((ChatTimelineStoreObservationRegistrationIdentity) -> Void)?
    var didRegister:
        ((ChatTimelineStoreObservationRegistrationIdentity) -> Void)?
    var didCancel:
        ((ChatTimelineStoreObservationRegistrationIdentity) -> Void)?
}

private enum ChatTimelineStoreObservationDiagnosticEvent {
    case activationStarted(pendingWorkCount: Int)
    case realmQuery(candidateCount: Int, wasOnMainThread: Bool)
    case initialCallback(candidateCount: Int, wasOnMainThread: Bool)
    case metadataQuery(
        queryCount: Int,
        fullScanCount: Int,
        maxCandidateCount: Int,
        wasOnMainThread: Bool
    )
    case catchUpMutations(Int)
    case pendingWorkDelta(Int)
}

final class RealmChatTimelineSessionStore: ChatTimelineSessionStore {
    private let owner: String
    private let jid: String
    private let conversationType: ClientSynchronizationManager.ConversationType
    private let providerDiagnostics = ChatLocalHistoryPageProviderDiagnostics()
    private let diagnosticsLock = NSLock()
    private var supplementalDiagnostics = ChatTimelineStoreDiagnosticsSnapshot.empty
    private var observationDiagnostics =
        ChatTimelineStoreObservationDiagnosticsSnapshot.empty
    private let observationTestHooks: ChatTimelineStoreObservationTestHooks

    var diagnosticsSnapshot: ChatTimelineStoreDiagnosticsSnapshot {
        let localDiagnostics = diagnosticsLock.withLock {
            (supplementalDiagnostics, observationDiagnostics)
        }
        let supplemental = localDiagnostics.0
        let providerOperationCounts = providerDiagnostics.records.reduce(into: [String: Int]()) {
            $0[$1.operation] = max($0[$1.operation] ?? 0, $1.candidateCount)
        }
        let providerInvocationCounts = providerDiagnostics.records.reduce(
            into: [String: Int]()
        ) {
            $0[$1.operation, default: 0] += 1
        }
        let operationCounts = supplemental.operationCounts.merging(
            providerInvocationCounts,
            uniquingKeysWith: { $0 + $1 }
        )
        let operationCandidateCounts = supplemental.operationCandidateCounts.merging(
            providerOperationCounts,
            uniquingKeysWith: max
        )
        return ChatTimelineStoreDiagnosticsSnapshot(
            queryCount: providerDiagnostics.queryCount + supplemental.queryCount,
            mainThreadQueryCount:
                providerDiagnostics.mainThreadQueryCount +
                supplemental.mainThreadQueryCount,
            fullScanCount: providerDiagnostics.fullScanCount + supplemental.fullScanCount,
            maxCandidateCount: max(providerDiagnostics.maxCandidateCount, supplemental.maxCandidateCount),
            operationCounts: operationCounts,
            operationCandidateCounts: operationCandidateCounts,
            observation: localDiagnostics.1
        )
    }

    init(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        observationTestHooks: ChatTimelineStoreObservationTestHooks = .none
    ) {
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
        self.observationTestHooks = observationTestHooks
    }

    func latest(limit: Int) -> [MessageStorageItem] {
        withProvider(default: []) { provider in
            provider.latest(limit: limit).map(Self.frozen)
        }
    }

    func initialLatestWindow(limit: Int) -> [MessageStorageItem] {
        withProvider(default: []) { provider in
            provider.initialLatestWindow(limit: limit).map(Self.frozen)
        }
    }

    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        withProvider(default: []) { provider in
            provider.older(before: boundary, limit: limit).map(Self.frozen)
        }
    }

    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        withProvider(default: []) { provider in
            provider.newer(after: boundary, limit: limit).map(Self.frozen)
        }
    }

    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem] {
        withProvider(default: []) { provider in
            provider.around(anchor: anchor, before: before, after: after).map(Self.frozen)
        }
    }

    func message(
        primary: String?,
        archivedId: String?,
        messageId: String?
    ) -> MessageStorageItem? {
        withProvider(default: nil) { provider in
            provider.message(primary: primary, archivedId: archivedId, messageId: messageId).map(Self.frozen)
        }
    }

    func searchMessage(anchor: ChatMessageAnchorRef) -> MessageStorageItem? {
        searchMessageResolution(anchor: anchor).message
    }

    func searchMessageResolution(
        anchor: ChatMessageAnchorRef
    ) -> ChatTimelineSearchMessageResolution {
        withProvider(default: .failed(.targetMissing)) { provider in
            switch provider.searchMessageResolution(anchor: anchor) {
            case .found(let message):
                return .found(Self.frozen(message))
            case .failed(let failure):
                return .failed(failure)
            }
        }
    }

    func items(primaryKeys: [String]) -> [MessageStorageItem] {
        withProvider(default: []) { provider in
            let items = provider.items(primaryKeys: primaryKeys).map(Self.frozen)
            recordSupplemental(operation: "resident", candidateCount: items.count)
            return items
        }
    }

    func messageWindow(
        primary: String?,
        archivedId: String?,
        messageId: String?,
        before: Int,
        after: Int
    ) -> ChatTimelineInitialFrameWindow? {
        withProvider(default: nil) { provider in
            guard let window = provider.messageWindow(
                primary: primary,
                archivedId: archivedId,
                messageId: messageId,
                before: before,
                after: after
            ) else {
                return nil
            }
            return ChatTimelineInitialFrameWindow(
                target: Self.frozen(window.target),
                items: window.items.map(Self.frozen),
                materializedCandidateCount: window.materializedCandidateCount
            )
        }
    }

    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem? {
        withProvider(default: nil) { provider in
            provider.firstIncoming(afterArchiveBoundaryId: boundaryArchivedId).map(Self.frozen)
        }
    }

    func firstIncomingWindow(
        afterArchiveBoundaryId boundaryArchivedId: String,
        before: Int,
        after: Int
    ) -> ChatTimelineInitialFrameWindow? {
        withProvider(default: nil) { provider in
            guard let window = provider.firstIncomingWindow(
                afterArchiveBoundaryId: boundaryArchivedId,
                before: before,
                after: after
            ) else {
                return nil
            }
            return ChatTimelineInitialFrameWindow(
                target: Self.frozen(window.target),
                items: window.items.map(Self.frozen),
                materializedCandidateCount: window.materializedCandidateCount
            )
        }
    }

    func unreadMetadata(limit: Int) -> ChatTimelineUnreadMetadata {
        readUnreadMetadata(
            limit: limit,
            initialFrameContext: nil
        )
    }

    func initialFrameMetadata(
        limit: Int,
        materializedLocalMessageCount: Int,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64
    ) -> ChatTimelineUnreadMetadata {
        ChatPerformanceSignposts.measure(.localHistoryQuery) {
            readUnreadMetadata(
                limit: limit,
                initialFrameContext: (
                    materializedLocalMessageCount: max(0, materializedLocalMessageCount),
                    conversationKey: conversationKey,
                    baseGeneration: baseGeneration
                )
            )
        }
    }

    func withInitialFrameMetadataConsistencyLease(
        limit: Int,
        materializedLocalMessageCount: Int,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64,
        _ consume: (ChatTimelineUnreadMetadata) -> Void
    ) {
        ChatPerformanceSignposts.measure(.localHistoryQuery) {
            do {
                let realm = try WRealm.safe()
                realm.beginWrite()
                defer {
                    if realm.isInWriteTransaction {
                        realm.cancelWrite()
                    }
                }
                consume(
                    readUnreadMetadata(
                        limit: limit,
                        initialFrameContext: (
                            materializedLocalMessageCount:
                                max(0, materializedLocalMessageCount),
                            conversationKey: conversationKey,
                            baseGeneration: baseGeneration
                        ),
                        realm: realm
                    )
                )
            } catch {
                DDLogDebug(
                    "RealmChatTimelineSessionStore.initialFrameMetadata lease: \(error.localizedDescription)"
                )
                recordSupplemental(operation: "unread", candidateCount: 0)
                consume(.empty)
            }
        }
    }

    func withPostBootstrapInitialFrameConsistencyLease(
        target: ChatTimelineInitialFrameTarget,
        searchAnchor: ChatMessageAnchorRef?,
        limit: Int,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64,
        _ consume: (ChatTimelineInitialFrameLeaseMaterialization?) -> Void
    ) {
        ChatPerformanceSignposts.measure(.localHistoryQuery) {
            do {
                let realm = try WRealm.safe()
                realm.beginWrite()
                defer {
                    if realm.isInWriteTransaction {
                        realm.cancelWrite()
                    }
                }
                let boundedLimit = min(
                    max(1, limit),
                    ChatInitialFirstFrameHistoryConfiguration.pageSize
                )
                let provider = makeProvider(
                    realm: realm,
                    recordsDiagnostics: false
                )
                let effectiveTarget: ChatTimelineInitialFrameTarget
                let searchResolutionProof: ChatTimelineSearchResolutionProof
                if let searchAnchor {
                    switch provider.searchMessageResolution(
                        anchor: searchAnchor
                    ) {
                    case .found(let message):
                        searchResolutionProof = .found(
                            primary: message.primary
                        )
                        effectiveTarget = .message(ChatTimelineAnchor(
                            primary: message.primary,
                            archivedId: nil,
                            messageId: nil,
                            date: message.date
                        ))
                    case .failed(let failure):
                        recordSupplemental(
                            operation: "postBootstrapWindowAndMetadata",
                            candidateCount: 0
                        )
                        consume(ChatTimelineInitialFrameLeaseMaterialization(
                            preparedLatestItems: nil,
                            preparedAroundWindow: nil,
                            unreadMetadata: .empty,
                            searchResolutionProof: .failed(failure)
                        ))
                        return
                    }
                } else {
                    searchResolutionProof = .notRequested
                    effectiveTarget = target
                }
                let preparedLatestItems: [MessageStorageItem]?
                let preparedAroundWindow: ChatTimelineInitialFrameWindow?
                switch effectiveTarget {
                case .latest:
                    preparedLatestItems = provider.initialLatestWindow(
                        limit: boundedLimit
                    ).map(Self.frozen)
                    preparedAroundWindow = nil
                case .message(let anchor):
                    let before = boundedLimit / 2
                    preparedLatestItems = nil
                    preparedAroundWindow = provider.messageWindow(
                        primary: anchor.primary,
                        archivedId: anchor.archivedId,
                        messageId: anchor.messageId,
                        before: before,
                        after: max(0, boundedLimit - before - 1)
                    ).map {
                        ChatTimelineInitialFrameWindow(
                            target: Self.frozen($0.target),
                            items: $0.items.map(Self.frozen),
                            materializedCandidateCount:
                                $0.materializedCandidateCount
                        )
                    }
                case .firstIncomingAfterBoundary(let boundaryArchivedId):
                    let before = boundedLimit / 2
                    preparedLatestItems = nil
                    preparedAroundWindow = provider.firstIncomingWindow(
                        afterArchiveBoundaryId: boundaryArchivedId,
                        before: before,
                        after: max(0, boundedLimit - before - 1)
                    ).map {
                        ChatTimelineInitialFrameWindow(
                            target: Self.frozen($0.target),
                            items: $0.items.map(Self.frozen),
                            materializedCandidateCount:
                                $0.materializedCandidateCount
                        )
                    }
                }
                guard effectiveTarget == .latest ||
                        preparedAroundWindow != nil else {
                    recordSupplemental(
                        operation: "postBootstrapWindowAndMetadata",
                        candidateCount: 0
                    )
                    consume(nil)
                    return
                }
                let materializedMessageCount =
                    preparedAroundWindow?.items.count ??
                    preparedLatestItems?.count ?? 0
                let unreadMetadata = readUnreadMetadata(
                    limit: boundedLimit,
                    initialFrameContext: (
                        materializedLocalMessageCount: materializedMessageCount,
                        conversationKey: conversationKey,
                        baseGeneration: baseGeneration
                    ),
                    realm: realm,
                    recordsDiagnostics: false
                )
                recordSupplemental(
                    operation: "postBootstrapWindowAndMetadata",
                    candidateCount: max(
                        preparedAroundWindow?.materializedCandidateCount ??
                            preparedLatestItems?.count ?? 0,
                        unreadMetadata.candidateCount
                    )
                )
                consume(ChatTimelineInitialFrameLeaseMaterialization(
                    preparedLatestItems: preparedLatestItems,
                    preparedAroundWindow: preparedAroundWindow,
                    unreadMetadata: unreadMetadata,
                    searchResolutionProof: searchResolutionProof
                ))
            } catch {
                DDLogDebug(
                    "RealmChatTimelineSessionStore.postBootstrap lease: \(error.localizedDescription)"
                )
                recordSupplemental(
                    operation: "postBootstrapWindowAndMetadata",
                    candidateCount: 0
                )
                consume(nil)
            }
        }
    }

    private func readUnreadMetadata(
        limit: Int,
        initialFrameContext: (
            materializedLocalMessageCount: Int,
            conversationKey: ChatTimelineConversationKey,
            baseGeneration: UInt64
        )?,
        realm suppliedRealm: Realm? = nil,
        recordsDiagnostics: Bool = true,
        providerDiagnosticsOverride:
            ChatLocalHistoryPageProviderDiagnostics? = nil
    ) -> ChatTimelineUnreadMetadata {
        guard limit > 0 else { return .empty }
        do {
            let realm: Realm
            if let suppliedRealm {
                realm = suppliedRealm
            } else {
                realm = try WRealm.safe()
            }
            let chatPrimary = LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
            let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: chatPrimary
            )
            let unreadCount = max(0, chat?.unread ?? 0)
            let latestUnreadMentionArchivedId =
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    chat?.mentionId
                )
            let archiveState = conversationType.supportsSnapshotArchiveRepair
                ? realm.object(
                    ofType: RegularChatArchiveSyncStateStorageItem.self,
                    forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                        jid: jid,
                        owner: owner,
                        conversationType: conversationType
                    )
                )
                : nil
            let loadedRanges = archiveState?.loadedRanges ?? []
            let knownGaps = archiveState?.knownGaps ?? []
            let persistedCursorId = archiveState?.oldestLoadedArchiveId ?? {
                guard chat?.lastLoadedMessageHistoryId?.isNotEmpty == true else {
                    return nil
                }
                return chat?.lastLoadedMessageHistoryId
            }()
            let archiveStateSnapshot = ChatArchiveStateSnapshot(
                primaryKey: chatPrimary,
                persistedCursorId: persistedCursorId,
                fullArchiveLoaded:
                    archiveState?.olderArchiveEndReached ??
                    chat?.fullArchiveLoaded ?? false,
                newestCursorId: archiveState?.newestLoadedArchiveId,
                newerLiveEdgeReached:
                    archiveState?.newerLiveEdgeReached ?? true,
                hasKnownNewerGap: knownGaps.isNotEmpty,
                knownGaps: knownGaps
            )
            let archiveBoundaryFingerprint =
                conversationType.supportsSnapshotArchiveRepair
                ? MessageArchiveManager.conversationArchiveBoundaryFingerprint(
                    chat: chat,
                    archiveState: archiveState
                )
                : nil
            let hasKnownRemoteArchiveBoundary =
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    chat?.syncSnapshotLastArchiveId
                ) != nil || (
                    (chat?.syncUnreadCount ?? 0) > 0 &&
                    RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                        chat?.syncUnreadAfterId
                    ) != nil
                ) || RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    archiveState?.lastSnapshotArchiveId
                ) != nil || RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    archiveState?.lastSnapshotMessageId
                ) != nil
            let readinessProof = initialFrameContext.flatMap { context ->
                ChatTimelineInitialFrameReadinessProof? in
                guard context.conversationKey.owner == owner,
                      context.conversationKey.jid == jid,
                      context.conversationKey.conversationType == conversationType else {
                    return nil
                }
                return ChatTimelineInitialFrameReadinessProof(
                    conversationKey: context.conversationKey,
                    baseGeneration: context.baseGeneration,
                    materializedLocalMessageCount:
                        context.materializedLocalMessageCount,
                    isSynced: chat?.isSynced ?? false,
                    isInitialArchiveLoaded:
                        chat?.isInitialArchiveLoaded ?? false,
                    hasDurableArchiveReadiness:
                        ConversationArchiveDurableReadinessPolicy.isReady(
                            chat: chat,
                            archiveState: archiveState,
                            conversationType: conversationType,
                            localMessageCount:
                                context.materializedLocalMessageCount
                        ),
                    archiveState: archiveStateSnapshot,
                    chatFullArchiveLoaded:
                        chat?.fullArchiveLoaded ?? false,
                    loadedRanges: loadedRanges,
                    knownGaps: knownGaps,
                    archiveBoundaryFingerprint: archiveBoundaryFingerprint,
                    hasKnownRemoteArchiveBoundary:
                        hasKnownRemoteArchiveBoundary,
                    latestMessageFingerprint: chat?.lastMessage.flatMap {
                        $0.isDeleted
                            ? nil
                            : ChatTimelineObservedMessageFingerprint(message: $0)
                    }
                )
            }
            guard conversationType == .group else {
                if recordsDiagnostics {
                    recordSupplemental(operation: "unread", candidateCount: 1)
                }
                return ChatTimelineUnreadMetadata(
                    unreadCount: unreadCount,
                    mentions: [],
                    candidateCount: 1,
                    initialFrameReadinessProof: readinessProof,
                    latestUnreadMentionArchivedId:
                        latestUnreadMentionArchivedId
                )
            }

            let boundedLimit = min(
                limit,
                ChatInitialFirstFrameHistoryConfiguration.pageSize
            )
            let notifications = Array(
                realm.objects(NotificationStorageItem.self)
                    .filter(
                        "owner == %@ AND category_ == %@ AND isRead == false AND associatedJid == %@",
                        owner,
                        XMPPNotificationsManager.Category.mention.rawValue,
                        jid
                    )
                    .sorted(byKeyPath: "date", ascending: true)
                    .prefix(boundedLimit)
            )
            let currentMemberId = MentionNotificationSync.currentGroupMemberId(
                owner: owner,
                groupchatJid: jid,
                in: realm
            )
            let provider = makeProvider(
                realm: realm,
                recordsDiagnostics: recordsDiagnostics,
                diagnosticsOverride: providerDiagnosticsOverride
            )
            let messagePrimaryByNotificationPrimary =
                provider.unreadMentionMessagePrimaries(
                    for: notifications,
                    limit: boundedLimit
                )
            let mentions = ChatUnreadMentionIndexPolicy.rebuild(
                from: notifications,
                resolveMessagePrimary: { notification in
                    messagePrimaryByNotificationPrimary[notification.primary]
                },
                chatPrimary: chatPrimary,
                currentMemberId: currentMemberId,
                groupchatJid: jid
            )
            return ChatTimelineUnreadMetadata(
                unreadCount: unreadCount,
                mentions: mentions,
                candidateCount: notifications.count,
                initialFrameReadinessProof: readinessProof,
                latestUnreadMentionArchivedId:
                    latestUnreadMentionArchivedId
            )
        } catch {
            DDLogDebug("RealmChatTimelineSessionStore.unreadMetadata: \(error.localizedDescription)")
            if recordsDiagnostics {
                recordSupplemental(operation: "unread", candidateCount: 0)
            }
            return .empty
        }
    }

    func observe(
        baseline: ChatTimelineStoreObservationBaseline,
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) -> ChatTimelineStoreObservation {
        RealmChatTimelineStoreObservation(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            baseline: baseline,
            readUnreadMetadata: { [weak self] realm, limit in
                guard let self else {
                    return ChatTimelineStoreObservedUnreadMetadata(
                        metadata: .empty,
                        queryCount: 0,
                        fullScanCount: 0,
                        maxCandidateCount: 0
                    )
                }
                let mentionDiagnostics =
                    ChatLocalHistoryPageProviderDiagnostics()
                let metadata = self.readUnreadMetadata(
                    limit: limit,
                    initialFrameContext: nil,
                    realm: realm,
                    recordsDiagnostics: false,
                    providerDiagnosticsOverride: mentionDiagnostics
                )
                return ChatTimelineStoreObservedUnreadMetadata(
                    metadata: metadata,
                    queryCount: 1 + mentionDiagnostics.queryCount,
                    fullScanCount: mentionDiagnostics.fullScanCount,
                    maxCandidateCount: max(
                        metadata.candidateCount,
                        mentionDiagnostics.maxCandidateCount
                    )
                )
            },
            recordDiagnostics: { [weak self] event in
                self?.recordObservationDiagnosticEvent(event)
            },
            testHooks: observationTestHooks,
            onChange: onChange
        )
    }

    private func withProvider<T>(
        default defaultValue: T,
        _ operation: (ChatLocalHistoryPageProvider) -> T
    ) -> T {
        autoreleasepool {
            do {
                let realm = try WRealm.safe()
                return operation(makeProvider(realm: realm))
            } catch {
                DDLogDebug("RealmChatTimelineSessionStore: \(error.localizedDescription)")
                return defaultValue
            }
        }
    }

    private func makeProvider(
        realm: Realm,
        recordsDiagnostics: Bool = true,
        diagnosticsOverride: ChatLocalHistoryPageProviderDiagnostics? = nil
    ) -> ChatLocalHistoryPageProvider {
        ChatLocalHistoryPageProvider(
            realm: realm,
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            diagnostics:
                diagnosticsOverride ??
                (recordsDiagnostics ? providerDiagnostics : nil)
        )
    }

    private func recordSupplemental(operation: String, candidateCount: Int) {
        diagnosticsLock.withLock {
            supplementalDiagnostics = supplementalDiagnostics.recording(
                operation: operation,
                candidateCount: candidateCount
            )
        }
    }

    private func recordObservationDiagnosticEvent(
        _ event: ChatTimelineStoreObservationDiagnosticEvent
    ) {
        diagnosticsLock.withLock {
            let current = observationDiagnostics
            switch event {
            case .activationStarted(let pendingWorkCount):
                observationDiagnostics =
                    ChatTimelineStoreObservationDiagnosticsSnapshot(
                        activationCount: current.activationCount + 1,
                        realmQueryCount: current.realmQueryCount,
                        mainThreadRealmQueryCount:
                            current.mainThreadRealmQueryCount,
                        initialCallbackCount: current.initialCallbackCount,
                        mainThreadInitialCallbackCount:
                            current.mainThreadInitialCallbackCount,
                        maxInitialCandidateCount:
                            current.maxInitialCandidateCount,
                        metadataQueryCount: current.metadataQueryCount,
                        mainThreadMetadataQueryCount:
                            current.mainThreadMetadataQueryCount,
                        metadataFullScanCount: current.metadataFullScanCount,
                        maxMetadataCandidateCount:
                            current.maxMetadataCandidateCount,
                        catchUpMutationCount: current.catchUpMutationCount,
                        pendingWorkCount:
                            current.pendingWorkCount + pendingWorkCount
                    )
            case .realmQuery(_, let wasOnMainThread):
                observationDiagnostics =
                    ChatTimelineStoreObservationDiagnosticsSnapshot(
                        activationCount: current.activationCount,
                        realmQueryCount: current.realmQueryCount + 1,
                        mainThreadRealmQueryCount:
                            current.mainThreadRealmQueryCount +
                            (wasOnMainThread ? 1 : 0),
                        initialCallbackCount: current.initialCallbackCount,
                        mainThreadInitialCallbackCount:
                            current.mainThreadInitialCallbackCount,
                        maxInitialCandidateCount:
                            current.maxInitialCandidateCount,
                        metadataQueryCount: current.metadataQueryCount,
                        mainThreadMetadataQueryCount:
                            current.mainThreadMetadataQueryCount,
                        metadataFullScanCount: current.metadataFullScanCount,
                        maxMetadataCandidateCount:
                            current.maxMetadataCandidateCount,
                        catchUpMutationCount: current.catchUpMutationCount,
                        pendingWorkCount: current.pendingWorkCount
                    )
            case .initialCallback(let candidateCount, let wasOnMainThread):
                observationDiagnostics =
                    ChatTimelineStoreObservationDiagnosticsSnapshot(
                        activationCount: current.activationCount,
                        realmQueryCount: current.realmQueryCount,
                        mainThreadRealmQueryCount:
                            current.mainThreadRealmQueryCount,
                        initialCallbackCount: current.initialCallbackCount + 1,
                        mainThreadInitialCallbackCount:
                            current.mainThreadInitialCallbackCount +
                            (wasOnMainThread ? 1 : 0),
                        maxInitialCandidateCount: max(
                            current.maxInitialCandidateCount,
                            max(0, candidateCount)
                        ),
                        metadataQueryCount: current.metadataQueryCount,
                        mainThreadMetadataQueryCount:
                            current.mainThreadMetadataQueryCount,
                        metadataFullScanCount: current.metadataFullScanCount,
                        maxMetadataCandidateCount:
                            current.maxMetadataCandidateCount,
                        catchUpMutationCount: current.catchUpMutationCount,
                        pendingWorkCount: current.pendingWorkCount
                    )
            case .metadataQuery(
                let queryCount,
                let fullScanCount,
                let maxCandidateCount,
                let wasOnMainThread
            ):
                observationDiagnostics =
                    ChatTimelineStoreObservationDiagnosticsSnapshot(
                        activationCount: current.activationCount,
                        realmQueryCount: current.realmQueryCount,
                        mainThreadRealmQueryCount:
                            current.mainThreadRealmQueryCount,
                        initialCallbackCount: current.initialCallbackCount,
                        mainThreadInitialCallbackCount:
                            current.mainThreadInitialCallbackCount,
                        maxInitialCandidateCount:
                            current.maxInitialCandidateCount,
                        metadataQueryCount:
                            current.metadataQueryCount + max(0, queryCount),
                        mainThreadMetadataQueryCount:
                            current.mainThreadMetadataQueryCount +
                            (wasOnMainThread ? max(0, queryCount) : 0),
                        metadataFullScanCount:
                            current.metadataFullScanCount +
                            max(0, fullScanCount),
                        maxMetadataCandidateCount: max(
                            current.maxMetadataCandidateCount,
                            max(0, maxCandidateCount)
                        ),
                        catchUpMutationCount: current.catchUpMutationCount,
                        pendingWorkCount: current.pendingWorkCount
                    )
            case .catchUpMutations(let count):
                observationDiagnostics =
                    ChatTimelineStoreObservationDiagnosticsSnapshot(
                        activationCount: current.activationCount,
                        realmQueryCount: current.realmQueryCount,
                        mainThreadRealmQueryCount:
                            current.mainThreadRealmQueryCount,
                        initialCallbackCount: current.initialCallbackCount,
                        mainThreadInitialCallbackCount:
                            current.mainThreadInitialCallbackCount,
                        maxInitialCandidateCount:
                            current.maxInitialCandidateCount,
                        metadataQueryCount: current.metadataQueryCount,
                        mainThreadMetadataQueryCount:
                            current.mainThreadMetadataQueryCount,
                        metadataFullScanCount: current.metadataFullScanCount,
                        maxMetadataCandidateCount:
                            current.maxMetadataCandidateCount,
                        catchUpMutationCount:
                            current.catchUpMutationCount + max(0, count),
                        pendingWorkCount: current.pendingWorkCount
                    )
            case .pendingWorkDelta(let delta):
                observationDiagnostics =
                    ChatTimelineStoreObservationDiagnosticsSnapshot(
                        activationCount: current.activationCount,
                        realmQueryCount: current.realmQueryCount,
                        mainThreadRealmQueryCount:
                            current.mainThreadRealmQueryCount,
                        initialCallbackCount: current.initialCallbackCount,
                        mainThreadInitialCallbackCount:
                            current.mainThreadInitialCallbackCount,
                        maxInitialCandidateCount:
                            current.maxInitialCandidateCount,
                        metadataQueryCount: current.metadataQueryCount,
                        mainThreadMetadataQueryCount:
                            current.mainThreadMetadataQueryCount,
                        metadataFullScanCount: current.metadataFullScanCount,
                        maxMetadataCandidateCount:
                            current.maxMetadataCandidateCount,
                        catchUpMutationCount: current.catchUpMutationCount,
                        pendingWorkCount: max(
                            0,
                            current.pendingWorkCount + delta
                        )
                    )
            }
        }
    }

    private static func frozen(_ item: MessageStorageItem) -> MessageStorageItem {
        item.realm == nil || item.isFrozen ? item : item.freeze()
    }
}

private final class RealmChatTimelineStoreObservation: ChatTimelineStoreObservation {
    private struct ResidentRegistrationBaseline {
        let items: [MessageStorageItem]
        let isAuthoritative: Bool

        var primaryKeys: [String] {
            Array(Set(items.map(\.primary))).sorted()
        }
    }

    private let owner: String
    private let jid: String
    private let conversationType: ClientSynchronizationManager.ConversationType
    private let initialBaseline: ChatTimelineStoreObservationBaseline
    private let readUnreadMetadata:
        (Realm, Int) -> ChatTimelineStoreObservedUnreadMetadata
    private let recordDiagnostics: (ChatTimelineStoreObservationDiagnosticEvent) -> Void
    private let testHooks: ChatTimelineStoreObservationTestHooks
    private let onChange: (ChatTimelineStoreChange) -> Void
    private let observationQueue: DispatchQueue
    private let lock = NSLock()

    private var invalidated = false
    private var activeWorkIdentifiers: Set<String> = ["activation"]
    private var requestedResidentItems: [MessageStorageItem]
    private var requestedResidentGeneration: UInt64 = 1
    private var deliveryGeneration: UInt64 = 0

    // Queue-confined state. Realm itself is explicitly confined to the same
    // serial queue, so GCD thread hopping cannot violate Realm isolation.
    private var queueRealm: Realm?
    private var lastChatsToken: NotificationToken?
    private var residentToken: NotificationToken?
    private var lastChatsRegistrationIdentity =
        ChatTimelineStoreObservationRegistrationIdentity(
            kind: .lastChats,
            generation: 1
        )
    private var residentRegistrationIdentity:
        ChatTimelineStoreObservationRegistrationIdentity?
    private var installedResidentGeneration: UInt64 = 0
    private var lastObservedLatestFingerprint:
        ChatTimelineObservedMessageFingerprint?
    private var lastObservedUnreadCount: Int?
    private var lastObservedUnreadMentionArchivedId: String?
    private var lastObservedUnreadMetadata: ChatTimelineUnreadMetadata
    private var residentIdentitiesByIndex: [ChatIncrementalMessageIdentity] = []
    private var residentPrimaryKeys: Set<String> = []
    private var mutationAccumulator =
        ChatIncrementalMessageMutationAccumulator<MessageStorageItem>()
    private var residentMutationAccumulators:
        [UInt64: ChatIncrementalMessageMutationAccumulator<MessageStorageItem>] = [:]
    private var mutationFlushScheduled = false
    private var pendingUnreadMetadata: ChatTimelineUnreadMetadata?
    private var mutationRevision: UInt64 = 0

    var activeWorkCount: Int {
        lock.withLock { activeWorkIdentifiers.count }
    }

    init(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        baseline: ChatTimelineStoreObservationBaseline,
        readUnreadMetadata: @escaping (
            Realm,
            Int
        ) -> ChatTimelineStoreObservedUnreadMetadata,
        recordDiagnostics: @escaping (
            ChatTimelineStoreObservationDiagnosticEvent
        ) -> Void,
        testHooks: ChatTimelineStoreObservationTestHooks,
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) {
        let frozenResidentItems = baseline.residentItems.map(Self.frozen)
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
        self.initialBaseline = ChatTimelineStoreObservationBaseline(
            isAuthoritative: baseline.isAuthoritative,
            residentItems: frozenResidentItems,
            latestMessageFingerprint: baseline.latestMessageFingerprint,
            unreadCount: baseline.unreadCount,
            unreadMetadataLimit: baseline.unreadMetadataLimit,
            unreadMetadata: baseline.unreadMetadata
        )
        self.requestedResidentItems = frozenResidentItems
        self.residentPrimaryKeys = Set(frozenResidentItems.map(\.primary))
        self.lastObservedUnreadMentionArchivedId =
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                baseline.latestUnreadMentionArchivedId
            )
        self.lastObservedUnreadMetadata = baseline.unreadMetadata
        self.readUnreadMetadata = readUnreadMetadata
        self.recordDiagnostics = recordDiagnostics
        self.testHooks = testHooks
        self.onChange = onChange
        self.observationQueue = DispatchQueue(
            label: "com.xabber.chat.timeline.realm-observation.\(UUID().uuidString)",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        )
        recordDiagnostics(.activationStarted(pendingWorkCount: 1))
        observationQueue.async { [weak self] in
            self?.installInitialObservations()
        }
    }

    deinit {
        invalidate()
    }

    func replaceResidentItems(_ items: [MessageStorageItem]) {
        let frozen = items.map(Self.frozen)
        let keys = Array(Set(frozen.map(\.primary))).sorted()
        let request: (generation: UInt64, previousPendingIdentifier: String?)? =
            lock.withLock {
                guard !invalidated else { return nil }
                let currentKeys = Array(Set(requestedResidentItems.map(\.primary))).sorted()
                guard currentKeys != keys else { return nil }
                requestedResidentItems = frozen
                let previousGeneration = requestedResidentGeneration
                requestedResidentGeneration &+= 1
                let workIdentifier = residentInstallWorkIdentifier(
                    generation: requestedResidentGeneration
                )
                activeWorkIdentifiers.insert(workIdentifier)
                return (
                    requestedResidentGeneration,
                    residentInitialWorkIdentifier(generation: previousGeneration)
                )
            }
        guard let request else { return }
        if let previousPendingIdentifier = request.previousPendingIdentifier {
            finishActiveWork(previousPendingIdentifier)
        }
        recordDiagnostics(.pendingWorkDelta(1))
        observationQueue.async { [weak self] in
            self?.installResidentObservation(generation: request.generation)
        }
    }

    func invalidate() {
        let cancellation = lock.withLock { () -> (
            workCount: Int,
            lastToken: NotificationToken?,
            lastIdentity: ChatTimelineStoreObservationRegistrationIdentity,
            residentToken: NotificationToken?,
            residentIdentity: ChatTimelineStoreObservationRegistrationIdentity?,
            realm: Realm?
        )? in
            guard !invalidated else { return nil }
            invalidated = true
            let count = activeWorkIdentifiers.count
            activeWorkIdentifiers.removeAll(keepingCapacity: false)
            let cancellation = (
                count,
                lastChatsToken,
                lastChatsRegistrationIdentity,
                residentToken,
                residentRegistrationIdentity,
                queueRealm
            )
            lastChatsToken = nil
            residentToken = nil
            queueRealm = nil
            return cancellation
        }
        guard let cancellation else { return }
        if cancellation.workCount > 0 {
            recordDiagnostics(.pendingWorkDelta(-cancellation.workCount))
        }
        let hooks = testHooks
        observationQueue.async {
            if let lastToken = cancellation.lastToken {
                lastToken.invalidate()
                hooks.didCancel?(cancellation.lastIdentity)
            }
            if let residentToken = cancellation.residentToken {
                residentToken.invalidate()
            }
            if cancellation.residentToken != nil,
               let identity = cancellation.residentIdentity {
                hooks.didCancel?(identity)
            }
            // Retain the queue-confined Realm until this queue-bound cleanup
            // completes; no reference to the deinitializing observation is
            // captured or resurrected.
            withExtendedLifetime(cancellation.realm) {}
        }
    }

    private func installInitialObservations() {
        guard !isInvalidated else {
            finishActiveWork("activation")
            return
        }
        do {
            // Opening the Realm on this dedicated queue is essential. Moving
            // only `observe` callbacks off main would leave Realm open/query
            // and Results construction in the first visible main-thread slice.
            let realm = try WRealm.safe(queue: observationQueue)
            let shouldInstall = lock.withLock { () -> Bool in
                guard !invalidated else { return false }
                queueRealm = realm
                return true
            }
            guard shouldInstall else {
                finishActiveWork("activation")
                return
            }
            installLastChatsObservation(realm: realm)
            installResidentObservation(
                generation: lock.withLock { requestedResidentGeneration },
                realm: realm
            )
        } catch {
            DDLogDebug(
                "RealmChatTimelineStoreObservation.install: \(error.localizedDescription)"
            )
        }
        finishActiveWork("activation")
    }

    private func installLastChatsObservation(realm: Realm) {
        let identity = lastChatsRegistrationIdentity
        guard startActiveWork(lastChatsInitialWorkIdentifier),
              !isInvalidated else {
            return
        }
        testHooks.beforeRealmQuery?(identity)
        guard !isInvalidated else {
            finishActiveWork(lastChatsInitialWorkIdentifier)
            return
        }
        recordDiagnostics(.realmQuery(
            candidateCount: 1,
            wasOnMainThread: Thread.isMainThread
        ))
        let primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: conversationType
        )
        let token = realm.objects(LastChatsStorageItem.self)
            .filter("primary == %@", primary)
            .observe(on: observationQueue) { [weak self] change in
                self?.handleLastChatsChange(change, realm: realm)
            }
        guard !isInvalidated else {
            token.invalidate()
            finishActiveWork(lastChatsInitialWorkIdentifier)
            return
        }
        let previousToken = lock.withLock { () -> NotificationToken? in
            guard !invalidated else { return token }
            let previous = lastChatsToken
            lastChatsToken = token
            return previous
        }
        if previousToken === token {
            token.invalidate()
            finishActiveWork(lastChatsInitialWorkIdentifier)
            return
        }
        previousToken?.invalidate()
        testHooks.didRegister?(identity)
    }

    private func handleLastChatsChange(
        _ change: RealmCollectionChange<Results<LastChatsStorageItem>>,
        realm: Realm
    ) {
        guard !isInvalidated else { return }
        switch change {
        case .initial(let collection):
            recordDiagnostics(.initialCallback(
                candidateCount: collection.count,
                wasOnMainThread: Thread.isMainThread
            ))
            let chat = collection.first
            let currentMessage = chat?.lastMessage.flatMap { $0.isDeleted ? nil : $0 }
            let currentFingerprint = currentMessage.map(
                ChatTimelineObservedMessageFingerprint.init(message:)
            )
            let unreadCount = max(0, chat?.unread ?? 0)
            let unreadMentionArchivedId =
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    chat?.mentionId
                )
            if initialBaseline.isAuthoritative {
                let catchUpCount = enqueueLatestDifference(
                    previous: initialBaseline.latestMessageFingerprint,
                    currentMessage: currentMessage,
                    currentFingerprint: currentFingerprint
                )
                let unreadChanged = unreadCount !=
                    max(0, initialBaseline.unreadCount)
                if catchUpCount > 0 || unreadChanged {
                    enqueueUnreadMetadata(
                        observedUnreadMetadata(
                            realm,
                            initialBaseline.unreadMetadataLimit
                        )
                    )
                } else {
                    enqueueUnreadMentionMetadataTransitionIfNeeded(
                        from: initialBaseline.latestUnreadMentionArchivedId,
                        to: unreadMentionArchivedId,
                        realm: realm
                    )
                }
                if catchUpCount > 0 {
                    recordDiagnostics(.catchUpMutations(catchUpCount))
                }
            }
            lastObservedLatestFingerprint = currentFingerprint
            lastObservedUnreadCount = unreadCount
            lastObservedUnreadMentionArchivedId = unreadMentionArchivedId
            finishActiveWork(lastChatsInitialWorkIdentifier)

        case .update(let collection, _, _, _):
            let chat = collection.first
            let currentMessage = chat?.lastMessage.flatMap {
                $0.isDeleted ? nil : $0
            }
            let currentFingerprint = currentMessage.map(
                ChatTimelineObservedMessageFingerprint.init(message:)
            )
            let mutationCount = enqueueLatestDifference(
                previous: lastObservedLatestFingerprint,
                currentMessage: currentMessage,
                currentFingerprint: currentFingerprint
            )
            let unreadCount = max(0, chat?.unread ?? 0)
            let unreadMentionArchivedId =
                RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    chat?.mentionId
                )
            if mutationCount > 0 || lastObservedUnreadCount != unreadCount {
                enqueueUnreadMetadata(
                    observedUnreadMetadata(
                        realm,
                        initialBaseline.unreadMetadataLimit
                    )
                )
            } else {
                enqueueUnreadMentionMetadataTransitionIfNeeded(
                    from: lastObservedUnreadMentionArchivedId,
                    to: unreadMentionArchivedId,
                    realm: realm
                )
            }
            lastObservedLatestFingerprint = currentFingerprint
            lastObservedUnreadCount = unreadCount
            lastObservedUnreadMentionArchivedId = unreadMentionArchivedId

        case .error(let error):
            finishActiveWork(lastChatsInitialWorkIdentifier)
            DDLogDebug(
                "RealmChatTimelineStoreObservation.lastChats change: \(error.localizedDescription)"
            )
        }
    }

    private func enqueueUnreadMentionMetadataTransitionIfNeeded(
        from previousArchivedId: String?,
        to currentArchivedId: String?,
        realm: Realm
    ) {
        switch ChatTimelineUnreadMentionMetadataTransitionPolicy.resolve(
            metadata: lastObservedUnreadMetadata,
            previousArchivedId: previousArchivedId,
            currentArchivedId: currentArchivedId
        ) {
        case .unchanged:
            return
        case .publish(let metadata):
            enqueueUnreadMetadata(metadata)
        case .resample:
            enqueueUnreadMetadata(observedUnreadMetadata(
                realm,
                initialBaseline.unreadMetadataLimit
            ))
        }
    }

    private func enqueueUnreadMetadata(
        _ metadata: ChatTimelineUnreadMetadata
    ) {
        lastObservedUnreadMetadata = metadata
        pendingUnreadMetadata = metadata
        scheduleMutationFlush()
    }

    private func observedUnreadMetadata(
        _ realm: Realm,
        _ limit: Int
    ) -> ChatTimelineUnreadMetadata {
        let result = readUnreadMetadata(realm, limit)
        recordDiagnostics(.metadataQuery(
            queryCount: result.queryCount,
            fullScanCount: result.fullScanCount,
            maxCandidateCount: result.maxCandidateCount,
            wasOnMainThread: Thread.isMainThread
        ))
        return result.metadata
    }

    @discardableResult
    private func enqueueLatestDifference(
        previous: ChatTimelineObservedMessageFingerprint?,
        currentMessage: MessageStorageItem?,
        currentFingerprint: ChatTimelineObservedMessageFingerprint?
    ) -> Int {
        switch (previous, currentFingerprint) {
        case (.none, .none):
            return 0
        case (.some(let previous), .none):
            guard !residentPrimaryKeys.contains(previous.identity.primary) else {
                // The bounded resident observer owns deletion/tombstone
                // reconciliation for visible rows.
                return 0
            }
            enqueueMutation(.delete(
                identity: previous.identity,
                revision: nextMutationRevision()
            ))
            return 1
        case (.none, .some(let current)):
            guard !residentPrimaryKeys.contains(current.identity.primary),
                  let currentMessage else { return 0 }
            let frozen = Self.frozen(currentMessage)
            enqueueMutation(.upsert(
                identity: current.identity,
                revision: nextMutationRevision(),
                payload: frozen
            ))
            return 1
        case (.some(let previous), .some(let current)):
            guard previous.identity != current.identity,
                  !residentPrimaryKeys.contains(current.identity.primary),
                  let currentMessage else { return 0 }
            let frozen = Self.frozen(currentMessage)
            enqueueMutation(.upsert(
                identity: current.identity,
                revision: nextMutationRevision(),
                payload: frozen
            ))
            return 1
        }
    }

    private func installResidentObservation(generation: UInt64) {
        guard let realm = lock.withLock({ queueRealm }) else {
            finishActiveWork(residentInstallWorkIdentifier(generation: generation))
            return
        }
        installResidentObservation(generation: generation, realm: realm)
        finishActiveWork(residentInstallWorkIdentifier(generation: generation))
    }

    private func installResidentObservation(generation: UInt64, realm: Realm) {
        guard isCurrentResidentGeneration(generation), !isInvalidated else {
            return
        }
        guard installedResidentGeneration != generation else { return }
        installedResidentGeneration = generation
        let previousRegistration = lock.withLock { () -> (
            NotificationToken?,
            ChatTimelineStoreObservationRegistrationIdentity?
        ) in
            let previous = (residentToken, residentRegistrationIdentity)
            residentToken = nil
            residentRegistrationIdentity = nil
            return previous
        }
        previousRegistration.0?.invalidate()
        if previousRegistration.0 != nil,
           let identity = previousRegistration.1 {
            testHooks.didCancel?(identity)
        }

        let items = lock.withLock { requestedResidentItems }
        let baseline = ResidentRegistrationBaseline(
            items: items,
            isAuthoritative: initialBaseline.isAuthoritative || generation > 1
        )
        guard baseline.primaryKeys.isNotEmpty else {
            residentIdentitiesByIndex = []
            residentPrimaryKeys = []
            return
        }
        let identity = ChatTimelineStoreObservationRegistrationIdentity(
            kind: .resident,
            generation: generation
        )
        lock.withLock {
            residentRegistrationIdentity = identity
        }
        let initialWorkIdentifier = residentInitialWorkIdentifier(
            generation: generation
        )
        guard startActiveWork(initialWorkIdentifier) else { return }
        testHooks.beforeRealmQuery?(identity)
        guard isCurrentResidentGeneration(generation), !isInvalidated else {
            finishActiveWork(initialWorkIdentifier)
            return
        }
        recordDiagnostics(.realmQuery(
            candidateCount: baseline.primaryKeys.count,
            wasOnMainThread: Thread.isMainThread
        ))
        let token = realm.objects(MessageStorageItem.self)
            .filter("primary IN %@ AND isDeleted == false", baseline.primaryKeys)
            .observe(on: observationQueue) { [weak self] change in
                self?.handleResidentChange(
                    change,
                    identity: identity,
                    baseline: baseline
                )
            }
        guard isCurrentResidentGeneration(generation), !isInvalidated else {
            token.invalidate()
            finishActiveWork(initialWorkIdentifier)
            return
        }
        let shouldKeepToken = lock.withLock { () -> Bool in
            guard !invalidated,
                  requestedResidentGeneration == generation else {
                return false
            }
            residentToken = token
            return true
        }
        guard shouldKeepToken else {
            token.invalidate()
            finishActiveWork(initialWorkIdentifier)
            return
        }
        testHooks.didRegister?(identity)
    }

    private func handleResidentChange(
        _ change: RealmCollectionChange<Results<MessageStorageItem>>,
        identity: ChatTimelineStoreObservationRegistrationIdentity,
        baseline: ResidentRegistrationBaseline
    ) {
        guard isCurrentResidentGeneration(identity.generation),
              !isInvalidated else {
            return
        }
        let initialWorkIdentifier = residentInitialWorkIdentifier(
            generation: identity.generation
        )
        switch change {
        case .initial(let collection):
            recordDiagnostics(.initialCallback(
                candidateCount: collection.count,
                wasOnMainThread: Thread.isMainThread
            ))
            var currentByPrimary:
                [String: (MessageStorageItem, ChatTimelineObservedMessageFingerprint)] = [:]
            for message in collection {
                currentByPrimary[message.primary] = (
                    message,
                    ChatTimelineObservedMessageFingerprint(message: message)
                )
            }
            if baseline.isAuthoritative {
                var baselineByPrimary:
                    [String: ChatTimelineObservedMessageFingerprint] = [:]
                for message in baseline.items where !message.isDeleted {
                    baselineByPrimary[message.primary] =
                        ChatTimelineObservedMessageFingerprint(message: message)
                }
                var catchUpCount = 0
                for (primary, previous) in baselineByPrimary
                    where !currentByPrimary.keys.contains(primary) {
                    enqueueResidentMutation(
                        .delete(
                            identity: previous.identity,
                            revision: nextMutationRevision()
                        ),
                        generation: identity.generation
                    )
                    catchUpCount += 1
                }
                for (primary, current) in currentByPrimary
                    where baselineByPrimary[primary] != current.1 {
                    let frozen = Self.frozen(current.0)
                    enqueueResidentMutation(
                        .upsert(
                            identity: current.1.identity,
                            revision: nextMutationRevision(),
                            payload: frozen
                        ),
                        generation: identity.generation
                    )
                    catchUpCount += 1
                }
                if catchUpCount > 0 {
                    recordDiagnostics(.catchUpMutations(catchUpCount))
                }
            }
            residentIdentitiesByIndex = collection.map(
                ChatIncrementalMessageIdentity.init(message:)
            )
            residentPrimaryKeys = Set(collection.map(\.primary))
            finishActiveWork(initialWorkIdentifier)

        case .update(
            let collection,
            let deletions,
            let insertions,
            let modifications
        ):
            let previousIdentities = residentIdentitiesByIndex
            deletions.compactMap {
                previousIdentities.indices.contains($0)
                    ? previousIdentities[$0]
                    : nil
            }.forEach {
                enqueueResidentMutation(
                    .delete(
                        identity: $0,
                        revision: nextMutationRevision()
                    ),
                    generation: identity.generation
                )
            }
            Set(insertions + modifications).sorted().forEach { index in
                guard collection.indices.contains(index) else { return }
                let message = collection[index]
                let frozen = Self.frozen(message)
                enqueueResidentMutation(
                    .upsert(
                        identity: ChatIncrementalMessageIdentity(message: frozen),
                        revision: nextMutationRevision(),
                        payload: frozen
                    ),
                    generation: identity.generation
                )
            }
            residentIdentitiesByIndex = collection.map(
                ChatIncrementalMessageIdentity.init(message:)
            )
            residentPrimaryKeys = Set(collection.map(\.primary))

        case .error(let error):
            finishActiveWork(initialWorkIdentifier)
            DDLogDebug(
                "RealmChatTimelineStoreObservation.resident change: \(error.localizedDescription)"
            )
        }
    }

    private func enqueueMutation(
        _ mutation: ChatIncrementalMessageMutation<MessageStorageItem>
    ) {
        mutationAccumulator.enqueue(mutation)
        scheduleMutationFlush()
    }

    private func enqueueResidentMutation(
        _ mutation: ChatIncrementalMessageMutation<MessageStorageItem>,
        generation: UInt64
    ) {
        residentMutationAccumulators[generation, default:
            ChatIncrementalMessageMutationAccumulator<MessageStorageItem>()
        ].enqueue(mutation)
        scheduleMutationFlush()
    }

    private func scheduleMutationFlush() {
        guard !mutationFlushScheduled, !isInvalidated else { return }
        mutationFlushScheduled = true
        deliveryGeneration &+= 1
        let workIdentifier = "delivery-\(deliveryGeneration)"
        guard startActiveWork(workIdentifier) else {
            mutationFlushScheduled = false
            return
        }
        observationQueue.async { [weak self] in
            guard let self else { return }
            self.mutationFlushScheduled = false
            let independentBatch = self.mutationAccumulator.drain()
            var mutations = independentBatch.mutations
            var enqueuedMutationCount =
                independentBatch.enqueuedMutationCount
            var residentGenerationByRevision: [UInt64: UInt64] = [:]
            for generation in self.residentMutationAccumulators.keys.sorted() {
                guard var accumulator =
                        self.residentMutationAccumulators[generation] else {
                    continue
                }
                let residentBatch = accumulator.drain()
                mutations.append(contentsOf: residentBatch.mutations)
                enqueuedMutationCount += residentBatch.enqueuedMutationCount
                for mutation in residentBatch.mutations {
                    residentGenerationByRevision[mutation.revision] = generation
                }
            }
            self.residentMutationAccumulators.removeAll(keepingCapacity: true)
            mutations.sort {
                if $0.revision != $1.revision {
                    return $0.revision < $1.revision
                }
                return $0.identity.coalescingKey < $1.identity.coalescingKey
            }
            let batch = ChatIncrementalMessageMutationBatch(
                mutations: mutations,
                enqueuedMutationCount: enqueuedMutationCount,
                residentGenerationByRevision: residentGenerationByRevision
            )
            let unreadMetadata = self.pendingUnreadMetadata
            self.pendingUnreadMetadata = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.isInvalidated {
                    if batch.mutations.isNotEmpty, let unreadMetadata {
                        self.onChange(.incrementalWithUnreadMetadata(
                            batch,
                            unreadMetadata: unreadMetadata
                        ))
                    } else if batch.mutations.isNotEmpty {
                        self.onChange(.incremental(
                            batch,
                            refreshUnread: false
                        ))
                    } else if let unreadMetadata {
                        self.onChange(.unreadMetadataChanged(unreadMetadata))
                    }
                }
                self.finishActiveWork(workIdentifier)
            }
        }
    }

    private var isInvalidated: Bool {
        lock.withLock { invalidated }
    }

    private func isCurrentResidentGeneration(_ generation: UInt64) -> Bool {
        lock.withLock {
            !invalidated && requestedResidentGeneration == generation
        }
    }

    func authorizesResidentMutation(generation: UInt64) -> Bool {
        isCurrentResidentGeneration(generation)
    }

    private func startActiveWork(_ identifier: String) -> Bool {
        let inserted = lock.withLock { () -> Bool in
            guard !invalidated else { return false }
            return activeWorkIdentifiers.insert(identifier).inserted
        }
        if inserted {
            recordDiagnostics(.pendingWorkDelta(1))
        }
        return inserted
    }

    private func finishActiveWork(_ identifier: String) {
        let removed = lock.withLock {
            activeWorkIdentifiers.remove(identifier) != nil
        }
        if removed {
            recordDiagnostics(.pendingWorkDelta(-1))
        }
    }

    private var lastChatsInitialWorkIdentifier: String {
        "initial-lastChats-\(lastChatsRegistrationIdentity.generation)"
    }

    private func residentInstallWorkIdentifier(generation: UInt64) -> String {
        "install-resident-\(generation)"
    }

    private func residentInitialWorkIdentifier(generation: UInt64) -> String {
        "initial-resident-\(generation)"
    }

    private func nextMutationRevision() -> UInt64 {
        mutationRevision &+= 1
        return mutationRevision
    }

    private static func frozen(_ item: MessageStorageItem) -> MessageStorageItem {
        item.realm == nil || item.isFrozen ? item : item.freeze()
    }
}

private extension NSLocking {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
