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

struct ChatTimelineUnreadMetadata: Equatable {
    static let empty = ChatTimelineUnreadMetadata(
        unreadCount: 0,
        mentions: [],
        candidateCount: 0,
        latestUnreadMentionArchivedId: nil
    )

    let unreadCount: Int
    let mentions: [ChatUnreadMentionItem]
    let candidateCount: Int
    let latestUnreadMentionArchivedId: String?

    init(
        unreadCount: Int,
        mentions: [ChatUnreadMentionItem],
        candidateCount: Int,
        latestUnreadMentionArchivedId: String? = nil
    ) {
        self.unreadCount = unreadCount
        self.mentions = mentions
        self.candidateCount = candidateCount
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
            latestUnreadMentionArchivedId: current
        ))
    }
}

protocol ChatTimelineSessionStore: ChatTimelinePageProviding, AnyObject {
    var diagnosticsSnapshot: ChatTimelineStoreDiagnosticsSnapshot { get }

    func unreadMetadata(limit: Int) -> ChatTimelineUnreadMetadata
    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem?
    func observe(
        baseline: ChatTimelineStoreObservationBaseline,
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) -> ChatTimelineStoreObservation
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
    case localOutgoingAdmission
}

struct ChatTimelineAuthoritativeEmptyLiveTailAuthority: Equatable, Sendable {
    let connectionGeneration: UInt64
    let freshnessFingerprint: String

    init?(freshnessToken: ArchiveFreshnessToken) {
        guard case .sessionMAM(let connectionGeneration, _) = freshnessToken,
              freshnessToken.fingerprint.isNotEmpty else {
            return nil
        }
        self.connectionGeneration = connectionGeneration
        self.freshnessFingerprint = freshnessToken.fingerprint
    }
}

struct ChatTimelineSessionSnapshot {
    let generation: UInt64
    let cause: ChatTimelineSessionSnapshotCause
    let items: [MessageStorageItem]
    let state: ChatVirtualTimelineState
    let anchorRestore: ChatTimelineAnchorRestoreCommand?
    let pageSize: Int
    let residentIndex: ChatTimelineResidentIndex
    let readBoundary: ChatTimelineReadBoundary?
    let unreadMetadata: ChatTimelineUnreadMetadata
    let residentHardLimit: Int
    let residentChangeSet: ChatIncrementalResidentChangeSet?
    let authoritativeEmptyLiveTailAuthority:
        ChatTimelineAuthoritativeEmptyLiveTailAuthority?
    let provisionalLocalOutgoingPrimaryIDs: Set<String>

    init(
        generation: UInt64,
        cause: ChatTimelineSessionSnapshotCause,
        items: [MessageStorageItem],
        state: ChatVirtualTimelineState,
        anchorRestore: ChatTimelineAnchorRestoreCommand?,
        pageSize: Int,
        residentIndex: ChatTimelineResidentIndex,
        readBoundary: ChatTimelineReadBoundary?,
        unreadMetadata: ChatTimelineUnreadMetadata,
        residentHardLimit: Int,
        residentChangeSet: ChatIncrementalResidentChangeSet?,
        authoritativeEmptyLiveTailAuthority:
            ChatTimelineAuthoritativeEmptyLiveTailAuthority? = nil,
        provisionalLocalOutgoingPrimaryIDs: Set<String> = []
    ) {
        self.generation = generation
        self.cause = cause
        self.items = items
        self.state = state
        self.anchorRestore = anchorRestore
        self.pageSize = pageSize
        self.residentIndex = residentIndex
        self.readBoundary = readBoundary
        self.unreadMetadata = unreadMetadata
        self.residentHardLimit = residentHardLimit
        self.residentChangeSet = residentChangeSet
        self.authoritativeEmptyLiveTailAuthority =
            authoritativeEmptyLiveTailAuthority
        self.provisionalLocalOutgoingPrimaryIDs =
            provisionalLocalOutgoingPrimaryIDs
    }

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
            anchorRestore: anchorRestore
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

enum ChatTimelineVerifiedBoundaryPreparationDisposition: Equatable {
    case started
    case coalesced
    case rejectedStale
}

enum ChatTimelineVerifiedBoundaryPreparationResult {
    case prepared(ChatTimelinePreparedVerifiedBoundaryPage)
    case stale
}

final class ChatTimelinePreparedVerifiedBoundaryPage {
    fileprivate let sessionID: UUID
    fileprivate let baseGeneration: UInt64
    fileprivate let direction: ChatHistoryPageDirection
    fileprivate let verifiedScope: ChatTimelineVerifiedScope
    fileprivate let outcome:
        ChatVirtualTimelineBoundaryOutcome<ChatTimelineSnapshot>

    private let lock = NSLock()
    private var consumed = false

    fileprivate init(
        sessionID: UUID,
        baseGeneration: UInt64,
        direction: ChatHistoryPageDirection,
        verifiedScope: ChatTimelineVerifiedScope,
        outcome: ChatVirtualTimelineBoundaryOutcome<ChatTimelineSnapshot>
    ) {
        self.sessionID = sessionID
        self.baseGeneration = baseGeneration
        self.direction = direction
        self.verifiedScope = verifiedScope
        self.outcome = outcome
    }

    fileprivate func consume() -> Bool {
        lock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }

    fileprivate var isAvailable: Bool {
        lock.withLock { !consumed }
    }
}

enum ChatTimelineVerifiedTargetPreparationDisposition: Equatable {
    case started
    case rejectedStale
}

enum ChatTimelineVerifiedTargetPreparationResult {
    case prepared(ChatTimelinePreparedVerifiedLocalTarget)
    case stale
}

final class ChatTimelinePreparedVerifiedLocalTarget {
    fileprivate let sessionID: UUID
    fileprivate let baseGeneration: UInt64
    fileprivate let verifiedScope: ChatTimelineVerifiedScope
    fileprivate let outcome:
        ChatVirtualTimelineTargetOutcome<ChatTimelineSnapshot>

    private let lock = NSLock()
    private var consumed = false

    fileprivate init(
        sessionID: UUID,
        baseGeneration: UInt64,
        verifiedScope: ChatTimelineVerifiedScope,
        outcome: ChatVirtualTimelineTargetOutcome<ChatTimelineSnapshot>
    ) {
        self.sessionID = sessionID
        self.baseGeneration = baseGeneration
        self.verifiedScope = verifiedScope
        self.outcome = outcome
    }

    fileprivate var isAvailable: Bool {
        lock.withLock { !consumed }
    }

    fileprivate func consume() -> Bool {
        lock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }
}

final class ChatTimelinePreparedVerifiedWindow {
    fileprivate let sessionID: UUID
    fileprivate let baseGeneration: UInt64
    fileprivate let previousScope: ChatTimelineVerifiedScope?
    fileprivate let scope: ChatTimelineVerifiedScope
    fileprivate let direction: ChatHistoryPageDirection?
    fileprivate let candidate: ChatTimelineSnapshot

    private let lock = NSLock()
    private var consumed = false

