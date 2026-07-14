import Foundation
import RealmSwift
import CocoaLumberjack

enum ChatTimelineStoreChange: Equatable {
    case latestChanged
    case residentChanged
    case unreadChanged
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

final class ChatTimelineSession {
    typealias SnapshotHandler = (ChatTimelineSessionSnapshot) -> Void

    private let lock = NSRecursiveLock()
    private let operationLock = NSRecursiveLock()
    private let store: ChatTimelineSessionStore
    private let pageSize: Int
    private let conversationKey: ChatTimelineConversationKey
    private var archiveState: ChatArchiveStateSnapshot
    private var storedSnapshot: ChatTimelineSessionSnapshot
    private var observation: ChatTimelineStoreObservation?
    private var storedSnapshotHandler: SnapshotHandler?
    private var storeChangeDepth = 0

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
            residentHardLimit: ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: self.pageSize)
        )
        self.observation = store.observe(residentPrimaryKeys: []) { [weak self] change in
            self?.handleStoreChange(change)
        }
    }

    deinit {
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

    func previewPage(
        direction: ChatHistoryPageDirection,
        queryId: String? = nil,
        archiveState: ChatArchiveStateSnapshot? = nil
    ) -> ChatTimelineSnapshot {
        operationLock.withLock {
            let input = lock.withLock { (storedSnapshot, archiveState ?? self.archiveState) }
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
            switch direction {
            case .older:
                return engine.pageOlder(queryId: queryId)
            case .newer:
                return engine.pageNewer(queryId: queryId)
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
        unreadMetadata: ChatTimelineUnreadMetadata
    ) -> ChatTimelineSessionSnapshot {
        let hardLimit = ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: pageSize)
        let ordered = ChatTimelineOrdering.deduplicatedChronological(items)
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
                residentHardLimit: hardLimit
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
                _ = openLatest()
            } else {
                _ = refreshResidentItems()
            }
            _ = refreshUnreadMetadata()
        case .residentChanged:
            _ = refreshResidentItems()
        case .unreadChanged:
            _ = refreshUnreadMetadata()
        }
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
            var deliveredInitial = false
            let token = realm.objects(LastChatsStorageItem.self)
                .filter("primary == %@", primary)
                .observe { [weak self] change in
                    guard let self else { return }
                    if case .initial = change {
                        deliveredInitial = true
                        return
                    }
                    guard deliveredInitial else { return }
                    self.onChange(.latestChanged)
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
            var deliveredInitial = false
            let token = realm.objects(MessageStorageItem.self)
                .filter("primary IN %@", keys)
                .observe { [weak self] change in
                    guard let self else { return }
                    if case .initial = change {
                        deliveredInitial = true
                        return
                    }
                    guard deliveredInitial else { return }
                    self.onChange(.residentChanged)
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
}

private extension NSLocking {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
