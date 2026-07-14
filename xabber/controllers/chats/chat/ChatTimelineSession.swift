import Foundation
import RealmSwift
import CocoaLumberjack

enum ChatTimelineStoreChange {
    case latestChanged
    case residentChanged
    case unreadChanged
    case incremental(
        ChatIncrementalMessageMutationBatch<MessageStorageItem>,
        refreshUnread: Bool
    )
}

protocol ChatTimelineStoreObservation: AnyObject {
    func replaceResidentPrimaryKeys(_ primaryKeys: [String])
    func invalidate()
}

struct ChatTimelineStoreDiagnosticsSnapshot: Equatable {
    static let empty = ChatTimelineStoreDiagnosticsSnapshot(
        queryCount: 0,
        fullScanCount: 0,
        maxCandidateCount: 0,
        operationCandidateCounts: [:]
    )

    let queryCount: Int
    let fullScanCount: Int
    let maxCandidateCount: Int
    let operationCandidateCounts: [String: Int]

    func recording(operation: String, candidateCount: Int) -> ChatTimelineStoreDiagnosticsSnapshot {
        let boundedCandidateCount = max(0, candidateCount)
        var nextOperationCandidateCounts = operationCandidateCounts
        nextOperationCandidateCounts[operation] = max(
            boundedCandidateCount,
            nextOperationCandidateCounts[operation] ?? 0
        )
        return ChatTimelineStoreDiagnosticsSnapshot(
            queryCount: queryCount + 1,
            fullScanCount: fullScanCount,
            maxCandidateCount: max(maxCandidateCount, boundedCandidateCount),
            operationCandidateCounts: nextOperationCandidateCounts
        )
    }
}

struct ChatTimelineUnreadMetadata: Equatable {
    static let empty = ChatTimelineUnreadMetadata(
        unreadCount: 0,
        mentions: [],
        candidateCount: 0
    )

    let unreadCount: Int
    let mentions: [ChatUnreadMentionItem]
    let candidateCount: Int
}

protocol ChatTimelineSessionStore: ChatTimelinePageProviding, AnyObject {
    var diagnosticsSnapshot: ChatTimelineStoreDiagnosticsSnapshot { get }

    func unreadMetadata(limit: Int) -> ChatTimelineUnreadMetadata
    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem?
    func observe(
        residentPrimaryKeys: [String],
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
}

struct ChatTimelineInitialFramePreparationMetrics: Equatable {
    let storeQueryCount: Int
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

final class ChatTimelinePreparedInitialFrame {
    let target: ChatTimelineInitialFrameTarget
    let conversationKey: ChatTimelineConversationKey
    let baseGeneration: UInt64
    let snapshot: ChatTimelineSnapshot
    let alignment: ChatTimelineInitialFrameAlignment
    let metrics: ChatTimelineInitialFramePreparationMetrics
    let unreadMetadata: ChatTimelineUnreadMetadata

    fileprivate let sessionID: UUID
    private let consumeLock = NSLock()
    private var consumed = false

    fileprivate init(
        sessionID: UUID,
        target: ChatTimelineInitialFrameTarget,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64,
        snapshot: ChatTimelineSnapshot,
        alignment: ChatTimelineInitialFrameAlignment,
        metrics: ChatTimelineInitialFramePreparationMetrics,
        unreadMetadata: ChatTimelineUnreadMetadata
    ) {
        self.sessionID = sessionID
        self.target = target
        self.conversationKey = conversationKey
        self.baseGeneration = baseGeneration
        self.snapshot = snapshot
        self.alignment = alignment
        self.metrics = metrics
        self.unreadMetadata = unreadMetadata
    }