    fileprivate init(
        sessionID: UUID,
        baseGeneration: UInt64,
        previousScope: ChatTimelineVerifiedScope?,
        scope: ChatTimelineVerifiedScope,
        direction: ChatHistoryPageDirection?,
        candidate: ChatTimelineSnapshot
    ) {
        self.sessionID = sessionID
        self.baseGeneration = baseGeneration
        self.previousScope = previousScope
        self.scope = scope
        self.direction = direction
        self.candidate = candidate
    }

    fileprivate var isAvailable: Bool {
        lock.withLock { !consumed }
    }

    fileprivate func consume() -> Bool {
        lock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }
}

enum ChatTimelineLiveEdgeCommitMode: Equatable {
    case residentNewer
    case proofOnly
}

struct ChatTimelinePreparedLiveEdgeCandidate {
    let snapshot: ChatTimelineSnapshot
    let mode: ChatTimelineLiveEdgeCommitMode
    let shouldExposeNewMessageBadge: Bool
}

struct ChatTimelineCommittedLiveEdgeAdmission {
    let snapshot: ChatTimelineSessionSnapshot
    let mode: ChatTimelineLiveEdgeCommitMode
    let shouldExposeNewMessageBadge: Bool
}

final class ChatTimelinePreparedLiveEdgeAdmission {
    fileprivate let sessionID: UUID
    fileprivate let baseGeneration: UInt64
    fileprivate let baseState: ChatVirtualTimelineState
    fileprivate let baseAnchorRestore: ChatTimelineAnchorRestoreCommand?
    fileprivate let baseItemFingerprints: [ChatTimelineObservedMessageFingerprint]
    fileprivate let previousScope: ChatTimelineVerifiedScope?
    fileprivate let scope: ChatTimelineVerifiedScope
    fileprivate let candidate: ChatTimelineSnapshot
    fileprivate let mode: ChatTimelineLiveEdgeCommitMode
    fileprivate let shouldExposeNewMessageBadge: Bool

    private let lock = NSLock()
    private var consumed = false

    fileprivate init(
        sessionID: UUID,
        baseGeneration: UInt64,
        baseState: ChatVirtualTimelineState,
        baseAnchorRestore: ChatTimelineAnchorRestoreCommand?,
        baseItemFingerprints: [ChatTimelineObservedMessageFingerprint],
        previousScope: ChatTimelineVerifiedScope?,
        scope: ChatTimelineVerifiedScope,
        candidate: ChatTimelineSnapshot,
        mode: ChatTimelineLiveEdgeCommitMode,
        shouldExposeNewMessageBadge: Bool
    ) {
        self.sessionID = sessionID
        self.baseGeneration = baseGeneration
        self.baseState = baseState
        self.baseAnchorRestore = baseAnchorRestore
        self.baseItemFingerprints = baseItemFingerprints
        self.previousScope = previousScope
        self.scope = scope
        self.candidate = candidate
        self.mode = mode
        self.shouldExposeNewMessageBadge = shouldExposeNewMessageBadge
    }

    fileprivate var isAvailable: Bool {
        lock.withLock { !consumed }
    }

    fileprivate func consume() -> Bool {
        lock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }
}

private struct ChatTimelineVerifiedBoundaryPreparationKey: Equatable {
    let direction: ChatHistoryPageDirection
    let boundaryPrimary: String?
    let baseGeneration: UInt64
    let verifiedScope: ChatTimelineVerifiedScope
}

private struct ChatTimelineActiveVerifiedBoundaryPreparation {
    let key: ChatTimelineVerifiedBoundaryPreparationKey
    var completions: [(ChatTimelineVerifiedBoundaryPreparationResult) -> Void]
}

private enum ChatTimelineVerifiedScopeMutation {
    case unchanged
    case replace(ChatTimelineVerifiedScope?)
}


final class ChatTimelineSession {
    typealias SnapshotHandler = (ChatTimelineSessionSnapshot) -> Void

