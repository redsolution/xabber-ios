import XCTest
@testable import xabber

final class ChatTimelineSessionTests: XCTestCase {
    private let owner = "owner@example.com"
    private let jid = "chat@example.com"

    func testMillionRowLogicalHistoryKeepsResidentSnapshotAndOperationsBounded() {
        let store = FakeChatTimelineSessionStore(
            messages: makeMessages(count: 1_000),
            logicalRowCount: 1_000_000
        )
        let session = makeSession(store: store, pageSize: 20)

        let snapshot = session.openLatest()

        XCTAssertEqual(snapshot.items.count, ChatBoundedTimelineWindowPolicy.targetLimit(pageSize: 20))
        XCTAssertLessThanOrEqual(snapshot.items.count, snapshot.residentHardLimit)
        XCTAssertEqual(snapshot.residentIndex.count, snapshot.items.count)
        XCTAssertEqual(store.diagnosticsSnapshot.fullScanCount, 0)
        XCTAssertLessThanOrEqual(
            store.diagnosticsSnapshot.maxCandidateCount,
            snapshot.residentHardLimit * 4
        )
        XCTAssertEqual(store.logicalRowCount, 1_000_000)
        XCTAssertEqual(store.observation?.residentPrimaryKeys.count, snapshot.items.count)
    }