    fileprivate func consumeOnce() -> Bool {
        consumeLock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
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

    init(upstream: ChatTimelinePageProviding, residentItems: [MessageStorageItem]) {
        self.upstream = upstream
        self.itemsByPrimary = Dictionary(
            residentItems.map { ($0.primary, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    func latest(limit: Int) -> [MessageStorageItem] {
        cache(upstream.latest(limit: limit))
    }

    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        cache(upstream.older(before: boundary, limit: limit))
    }

    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        cache(upstream.newer(after: boundary, limit: limit))
    }

    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem] {
        cache(upstream.around(anchor: anchor, before: before, after: after))
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
    private var archiveState: ChatArchiveStateSnapshot
    private var storedSnapshot: ChatTimelineSessionSnapshot
    private var observation: ChatTimelineStoreObservation?
    private var storedSnapshotHandler: SnapshotHandler?
    private var storeChangeDepth = 0
    private var incrementalResidentReducer = ChatIncrementalResidentReducer()

    var snapshot: ChatTimelineSessionSnapshot {
        lock.withLock { storedSnapshot }
    }

    var onSnapshot: SnapshotHandler? {
        get { lock.withLock { storedSnapshotHandler } }
        set { lock.withLock { storedSnapshotHandler = newValue } }
    }

    init(
        store: ChatTimelineSessionStore,
        pageSize: Int,
        conversationKey: ChatTimelineConversationKey,
        archiveState: ChatArchiveStateSnapshot
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
        self.observation = store.observe(residentPrimaryKeys: []) { [weak self] change in
            self?.handleStoreChange(change)
        }
    }

    deinit {
        cancelInitialFramePreparations()
        cancelLocalPagePreparations()
        observation?.invalidate()
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
        completion: @escaping (ChatTimelineInitialFramePreparationResult) -> Void
    ) -> ChatTimelineInitialFrameLoadDisposition {
        let base = snapshot
        guard base.generation == expectedGeneration else {
            return .rejectedStale
        }

        let epoch = initialFramePreparationLock.withLock { () -> UInt64 in
            initialFramePreparationEpoch &+= 1
            return initialFramePreparationEpoch
        }
        let boundedLimit = min(
            max(1, limit),
            ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize)
        )

        localPagePreparationQueue.async { [weak self] in
            guard let self else { return }
            let result = self.prepareInitialFrameResult(
                target: target,
                limit: boundedLimit,
                base: base
            )
            let isCurrent = self.lock.withLock {
                self.storedSnapshot.generation == expectedGeneration
            }
            let isActive = self.initialFramePreparationLock.withLock {
                self.initialFramePreparationEpoch == epoch
            }
            let deliveredResult = isCurrent && isActive ? result : .stale
            DispatchQueue.main.async {
                completion(deliveredResult)
            }
        }
        return .started
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
                  preparedFrame.consumeOnce() else {
                return nil
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
                unreadMetadata: preparedFrame.unreadMetadata
            )
        }
    }

    func cancelInitialFramePreparations() {
        initialFramePreparationLock.withLock {
            initialFramePreparationEpoch &+= 1
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

    @discardableResult
    func finishRemoteLoad(
        queryId: String,
        refetchDirection: ChatHistoryPageDirection? = nil
    ) -> ChatTimelineSessionSnapshot {
        mutateTimeline { engine in
            engine.finishRemoteLoad(queryId: queryId, refetchDirection: refetchDirection)
        }
    }

    @discardableResult
    func abortRemoteLoad(queryId: String) -> ChatTimelineSessionSnapshot {
        mutateTimeline { engine in
            engine.abortRemoteLoad(queryId: queryId)
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

    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem? {
        store.firstIncoming(afterArchiveBoundaryId: boundaryArchivedId)
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
                candidateCount: min(max(0, metadata.candidateCount), hardLimit)
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
                unreadMetadata: base.unreadMetadata
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
            let isCurrent = self.lock.withLock {
                self.storedSnapshot.generation == expectedGeneration
            }
            let isActive = self.localPagePreparationLock.withLock { () -> Bool in
                let epochMatches = self.localPagePreparationEpoch == epochAndStarted.0
                let keyWasActive = self.activeLocalPagePreparationKeys.remove(key) != nil
                return epochMatches && keyWasActive
            }
            let result: ChatTimelineLocalPagePreparationResult
            if isCurrent, isActive {
                result = .prepared(
                    ChatTimelinePreparedLocalPage(
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
                )
            } else {
                result = .stale
            }
            DispatchQueue.main.async {
                completion(result)
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
        base: ChatTimelineSessionSnapshot
    ) -> ChatTimelineInitialFramePreparationResult {
        let diagnosticsBefore = store.diagnosticsSnapshot
        let preparedOnMainThread = Thread.isMainThread
        let resolvedMessage: MessageStorageItem?
        switch target {
        case .latest:
            resolvedMessage = nil
        case .message(let anchor):
            resolvedMessage = store.message(
                primary: anchor.primary,
                archivedId: anchor.archivedId,
                messageId: anchor.messageId
            )
        case .firstIncomingAfterBoundary(let boundaryArchivedId):
            resolvedMessage = store.firstIncoming(afterArchiveBoundaryId: boundaryArchivedId)
        }

        if target != .latest, resolvedMessage == nil {
            return .blocked(.targetMissing(target))
        }

        let seededItems = base.items + (resolvedMessage.map { [$0] } ?? [])
        let preparationProvider = ChatTimelineLocalPagePreparationProvider(
            upstream: store,
            residentItems: seededItems
        )
        var engine = ChatVirtualTimelineEngine(
            provider: preparationProvider,
            pageSize: limit,
            state: base.state.normalized(
                owner: conversationKey.owner,
                jid: conversationKey.jid,
                conversationType: conversationKey.conversationType
            ),
            archiveState: lock.withLock { archiveState }
        )

        let snapshot: ChatTimelineSnapshot
        let alignment: ChatTimelineInitialFrameAlignment
        switch target {
        case .latest:
            snapshot = engine.openLatest(limit: limit)
            alignment = .bottom
        case .message, .firstIncomingAfterBoundary:
            guard let resolvedMessage else {
                return .blocked(.targetMissing(target))
            }
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
                archivedId: RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                    resolvedMessage.archivedId
                )
            )
        }

        let frozenSnapshot = ChatTimelineSnapshot(
            items: snapshot.items.map(Self.frozen),
            state: snapshot.state,
            loadingState: snapshot.loadingState,
            loadDecision: snapshot.loadDecision,
            anchorRestore: snapshot.anchorRestore,
            localOlderCandidateCount: snapshot.localOlderCandidateCount,
            pageSize: snapshot.pageSize,
            shortLocalRemainderRemoteFirst: snapshot.shortLocalRemainderRemoteFirst
        )
        let unreadMetadata = store.unreadMetadata(
            limit: ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize)
        )
        let diagnosticsAfter = store.diagnosticsSnapshot
        let metrics = ChatTimelineInitialFramePreparationMetrics(
            storeQueryCount: max(0, diagnosticsAfter.queryCount - diagnosticsBefore.queryCount),
            fullScanCount: max(0, diagnosticsAfter.fullScanCount - diagnosticsBefore.fullScanCount),
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
                unreadMetadata: unreadMetadata
            )
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
        residentChangeSet: ChatIncrementalResidentChangeSet? = nil
    ) -> ChatTimelineSessionSnapshot {
        let hardLimit = ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize)
        let immutableItems = items.map(Self.frozen)
        let ordered = ChatTimelineOrdering.deduplicatedChronological(immutableItems)
        let boundedItems = ordered.count > hardLimit ? Array(ordered.suffix(hardLimit)) : ordered
        let boundedState = boundedItems.count == ordered.count
            ? state
            : stateByReplacingResidentItems(boundedItems, in: state)

        let result: (ChatTimelineSessionSnapshot, SnapshotHandler?) = lock.withLock {
            let next = ChatTimelineSessionSnapshot(
                generation: storedSnapshot.generation &+ 1,
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
            storedSnapshot = next
            return (next, storedSnapshotHandler)
        }
        observation?.replaceResidentPrimaryKeys(result.0.state.residentPrimaryKeys)
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
        case .incremental(let batch, let refreshUnread):
            _ = applyIncrementalStoreChange(batch, refreshUnread: refreshUnread)
        }
    }

    private func applyIncrementalStoreChange(
        _ batch: ChatIncrementalMessageMutationBatch<MessageStorageItem>,
        refreshUnread: Bool
    ) -> ChatTimelineSessionSnapshot {
        operationLock.withLock {
            let base = snapshot
            let result = incrementalResidentReducer.apply(
                currentItems: base.items,
                mutations: batch.mutations,
                isResidentAtLiveTail: base.state.isResidentAtLiveTail,
                hardLimit: base.residentHardLimit
            )
            let unreadMetadata: ChatTimelineUnreadMetadata
            if refreshUnread {
                let metadata = store.unreadMetadata(limit: base.residentHardLimit)
                unreadMetadata = ChatTimelineUnreadMetadata(
                    unreadCount: max(0, metadata.unreadCount),
                    mentions: Array(metadata.mentions.prefix(base.residentHardLimit)),
                    candidateCount: min(max(0, metadata.candidateCount), base.residentHardLimit)
                )
            } else {
                unreadMetadata = base.unreadMetadata
            }
            guard !result.changeSet.isEmpty || refreshUnread else {
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

    private static func frozen(_ item: MessageStorageItem) -> MessageStorageItem {
        item.realm == nil || item.isFrozen ? item : item.freeze()
    }
}

final class RealmChatTimelineSessionStore: ChatTimelineSessionStore {
    private let owner: String
    private let jid: String
    private let conversationType: ClientSynchronizationManager.ConversationType
    private let providerDiagnostics = ChatLocalHistoryPageProviderDiagnostics()
    private let diagnosticsLock = NSLock()
    private var supplementalDiagnostics = ChatTimelineStoreDiagnosticsSnapshot.empty

    var diagnosticsSnapshot: ChatTimelineStoreDiagnosticsSnapshot {
        let supplemental = diagnosticsLock.withLock { supplementalDiagnostics }
        let providerOperationCounts = providerDiagnostics.records.reduce(into: [String: Int]()) {
            $0[$1.operation] = max($0[$1.operation] ?? 0, $1.candidateCount)
        }
        let operationCandidateCounts = supplemental.operationCandidateCounts.merging(
            providerOperationCounts,
            uniquingKeysWith: max
        )
        return ChatTimelineStoreDiagnosticsSnapshot(
            queryCount: providerDiagnostics.queryCount + supplemental.queryCount,
            fullScanCount: providerDiagnostics.fullScanCount + supplemental.fullScanCount,
            maxCandidateCount: max(providerDiagnostics.maxCandidateCount, supplemental.maxCandidateCount),
            operationCandidateCounts: operationCandidateCounts
        )
    }

    init(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) {
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
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
        guard limit > 0 else { return .empty }
        do {
            let realm = try WRealm.safe()
            let chatPrimary = LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
            let unreadCount = max(
                0,
                realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: chatPrimary)?.unread ?? 0
            )
            guard conversationType == .group else {
                recordSupplemental(operation: "unread", candidateCount: 1)
                return ChatTimelineUnreadMetadata(
                    unreadCount: unreadCount,
                    mentions: [],
                    candidateCount: 1
                )
            }

            let notifications = Array(
                realm.objects(NotificationStorageItem.self)
                    .filter(
                        "owner == %@ AND category_ == %@ AND isRead == false AND associatedJid == %@",
                        owner,
                        XMPPNotificationsManager.Category.mention.rawValue,
                        jid
                    )
                    .sorted(byKeyPath: "date", ascending: true)
                    .prefix(limit)
            )
            let currentMemberId = MentionNotificationSync.currentGroupMemberId(
                owner: owner,
                groupchatJid: jid,
                in: realm
            )
            let provider = makeProvider(realm: realm)
            let mentions = ChatUnreadMentionIndexPolicy.rebuild(
                from: notifications,
                resolveMessagePrimary: { notification in
                    provider.message(
                        primary: nil,
                        archivedId: notification.sourceArchivedId,
                        messageId: notification.sourceMessageId
                    )?.primary
                },
                chatPrimary: chatPrimary,
                currentMemberId: currentMemberId,
                groupchatJid: jid
            )
            recordSupplemental(operation: "unreadMentions", candidateCount: notifications.count)
            return ChatTimelineUnreadMetadata(
                unreadCount: unreadCount,
                mentions: mentions,
                candidateCount: notifications.count
            )
        } catch {
            DDLogDebug("RealmChatTimelineSessionStore.unreadMetadata: \(error.localizedDescription)")
            return .empty
        }
    }

    func observe(
        residentPrimaryKeys: [String],
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) -> ChatTimelineStoreObservation {
        RealmChatTimelineStoreObservation(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            residentPrimaryKeys: residentPrimaryKeys,
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

    private func makeProvider(realm: Realm) -> ChatLocalHistoryPageProvider {
        ChatLocalHistoryPageProvider(
            realm: realm,
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            diagnostics: providerDiagnostics
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

    private static func frozen(_ item: MessageStorageItem) -> MessageStorageItem {
        item.realm == nil || item.isFrozen ? item : item.freeze()
    }
}

private final class RealmChatTimelineStoreObservation: ChatTimelineStoreObservation {
    private let owner: String
    private let jid: String
    private let conversationType: ClientSynchronizationManager.ConversationType
    private let onChange: (ChatTimelineStoreChange) -> Void
    private let lock = NSLock()
    private var invalidated = false
    private var requestedResidentPrimaryKeys: [String]
    private var lastChatsToken: NotificationToken?
    private var residentToken: NotificationToken?
    private var lastObservedLatestIdentity: ChatIncrementalMessageIdentity?
    private var residentIdentitiesByIndex: [ChatIncrementalMessageIdentity] = []
    private var mutationAccumulator = ChatIncrementalMessageMutationAccumulator<MessageStorageItem>()
    private var mutationFlushScheduled = false
    private var pendingUnreadRefresh = false
    private var mutationRevision: UInt64 = 0

    init(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        residentPrimaryKeys: [String],
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) {
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
        self.requestedResidentPrimaryKeys = residentPrimaryKeys
        self.onChange = onChange
        performOnMain { [weak self] in
            self?.installLastChatsObservation()
            self?.installResidentObservation()
        }
    }

    deinit {
        invalidate()
    }

    func replaceResidentPrimaryKeys(_ primaryKeys: [String]) {
        let deduplicatedKeys = Array(Set(primaryKeys)).sorted()
        let shouldReplace = lock.withLock { () -> Bool in
            guard !invalidated, requestedResidentPrimaryKeys != deduplicatedKeys else {
                return false
            }
            requestedResidentPrimaryKeys = deduplicatedKeys
            return true
        }
        guard shouldReplace else { return }
        performOnMain { [weak self] in
            self?.installResidentObservation()
        }
    }

    func invalidate() {
        let tokens = lock.withLock { () -> (NotificationToken?, NotificationToken?) in
            guard !invalidated else { return (nil, nil) }
            invalidated = true
            let tokens = (lastChatsToken, residentToken)
            lastChatsToken = nil
            residentToken = nil
            return tokens
        }
        tokens.0?.invalidate()
        tokens.1?.invalidate()
    }

    private func installLastChatsObservation() {
        guard !lock.withLock({ invalidated }) else { return }
        do {
            let realm = try WRealm.safe()
            let primary = LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
            let token = realm.objects(LastChatsStorageItem.self)
                .filter("primary == %@", primary)
                .observe { [weak self] change in
                    guard let self else { return }
                    switch change {
                    case .initial(let collection):
                        self.lastObservedLatestIdentity = collection.first?.lastMessage.map(
                            ChatIncrementalMessageIdentity.init(message:)
                        )
                    case .update(let collection, _, _, _):
                        let currentMessage = collection.first?.lastMessage
                        let currentIdentity = currentMessage.map(ChatIncrementalMessageIdentity.init(message:))
                        let action = ChatIncrementalLatestObservationPolicy.action(
                            previous: self.lastObservedLatestIdentity,
                            current: currentIdentity
                        )
                        switch action {
                        case .upsert:
                            guard let currentMessage else { break }
                            let frozen = currentMessage.isFrozen ? currentMessage : currentMessage.freeze()
                            self.enqueueMutation(
                                .upsert(
                                    identity: ChatIncrementalMessageIdentity(message: frozen),
                                    revision: self.nextMutationRevision(),
                                    payload: frozen
                                ),
                                refreshUnread: true
                            )
                        case .delete:
                            guard let previousIdentity = self.lastObservedLatestIdentity else { break }
                            self.enqueueMutation(
                                .delete(
                                    identity: previousIdentity,
                                    revision: self.nextMutationRevision()
                                ),
                                refreshUnread: true
                            )
                        case .metadataOnly:
                            self.pendingUnreadRefresh = true
                            self.scheduleMutationFlush()
                        }
                        self.lastObservedLatestIdentity = currentIdentity
                    case .error(let error):
                        DDLogDebug("RealmChatTimelineStoreObservation.lastChats change: \(error.localizedDescription)")
                    }
                }
            lock.withLock {
                if invalidated {
                    token.invalidate()
                } else {
                    lastChatsToken?.invalidate()
                    lastChatsToken = token
                }
            }
        } catch {
            DDLogDebug("RealmChatTimelineStoreObservation.lastChats: \(error.localizedDescription)")
        }
    }

    private func installResidentObservation() {
        let keys = lock.withLock { requestedResidentPrimaryKeys }
        lock.withLock {
            residentToken?.invalidate()
            residentToken = nil
        }
        guard !keys.isEmpty, !lock.withLock({ invalidated }) else { return }
        do {
            let realm = try WRealm.safe()
            let token = realm.objects(MessageStorageItem.self)
                .filter("primary IN %@", keys)
                .observe { [weak self] change in
                    guard let self else { return }
                    switch change {
                    case .initial(let collection):
                        self.residentIdentitiesByIndex = collection.map(
                            ChatIncrementalMessageIdentity.init(message:)
                        )
                    case .update(let collection, let deletions, let insertions, let modifications):
                        let previousIdentities = self.residentIdentitiesByIndex
                        deletions.compactMap {
                            previousIdentities.indices.contains($0) ? previousIdentities[$0] : nil
                        }.forEach {
                            self.enqueueMutation(
                                .delete(identity: $0, revision: self.nextMutationRevision()),
                                refreshUnread: false
                            )
                        }
                        Set(insertions + modifications).sorted().forEach { index in
                            guard collection.indices.contains(index) else { return }
                            let message = collection[index]
                            let frozen = message.isFrozen ? message : message.freeze()
                            self.enqueueMutation(
                                .upsert(
                                    identity: ChatIncrementalMessageIdentity(message: frozen),
                                    revision: self.nextMutationRevision(),
                                    payload: frozen
                                ),
                                refreshUnread: false
                            )
                        }
                        self.residentIdentitiesByIndex = collection.map(
                            ChatIncrementalMessageIdentity.init(message:)
                        )
                    case .error(let error):
                        DDLogDebug("RealmChatTimelineStoreObservation.resident change: \(error.localizedDescription)")
                    }
                }
            lock.withLock {
                if invalidated {
                    token.invalidate()
                } else {
                    residentToken = token
                }
            }
        } catch {
            DDLogDebug("RealmChatTimelineStoreObservation.resident: \(error.localizedDescription)")
        }
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func nextMutationRevision() -> UInt64 {
        lock.withLock {
            mutationRevision &+= 1
            return mutationRevision
        }
    }

    private func enqueueMutation(
        _ mutation: ChatIncrementalMessageMutation<MessageStorageItem>,
        refreshUnread: Bool
    ) {
        mutationAccumulator.enqueue(mutation)
        pendingUnreadRefresh = pendingUnreadRefresh || refreshUnread
        scheduleMutationFlush()
    }

    private func scheduleMutationFlush() {
        guard !mutationFlushScheduled else { return }
        mutationFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushMutations()
        }
    }

    private func flushMutations() {
        mutationFlushScheduled = false
        guard !lock.withLock({ invalidated }) else { return }
        let batch = mutationAccumulator.drain()
        let refreshUnread = pendingUnreadRefresh
        pendingUnreadRefresh = false
        if batch.mutations.isNotEmpty {
            onChange(.incremental(batch, refreshUnread: refreshUnread))
        } else if refreshUnread {
            onChange(.unreadChanged)
        }
    }
}

private extension NSLocking {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
