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

    func testFirstIncomingUsesResidentMatchWithoutQueryingStore() {
        let messages = makeMessages(count: 20)
        for (index, message) in messages.enumerated() {
            message.archivedId = "\(index * 1_000_000)"
        }
        let store = FakeChatTimelineSessionStore(messages: messages)
        let session = makeSession(store: store, pageSize: 4)
        _ = session.openAround(
            anchor: ChatTimelineAnchor(
                primary: "primary-8",
                archivedId: "8000000",
                messageId: "message-8",
                date: Date(timeIntervalSince1970: 8)
            )
        )

        let firstIncoming = session.firstIncoming(
            afterArchiveBoundaryId: "8000000"
        )

        XCTAssertEqual(firstIncoming?.primary, "primary-9")
        XCTAssertEqual(store.firstIncomingQueryCount, 0)
    }

    func testFirstIncomingFallsBackToStoreWhenResidentWindowHasNoMatch() {
        let messages = makeMessages(count: 20)
        for (index, message) in messages.enumerated() {
            message.archivedId = "\(index * 1_000_000)"
        }
        messages[9].outgoing = true
        let store = FakeChatTimelineSessionStore(messages: messages)
        let session = makeSession(store: store, pageSize: 4)
        _ = session.openAround(
            anchor: ChatTimelineAnchor(
                primary: "primary-8",
                archivedId: "8000000",
                messageId: "message-8",
                date: Date(timeIntervalSince1970: 8)
            )
        )

        let firstIncoming = session.firstIncoming(
            afterArchiveBoundaryId: "8000000"
        )

        XCTAssertEqual(firstIncoming?.primary, "primary-10")
        XCTAssertEqual(store.firstIncomingQueryCount, 1)
    }

    func testFirstIncomingExcludesCanonicalBoundaryIdentityFromResidentMatch() {
        let messages = makeMessages(count: 20)
        for (index, message) in messages.enumerated() {
            message.archivedId = "\(index * 1_000_000)"
        }
        messages[8].archivedId = "\t8000000 "
        let store = FakeChatTimelineSessionStore(messages: messages)
        let session = makeSession(store: store, pageSize: 4)
        _ = session.openAround(
            anchor: ChatTimelineAnchor(
                primary: "primary-8",
                archivedId: "8000000",
                messageId: "message-8",
                date: Date(timeIntervalSince1970: 8)
            )
        )

        let firstIncoming = session.firstIncoming(
            afterArchiveBoundaryId: " 8000000\n"
        )

        XCTAssertEqual(firstIncoming?.primary, "primary-9")
        XCTAssertEqual(store.firstIncomingQueryCount, 0)
    }

    func testAbortUnknownRemoteLoadIsGenerationStableNoOp() {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 20))
        let session = makeSession(store: store, pageSize: 4)
        let committed = session.openLatest()

        let result = session.abortRemoteLoad(queryId: "unknown-query")

        XCTAssertEqual(result.generation, committed.generation)
        XCTAssertEqual(result.items.map(\.primary), committed.items.map(\.primary))
        XCTAssertEqual(result.state, committed.state)
        XCTAssertEqual(session.snapshot.generation, committed.generation)
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

    func testControllerReadBoundaryUsesLastPrecedingResidentWhenBoundaryLeavesWindow() {
        let store = FakeChatTimelineSessionStore(messages: makeMessages(count: 30))
        let session = makeSession(store: store, pageSize: 2)
        _ = session.openLatest()
        XCTAssertTrue(session.advanceReadBoundary(toPrimary: "primary-25"))

        store.delete(primary: "primary-25")
        store.emit(.residentChanged)

        let snapshot = session.snapshot
        XCTAssertNil(snapshot.residentIndex.index(primary: "primary-25"))
        XCTAssertEqual(snapshot.items.last?.primary, "primary-29")

        let controller = ChatViewController()
        controller.timelineSession = session

        XCTAssertEqual(
            controller.currentViewportReadBoundaryIndex(in: []),
            snapshot.residentIndex.index(primary: "primary-24")
        )
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

    func testOlderRemoteLoadIgnoresHistoricalLatestMutationButKeepsGenuineLiveInsert() {
        let allMessages = makeMessages(count: 321)
        let store = FakeChatTimelineSessionStore(
            messages: Array(allMessages[240..<320])
        )
        let session = ChatTimelineSession(
            store: store,
            pageSize: 80,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            archiveState: ChatArchiveStateSnapshot(
                primaryKey: "active-older-load",
                persistedCursorId: nil,
                fullArchiveLoaded: false,
                newestCursorId: "archive-319",
                newerLiveEdgeReached: true
            )
        )
        _ = session.openLatest(limit: 80)
        let armed = session.pageOlder(queryId: "older-gap-query")
        XCTAssertEqual(armed.state.activeRemoteLoad?.queryId, "older-gap-query")
        XCTAssertEqual(armed.state.oldest?.primary, "primary-240")
        var publishedSnapshots: [ChatTimelineSessionSnapshot] = []
        session.onSnapshot = { publishedSnapshots.append($0) }

        let historical = allMessages[239]
        store.append(historical)
        var historicalAccumulator =
            ChatIncrementalMessageMutationAccumulator<MessageStorageItem>()
        historicalAccumulator.enqueue(.upsert(
            identity: ChatIncrementalMessageIdentity(message: historical),
            revision: 1,
            payload: historical
        ))
        store.emit(.incremental(
            historicalAccumulator.drain(),
            refreshUnread: false
        ))

        XCTAssertTrue(publishedSnapshots.isEmpty)
        XCTAssertEqual(session.snapshot.generation, armed.generation)
        XCTAssertEqual(session.snapshot.state.oldest?.primary, "primary-240")
        XCTAssertEqual(
            session.snapshot.state.activeRemoteLoad?.queryId,
            "older-gap-query"
        )

        let live = allMessages[320]
        store.append(live)
        var liveAccumulator =
            ChatIncrementalMessageMutationAccumulator<MessageStorageItem>()
        liveAccumulator.enqueue(.upsert(
            identity: ChatIncrementalMessageIdentity(message: live),
            revision: 2,
            payload: live
        ))
        store.emit(.incremental(
            liveAccumulator.drain(),
            refreshUnread: false
        ))

        XCTAssertEqual(publishedSnapshots.count, 1)
        XCTAssertEqual(session.snapshot.generation, armed.generation + 1)
        XCTAssertEqual(session.snapshot.items.count, 81)
        XCTAssertEqual(session.snapshot.items.first?.primary, "primary-240")
        XCTAssertEqual(session.snapshot.items.last?.primary, "primary-320")
        XCTAssertEqual(
            session.snapshot.state.activeRemoteLoad?.queryId,
            "older-gap-query"
        )
    }

    func testOlderRemoteGapFinishPublishesExactlyQueryWindowAfterHistoricalMutation() {
        let allMessages = makeMessages(count: 320)
        let store = FakeChatTimelineSessionStore(
            messages: Array(allMessages[240..<320])
        )
        let session = ChatTimelineSession(
            store: store,
            pageSize: 80,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            archiveState: ChatArchiveStateSnapshot(
                primaryKey: "g06-gap-repair",
                persistedCursorId: nil,
                fullArchiveLoaded: false,
                newestCursorId: "archive-319",
                newerLiveEdgeReached: true
            )
        )
        let opened = session.openLatest(limit: 80)
        let armed = session.pageOlder(queryId: "g06-gap-query")
        XCTAssertEqual(opened.items.count, 80)
        XCTAssertEqual(armed.state.oldest?.primary, "primary-240")

        for historical in allMessages[160..<240] {
            store.append(historical)
        }
        let latestHistorical = allMessages[239]
        var accumulator =
            ChatIncrementalMessageMutationAccumulator<MessageStorageItem>()
        accumulator.enqueue(.upsert(
            identity: ChatIncrementalMessageIdentity(message: latestHistorical),
            revision: 1,
            payload: latestHistorical
        ))
        store.emit(.incremental(accumulator.drain(), refreshUnread: false))
        XCTAssertEqual(session.snapshot.generation, armed.generation)
        XCTAssertEqual(session.snapshot.state.oldest?.primary, "primary-240")

        let finished = session.finishRemoteLoad(
            queryId: "g06-gap-query",
            refetchDirection: .older,
            refetchLimit: 80
        )

        XCTAssertEqual(finished.items.count, 160)
        XCTAssertEqual(finished.items.first?.primary, "primary-160")
        XCTAssertEqual(finished.items.last?.primary, "primary-319")
        XCTAssertNil(finished.state.activeRemoteLoad)
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
        ).observe(baseline: ChatTimelineStoreObservationBaseline(
            isAuthoritative: false,
            residentItems: [item],
            latestMessageFingerprint: nil,
            unreadCount: 0,
            unreadMetadataLimit: 20
        )) { change in
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

    @MainActor
    func testProductionMentionReadPublishesFreshUnreadMetadataWhenUnreadCountAndLatestIdentityStayUnchanged()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let configuration = Realm.Configuration(
            inMemoryIdentifier:
                "ChatTimelineSessionMentionRead-\(UUID().uuidString)"
        )
        Realm.Configuration.defaultConfiguration = configuration
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }

        let realm = try Realm(configuration: configuration)
        let target = MessageStorageItem()
        target.primary = "mention-read-target"
        target.owner = owner
        target.opponent = jid
        target.conversationType = .group
        target.archivedId = "mention-read-archive"
        target.messageId = "mention-read-message"
        target.date = Date(timeIntervalSince1970: 1_700_000_000)
        target.sentDate = target.date
        target.body = "@member unread mention"
        target.legacyBody = target.body
        target.outgoing = false
        target.isRead = false
        target.state = .deliver

        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .group
        )
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .group
        chat.lastMessage = target
        chat.lastMessageId = target.messageId
        chat.messageDate = target.sentDate
        chat.unread = 7
        chat.syncUnreadCount = 7
        chat.runtimeUnreadCount = 0
        chat.mentionId = target.archivedId

        let notification = NotificationStorageItem()
        notification.primary = NotificationStorageItem.genPrimary(
            owner: owner,
            jid: jid,
            uniqueId: "mention-read-notification"
        )
        notification.owner = owner
        notification.jid = jid
        notification.uniqueId = "mention-read-notification"
        notification.messageId = notification.uniqueId
        notification.category = .mention
        notification.isRead = false
        notification.shouldShow = true
        notification.associatedJid = jid
        notification.date = target.date
        notification.sourceConversationType = .group
        notification.sourceChatJid = jid
        notification.sourceArchivedId = target.archivedId
        notification.sourceMessageId = target.messageId
        notification.sourceSenderId = "member-other"
        notification.mentionTargetUserId = "member-me"
        notification.sourceMessageDate = target.date
        notification.mentionLinkStatus = .resolved

        try realm.write {
            realm.add(target)
            ChatLocalHistoryLinkedIndex.upsert(target, in: realm)
            realm.add(chat)
            realm.add(notification)
        }

        let session = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(
                owner: owner,
                jid: jid,
                conversationType: .group
            ),
            pageSize: 20,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .group
            ),
            archiveState: ChatArchiveStateSnapshot(
                primaryKey: "mention-read-archive-state",
                persistedCursorId: nil,
                fullArchiveLoaded: true,
                newestCursorId: target.archivedId,
                newerLiveEdgeReached: true,
                hasKnownNewerGap: false,
                knownGaps: []
            ),
            observesStoreImmediately: false
        )
        _ = session.openLatest()
        let initial = session.refreshUnreadMetadata()
        XCTAssertEqual(
            initial.unreadMetadata.mentions.map(\.notificationPrimary),
            [notification.primary]
        )
        XCTAssertEqual(
            initial.unreadMetadata.mentions.map(\.messagePrimary),
            [target.primary]
        )
        XCTAssertEqual(
            initial.unreadMetadata.latestUnreadMentionArchivedId,
            target.archivedId,
            "refreshUnreadMetadata must preserve the LastChats mention signal"
        )
        let initialGeneration = initial.generation
        let initialUnreadCount = chat.unread
        let initialLatestFingerprint = ChatTimelineObservedMessageFingerprint(
            message: target
        )

        session.activateStoreObservation()
        XCTAssertTrue(
            waitUntilTimelineCondition {
                session.activeStoreObservationWorkCount == 0
            },
            "the real Realm observation must be active before the mention read"
        )

        try realm.write {
            notification.isRead = true
            MentionNotificationSync.refreshLastChatMentionIds(
                owner: owner,
                groupchatJids: [jid],
                in: realm
            )
        }
        XCTAssertTrue(notification.isRead)
        XCTAssertNil(chat.mentionId)
        XCTAssertEqual(chat.unread, initialUnreadCount)
        XCTAssertEqual(
            ChatTimelineObservedMessageFingerprint(message: target),
            initialLatestFingerprint
        )

        XCTAssertTrue(
            waitUntilTimelineCondition {
                let snapshot = session.snapshot
                let resolvedState = ChatUnreadMentionNavigationPolicy
                    .resolveState(
                        items: snapshot.unreadMetadata.mentions,
                        residentPrimaryPositions:
                            snapshot.residentIndex.primaryIndexByID,
                        visiblePrimaries: [target.primary]
                    )
                return snapshot.cause == .storeChange &&
                    snapshot.generation > initialGeneration &&
                    !snapshot.unreadMetadata.mentions.contains(where: {
                        $0.notificationPrimary == notification.primary
                    }) &&
                    resolvedState.currentTarget?.messagePrimary !=
                        target.primary
            },
            "a mentionId-only Last Chats update must publish fresh unread " +
                "metadata and remove the consumed target from navigation"
        )
    }

    func testUnreadMentionSignalTransitionRemovesEveryNotificationForConsumedMessageWithoutResampling() {
        let firstConsumed = ChatUnreadMentionItem(
            notificationPrimary: "mention-transition-consumed-1",
            messagePrimary: "mention-transition-message-consumed",
            archivedId: "mention-transition-archive-consumed",
            messageId: "mention-transition-message-id-consumed",
            chatPrimary: "mention-transition-chat",
            authorId: "member-other",
            date: Date(timeIntervalSince1970: 1),
            targetMemberId: "member-me",
            groupchatJid: jid
        )
        let secondConsumed = ChatUnreadMentionItem(
            notificationPrimary: "mention-transition-consumed-2",
            messagePrimary: "mention-transition-message-consumed",
            archivedId: "\tmention-transition-archive-consumed ",
            messageId: "mention-transition-message-id-consumed",
            chatPrimary: "mention-transition-chat",
            authorId: "member-other",
            date: Date(timeIntervalSince1970: 2),
            targetMemberId: "member-me",
            groupchatJid: jid
        )
        let retained = ChatUnreadMentionItem(
            notificationPrimary: "mention-transition-retained",
            messagePrimary: "mention-transition-message-retained",
            archivedId: "mention-transition-archive-retained",
            messageId: "mention-transition-message-id-retained",
            chatPrimary: "mention-transition-chat",
            authorId: "member-other",
            date: Date(timeIntervalSince1970: 3),
            targetMemberId: "member-me",
            groupchatJid: jid
        )
        let metadata = ChatTimelineUnreadMetadata(
            unreadCount: 7,
            mentions: [firstConsumed, secondConsumed, retained],
            candidateCount: 5,
            latestUnreadMentionArchivedId:
                firstConsumed.archivedId
        )

        let transition = ChatTimelineUnreadMentionMetadataTransitionPolicy
            .resolve(
                metadata: metadata,
                previousArchivedId: " mention-transition-archive-consumed\n",
                currentArchivedId: nil
            )

        guard case .publish(let published) = transition else {
            return XCTFail("A consumed known mention must use the bounded publish path")
        }
        XCTAssertEqual(published.unreadCount, metadata.unreadCount)
        XCTAssertEqual(published.mentions, [retained])
        XCTAssertEqual(
            published.candidateCount,
            3,
            "candidateCount must drop by both notifications linked to the consumed message"
        )
        XCTAssertNil(published.latestUnreadMentionArchivedId)
        XCTAssertEqual(
            ChatTimelineUnreadMentionMetadataTransitionPolicy.resolve(
                metadata: metadata,
                previousArchivedId: firstConsumed.archivedId,
                currentArchivedId: firstConsumed.archivedId
            ),
            .unchanged
        )
        XCTAssertEqual(
            ChatTimelineUnreadMentionMetadataTransitionPolicy.resolve(
                metadata: .empty,
                previousArchivedId: nil,
                currentArchivedId: retained.archivedId
            ),
            .resample
        )
        XCTAssertEqual(
            ChatTimelineUnreadMentionMetadataTransitionPolicy.resolve(
                metadata: metadata,
                previousArchivedId: "mention-transition-archive-not-in-baseline",
                currentArchivedId: nil
            ),
            .resample
        )
    }

    @MainActor
    func testProductionMentionReadBetweenBaselineAndObserverRegistrationPublishesBoundedCatchUp()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let configuration = Realm.Configuration(
            inMemoryIdentifier:
                "ChatTimelineSessionMentionReadCatchUp-\(UUID().uuidString)"
        )
        Realm.Configuration.defaultConfiguration = configuration
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }

        let realm = try Realm(configuration: configuration)
        let target = MessageStorageItem()
        target.primary = "mention-read-catch-up-target"
        target.owner = owner
        target.opponent = jid
        target.conversationType = .group
        target.archivedId = "mention-read-catch-up-archive"
        target.messageId = "mention-read-catch-up-message"
        target.date = Date(timeIntervalSince1970: 1_700_000_100)
        target.sentDate = target.date
        target.body = "@member unread mention during registration"
        target.legacyBody = target.body
        target.outgoing = false
        target.isRead = false
        target.state = .deliver

        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .group
        )
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .group
        chat.lastMessage = target
        chat.lastMessageId = target.messageId
        chat.messageDate = target.sentDate
        chat.unread = 7
        chat.syncUnreadCount = 7
        chat.runtimeUnreadCount = 0
        chat.mentionId = target.archivedId

        let notification = NotificationStorageItem()
        notification.primary = NotificationStorageItem.genPrimary(
            owner: owner,
            jid: jid,
            uniqueId: "mention-read-catch-up-notification"
        )
        notification.owner = owner
        notification.jid = jid
        notification.uniqueId = "mention-read-catch-up-notification"
        notification.messageId = notification.uniqueId
        notification.category = .mention
        notification.isRead = false
        notification.shouldShow = true
        notification.associatedJid = jid
        notification.date = target.date
        notification.sourceConversationType = .group
        notification.sourceChatJid = jid
        notification.sourceArchivedId = target.archivedId
        notification.sourceMessageId = target.messageId
        notification.sourceSenderId = "member-other"
        notification.mentionTargetUserId = "member-me"
        notification.sourceMessageDate = target.date
        notification.mentionLinkStatus = .resolved

        try realm.write {
            realm.add(target)
            ChatLocalHistoryLinkedIndex.upsert(target, in: realm)
            realm.add(chat)
            realm.add(notification)
        }

        let registrationReached = expectation(
            description: "LastChats observer is held between baseline and registration"
        )
        registrationReached.assertForOverFulfill = true
        let registrationRelease = DispatchSemaphore(value: 0)
        let cancelled = expectation(
            description: "both bounded Realm registrations are cancelled"
        )
        cancelled.expectedFulfillmentCount = 2
        cancelled.assertForOverFulfill = true
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .group,
            observationTestHooks: ChatTimelineStoreObservationTestHooks(
                beforeRealmQuery: { identity in
                    guard identity == .init(
                        kind: .lastChats,
                        generation: 1
                    ) else { return }
                    registrationReached.fulfill()
                    _ = registrationRelease.wait(timeout: .now() + 5)
                },
                didRegister: nil,
                didCancel: { _ in cancelled.fulfill() }
            )
        )
        let initialMetadata = store.unreadMetadata(limit: 20)
        XCTAssertEqual(
            initialMetadata.mentions.map(\.notificationPrimary),
            [notification.primary]
        )
        XCTAssertEqual(
            initialMetadata.latestUnreadMentionArchivedId,
            target.archivedId
        )
        let initialUnreadCount = chat.unread
        let initialLatestFingerprint = ChatTimelineObservedMessageFingerprint(
            message: target
        )

        let metadataPublished = expectation(
            description: "registration catch-up publishes consumed mention metadata"
        )
        metadataPublished.assertForOverFulfill = true
        var publishedMetadata: ChatTimelineUnreadMetadata?
        var observation: ChatTimelineStoreObservation? = store.observe(
            baseline: ChatTimelineStoreObservationBaseline(
                isAuthoritative: true,
                residentItems: [target.freeze()],
                latestMessageFingerprint: initialLatestFingerprint,
                unreadCount: initialUnreadCount,
                unreadMetadataLimit: 20,
                unreadMetadata: initialMetadata
            ),
            onChange: { change in
                guard case .unreadMetadataChanged(let metadata) = change,
                      metadata.mentions.allSatisfy({
                          $0.notificationPrimary != notification.primary
                      }) else { return }
                publishedMetadata = metadata
                metadataPublished.fulfill()
            }
        )
        var didReleaseRegistration = false
        defer {
            if !didReleaseRegistration {
                registrationRelease.signal()
            }
            observation?.invalidate()
        }

        wait(for: [registrationReached], timeout: 2)
        try realm.write {
            notification.isRead = true
            MentionNotificationSync.refreshLastChatMentionIds(
                owner: owner,
                groupchatJids: [jid],
                in: realm
            )
        }
        XCTAssertNil(chat.mentionId)
        XCTAssertEqual(chat.unread, initialUnreadCount)
        XCTAssertEqual(
            ChatTimelineObservedMessageFingerprint(message: target),
            initialLatestFingerprint
        )
        registrationRelease.signal()
        didReleaseRegistration = true

        wait(for: [metadataPublished], timeout: 3)
        let activeObservation = try XCTUnwrap(observation)
        XCTAssertTrue(
            waitUntilTimelineCondition {
                activeObservation.activeWorkCount == 0
            },
            "registration catch-up must reach a stable terminal state"
        )
        XCTAssertEqual(publishedMetadata?.unreadCount, initialUnreadCount)
        XCTAssertEqual(publishedMetadata?.mentions, [])
        XCTAssertEqual(publishedMetadata?.candidateCount, 0)
        XCTAssertNil(publishedMetadata?.latestUnreadMentionArchivedId)

        let diagnostics = store.diagnosticsSnapshot.observation
        XCTAssertEqual(diagnostics.activationCount, 1)
        XCTAssertEqual(diagnostics.realmQueryCount, 2)
        XCTAssertEqual(diagnostics.mainThreadRealmQueryCount, 0)
        XCTAssertEqual(diagnostics.initialCallbackCount, 2)
        XCTAssertEqual(diagnostics.mainThreadInitialCallbackCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.maxInitialCandidateCount, 20)
        XCTAssertEqual(
            diagnostics.metadataQueryCount,
            0,
            "known mentionId consumption must not query NotificationStorageItem"
        )
        XCTAssertEqual(diagnostics.mainThreadMetadataQueryCount, 0)
        XCTAssertEqual(diagnostics.metadataFullScanCount, 0)
        XCTAssertEqual(diagnostics.pendingWorkCount, 0)

        observation?.invalidate()
        observation = nil
        wait(for: [cancelled], timeout: 2)
    }

    @MainActor
    func testAuthoritativeInitialFrameCatchUpSurvivesReadBoundaryPublishBeforeObservationRegistration()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let configuration = Realm.Configuration(
            inMemoryIdentifier:
                "ChatTimelineSessionReadBoundaryCatchUp-\(UUID().uuidString)"
        )
        Realm.Configuration.defaultConfiguration = configuration
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }

        let realm = try Realm(configuration: configuration)
        let target = MessageStorageItem()
        target.primary = "read-boundary-catch-up-target"
        target.owner = owner
        target.opponent = jid
        target.conversationType = .group
        target.archivedId = "read-boundary-catch-up-archive"
        target.messageId = "read-boundary-catch-up-message"
        target.date = Date(timeIntervalSince1970: 1_700_000_200)
        target.sentDate = target.date
        target.body = "@member unread mention before observer registration"
        target.legacyBody = target.body
        target.outgoing = false
        target.isRead = false
        target.state = .deliver

        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .group
        )
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .group
        chat.lastMessage = target
        chat.lastMessageId = target.messageId
        chat.messageDate = target.sentDate
        chat.unread = 7
        chat.syncUnreadCount = 7
        chat.runtimeUnreadCount = 0
        chat.mentionId = target.archivedId
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.fullArchiveLoaded = true

        let notification = NotificationStorageItem()
        notification.primary = NotificationStorageItem.genPrimary(
            owner: owner,
            jid: jid,
            uniqueId: "read-boundary-catch-up-notification"
        )
        notification.owner = owner
        notification.jid = jid
        notification.uniqueId = "read-boundary-catch-up-notification"
        notification.messageId = notification.uniqueId
        notification.category = .mention
        notification.isRead = false
        notification.shouldShow = true
        notification.associatedJid = jid
        notification.date = target.date
        notification.sourceConversationType = .group
        notification.sourceChatJid = jid
        notification.sourceArchivedId = target.archivedId
        notification.sourceMessageId = target.messageId
        notification.sourceSenderId = "member-other"
        notification.mentionTargetUserId = "member-me"
        notification.sourceMessageDate = target.date
        notification.mentionLinkStatus = .resolved

        try realm.write {
            realm.add(target)
            ChatLocalHistoryLinkedIndex.upsert(target, in: realm)
            realm.add(chat)
            realm.add(notification)
        }

        let registrationReached = expectation(
            description:
                "production activation held between baseline and Realm registration"
        )
        registrationReached.assertForOverFulfill = true
        let registrationRelease = DispatchSemaphore(value: 0)
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .group,
            observationTestHooks: ChatTimelineStoreObservationTestHooks(
                beforeRealmQuery: { identity in
                    guard identity == .init(
                        kind: .lastChats,
                        generation: 1
                    ) else { return }
                    registrationReached.fulfill()
                    _ = registrationRelease.wait(timeout: .now() + 5)
                },
                didRegister: nil,
                didCancel: nil
            )
        )
        let session = ChatTimelineSession(
            store: store,
            pageSize: 20,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .group
            ),
            archiveState: ChatArchiveStateSnapshot(
                primaryKey: "read-boundary-catch-up-archive-state",
                persistedCursorId: nil,
                fullArchiveLoaded: true,
                newestCursorId: target.archivedId,
                newerLiveEdgeReached: true,
                hasKnownNewerGap: false,
                knownGaps: []
            ),
            observesStoreImmediately: false
        )
        var didReleaseRegistration = false
        defer {
            if !didReleaseRegistration {
                registrationRelease.signal()
            }
            session.deactivateStoreObservation()
        }

        let framePrepared = expectation(
            description: "production initial frame and readiness proof prepared"
        )
        framePrepared.assertForOverFulfill = true
        var preparedFrame: ChatTimelinePreparedInitialFrame?
        let preparationDisposition = session.prepareInitialFrame(
            target: .latest,
            limit: 20,
            expectedGeneration: session.snapshot.generation
        ) { result in
            if case .prepared(let frame) = result {
                preparedFrame = frame
            }
            framePrepared.fulfill()
        }
        XCTAssertEqual(preparationDisposition, .started)
        wait(for: [framePrepared], timeout: 3)

        let frame = try XCTUnwrap(preparedFrame)
        let committed = try XCTUnwrap(
            session.commitPreparedInitialFrame(frame)
        )
        XCTAssertEqual(committed.generation, 1)
        XCTAssertEqual(
            committed.unreadMetadata.initialFrameReadinessProof?
                .baseGeneration,
            0
        )
        XCTAssertEqual(
            committed.unreadMetadata.latestUnreadMentionArchivedId,
            target.archivedId
        )
        XCTAssertEqual(
            committed.unreadMetadata.mentions.map(\.notificationPrimary),
            [notification.primary]
        )

        XCTAssertTrue(session.advanceReadBoundary(toPrimary: target.primary))
        let postBoundary = session.snapshot
        XCTAssertEqual(postBoundary.generation, committed.generation + 1)
        XCTAssertEqual(postBoundary.readBoundary?.primary, target.primary)
        XCTAssertEqual(
            postBoundary.unreadMetadata,
            committed.unreadMetadata,
            "a read-boundary-only publication must preserve the authoritative " +
                "initial-frame unread baseline"
        )

        session.activateStoreObservation()
        wait(for: [registrationReached], timeout: 2)

        try realm.write {
            notification.isRead = true
            chat.mentionId = nil
        }
        XCTAssertTrue(notification.isRead)
        XCTAssertNil(chat.mentionId)
        XCTAssertEqual(chat.unread, committed.unreadMetadata.unreadCount)

        registrationRelease.signal()
        didReleaseRegistration = true

        let didPublishCatchUp = waitUntilTimelineCondition {
            let snapshot = session.snapshot
            return snapshot.cause == .storeChange &&
                snapshot.generation > postBoundary.generation &&
                snapshot.readBoundary == postBoundary.readBoundary &&
                snapshot.unreadMetadata.mentions.allSatisfy {
                    $0.notificationPrimary != notification.primary
                } &&
                snapshot.unreadMetadata.latestUnreadMentionArchivedId == nil
        }
        XCTAssertTrue(
            didPublishCatchUp,
            "a metadata-only generation between initial-frame commit and " +
                "activation must not disable authoritative registration catch-up"
        )
        guard didPublishCatchUp else { return }

        XCTAssertTrue(
            waitUntilTimelineCondition {
                session.activeStoreObservationWorkCount == 0
            },
            "the production observation must settle after bounded catch-up"
        )
        XCTAssertEqual(session.snapshot.unreadMetadata.mentions, [])
        XCTAssertEqual(session.snapshot.unreadMetadata.candidateCount, 0)
        XCTAssertEqual(
            session.snapshot.unreadMetadata.unreadCount,
            committed.unreadMetadata.unreadCount
        )

        let diagnostics = store.diagnosticsSnapshot.observation
        XCTAssertEqual(diagnostics.activationCount, 1)
        XCTAssertEqual(diagnostics.realmQueryCount, 2)
        XCTAssertEqual(diagnostics.mainThreadRealmQueryCount, 0)
        XCTAssertEqual(diagnostics.initialCallbackCount, 2)
        XCTAssertEqual(diagnostics.mainThreadInitialCallbackCount, 0)
        XCTAssertLessThanOrEqual(
            diagnostics.maxInitialCandidateCount,
            postBoundary.residentHardLimit
        )
        XCTAssertEqual(
            diagnostics.metadataQueryCount,
            0,
            "known mentionId consumption must use the bounded baseline transition"
        )
        XCTAssertEqual(diagnostics.mainThreadMetadataQueryCount, 0)
        XCTAssertEqual(diagnostics.metadataFullScanCount, 0)
        XCTAssertEqual(diagnostics.pendingWorkCount, 0)
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

    func testStructuralPublishBetweenAuthoritativeCaptureAndObservationInstallRejectsOldInitialBatch() throws {
        let messages = makeMessages(count: 8)
        let archiveState = ChatArchiveStateSnapshot(
            primaryKey: "activation-authority-race-archive-state",
            persistedCursorId: nil,
            fullArchiveLoaded: true,
            newestCursorId: messages.last?.archivedId,
            newerLiveEdgeReached: true,
            hasKnownNewerGap: false,
            knownGaps: []
        )
        let observationEntered = expectation(
            description: "authoritative baseline reached store observation"
        )
        observationEntered.assertForOverFulfill = true
        let activationFinished = expectation(
            description: "store observation activation finished"
        )
        activationFinished.assertForOverFulfill = true
        let observationRelease = DispatchSemaphore(value: 0)
        let structuralFinished = DispatchSemaphore(value: 0)
        let raceLock = NSLock()
        var firstCapturedBaseline: ChatTimelineStoreObservationBaseline?
        var structuralSnapshot: ChatTimelineSessionSnapshot?
        var observationHookInvocationCount = 0
        let oldResident = messages[messages.count - 2]
        let oldInitialBatch = ChatIncrementalMessageMutationBatch(
            mutations: [
                ChatIncrementalMessageMutation.upsert(
                    identity: ChatIncrementalMessageIdentity(
                        message: oldResident
                    ),
                    revision: 1,
                    payload: oldResident
                )
            ],
            enqueuedMutationCount: 1
        )
        let store = FakeChatTimelineSessionStore(
            messages: messages,
            initialFrameArchiveState: archiveState,
            observationInstallationHook: { baseline, onChange in
                let isFirst = raceLock.withLock { () -> Bool in
                    observationHookInvocationCount += 1
                    guard observationHookInvocationCount == 1 else {
                        return false
                    }
                    firstCapturedBaseline = baseline
                    return true
                }
                guard isFirst else { return }
                observationEntered.fulfill()
                _ = observationRelease.wait(timeout: .now() + 5)
                onChange(.incremental(
                    oldInitialBatch,
                    refreshUnread: false
                ))
            }
        )
        let session = ChatTimelineSession(
            store: store,
            pageSize: 2,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            archiveState: archiveState,
            observesStoreImmediately: false
        )
        var didReleaseObservation = false
        defer {
            if !didReleaseObservation {
                observationRelease.signal()
            }
            session.deactivateStoreObservation()
        }

        let framePrepared = expectation(
            description: "authoritative initial frame prepared"
        )
        framePrepared.assertForOverFulfill = true
        var preparedFrame: ChatTimelinePreparedInitialFrame?
        XCTAssertEqual(
            session.prepareInitialFrame(
                target: .latest,
                limit: 4,
                expectedGeneration: session.snapshot.generation
            ) { result in
                if case .prepared(let frame) = result {
                    preparedFrame = frame
                }
                framePrepared.fulfill()
            },
            .started
        )
        wait(for: [framePrepared], timeout: 2)
        let committed = try XCTUnwrap(
            session.commitPreparedInitialFrame(
                try XCTUnwrap(preparedFrame)
            )
        )
        XCTAssertTrue(committed.items.contains {
            $0.primary == oldResident.primary
        })

        DispatchQueue.global(qos: .userInitiated).async {
            session.activateStoreObservation()
            activationFinished.fulfill()
        }
        wait(for: [observationEntered], timeout: 2)
        XCTAssertTrue(
            try XCTUnwrap(
                raceLock.withLock { firstCapturedBaseline }
            ).isAuthoritative,
            "the race must start from an authoritative committed-frame baseline"
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let published = session.openAround(
                anchor: ChatTimelineAnchor(
                    primary: messages[0].primary,
                    archivedId: messages[0].archivedId,
                    messageId: messages[0].messageId,
                    date: messages[0].date
                )
            )
            raceLock.withLock {
                structuralSnapshot = published
            }
            structuralFinished.signal()
        }

        // On the defective implementation the structural command completes
        // while `observe` is blocked. A safe implementation may instead
        // serialize activation; release it without making that strategy fail.
        let structuralWonInstallationWindow =
            structuralFinished.wait(timeout: .now() + 0.5) == .success
        observationRelease.signal()
        didReleaseObservation = true
        wait(for: [activationFinished], timeout: 2)
        if !structuralWonInstallationWindow {
            XCTAssertEqual(
                structuralFinished.wait(timeout: .now() + 2),
                .success,
                "the serialized structural command must finish after activation"
            )
        }

        let expectedStructuralSnapshot = try XCTUnwrap(
            raceLock.withLock { structuralSnapshot }
        )
        XCTAssertFalse(expectedStructuralSnapshot.state.isResidentAtLiveTail)
        XCTAssertFalse(expectedStructuralSnapshot.items.contains {
            $0.primary == oldResident.primary
        })
        XCTAssertEqual(
            session.snapshot.generation,
            expectedStructuralSnapshot.generation,
            "an initial batch tied to superseded S1 authority must not publish " +
                "after structural S2 has won installation"
        )
        XCTAssertEqual(
            store.observation?.residentPrimaryKeys,
            expectedStructuralSnapshot.items.map(\.primary),
            "the installed observer must monitor the winning structural window, " +
                "not the captured S1 resident keys"
        )
    }

    func testSupersededResidentDeliveryPreservesIndependentLatestAndUnreadMetadata() throws {
        let messages = makeMessages(count: 20)
        let store = FakeChatTimelineSessionStore(messages: messages)
        let session = makeSession(store: store, pageSize: 4)
        defer { session.deactivateStoreObservation() }

        let firstWindow = session.openLatest(limit: 8)
        XCTAssertEqual(firstWindow.items.map(\.primary), primaryRange(12...19))
        let observation = try XCTUnwrap(store.observation)
        let supersededGeneration = observation.residentGeneration

        let structuralWinner = session.openAround(
            anchor: ChatTimelineAnchor(
                primary: messages[14].primary,
                archivedId: messages[14].archivedId,
                messageId: messages[14].messageId,
                date: messages[14].date
            )
        )
        XCTAssertEqual(
            structuralWinner.items.map(\.primary),
            primaryRange(12...15)
        )
        XCTAssertFalse(
            observation.authorizesResidentMutation(
                generation: supersededGeneration
            )
        )

        let replacementPayloads = makeMessages(count: 20)
        replacementPayloads[12].body = "stale resident body"
        replacementPayloads[12].legacyBody = replacementPayloads[12].body
        replacementPayloads[13].body = "independent latest body"
        replacementPayloads[13].legacyBody = replacementPayloads[13].body
        let staleResidentRevision: UInt64 = 101
        let independentLatestRevision: UInt64 = 102
        let batch = ChatIncrementalMessageMutationBatch(
            mutations: [
                .upsert(
                    identity: ChatIncrementalMessageIdentity(
                        message: replacementPayloads[12]
                    ),
                    revision: staleResidentRevision,
                    payload: replacementPayloads[12]
                ),
                .upsert(
                    identity: ChatIncrementalMessageIdentity(
                        message: replacementPayloads[13]
                    ),
                    revision: independentLatestRevision,
                    payload: replacementPayloads[13]
                )
            ],
            enqueuedMutationCount: 2,
            residentGenerationByRevision: [
                staleResidentRevision: supersededGeneration
            ]
        )
        let unreadMetadata = ChatTimelineUnreadMetadata(
            unreadCount: 7,
            mentions: [],
            candidateCount: 0
        )

        store.emit(.incrementalWithUnreadMetadata(
            batch,
            unreadMetadata: unreadMetadata
        ))

        let delivered = session.snapshot
        XCTAssertEqual(
            delivered.generation,
            structuralWinner.generation + 1,
            "the mixed callback must publish exactly once"
        )
        XCTAssertNotEqual(
            delivered.item(primary: "primary-12")?.body,
            "stale resident body",
            "a resident mutation from the replaced generation must be dropped"
        )
        XCTAssertEqual(
            delivered.item(primary: "primary-13")?.body,
            "independent latest body",
            "an untagged LastChats/latest mutation must survive resident rejection"
        )
        XCTAssertEqual(delivered.unreadMetadata, unreadMetadata)
        XCTAssertEqual(
            delivered.residentChangeSet?.updatedStablePrimaries,
            ["primary-13"]
        )
    }

    func testObservationAuthorityLineageRejectsResidentOrUnreadMutation() throws {
        let messages = makeMessages(count: 6)
        let store = FakeChatTimelineSessionStore(messages: messages)
        let session = makeSession(store: store, pageSize: 2)
        let previous = session.openLatest()
        let firstBoundaryTarget = try XCTUnwrap(previous.items.dropFirst().first)
        let secondBoundaryTarget = try XCTUnwrap(previous.items.dropFirst(2).first)
        let conversationKey = ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let lineage = ChatTimelineStoreObservationAuthorityLineage(
            conversationKey: conversationKey,
            proofBaseGeneration: 0,
            currentGeneration: previous.generation,
            projection: .capture(previous)
        )
        let advancedBoundary = ChatTimelineReadBoundary(
            primary: firstBoundaryTarget.primary,
            position: ChatTimelinePositionKey(message: firstBoundaryTarget)
        )
        let secondAdvancedBoundary = ChatTimelineReadBoundary(
            primary: secondBoundaryTarget.primary,
            position: ChatTimelinePositionKey(message: secondBoundaryTarget)
        )
        let boundaryOnly = replacingSnapshot(
            previous,
            generation: previous.generation &+ 1,
            readBoundary: advancedBoundary
        )

        let preserved = ChatTimelineStoreObservationAuthorityPolicy.updatedLineage(
            lineage,
            from: previous,
            to: boundaryOnly,
            conversationKey: conversationKey,
            publication: .readBoundaryOnly
        )

        XCTAssertEqual(preserved?.currentGeneration, boundaryOnly.generation)
        XCTAssertEqual(preserved?.projection, lineage.projection)

        let editedItems = makeMessages(count: 6)
        editedItems[5].messageId = "message-edited-after-baseline"
        let residentMutation = replacingSnapshot(
            boundaryOnly,
            generation: boundaryOnly.generation &+ 1,
            items: editedItems,
            readBoundary: secondAdvancedBoundary
        )
        XCTAssertNil(
            ChatTimelineStoreObservationAuthorityPolicy.updatedLineage(
                preserved,
                from: boundaryOnly,
                to: residentMutation,
                conversationKey: conversationKey,
                publication: .readBoundaryOnly
            ),
            "a resident revision must invalidate the deferred observer baseline"
        )

        let changedUnreadMetadata = ChatTimelineUnreadMetadata(
            unreadCount: boundaryOnly.unreadMetadata.unreadCount + 1,
            mentions: boundaryOnly.unreadMetadata.mentions,
            candidateCount: boundaryOnly.unreadMetadata.candidateCount,
            initialFrameReadinessProof:
                boundaryOnly.unreadMetadata.initialFrameReadinessProof,
            latestUnreadMentionArchivedId:
                boundaryOnly.unreadMetadata.latestUnreadMentionArchivedId
        )
        let unreadMutation = replacingSnapshot(
            boundaryOnly,
            generation: boundaryOnly.generation &+ 1,
            readBoundary: secondAdvancedBoundary,
            unreadMetadata: changedUnreadMetadata
        )
        XCTAssertNil(
            ChatTimelineStoreObservationAuthorityPolicy.updatedLineage(
                preserved,
                from: boundaryOnly,
                to: unreadMutation,
                conversationKey: conversationKey,
                publication: .readBoundaryOnly
            ),
            "an unread-metadata revision must invalidate the deferred observer baseline"
        )
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

    @MainActor
    private func waitUntilTimelineCondition(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        return condition()
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

    private func replacingSnapshot(
        _ snapshot: ChatTimelineSessionSnapshot,
        generation: UInt64,
        items: [MessageStorageItem]? = nil,
        readBoundary: ChatTimelineReadBoundary?,
        unreadMetadata: ChatTimelineUnreadMetadata? = nil
    ) -> ChatTimelineSessionSnapshot {
        let replacementItems = items ?? snapshot.items
        return ChatTimelineSessionSnapshot(
            generation: generation,
            cause: .command,
            items: replacementItems,
            state: snapshot.state,
            loadingState: snapshot.loadingState,
            loadDecision: snapshot.loadDecision,
            anchorRestore: snapshot.anchorRestore,
            localOlderCandidateCount: snapshot.localOlderCandidateCount,
            pageSize: snapshot.pageSize,
            shortLocalRemainderRemoteFirst:
                snapshot.shortLocalRemainderRemoteFirst,
            residentIndex: ChatTimelineResidentIndex(items: replacementItems),
            readBoundary: readBoundary,
            unreadMetadata: unreadMetadata ?? snapshot.unreadMetadata,
            residentHardLimit: snapshot.residentHardLimit,
            residentChangeSet: snapshot.residentChangeSet
        )
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
    private(set) var firstIncomingQueryCount = 0
    private(set) var unreadQueryLimits: [Int] = []
    private(set) var observation: FakeChatTimelineObservation?
    private var unreadMetadata: ChatTimelineUnreadMetadata
    private let initialFrameArchiveState: ChatArchiveStateSnapshot?
    private let observationInstallationHook: ((
        ChatTimelineStoreObservationBaseline,
        (ChatTimelineStoreChange) -> Void
    ) -> Void)?
    let logicalRowCount: Int
    private(set) var diagnosticsSnapshot = ChatTimelineStoreDiagnosticsSnapshot.empty

    init(
        messages: [MessageStorageItem],
        logicalRowCount: Int? = nil,
        unreadMetadata: ChatTimelineUnreadMetadata = .empty,
        initialFrameArchiveState: ChatArchiveStateSnapshot? = nil,
        observationInstallationHook: ((
            ChatTimelineStoreObservationBaseline,
            (ChatTimelineStoreChange) -> Void
        ) -> Void)? = nil
    ) {
        self.messages = ChatTimelineOrdering.chronological(messages)
        self.logicalRowCount = logicalRowCount ?? messages.count
        self.unreadMetadata = unreadMetadata
        self.initialFrameArchiveState = initialFrameArchiveState
        self.observationInstallationHook = observationInstallationHook
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
        firstIncomingQueryCount += 1
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

    func initialFrameMetadata(
        limit: Int,
        materializedLocalMessageCount: Int,
        conversationKey: ChatTimelineConversationKey,
        baseGeneration: UInt64
    ) -> ChatTimelineUnreadMetadata {
        guard let initialFrameArchiveState else {
            return unreadMetadata(limit: limit)
        }
        return ChatTimelineUnreadMetadata(
            unreadCount: unreadMetadata.unreadCount,
            mentions: unreadMetadata.mentions,
            candidateCount: unreadMetadata.candidateCount,
            initialFrameReadinessProof: ChatTimelineInitialFrameReadinessProof(
                conversationKey: conversationKey,
                baseGeneration: baseGeneration,
                materializedLocalMessageCount:
                    max(0, materializedLocalMessageCount),
                isSynced: true,
                isInitialArchiveLoaded: true,
                hasDurableArchiveReadiness: true,
                archiveState: initialFrameArchiveState,
                chatFullArchiveLoaded:
                    initialFrameArchiveState.fullArchiveLoaded,
                loadedRanges: [],
                knownGaps: initialFrameArchiveState.knownGaps,
                archiveBoundaryFingerprint: nil,
                hasKnownRemoteArchiveBoundary: false,
                latestMessageFingerprint: messages.last.map(
                    ChatTimelineObservedMessageFingerprint.init(message:)
                )
            ),
            latestUnreadMentionArchivedId:
                unreadMetadata.latestUnreadMentionArchivedId
        )
    }

    func observe(
        baseline: ChatTimelineStoreObservationBaseline,
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) -> ChatTimelineStoreObservation {
        observationInstallationHook?(baseline, onChange)
        let observation = FakeChatTimelineObservation(
            residentPrimaryKeys: baseline.residentPrimaryKeys,
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
    private(set) var residentGeneration: UInt64 = 1
    private(set) var isInvalidated = false

    init(
        residentPrimaryKeys: [String],
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) {
        self.residentPrimaryKeys = residentPrimaryKeys
        self.onChange = onChange
    }

    func replaceResidentItems(_ items: [MessageStorageItem]) {
        let replacement = items.map(\.primary)
        guard replacement != residentPrimaryKeys else { return }
        residentPrimaryKeys = replacement
        residentGeneration &+= 1
    }

    func authorizesResidentMutation(generation: UInt64) -> Bool {
        !isInvalidated && residentGeneration == generation
    }

    func invalidate() {
        isInvalidated = true
    }

    func emit(_ change: ChatTimelineStoreChange) {
        guard !isInvalidated else { return }
        onChange(change)
    }
}

private extension NSLocking {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