    func testOlderThenNewerPagingTrimsOppositeResidentEnds() {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 30))
        let session = makeSession(store: store, pageSize: 2)

        XCTAssertEqual(session.openLatest().items.map(\.primary), primaryRange(20...29))
        XCTAssertEqual(session.pageOlder().items.map(\.primary), primaryRange(18...29))
        XCTAssertEqual(session.pageOlder().items.map(\.primary), primaryRange(16...27))

        let newer = session.pageNewer()

        XCTAssertEqual(newer.items.map(\.primary), primaryRange(18...29))
        XCTAssertLessThanOrEqual(newer.items.count, ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: 2))
        XCTAssertEqual(Set(newer.items.map(\.primary)).count, newer.items.count)
    }

    func testExternalAnchorUsesDirectStoreLookupAndPublishesAroundSnapshot() {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 20))
        let session = makeSession(store: store, pageSize: 4)

        let snapshot = session.openAround(
            anchor: ChatTimelineAnchor(
                primary: nil,
                archivedId: "archive-8",
                messageId: nil,
                date: nil
            )
        )

        XCTAssertEqual(store.directLookupCount, 1)
        XCTAssertEqual(snapshot.items.map(\.primary), primaryRange(6...10))
        XCTAssertEqual(snapshot.residentIndex.index(archivedId: "archive-8"), 2)
        XCTAssertEqual(snapshot.state.isResidentAtLiveTail, false)
    }

    func testInteriorEditAndDeleteRefreshResidentLookupWithoutStaleIdentity() {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 12))
        let session = makeSession(store: store, pageSize: 2)
        _ = session.openLatest()

        store.edit(primary: "primary-6", archivedId: "archive-edited", messageId: "message-edited")
        store.emit(.residentChanged)

        XCTAssertNil(session.snapshot.residentIndex.index(archivedId: "archive-6"))
        XCTAssertEqual(session.snapshot.residentIndex.index(archivedId: "archive-edited"), 4)
        XCTAssertEqual(session.snapshot.residentIndex.index(messageId: "message-edited"), 4)

        store.delete(primary: "primary-7")
        store.emit(.residentChanged)

        XCTAssertNil(session.snapshot.residentIndex.index(primary: "primary-7"))
        XCTAssertEqual(session.snapshot.items.count, 9)
        XCTAssertEqual(store.observation?.residentPrimaryKeys.count, 9)
    }

    func testStableReadBoundarySurvivesResidentTrimByCursorAndPrimary() {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 30))
        let session = makeSession(store: store, pageSize: 2)
        _ = session.openLatest()

        XCTAssertTrue(session.advanceReadBoundary(toPrimary: "primary-25"))
        let boundary = session.snapshot.readBoundary
        _ = session.pageOlder()
        _ = session.pageOlder()

        XCTAssertEqual(session.snapshot.readBoundary, boundary)
        XCTAssertEqual(session.snapshot.readBoundary?.primary, "primary-25")
        XCTAssertFalse(session.advanceReadBoundary(toPrimary: "primary-24"))
        XCTAssertTrue(session.advanceReadBoundary(toPrimary: "primary-26"))
    }

    func testRegularAndGroupUnreadMetadataUseBoundedStoreQuery() {
        let mention = ChatUnreadMentionItem(
            notificationPrimary: "notification-1",
            messagePrimary: "primary-8",
            archivedId: "archive-8",
            messageId: "message-8",
            chatPrimary: "chat-primary",
            authorId: "member-2",
            date: Date(timeIntervalSince1970: 8),
            targetMemberId: "member-1",
            groupchatJid: jid
        )
        let regularStore = FakeChatTimelineSessionStore(
            messages: makeMessages(count: 10),
            unreadMetadata: ChatTimelineUnreadMetadata(
                unreadCount: 4,
                mentions: [],
                candidateCount: 1
            )
        )
        let groupStore = FakeChatTimelineSessionStore(
            messages: makeMessages(count: 10),
            unreadMetadata: ChatTimelineUnreadMetadata(
                unreadCount: 7,
                mentions: [mention],
                candidateCount: 2
            )
        )
        let regularSession = makeSession(store: regularStore, pageSize: 2, conversationType: .regular)
        let groupSession = makeSession(store: groupStore, pageSize: 2, conversationType: .group)

        let regular = regularSession.refreshUnreadMetadata()
        let group = groupSession.refreshUnreadMetadata()

        XCTAssertEqual(regular.unreadMetadata.unreadCount, 4)
        XCTAssertTrue(regular.unreadMetadata.mentions.isEmpty)
        XCTAssertEqual(group.unreadMetadata.mentions.map(\.archivedId), ["archive-8"])
        XCTAssertLessThanOrEqual(group.unreadMetadata.candidateCount, group.residentHardLimit)
        XCTAssertEqual(regularStore.unreadQueryLimits, [regular.residentHardLimit])
        XCTAssertEqual(groupStore.unreadQueryLimits, [group.residentHardLimit])
    }

    func testStoreChangesIncrementGenerationAndPublishImmutableSnapshots() {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 12))
        let session = makeSession(store: store, pageSize: 2)
        var publishedGenerations: [UInt64] = []
        session.onSnapshot = { publishedGenerations.append($0.generation) }
        let opened = session.openLatest()

        store.emit(.latestChanged)
        store.emit(.unreadChanged)

        XCTAssertGreaterThan(session.snapshot.generation, opened.generation)
        XCTAssertEqual(publishedGenerations, publishedGenerations.sorted())
        XCTAssertEqual(Set(publishedGenerations).count, publishedGenerations.count)
    }

    func testSessionDeinitInvalidatesBoundedObservation() {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 4))
        weak var weakSession: ChatTimelineSession?
        var observation: FakeChatTimelineObservation?

        autoreleasepool {
            var session: ChatTimelineSession? = makeSession(store: store, pageSize: 2)
            weakSession = session
            _ = session?.openLatest()
            observation = store.observation
            XCTAssertFalse(observation?.isInvalidated ?? true)
            session = nil
        }

        XCTAssertNil(weakSession)
        XCTAssertTrue(observation?.isInvalidated == true)
    }

    func testControllerDeinitReleasesSessionAndInvalidatesObservation() {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 4))
        weak var weakController: ChatViewController?
        weak var weakSession: ChatTimelineSession?
        var observation: FakeChatTimelineObservation?

        autoreleasepool {
            var controller: ChatViewController? = ChatViewController()
            let session = makeSession(store: store, pageSize: 2)
            controller?.timelineSession = session
            session.onSnapshot = { [weak controller, weak session] _ in
                guard let controller, let session, controller.timelineSession === session else { return }
            }
            _ = session.openLatest()
            weakController = controller
            weakSession = session
            observation = store.observation
            controller = nil
        }

        XCTAssertNil(weakController)
        XCTAssertNil(weakSession)
        XCTAssertTrue(observation?.isInvalidated == true)
    }

    private func makeSession(
        store: FakeChatTimelineSessionStore,
        pageSize: Int,
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> ChatTimelineSession {
        ChatTimelineSession(
            store: store,
            pageSize: pageSize,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: conversationType
            ),
            archiveState: ChatArchiveStateSnapshot(
                primaryKey: "archive-state",
                persistedCursorId: nil,
                fullArchiveLoaded: true,
                newestCursorId: nil,
                newerLiveEdgeReached: true,
                hasKnownNewerGap: false,
                knownGaps: []
            )
        )
    }

    private func makeMessages(count: Int) -> [MessageStorageItem] {
        (0..<count).map { index in
            let item = MessageStorageItem()
            item.primary = "primary-\(index)"
            item.owner = owner
            item.opponent = jid
            item.archivedId = "archive-\(index)"
            item.messageId = "message-\(index)"
            item.date = Date(timeIntervalSince1970: TimeInterval(index))
            item.sentDate = item.date
            item.conversationType = .regular
            return item
        }
    }

    private func primaryRange(_ range: ClosedRange<Int>) -> [String] {
        range.map { "primary-\($0)" }
    }
}

final class ChatTimelineSessionSourcePolicyTests: XCTestCase {
    func testChatControllerSourcesDoNotRetainFullHistoryOrLegacyGlobalLookupState() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "xabber/controllers/chats/chat/ChatViewController.swift",
            "xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift",
            "xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift",
            "xabber/controllers/chats/chat/delegate/action/ChatViewController+CellDelegate.swift",
            "xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift",
            "xabber/controllers/chats/chat/rx/ChatViewController+LowPrioritySubscribtions.swift"
        ]
        let forbiddenTokens = [
            "messagesObserver",
            "observerPrimaryIndexMap",
            "observerArchivedIdIndexMap",
            "observerMessageIdIndexMap",
            "ensureObserverLookupMaps",
            "class ChatPage",
            "ChatTimelinePagingState",
            "ChatVirtualTimelineEngine(",
            "ChatLocalHistoryPageProvider("
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for token in forbiddenTokens {
                XCTAssertFalse(source.contains(token), "\(relativePath) still contains forbidden full-history token \(token)")
            }
        }
    }
}