    private let lock = NSRecursiveLock()
    private let operationLock = NSRecursiveLock()
    private let store: ChatTimelineSessionStore
    private let pageSize: Int
    private let conversationKey: ChatTimelineConversationKey
    private let sessionID = UUID()
    private let verifiedBoundaryPreparationQueue = DispatchQueue(
        label: "org.xabber.chat.timeline.verified-boundary",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private var storedSnapshot: ChatTimelineSessionSnapshot
    private var storedVerifiedScope: ChatTimelineVerifiedScope?
    private var activeVerifiedBoundaryPreparation:
        ChatTimelineActiveVerifiedBoundaryPreparation?
    private var observation: ChatTimelineStoreObservation?
    private var isInstallingStoreObservation = false
    private var storeObservationEpoch: UInt64 = 0
    private var storedSnapshotHandler: SnapshotHandler?
    private var storeChangeDepth = 0
    private var incrementalResidentReducer = ChatIncrementalResidentReducer()
    /// Typed optimistic rows live outside the verified virtual-engine state.
    /// They are presented and observed, but never become archive boundaries.
    private var provisionalLocalOutgoingPrimaryIDs = Set<String>()
    private var storedAuthoritativeEmptyLiveTailAuthority:
        ChatTimelineAuthoritativeEmptyLiveTailAuthority?

    var snapshot: ChatTimelineSessionSnapshot {
        lock.withLock { storedSnapshot }
    }

    var verifiedScope: ChatTimelineVerifiedScope? {
        lock.withLock { storedVerifiedScope }
    }

    /// Route-total diagnostics begin when the production session store is
    /// installed and remain independent from archive-engine orchestration.
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
        observesStoreImmediately: Bool = true
    ) {
        self.store = store
        self.pageSize = max(1, pageSize)
        self.conversationKey = conversationKey
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
            anchorRestore: nil,
            pageSize: self.pageSize,
            residentIndex: ChatTimelineResidentIndex(items: []),
            readBoundary: nil,
            unreadMetadata: .empty,
            residentHardLimit: ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: self.pageSize),
            residentChangeSet: nil
        )
        self.storedVerifiedScope = nil
        if observesStoreImmediately {
            activateStoreObservation()
        }
    }

    deinit {
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
            let committed = lock.withLock { storedSnapshot }
            let baseline = ChatTimelineStoreObservationBaseline(
                isAuthoritative:
                    authoritativeEmptyBaseline && committed.items.isEmpty,
                residentItems: committed.items,
                latestMessageFingerprint: nil,
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

    /// Revokes every session-scoped archive proof without publishing cached
    /// rows back to presentation. The generation bump makes all outstanding
    /// prepared boundary, target and remote-window receipts fail closed.
    func invalidateVerifiedScope() {
        let invalidated = operationLock.withLock { () -> (
            ChatTimelineStoreObservation?,
            [(ChatTimelineVerifiedBoundaryPreparationResult) -> Void]
        ) in
            incrementalResidentReducer = ChatIncrementalResidentReducer()
            provisionalLocalOutgoingPrimaryIDs.removeAll(keepingCapacity: false)
            storedAuthoritativeEmptyLiveTailAuthority = nil
            return lock.withLock {
                let previous = storedSnapshot
                let staleCompletions =
                    activeVerifiedBoundaryPreparation?.completions ?? []
                activeVerifiedBoundaryPreparation = nil
                storedVerifiedScope = nil
                let emptyState = ChatVirtualTimelineState.empty(
                    owner: conversationKey.owner,
                    jid: conversationKey.jid,
                    conversationType: conversationKey.conversationType
                )
                storedSnapshot = ChatTimelineSessionSnapshot(
                    generation: previous.generation &+ 1,
                    cause: .command,
                    items: [],
                    state: emptyState,
                    anchorRestore: nil,
                    pageSize: previous.pageSize,
                    residentIndex: ChatTimelineResidentIndex(items: []),
                    readBoundary: previous.readBoundary,
                    unreadMetadata: previous.unreadMetadata,
                    residentHardLimit: previous.residentHardLimit,
                    residentChangeSet: nil
                )
                return (observation, staleCompletions)
            }
        }
        invalidated.0?.replaceResidentItems([])
        invalidated.1.forEach { completion in
            DispatchQueue.main.async {
                completion(.stale)
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
                anchorRestore: snapshot.anchorRestore,
                readBoundary: base.readBoundary,
                unreadMetadata: base.unreadMetadata
            )
        }
    }

    @discardableResult
    func installArchiveEngineVerifiedWindow(
        _ window: ArchiveWindowSnapshot
    ) -> ChatTimelineSessionSnapshot? {
        guard let prepared = prepareArchiveEngineVerifiedWindow(window) else {
            return nil
        }
        return commitPreparedArchiveEngineVerifiedWindow(prepared)
    }

    func prepareArchiveEngineVerifiedWindow(
        _ window: ArchiveWindowSnapshot
    ) -> ChatTimelinePreparedVerifiedWindow? {
        operationLock.withLock {
            guard let scope = ChatTimelineVerifiedScope(
                conversationKey: conversationKey,
                segment: window.verifiedSegment,
                coverageGeneration: window.coverageGeneration,
                freshnessToken: window.freshnessToken
            ) else {
                return nil
            }
            let currentScope = verifiedScope
            guard currentScope.map({
                scope.coverageGeneration >= $0.coverageGeneration
            }) ?? true else {
                return nil
            }
            var direction = Self.boundaryDirection(for: window.target)
            if currentScope == nil ||
                currentScope?.freshnessFingerprint != scope.freshnessFingerprint {
                direction = nil
            }
            guard let candidate = prepareVerifiedWindowCandidate(
                primaryIDs: window.messagePrimaryIDs,
                scope: scope,
                requestedDirection: direction
            ) else {
                return nil
            }
            return ChatTimelinePreparedVerifiedWindow(
                sessionID: sessionID,
                baseGeneration: snapshot.generation,
                previousScope: currentScope,
                scope: scope,
                direction: direction,
                candidate: candidate
            )
        }
    }

    func inspectPreparedArchiveEngineVerifiedWindow(
        _ prepared: ChatTimelinePreparedVerifiedWindow
    ) -> ChatTimelineSnapshot? {
        operationLock.withLock {
            guard prepared.isAvailable,
                  prepared.sessionID == sessionID,
                  snapshot.generation == prepared.baseGeneration,
                  verifiedScope == prepared.previousScope else {
                return nil
            }
            return prepared.candidate
        }
    }

    func commitPreparedArchiveEngineVerifiedWindow(
        _ prepared: ChatTimelinePreparedVerifiedWindow
    ) -> ChatTimelineSessionSnapshot? {
        operationLock.withLock {
            guard prepared.consume(),
                  prepared.sessionID == sessionID else {
                return nil
            }
            let base = snapshot
            guard base.generation == prepared.baseGeneration,
                  verifiedScope == prepared.previousScope else {
                return nil
            }
            storedAuthoritativeEmptyLiveTailAuthority = nil
            return publish(
                items: prepared.candidate.items,
                state: prepared.candidate.state,
                anchorRestore: prepared.candidate.anchorRestore,
                readBoundary: base.readBoundary,
                unreadMetadata: base.unreadMetadata,
                retentionDirection: prepared.direction,
                verifiedScopeMutation: .replace(prepared.scope)
            )
        }
    }

    func prepareArchiveLiveEdgeAdmission(
        _ admission: ArchiveLiveEdgeAdmission
    ) -> ChatTimelinePreparedLiveEdgeAdmission? {
        operationLock.withLock {
            let window = admission.latestWindow
            guard admission.conversation.owner == conversationKey.owner,
                  admission.conversation.jid == conversationKey.jid,
                  admission.conversation.conversationType ==
                    conversationKey.conversationType,
                  admission.presentationIntent.conversation ==
                    admission.conversation,
                  window.target == .latest,
                  window.messagePrimaryIDs.contains(admission.primaryID),
                  let scope = ChatTimelineVerifiedScope(
                    conversationKey: conversationKey,
                    segment: window.verifiedSegment,
                    coverageGeneration: window.coverageGeneration,
                    freshnessToken: window.freshnessToken
                  ) else {
                return nil
            }

            let base = snapshot
            let previousScope = verifiedScope
            if let previousScope {
                guard previousScope.reachesLiveEdge,
                      scope.connectionGeneration ==
                        previousScope.connectionGeneration,
                      scope.freshnessFingerprint ==
                        previousScope.freshnessFingerprint,
                      scope.coverageGeneration >
                        previousScope.coverageGeneration,
                      scope.newest >= previousScope.newest,
                      scope.canExtend(previousScope, direction: .newer) else {
                    return nil
                }
            } else {
                let hasOnlyTypedProvisionalOutgoing =
                    storedAuthoritativeEmptyLiveTailAuthority != nil &&
                    base.items.allSatisfy {
                        provisionalLocalOutgoingPrimaryIDs.contains($0.primary) &&
                            $0.outgoing &&
                            !$0.isDeleted &&
                            !$0.isLocallyHiddenByReport
                    }
                guard (base.items.isEmpty || hasOnlyTypedProvisionalOutgoing),
                      base.state.isResidentAtLiveTail,
                      scope.reachesArchiveStart,
                      scope.reachesLiveEdge else {
                    return nil
                }
            }
            let mode: ChatTimelineLiveEdgeCommitMode
            let candidate: ChatTimelineSnapshot
            let shouldExposeNewMessageBadge: Bool
            if base.state.isResidentAtLiveTail {
                guard let merged = prepareVerifiedWindowCandidate(
                    primaryIDs: window.messagePrimaryIDs,
                    scope: scope,
                    requestedDirection: .newer
                ) else {
                    return nil
                }
                mode = .residentNewer
                candidate = merged
                shouldExposeNewMessageBadge = false
            } else {
                let expected = window.messagePrimaryIDs
                let expectedSet = Set(expected)
                let materialized = store.items(primaryKeys: expected)
                guard expectedSet.count == expected.count,
                      materialized.count == expected.count,
                      Set(materialized.map(\.primary)) == expectedSet,
                      materialized.allSatisfy({ scope.contains($0) }),
                      let admittedLiveMessage = materialized.first(where: {
                        $0.primary == admission.primaryID
                      }) else {
                    return nil
                }
                mode = .proofOnly
                candidate = base.timelineSnapshot
                shouldExposeNewMessageBadge = !admittedLiveMessage.outgoing
            }
            return ChatTimelinePreparedLiveEdgeAdmission(
                sessionID: sessionID,
                baseGeneration: base.generation,
                baseState: base.state,
                baseAnchorRestore: base.anchorRestore,
                baseItemFingerprints: base.items.map {
                    ChatTimelineObservedMessageFingerprint(message: $0)
                },
                previousScope: previousScope,
                scope: scope,
                candidate: candidate,
                mode: mode,
                shouldExposeNewMessageBadge: shouldExposeNewMessageBadge
            )
        }
    }

    func inspectPreparedArchiveLiveEdgeAdmission(
        _ prepared: ChatTimelinePreparedLiveEdgeAdmission
    ) -> ChatTimelinePreparedLiveEdgeCandidate? {
        operationLock.withLock {
            guard prepared.isAvailable,
                  prepared.sessionID == sessionID,
                  isStructurallyCurrent(prepared) else {
                return nil
            }
            return ChatTimelinePreparedLiveEdgeCandidate(
                snapshot: prepared.candidate,
                mode: prepared.mode,
                shouldExposeNewMessageBadge:
                    prepared.shouldExposeNewMessageBadge
            )
        }
    }

    func commitPreparedArchiveLiveEdgeAdmission(
        _ prepared: ChatTimelinePreparedLiveEdgeAdmission
    ) -> ChatTimelineCommittedLiveEdgeAdmission? {
        operationLock.withLock {
            guard prepared.consume(),
                  prepared.sessionID == sessionID else {
                return nil
            }
            let base = snapshot
            guard isStructurallyCurrent(prepared, snapshot: base) else {
                return nil
            }
            let committed = publish(
                items: prepared.candidate.items,
                state: prepared.candidate.state,
                anchorRestore: prepared.candidate.anchorRestore,
                readBoundary: base.readBoundary,
                unreadMetadata: base.unreadMetadata,
                retentionDirection:
                    prepared.mode == .residentNewer ? .newer : nil,
                verifiedScopeMutation: .replace(prepared.scope)
            )
            return ChatTimelineCommittedLiveEdgeAdmission(
                snapshot: committed,
                mode: prepared.mode,
                shouldExposeNewMessageBadge:
                    prepared.shouldExposeNewMessageBadge
            )
        }
    }

    /// Generic Realm observation is allowed to publish unread/read metadata
    /// while an XMPP-proved live primary is being mapped for UIKit. Such a
    /// metadata-only publication advances the session generation, but must not
    /// invalidate the proof. Any resident content, ordering, anchor, state or
    /// verified-scope change still makes the preparation stale.
    private func isStructurallyCurrent(
        _ prepared: ChatTimelinePreparedLiveEdgeAdmission,
        snapshot current: ChatTimelineSessionSnapshot? = nil
    ) -> Bool {
        let current = current ?? snapshot
        guard verifiedScope == prepared.previousScope else {
            return false
        }
        if current.generation == prepared.baseGeneration {
            return true
        }
        return current.state == prepared.baseState &&
            current.anchorRestore == prepared.baseAnchorRestore &&
            current.items.map {
                ChatTimelineObservedMessageFingerprint(message: $0)
            } == prepared.baseItemFingerprints
    }

    /// Rebinds an in-flight local-outgoing presentation to the latest metadata
    /// generation without accepting a newer structural timeline. Read-boundary
    /// and unread commands may race off-main dataset mapping, but must not make
    /// the typed provisional row disappear until another store event arrives.
    func reprepareLocalOutgoingPresentation(
        _ prepared: ChatTimelineSessionSnapshot
    ) -> ChatTimelineSessionSnapshot? {
        operationLock.withLock {
            let current = snapshot
            guard prepared.cause == .localOutgoingAdmission,
                  current.cause == .command,
                  current.generation > prepared.generation,
                  !prepared.provisionalLocalOutgoingPrimaryIDs.isEmpty,
                  prepared.provisionalLocalOutgoingPrimaryIDs.isSubset(
                    of: current.provisionalLocalOutgoingPrimaryIDs
                  ),
                  current.state == prepared.state,
                  current.anchorRestore == prepared.anchorRestore,
                  current.items.map({
                    ChatTimelineObservedMessageFingerprint(message: $0)
                  }) == prepared.items.map({
                    ChatTimelineObservedMessageFingerprint(message: $0)
                  }) else {
                return nil
            }
            return ChatTimelineSessionSnapshot(
                generation: current.generation,
                cause: .localOutgoingAdmission,
                items: current.items,
                state: current.state,
                anchorRestore: current.anchorRestore,
                pageSize: current.pageSize,
                residentIndex: current.residentIndex,
                readBoundary: current.readBoundary,
                unreadMetadata: current.unreadMetadata,
                residentHardLimit: current.residentHardLimit,
                residentChangeSet: current.residentChangeSet,
                authoritativeEmptyLiveTailAuthority:
                    current.authoritativeEmptyLiveTailAuthority,
                provisionalLocalOutgoingPrimaryIDs:
                    current.provisionalLocalOutgoingPrimaryIDs
            )
        }
    }

    func loadVerifiedLocalBoundary(
        _ direction: ChatHistoryPageDirection
    ) -> ChatVirtualTimelineBoundaryOutcome<ChatTimelineSessionSnapshot> {
        operationLock.withLock {
            let base = snapshot
            guard let scope = verifiedScope else {
                return .invalidProof
            }
            var engine = ChatVirtualTimelineEngine(
                provider: store,
                pageSize: pageSize,
                state: base.state,
                verifiedScope: scope
            )
            return commitEngineBoundaryOutcome(
                engine.page(direction),
                direction: direction,
                base: base
            )
        }
    }

    /// Admits exactly one locally-authored row after its initial durable save.
    /// This is a presentation overlay: the archive proof remains unchanged
    /// until the numeric delivery receipt extends the live-edge scope.
    @discardableResult
    func admitLocalOutgoing(
        _ admission: ChatTimelineLocalOutgoingAdmission
    ) -> ChatTimelineSessionSnapshot? {
        operationLock.withLock {
            guard admission.conversation.owner == conversationKey.owner,
                  admission.conversation.jid == conversationKey.jid,
                  admission.conversation.conversationType ==
                    conversationKey.conversationType,
                  let item = store.message(
                    primary: admission.primaryID,
                    archivedId: nil,
                    messageId: nil
                  ),
                  item.primary == admission.primaryID,
                  item.owner == conversationKey.owner,
                  item.opponent == conversationKey.jid,
                  item.conversationType == conversationKey.conversationType,
                  item.outgoing,
                  !item.isDeleted,
                  !item.isLocallyHiddenByReport else {
                return nil
            }

            let scope = verifiedScope
            guard scope?.reachesLiveEdge == true ||
                    (scope == nil &&
                        storedAuthoritativeEmptyLiveTailAuthority != nil) else {
                return nil
            }

            let base = snapshot
            if base.item(primary: item.primary) != nil {
                return base
            }

            let tailItems: [MessageStorageItem]
            let tailState: ChatVirtualTimelineState
            if base.state.isResidentAtLiveTail {
                tailItems = base.items
                tailState = base.state
            } else {
                guard let scope else { return nil }
                var engine = ChatVirtualTimelineEngine(
                    provider: store,
                    pageSize: pageSize,
                    state: base.state,
                    verifiedScope: scope
                )
                guard case .local(let tail) = engine.openAround(
                    primary: nil,
                    archiveCursor: scope.newest,
                    before: pageSize,
                    after: 0
                ), tail.state.isResidentAtLiveTail else {
                    return nil
                }
                tailItems = tail.items
                tailState = tail.state
            }

            provisionalLocalOutgoingPrimaryIDs.insert(item.primary)
            let merged = presentationItemsByAttachingProvisionalOutgoing(
                to: tailItems,
                additionally: [item],
                direction: .newer,
                hardLimit: base.residentHardLimit
            )
            let bounded = merged.items
            guard bounded.contains(where: { $0.primary == item.primary }) else {
                provisionalLocalOutgoingPrimaryIDs.remove(item.primary)
                return nil
            }
            let presentationState = stateByReplacingResidentItems(
                merged.verifiedItems,
                in: tailState,
                retentionDirection: .newer
            )
            return publish(
                items: bounded,
                state: presentationState,
                anchorRestore: nil,
                readBoundary: base.readBoundary,
                unreadMetadata: base.unreadMetadata,
                residentChangeSet: ChatIncrementalResidentChangeSet(
                    insertedPrimaries: [item.primary],
                    updatedStablePrimaries: [],
                    deletedPrimaries: [],
                    trimmedPrimaries: merged.trimmedPrimaries,
                    nonResidentIncomingPrimaries: []
                ),
                retentionDirection: .newer,
                snapshotCause: .localOutgoingAdmission
            )
        }
    }

    @discardableResult
    func prepareVerifiedLocalBoundary(
        _ direction: ChatHistoryPageDirection,
        expectedGeneration: UInt64,
        completion: @escaping (
            ChatTimelineVerifiedBoundaryPreparationResult
        ) -> Void
    ) -> ChatTimelineVerifiedBoundaryPreparationDisposition {
        operationLock.withLock {
            let captured = lock.withLock { () -> (
                ChatTimelineSessionSnapshot,
                ChatTimelineVerifiedScope,
                ChatTimelineVerifiedBoundaryPreparationKey
            )? in
                guard storedSnapshot.generation == expectedGeneration,
                      let scope = storedVerifiedScope else {
                    return nil
                }
                let boundary = direction == .older
                    ? storedSnapshot.state.oldest
                    : storedSnapshot.state.newest
                let key = ChatTimelineVerifiedBoundaryPreparationKey(
                    direction: direction,
                    boundaryPrimary: boundary?.primary,
                    baseGeneration: expectedGeneration,
                    verifiedScope: scope
                )
                if var active = activeVerifiedBoundaryPreparation {
                    guard active.key == key else { return nil }
                    active.completions.append(completion)
                    activeVerifiedBoundaryPreparation = active
                    return (storedSnapshot, scope, key)
                }
                activeVerifiedBoundaryPreparation =
                    ChatTimelineActiveVerifiedBoundaryPreparation(
                        key: key,
                        completions: [completion]
                    )
                return (storedSnapshot, scope, key)
            }
            guard let captured else {
                return .rejectedStale
            }

            let isJoined = lock.withLock {
                activeVerifiedBoundaryPreparation?.completions.count ?? 0
            } > 1
            if isJoined {
                return .coalesced
            }

            verifiedBoundaryPreparationQueue.async { [weak self] in
                guard let self else { return }
                var engine = ChatVirtualTimelineEngine(
                    provider: self.store,
                    pageSize: self.pageSize,
                    state: captured.0.state,
                    verifiedScope: captured.1
                )
                let outcome = engine.page(direction)
                self.finishVerifiedBoundaryPreparation(
                    key: captured.2,
                    outcome: outcome
                )
            }
            return .started
        }
    }

    func commitPreparedVerifiedLocalBoundary(
        _ prepared: ChatTimelinePreparedVerifiedBoundaryPage
    ) -> ChatVirtualTimelineBoundaryOutcome<ChatTimelineSessionSnapshot> {
        operationLock.withLock {
            guard prepared.consume(),
                  prepared.sessionID == sessionID else {
                return .invalidProof
            }
            let base = snapshot
            guard base.generation == prepared.baseGeneration,
                  verifiedScope == prepared.verifiedScope else {
                return .invalidProof
            }
            return commitEngineBoundaryOutcome(
                prepared.outcome,
                direction: prepared.direction,
                base: base
            )
        }
    }

    /// Returns the immutable prepared candidate without advancing the session.
    /// UIKit maps this value off-main, then consumes it only from the winning
    /// atomic transaction authorization.
    func inspectPreparedVerifiedLocalBoundary(
        _ prepared: ChatTimelinePreparedVerifiedBoundaryPage
    ) -> ChatVirtualTimelineBoundaryOutcome<ChatTimelineSnapshot> {
        operationLock.withLock {
            guard prepared.isAvailable,
                  prepared.sessionID == sessionID else {
                return .invalidProof
            }
            let base = snapshot
            guard base.generation == prepared.baseGeneration,
                  verifiedScope == prepared.verifiedScope else {
                return .invalidProof
            }
            return prepared.outcome
        }
    }

    @discardableResult
    func prepareVerifiedLocalTarget(
        primary: String?,
        archiveCursor: ArchiveCursor,
        contextBefore: Int = ArchivePageSizing.anchorBefore,
        contextAfter: Int = ArchivePageSizing.anchorAfter,
        expectedGeneration: UInt64,
        completion: @escaping (ChatTimelineVerifiedTargetPreparationResult) -> Void
    ) -> ChatTimelineVerifiedTargetPreparationDisposition {
        let captured = operationLock.withLock { () -> (
            ChatTimelineSessionSnapshot,
            ChatTimelineVerifiedScope
        )? in
            let current = snapshot
            guard current.generation == expectedGeneration,
                  let scope = verifiedScope else {
                return nil
            }
            return (current, scope)
        }
        guard let captured else { return .rejectedStale }

        verifiedBoundaryPreparationQueue.async { [weak self] in
            guard let self else { return }
            var engine = ChatVirtualTimelineEngine(
                provider: self.store,
                pageSize: self.pageSize,
                state: captured.0.state,
                verifiedScope: captured.1
            )
            let outcome = engine.openAround(
                primary: primary,
                archiveCursor: archiveCursor,
                before: contextBefore,
                after: contextAfter
            )
            let isCurrent = self.operationLock.withLock {
                self.snapshot.generation == captured.0.generation &&
                    self.verifiedScope == captured.1
            }
            let result: ChatTimelineVerifiedTargetPreparationResult
            if isCurrent {
                result = .prepared(ChatTimelinePreparedVerifiedLocalTarget(
                    sessionID: self.sessionID,
                    baseGeneration: captured.0.generation,
                    verifiedScope: captured.1,
                    outcome: outcome
                ))
            } else {
                result = .stale
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
        return .started
    }

    func inspectPreparedVerifiedLocalTarget(
        _ prepared: ChatTimelinePreparedVerifiedLocalTarget
    ) -> ChatVirtualTimelineTargetOutcome<ChatTimelineSnapshot> {
        operationLock.withLock {
            guard prepared.isAvailable,
                  prepared.sessionID == sessionID,
                  snapshot.generation == prepared.baseGeneration,
                  verifiedScope == prepared.verifiedScope else {
                return .invalidProof
            }
            return prepared.outcome
        }
    }

    func commitPreparedVerifiedLocalTarget(
        _ prepared: ChatTimelinePreparedVerifiedLocalTarget
    ) -> ChatVirtualTimelineTargetOutcome<ChatTimelineSessionSnapshot> {
        operationLock.withLock {
            guard prepared.consume(),
                  prepared.sessionID == sessionID else {
                return .invalidProof
            }
            let base = snapshot
            guard base.generation == prepared.baseGeneration,
                  verifiedScope == prepared.verifiedScope else {
                return .invalidProof
            }
            switch prepared.outcome {
            case .local(let candidate):
                return .local(publish(
                    items: candidate.items,
                    state: candidate.state,
                    anchorRestore: candidate.anchorRestore,
                    readBoundary: base.readBoundary,
                    unreadMetadata: base.unreadMetadata
                ))
            case .needsArchiveTarget(let cursor):
                return .needsArchiveTarget(cursor)
            case .invalidProof:
                return .invalidProof
            }
        }
    }

    private func prepareVerifiedWindowCandidate(
        primaryIDs: [String],
        scope: ChatTimelineVerifiedScope,
        requestedDirection: ChatHistoryPageDirection?
    ) -> ChatTimelineSnapshot? {
        let base = snapshot
        let currentScope = verifiedScope
        guard currentScope.map({
            scope.coverageGeneration >= $0.coverageGeneration
        }) ?? true else {
            return nil
        }

        let direction: ChatHistoryPageDirection?
        if let requestedDirection,
           let currentScope {
            guard scope.canExtend(
                currentScope,
                direction: requestedDirection
            ) else {
                return nil
            }
            direction = requestedDirection
        } else {
            direction = nil
        }
        var engine = ChatVirtualTimelineEngine(
            provider: store,
            pageSize: pageSize,
            state: base.state,
            verifiedScope: currentScope ?? scope
        )
        let items = store.items(primaryKeys: primaryIDs)
        guard let candidate = engine.installVerified(
            items: items,
            expectedPrimaryIDs: primaryIDs,
            direction: direction,
            scope: scope
        ) else {
            return nil
        }
        // The store may finish materializing the live proof after a generic
        // resident observation has already published a newer frozen value.
        // Preserve that session-linearized value for rows which were already
        // verified. The one exception is a provisional outgoing row: its
        // receipt-backed Realm value must replace the pre-receipt overlay.
        let currentVerifiedByPrimary: [String: MessageStorageItem] = Dictionary(
            uniqueKeysWithValues: base.items.compactMap { item in
                guard !provisionalLocalOutgoingPrimaryIDs.contains(
                    item.primary
                ), currentScope?.contains(item) == true else {
                    return nil
                }
                return (item.primary, item)
            }
        )
        let verifiedCandidateItems = candidate.items.map {
            currentVerifiedByPrimary[$0.primary] ?? $0
        }
        let provisional = base.items.filter {
            provisionalLocalOutgoingPrimaryIDs.contains($0.primary)
        }
        let merged = presentationItemsByAttachingProvisionalOutgoing(
            to: verifiedCandidateItems,
            additionally: provisional,
            direction: direction,
            hardLimit: base.residentHardLimit,
            promotingPrimaryIDs: Set(primaryIDs)
        )
        return ChatTimelineSnapshot(
            items: merged.items,
            state: stateByReplacingResidentItems(
                merged.verifiedItems,
                in: candidate.state,
                retentionDirection: direction
            ),
            anchorRestore: candidate.anchorRestore
        )
    }

    private func finishVerifiedBoundaryPreparation(
        key: ChatTimelineVerifiedBoundaryPreparationKey,
        outcome: ChatVirtualTimelineBoundaryOutcome<ChatTimelineSnapshot>
    ) {
        let result = lock.withLock { () -> (
            [(ChatTimelineVerifiedBoundaryPreparationResult) -> Void],
            Bool
        )? in
            guard let active = activeVerifiedBoundaryPreparation,
                  active.key == key else {
                return nil
            }
            activeVerifiedBoundaryPreparation = nil
            let isCurrent = storedSnapshot.generation == key.baseGeneration &&
                storedVerifiedScope == key.verifiedScope
            return (active.completions, isCurrent)
        }
        guard let result else { return }

        let preparedOutcome = operationLock.withLock {
            boundaryOutcomeByAttachingProvisionalOutgoing(
                outcome,
                direction: key.direction,
                base: snapshot
            )
        }

        for completion in result.0 {
            let preparationResult: ChatTimelineVerifiedBoundaryPreparationResult
            if result.1 {
                preparationResult = .prepared(
                    ChatTimelinePreparedVerifiedBoundaryPage(
                        sessionID: sessionID,
                        baseGeneration: key.baseGeneration,
                        direction: key.direction,
                        verifiedScope: key.verifiedScope,
                        outcome: preparedOutcome
                    )
                )
            } else {
                preparationResult = .stale
            }
            DispatchQueue.main.async {
                completion(preparationResult)
            }
        }
    }

    private func commitEngineBoundaryOutcome(
        _ outcome: ChatVirtualTimelineBoundaryOutcome<ChatTimelineSnapshot>,
        direction: ChatHistoryPageDirection,
        base: ChatTimelineSessionSnapshot
    ) -> ChatVirtualTimelineBoundaryOutcome<ChatTimelineSessionSnapshot> {
        switch outcome {
        case .local(let candidate):
            let provisional = base.items.filter {
                provisionalLocalOutgoingPrimaryIDs.contains($0.primary)
            }
            let merged = presentationItemsByAttachingProvisionalOutgoing(
                to: candidate.items,
                additionally: provisional,
                direction: direction,
                hardLimit: base.residentHardLimit
            )
            let mergedState = stateByReplacingResidentItems(
                merged.verifiedItems,
                in: candidate.state,
                retentionDirection: direction
            )
            let committed = publish(
                items: merged.items,
                state: mergedState,
                anchorRestore: candidate.anchorRestore,
                readBoundary: base.readBoundary,
                unreadMetadata: base.unreadMetadata,
                retentionDirection: direction
            )
            return .local(committed)
        case .needsArchiveExpansion(let expansionDirection):
            return .needsArchiveExpansion(expansionDirection)
        case .endReached:
            return .endReached(base)
        case .invalidProof:
            return .invalidProof
        }
    }

    private func boundaryOutcomeByAttachingProvisionalOutgoing(
        _ outcome: ChatVirtualTimelineBoundaryOutcome<ChatTimelineSnapshot>,
        direction: ChatHistoryPageDirection,
        base: ChatTimelineSessionSnapshot
    ) -> ChatVirtualTimelineBoundaryOutcome<ChatTimelineSnapshot> {
        guard case .local(let candidate) = outcome else { return outcome }
        let provisional = base.items.filter {
            provisionalLocalOutgoingPrimaryIDs.contains($0.primary)
        }
        let merged = presentationItemsByAttachingProvisionalOutgoing(
            to: candidate.items,
            additionally: provisional,
            direction: direction,
            hardLimit: base.residentHardLimit
        )
        return .local(ChatTimelineSnapshot(
            items: merged.items,
            state: stateByReplacingResidentItems(
                merged.verifiedItems,
                in: candidate.state,
                retentionDirection: direction
            ),
            anchorRestore: candidate.anchorRestore
        ))
    }

    private static func boundaryDirection(
        for locator: ArchiveWindowLocator
    ) -> ChatHistoryPageDirection? {
        switch locator {
        case .older, .gap:
            return .older
        case .newer:
            return .newer
        case .latest, .firstUnread, .archiveID, .timestamp:
            return nil
        }
    }

    @discardableResult
    func installArchiveEngineAuthoritativeEmpty(
        freshnessToken: ArchiveFreshnessToken? = nil
    ) -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let base = snapshot
            storedAuthoritativeEmptyLiveTailAuthority = freshnessToken.flatMap {
                ChatTimelineAuthoritativeEmptyLiveTailAuthority(
                    freshnessToken: $0
                )
            }
            let state = ChatVirtualTimelineState(
                conversationKey: conversationKey,
                segments: [.liveTail],
                oldest: nil,
                newest: nil,
                residentPrimaryKeys: [],
                residentArchivedIds: [],
                isResidentAtLiveTail: true
            )
            return publish(
                items: [],
                state: state,
                anchorRestore: nil,
                readBoundary: base.readBoundary,
                unreadMetadata: base.unreadMetadata,
                verifiedScopeMutation: .replace(nil)
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
                anchorRestore: candidate.anchorRestore,
                readBoundary: current.readBoundary,
                unreadMetadata: current.unreadMetadata
            )
        }
    }

    @discardableResult
    func restorePresentationSnapshot(
        _ candidate: ChatTimelineSessionSnapshot,
        verifiedScope: ChatTimelineVerifiedScope?
    ) -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let current = snapshot
            storedAuthoritativeEmptyLiveTailAuthority =
                candidate.authoritativeEmptyLiveTailAuthority
            provisionalLocalOutgoingPrimaryIDs =
                candidate.provisionalLocalOutgoingPrimaryIDs
            return publish(
                items: candidate.items,
                state: candidate.state,
                anchorRestore: candidate.anchorRestore,
                readBoundary: current.readBoundary,
                unreadMetadata: current.unreadMetadata,
                verifiedScopeMutation: .replace(verifiedScope)
            )
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
            let refreshedItems = store.items(
                primaryKeys: base.items.map(\.primary)
            )
            return publish(
                items: refreshedItems,
                state: stateByReplacingResidentItems(refreshedItems, in: base.state),
                anchorRestore: base.anchorRestore,
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
                latestUnreadMentionArchivedId:
                    metadata.latestUnreadMentionArchivedId
            )
            return publish(
                items: base.items,
                state: base.state,
                anchorRestore: base.anchorRestore,
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
                anchorRestore: base.anchorRestore,
                readBoundary: candidate,
                unreadMetadata: base.unreadMetadata
            )
            return true
        }
    }


    @discardableResult
    private func publish(
        items: [MessageStorageItem],
        state: ChatVirtualTimelineState,
        anchorRestore: ChatTimelineAnchorRestoreCommand?,
        readBoundary: ChatTimelineReadBoundary?,
        unreadMetadata: ChatTimelineUnreadMetadata,
        residentChangeSet: ChatIncrementalResidentChangeSet? = nil,
        retentionDirection: ChatHistoryPageDirection? = nil,
        verifiedScopeMutation: ChatTimelineVerifiedScopeMutation = .unchanged,
        snapshotCause: ChatTimelineSessionSnapshotCause? = nil
    ) -> ChatTimelineSessionSnapshot {
        let hardLimit = ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize)
        let immutableItems = items.map(Self.frozen)
        let ordered = ChatTimelineOrdering.deduplicatedChronological(immutableItems)
        let boundedItems: [MessageStorageItem]
        if ordered.count > hardLimit {
            switch retentionDirection {
            case .older:
                boundedItems = Array(ordered.prefix(hardLimit))
            case .newer, .none:
                boundedItems = Array(ordered.suffix(hardLimit))
            }
        } else {
            boundedItems = ordered
        }
        let boundedState = boundedItems.count == ordered.count
            ? state
            : stateByReplacingResidentItems(
                boundedItems,
                in: state,
                retentionDirection: retentionDirection
            )

        let result: (ChatTimelineSessionSnapshot, SnapshotHandler?) = lock.withLock {
            let previous = storedSnapshot
            provisionalLocalOutgoingPrimaryIDs.formIntersection(
                Set(boundedItems.map(\.primary))
            )
            provisionalLocalOutgoingPrimaryIDs.subtract(
                Set(boundedState.residentPrimaryKeys)
            )
            let next = ChatTimelineSessionSnapshot(
                generation: previous.generation &+ 1,
                cause: snapshotCause ?? (
                    storeChangeDepth > 0 ? .storeChange : .command
                ),
                items: boundedItems,
                state: boundedState,
                anchorRestore: anchorRestore,
                pageSize: pageSize,
                residentIndex: ChatTimelineResidentIndex(items: boundedItems),
                readBoundary: readBoundary,
                unreadMetadata: unreadMetadata,
                residentHardLimit: hardLimit,
                residentChangeSet: residentChangeSet,
                authoritativeEmptyLiveTailAuthority:
                    storedAuthoritativeEmptyLiveTailAuthority,
                provisionalLocalOutgoingPrimaryIDs:
                    provisionalLocalOutgoingPrimaryIDs
            )
            storedSnapshot = next
            switch verifiedScopeMutation {
            case .unchanged:
                break
            case .replace(let scope):
                storedVerifiedScope = scope
            }
            return (next, storedSnapshotHandler)
        }
        let installedObservation = lock.withLock { observation }
        installedObservation?.replaceResidentItems(result.0.items)
        result.1?(result.0)
        return result.0
    }

    private func presentationItemsByAttachingProvisionalOutgoing(
        to verifiedAndResidentItems: [MessageStorageItem],
        additionally: [MessageStorageItem] = [],
        direction: ChatHistoryPageDirection?,
        hardLimit: Int,
        promotingPrimaryIDs: Set<String> = []
    ) -> (
        items: [MessageStorageItem],
        verifiedItems: [MessageStorageItem],
        trimmedPrimaries: [String]
    ) {
        // A verified-window candidate is rematerialized from Realm and must win
        // over an older frozen provisional value for the same primary. This is
        // important when the receipt proof arrives before Realm observation.
        let candidatePromotionPrimaries = Set(
            verifiedAndResidentItems.lazy
                .filter { promotingPrimaryIDs.contains($0.primary) }
                .map(\.primary)
        )
        let nonSupersededAdditionalItems = additionally.filter {
            !candidatePromotionPrimaries.contains($0.primary)
        }
        let ordered = ChatTimelineOrdering.deduplicatedChronological(
            verifiedAndResidentItems + nonSupersededAdditionalItems
        )
        let provisional = ordered.filter { item in
            provisionalLocalOutgoingPrimaryIDs.contains(item.primary) &&
                !candidatePromotionPrimaries.contains(item.primary)
        }
        let verified = ordered.filter { item in
            !provisional.contains(where: { $0.primary == item.primary })
        }
        let boundedProvisional = provisional.count > hardLimit
            ? Array(provisional.suffix(hardLimit))
            : provisional
        let verifiedLimit = max(0, hardLimit - boundedProvisional.count)
        let boundedVerified: [MessageStorageItem]
        if verified.count > verifiedLimit {
            switch direction {
            case .older:
                boundedVerified = Array(verified.prefix(verifiedLimit))
            case .newer, .none:
                boundedVerified = Array(verified.suffix(verifiedLimit))
            }
        } else {
            boundedVerified = verified
        }
        let items = ChatTimelineOrdering.deduplicatedChronological(
            boundedVerified + boundedProvisional
        )
        let retained = Set(items.map(\.primary))
        return (
            items,
            boundedVerified,
            ordered.compactMap {
                retained.contains($0.primary) ? nil : $0.primary
            }
        )
    }

    private func stateByReplacingResidentItems(
        _ items: [MessageStorageItem],
        in state: ChatVirtualTimelineState,
        retentionDirection: ChatHistoryPageDirection? = nil
    ) -> ChatVirtualTimelineState {
        let alreadyProvedResidentPrimaryIDs = Set(state.residentPrimaryKeys)
        let ordered = ChatTimelineOrdering.deduplicatedChronological(items)
            .filter { item in
                !provisionalLocalOutgoingPrimaryIDs.contains(item.primary) ||
                    alreadyProvedResidentPrimaryIDs.contains(item.primary)
            }
        let hardLimit = ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize)
        let bounded: [MessageStorageItem]
        if ordered.count > hardLimit {
            switch retentionDirection {
            case .older:
                bounded = Array(ordered.prefix(hardLimit))
            case .newer, .none:
                bounded = Array(ordered.suffix(hardLimit))
            }
        } else {
            bounded = ordered
        }
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
            isResidentAtLiveTail: state.isResidentAtLiveTail
        )
    }

    private func handleStoreChange(_ change: ChatTimelineStoreChange) {
        lock.withLock { storeChangeDepth += 1 }
        defer { lock.withLock { storeChangeDepth -= 1 } }
        switch change {
        case .latestChanged:
            _ = refreshResidentItems()
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
                hardLimit: base.residentHardLimit
            )
            guard bounded != base.unreadMetadata else { return base }
            return publish(
                items: base.items,
                state: base.state,
                anchorRestore: base.anchorRestore,
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
            let base = snapshot
            let authorizedBatch = authorizedIncrementalBatch(batch)
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
                    hardLimit: base.residentHardLimit
                )
            } else {
                unreadMetadata = base.unreadMetadata
            }
            guard !result.changeSet.isEmpty || unreadMetadata != base.unreadMetadata else {
                return base
            }
            return publish(
                items: result.items,
                state: stateByReplacingResidentItems(result.items, in: base.state),
                anchorRestore: base.anchorRestore,
                readBoundary: base.readBoundary,
                unreadMetadata: unreadMetadata,
                residentChangeSet: result.changeSet
            )
        }
    }

    /// `operationLock` is held by the caller. Structural publication and its
    /// synchronous `replaceResidentItems` therefore linearize either before
    /// this authorization (stale resident revisions are removed) or after the
    /// accepted store change. Revisions without resident provenance may still
    /// update or delete an identity already present in the resident index, but
    /// they cannot admit a new primary without a verified archive/live receipt.
    private func authorizedIncrementalBatch(
        _ batch: ChatIncrementalMessageMutationBatch<MessageStorageItem>
    ) -> ChatIncrementalMessageMutationBatch<MessageStorageItem> {
        let currentSnapshot = snapshot
        let residentIndex = currentSnapshot.residentIndex
        let currentScope = verifiedScope
        let installedObservation = lock.withLock { observation }
        let authorizedMutations = batch.mutations.filter { mutation in
            guard let index = residentIndex.index(
                primary: mutation.identity.primary,
                archivedId: mutation.identity.archivedId,
                messageId: mutation.identity.messageId
            ), currentSnapshot.items.indices.contains(index) else {
                // Generic Realm observations have no archive proof for a new
                // primary. They may reconcile a resident alias/update/delete,
                // but only a verified archive receipt or explicit live-edge
                // admission is allowed to grow the visible timeline.
                return false
            }
            let resident = currentSnapshot.items[index]
            switch mutation.operation {
            case .delete:
                // A deletion carries no payload from which to re-check the
                // conversation. Require the exact admitted primary rather than
                // accepting a cross-conversation message/archive alias.
                guard mutation.identity.primary == resident.primary else {
                    return false
                }
            case .upsert(let payload):
                guard payload.primary == resident.primary,
                      payload.owner == conversationKey.owner,
                      payload.opponent == conversationKey.jid,
                      payload.conversationType ==
                        conversationKey.conversationType else {
                    return false
                }
                if payload.isDeleted || payload.isLocallyHiddenByReport {
                    break
                }
                if provisionalLocalOutgoingPrimaryIDs.contains(
                    resident.primary
                ) {
                    guard payload.outgoing else { return false }
                } else {
                    // A generic observation may refresh only a row that is
                    // still inside the current archive proof. It cannot turn a
                    // verified resident into an empty, malformed or out-of-scope
                    // paging boundary.
                    guard currentScope?.contains(payload) == true else {
                        return false
                    }
                }
            }
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
        hardLimit: Int
    ) -> ChatTimelineUnreadMetadata {
        ChatTimelineUnreadMetadata(
            unreadCount: max(0, metadata.unreadCount),
            mentions: Array(metadata.mentions.prefix(hardLimit)),
            candidateCount: min(max(0, metadata.candidateCount), hardLimit),
            latestUnreadMentionArchivedId:
                metadata.latestUnreadMentionArchivedId
        )
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

    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem? {
        withProvider(default: nil) { provider in
            provider.firstIncoming(afterArchiveBoundaryId: boundaryArchivedId).map(Self.frozen)
        }
    }

    func unreadMetadata(limit: Int) -> ChatTimelineUnreadMetadata {
        readUnreadMetadata(limit: limit)
    }


    private func readUnreadMetadata(
        limit: Int,
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
            guard conversationType == .group else {
                if recordsDiagnostics {
                    recordSupplemental(operation: "unread", candidateCount: 1)
                }
                return ChatTimelineUnreadMetadata(
                    unreadCount: unreadCount,
                    mentions: [],
                    candidateCount: 1,
                    latestUnreadMentionArchivedId:
                        latestUnreadMentionArchivedId
                )
            }

            let boundedLimit = min(
                limit,
                ArchivePageSizing.initial
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
            var baselineByPrimary:
                [String: ChatTimelineObservedMessageFingerprint] = [:]
            for message in baseline.items where !message.isDeleted {
                baselineByPrimary[message.primary] =
                    ChatTimelineObservedMessageFingerprint(message: message)
            }
            var catchUpCount = 0
            // This query contains only exact, already-admitted resident keys.
            // A missing key therefore proves a tombstone or hard deletion even
            // when unrelated LastChats initial catch-up is non-authoritative.
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
            for (primary, current) in currentByPrimary {
                guard let previous = baselineByPrimary[primary],
                      previous != current.1 else {
                    continue
                }
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
