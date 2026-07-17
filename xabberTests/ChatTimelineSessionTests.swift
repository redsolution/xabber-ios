import XCTest
import RealmSwift
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
        XCTAssertEqual(snapshot.items.map(\.primary), primaryRange(6...9))
        XCTAssertEqual(snapshot.items.count, 4)
        XCTAssertEqual(snapshot.residentIndex.index(archivedId: "archive-8"), 2)
        XCTAssertEqual(snapshot.state.isResidentAtLiveTail, false)
    }

    func testPresentedAnchorSnapshotSupersedesInterveningLatestMutation() {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 30))
        let session = makeSession(store: store, pageSize: 4)
        let presentedAnchor = session.openAround(
            anchor: ChatTimelineAnchor(
                primary: "primary-10",
                archivedId: "archive-10",
                messageId: "message-10",
                date: Date(timeIntervalSince1970: 10)
            )
        )

        let interveningLatest = session.openLatest()
        let committed = session.commitPresentationSnapshot(presentedAnchor)

        XCTAssertNotEqual(interveningLatest.state.residentPrimaryKeys, presentedAnchor.state.residentPrimaryKeys)
        XCTAssertEqual(committed.items.map(\.primary), presentedAnchor.items.map(\.primary))
        XCTAssertEqual(committed.state, presentedAnchor.state)
        XCTAssertEqual(session.snapshot.state, presentedAnchor.state)
        XCTAssertEqual(store.observation?.residentPrimaryKeys, presentedAnchor.state.residentPrimaryKeys)
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

    func testIncrementalStoreBatchPublishesOnceWithoutLatestOrResidentRefetch() throws {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 12))
        let session = makeSession(store: store, pageSize: 2)
        let opened = session.openLatest()
        let queryCountBeforeMutation = store.diagnosticsSnapshot.queryCount
        var publishedSnapshots: [ChatTimelineSessionSnapshot] = []
        session.onSnapshot = { publishedSnapshots.append($0) }
        let incoming = try XCTUnwrap(makeMessages(count: 13).last)
        var accumulator = ChatIncrementalMessageMutationAccumulator<MessageStorageItem>()
        accumulator.enqueue(.upsert(
            identity: ChatIncrementalMessageIdentity(message: incoming),
            revision: 1,
            payload: incoming
        ))

        store.emit(.incremental(accumulator.drain(), refreshUnread: false))

        XCTAssertEqual(store.diagnosticsSnapshot.queryCount, queryCountBeforeMutation)
        XCTAssertEqual(publishedSnapshots.count, 1)
        XCTAssertEqual(session.snapshot.generation, opened.generation + 1)
        XCTAssertEqual(session.snapshot.items.last?.primary, "primary-12")
        XCTAssertEqual(session.snapshot.residentChangeSet?.insertedPrimaries, ["primary-12"])
        XCTAssertEqual(store.observation?.residentPrimaryKeys, session.snapshot.items.map(\.primary))
    }

    func testNewOutgoingIncrementalInsertFromHistoricalWindowReopensBoundedLatestOnce() throws {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 20))
        let session = makeSession(store: store, pageSize: 4)
        let historical = session.openAround(
            anchor: ChatTimelineAnchor(
                primary: "primary-8",
                archivedId: "archive-8",
                messageId: "message-8",
                date: Date(timeIntervalSince1970: 8)
            )
        )
        XCTAssertFalse(historical.state.isResidentAtLiveTail)

        let outgoing = try XCTUnwrap(makeMessages(count: 21).last)
        outgoing.outgoing = true
        store.append(outgoing)
        var publishedSnapshots: [ChatTimelineSessionSnapshot] = []
        session.onSnapshot = { publishedSnapshots.append($0) }
        var accumulator = ChatIncrementalMessageMutationAccumulator<MessageStorageItem>()
        accumulator.enqueue(.upsert(
            identity: ChatIncrementalMessageIdentity(message: outgoing),
            revision: 1,
            payload: outgoing
        ))

        store.emit(.incremental(accumulator.drain(), refreshUnread: false))

        XCTAssertEqual(publishedSnapshots.count, 1)
        XCTAssertTrue(session.snapshot.state.isResidentAtLiveTail)
        XCTAssertEqual(session.snapshot.items.last?.primary, outgoing.primary)
        XCTAssertEqual(
            session.snapshot.items.count,
            ChatBoundedTimelineWindowPolicy.targetLimit(pageSize: 4)
        )
        XCTAssertLessThanOrEqual(session.snapshot.items.count, session.snapshot.residentHardLimit)
        XCTAssertEqual(store.observation?.residentPrimaryKeys, session.snapshot.items.map(\.primary))
    }

    func testProductionLastChatObservationPublishesNewOutgoingFromHistoricalWindow() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "ChatTimelineSessionOutgoing-\(UUID().uuidString)"
        )
        Realm.Configuration.defaultConfiguration = configuration
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }

        let realm = try Realm(configuration: configuration)
        let messages = makeMessages(count: 21)
        let initialLatest = try XCTUnwrap(messages.last)
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .regular
        )
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.lastMessage = initialLatest
        chat.lastMessageId = initialLatest.messageId
        chat.messageDate = initialLatest.sentDate
        try realm.write {
            realm.add(messages)
            messages.forEach { ChatLocalHistoryLinkedIndex.upsert($0, in: realm) }
            realm.add(chat)
        }

        let session = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            pageSize: 4,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            archiveState: ChatArchiveStateSnapshot(
                primaryKey: "outgoing-archive-state",
                persistedCursorId: nil,
                fullArchiveLoaded: true,
                newestCursorId: initialLatest.archivedId,
                newerLiveEdgeReached: true,
                hasKnownNewerGap: false,
                knownGaps: []
            )
        )
        let historical = session.openAround(
            anchor: ChatTimelineAnchor(
                primary: "primary-8",
                archivedId: "archive-8",
                messageId: "message-8",
                date: Date(timeIntervalSince1970: 8)
            )
        )
        XCTAssertFalse(historical.state.isResidentAtLiveTail)

        let observationReady = expectation(description: "last chat observation ready")
        var readinessToken: NotificationToken?
        readinessToken = realm.objects(LastChatsStorageItem.self)
            .filter("primary == %@", chat.primary)
            .observe { change in
                if case .initial = change {
                    observationReady.fulfill()
                }
            }
        defer { readinessToken?.invalidate() }
        wait(for: [observationReady], timeout: 2)

        let outgoing = MessageStorageItem()
        outgoing.primary = "outgoing-primary"
        outgoing.owner = owner
        outgoing.opponent = jid
        outgoing.conversationType = .regular
        outgoing.archivedId = "archive-21"
        outgoing.messageId = "message-21"
        outgoing.date = Date(timeIntervalSince1970: 21)
        outgoing.sentDate = outgoing.date
        outgoing.body = "outgoing body"
        outgoing.legacyBody = outgoing.body
        outgoing.outgoing = true
        outgoing.state = .deliver
        let published = expectation(description: "outgoing latest published")
        session.onSnapshot = { snapshot in
            guard snapshot.cause == .storeChange,
                  snapshot.items.last?.primary == outgoing.primary else { return }
            published.fulfill()
        }

        try realm.write {
            realm.add(outgoing)
            ChatLocalHistoryLinkedIndex.upsert(outgoing, in: realm)
            chat.lastMessage = outgoing
            chat.lastMessageId = outgoing.messageId
            chat.messageDate = outgoing.sentDate
        }

        wait(for: [published], timeout: 2)
        XCTAssertTrue(session.snapshot.state.isResidentAtLiveTail)
        XCTAssertEqual(session.snapshot.items.last?.primary, outgoing.primary)
        XCTAssertLessThanOrEqual(
            session.snapshot.items.count,
            ChatBoundedTimelineWindowPolicy.hardLimit(pageSize: 4)
        )
    }

    func testProductionEditPublishesEditedBodyThroughRealmTimelineAndDisplayMapping() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "ChatTimelineSessionEdit-\(UUID().uuidString)"
        )
        Realm.Configuration.defaultConfiguration = configuration
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }

        let realm = try Realm(configuration: configuration)
        let item = MessageStorageItem()
        item.primary = "editable-primary"
        item.owner = owner
        item.opponent = jid
        item.conversationType = .regular
        item.archivedId = "editable-archive"
        item.messageId = "editable-message"
        item.date = Date(timeIntervalSince1970: 1_700_000_000)
        item.sentDate = item.date
        item.body = "original body"
        item.legacyBody = item.body
        item.outgoing = true
        item.state = .deliver
        try realm.write {
            realm.add(item)
            ChatLocalHistoryLinkedIndex.upsert(item, in: realm)
        }

        let session = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            pageSize: 20,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            archiveState: ChatArchiveStateSnapshot(
                primaryKey: "edit-archive-state",
                persistedCursorId: nil,
                fullArchiveLoaded: true,
                newestCursorId: nil,
                newerLiveEdgeReached: true,
                hasKnownNewerGap: false,
                knownGaps: []
            )
        )
        XCTAssertEqual(session.openLatest().items.first?.body, "original body")
        XCTAssertEqual(session.snapshot.state.residentPrimaryKeys, [item.primary])
        let residentObservationReady = expectation(description: "resident observation ready")
        let realmEditObserved = expectation(description: "Realm edit observed")
        let productionObservationEditObserved = expectation(description: "production observation edit observed")
        let productionObservation = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .regular
        ).observe(residentPrimaryKeys: [item.primary]) { change in
            guard case .incremental(let batch, _) = change,
                  batch.mutations.contains(where: { $0.payload?.body == "edited body" }) else { return }
            productionObservationEditObserved.fulfill()
        }
        defer { productionObservation.invalidate() }
        var residentObservationToken: NotificationToken?
        residentObservationToken = realm.objects(MessageStorageItem.self)
            .filter("primary == %@", item.primary)
            .observe { change in
                switch change {
                case .initial:
                    residentObservationReady.fulfill()
                case .update(let collection, _, _, let modifications):
                    guard modifications == [0], collection.first?.body == "edited body" else { return }
                    realmEditObserved.fulfill()
                case .error(let error):
                    XCTFail("Unexpected Realm observation error: \(error)")
                }
            }
        wait(for: [residentObservationReady], timeout: 2)
        defer { residentObservationToken?.invalidate() }

        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: "Owner")
        controller.opponentSender = Sender(id: jid, displayName: "Peer")
        controller.showSkeletonObserver.accept(false)
        let published = expectation(description: "edited body published")
        session.onSnapshot = { snapshot in
            guard snapshot.cause == .storeChange,
                  snapshot.items.first?.body == "edited body" else { return }
            let mapped = controller.mapDataset(dataset: snapshot.items)
            guard case .attributedText(let text)? = mapped.first(where: { $0.primary == item.primary })?.kind else {
                return
            }
            XCTAssertEqual(text.string, "edited body")
            published.fulfill()
        }

        MessageManager(withOwner: owner, activeStream: false).editSimpleMessage(
            "edited body",
            primary: item.primary
        )

        XCTAssertEqual(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.primary)?.body, "edited body")
        wait(for: [realmEditObserved, productionObservationEditObserved, published], timeout: 2)
        XCTAssertEqual(session.snapshot.residentChangeSet?.updatedStablePrimaries, [item.primary])
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

    func append(_ item: MessageStorageItem) {
        messages.append(item)
        messages = ChatTimelineOrdering.chronological(messages)
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