private final class FakeChatTimelineSessionStore: ChatTimelineSessionStore {
    private var messages: [MessageStorageItem]
    private(set) var directLookupCount = 0
    private(set) var unreadQueryLimits: [Int] = []
    private(set) var observation: FakeChatTimelineObservation?
    private var unreadMetadata: ChatTimelineUnreadMetadata
    let logicalRowCount: Int
    private(set) var diagnosticsSnapshot = ChatTimelineStoreDiagnosticsSnapshot.empty

    init(
        messages: [MessageStorageItem],
        logicalRowCount: Int? = nil,
        unreadMetadata: ChatTimelineUnreadMetadata = .empty
    ) {
        self.messages = ChatTimelineOrdering.chronological(messages)
        self.logicalRowCount = logicalRowCount ?? messages.count
        self.unreadMetadata = unreadMetadata
    }

    func latest(limit: Int) -> [MessageStorageItem] {
        recordQuery("latest", limit: limit)
        return Array(messages.suffix(limit))
    }

    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        recordQuery("older", limit: limit)
        guard let index = messages.firstIndex(where: { $0.primary == boundary.primary }) else { return [] }
        return Array(messages.prefix(index).suffix(limit))
    }

    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        recordQuery("newer", limit: limit)
        guard let index = messages.firstIndex(where: { $0.primary == boundary.primary }) else { return [] }
        return Array(messages.suffix(from: messages.index(after: index)).prefix(limit))
    }

    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem] {
        guard let index = messages.firstIndex(where: { $0.primary == anchor.primary }) else { return [] }
        let lower = max(0, index - before)
        let upper = min(messages.count, index + after + 1)
        recordQuery("around", limit: before + after + 1)
        return Array(messages[lower..<upper])
    }

    func message(primary: String?, archivedId: String?, messageId: String?) -> MessageStorageItem? {
        directLookupCount += 1
        if let primary, let item = messages.first(where: { $0.primary == primary }) { return item }
        if let archivedId, let item = messages.first(where: { $0.archivedId == archivedId }) { return item }
        if let messageId, let item = messages.first(where: { $0.messageId == messageId }) { return item }
        return nil
    }

    func items(primaryKeys: [String]) -> [MessageStorageItem] {
        let byPrimary = Dictionary(uniqueKeysWithValues: messages.map { ($0.primary, $0) })
        recordQuery("resident", limit: primaryKeys.count)
        return primaryKeys.compactMap { byPrimary[$0] }
    }

    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem? {
        guard let boundary = messages.firstIndex(where: { $0.archivedId == boundaryArchivedId }) else {
            return nil
        }
        return messages.suffix(from: messages.index(after: boundary)).first(where: { !$0.outgoing })
    }

    func unreadMetadata(limit: Int) -> ChatTimelineUnreadMetadata {
        unreadQueryLimits.append(limit)
        recordQuery("unread", limit: min(limit, unreadMetadata.candidateCount))
        return unreadMetadata
    }

    func observe(
        residentPrimaryKeys: [String],
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) -> ChatTimelineStoreObservation {
        let observation = FakeChatTimelineObservation(
            residentPrimaryKeys: residentPrimaryKeys,
            onChange: onChange
        )
        self.observation = observation
        return observation
    }

    func edit(primary: String, archivedId: String, messageId: String) {
        guard let item = messages.first(where: { $0.primary == primary }) else { return }
        item.archivedId = archivedId
        item.messageId = messageId
    }

    func delete(primary: String) {
        messages.removeAll { $0.primary == primary }
    }

    func emit(_ change: ChatTimelineStoreChange) {
        observation?.emit(change)
    }

    private func recordQuery(_ operation: String, limit: Int) {
        diagnosticsSnapshot = diagnosticsSnapshot.recording(
            operation: operation,
            candidateCount: min(max(0, limit), messages.count)
        )
    }
}

private final class FakeChatTimelineObservation: ChatTimelineStoreObservation {
    private let onChange: (ChatTimelineStoreChange) -> Void
    private(set) var residentPrimaryKeys: [String]
    private(set) var isInvalidated = false

    init(
        residentPrimaryKeys: [String],
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) {
        self.residentPrimaryKeys = residentPrimaryKeys
        self.onChange = onChange
    }

    func replaceResidentPrimaryKeys(_ primaryKeys: [String]) {
        residentPrimaryKeys = primaryKeys
    }

    func invalidate() {
        isInvalidated = true
    }

    func emit(_ change: ChatTimelineStoreChange) {
        guard !isInvalidated else { return }
        onChange(change)
    }
}
