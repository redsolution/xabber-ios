import XCTest
import UIKit
import RealmSwift
import XMPPFramework
@testable import xabber

private final class ChatGapWorkerPhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [(ChatRemoteHistoryApplyWorkerPhase, Bool)] = []

    func record(
        phase: ChatRemoteHistoryApplyWorkerPhase,
        isMain: Bool
    ) {
        lock.lock()
        phases.append((phase, isMain))
        lock.unlock()
    }

    var snapshot: [(ChatRemoteHistoryApplyWorkerPhase, Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return phases
    }
}

/// Production-shaped coverage for regular-chat internal gap repair.
///
/// Every terminal enters through MessageArchiveManager. Non-empty envelopes
/// traverse MessageManager and Realm before the resident session is refetched
/// and the controller publishes one UIKit transaction.
@MainActor
final class ChatGapRepairIntegrationTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatGapRepairIntegrationTests-\(name)"
        )
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        ChatRemoteHistoryCompletionCoordinator.resetPersistenceFlushesForTests()
    }

    override func tearDown() {
        ChatRemoteHistoryCompletionCoordinator.resetPersistenceFlushesForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testPartialRepairCommitPerformsExactlyOneOffMainRefetchMapAndApply() throws {
        let harness = try makeHarness(testSuffix: "partial")
        defer { harness.tearDown() }
        let queryId = "gap-partial-query"
        let pipeline = try armOlderGapPipeline(harness, queryId: queryId)
        defer { pipeline.tearDown() }
        let baselineDiagnostics = harness.store.diagnosticsSnapshot
        let baselineRows = try persistedMessageCount(harness)
        let baselineIDs = harness.controller.datasource.map(\.primary)
        var applyThreads: [Bool] = []
        let workerPhaseRecorder = ChatGapWorkerPhaseRecorder()
        harness.controller.remoteHistoryQueryCoordinator
            .remoteApplyWorkerObserverForTests = { observedQueryId, phase, isMain in
                guard observedQueryId == queryId else { return }
                workerPhaseRecorder.record(phase: phase, isMain: isMain)
            }
        harness.controller.datasourceDidSetForTests = { _ in
            applyThreads.append(Thread.isMainThread)
        }

        for (archiveId, messageId, stamp) in [
            ("399", "gap-partial-399", "1970-01-01T00:00:00.000399Z"),
            ("300", "gap-partial-300", "1970-01-01T00:00:00.000300Z")
        ] {
            let envelope = try archiveEnvelope(
                harness: harness,
                queryId: queryId,
                archiveId: archiveId,
                messageId: messageId,
                stamp: stamp
            )
            XCTAssertTrue(pipeline.mam.recordDeferredArchiveResultDelivery(envelope))
            pipeline.messages.receiveArchived(envelope)
        }

        XCTAssertEqual(try persistedMessageCount(harness), baselineRows)
        XCTAssertEqual(harness.controller.datasource.map(\.primary), baselineIDs)
        XCTAssertTrue(harness.controller.timelineInteractionState.locked)

        let final = try archiveFinalIQ(
            queryId: queryId,
            complete: false,
            cardinality: 501,
            first: "399",
            last: "300"
        )
        XCTAssertTrue(pipeline.mam.read(pipeline.stream, withIQ: final))
        XCTAssertTrue(waitUntil {
            harness.controller.interactiveHistoryPageLoadContext == nil &&
                harness.controller.datasource.contains { $0.archivedId == "300" }
        })

        let routeDiagnostics = harness.store.diagnosticsSnapshot.routeDelta(
            since: baselineDiagnostics
        )
        XCTAssertEqual(routeDiagnostics.operationCounts["older"], 1)
        XCTAssertEqual(routeDiagnostics.mainThreadQueryCount, 0)
        let workerPhases = workerPhaseRecorder.snapshot
        XCTAssertEqual(workerPhases.map(\.0), [.refetch, .map])
        XCTAssertEqual(workerPhases.filter { $0.0 == .refetch }.count, 1)
        XCTAssertEqual(workerPhases.filter { $0.0 == .map }.count, 1)
        XCTAssertTrue(workerPhases.allSatisfy { !$0.1 })
        XCTAssertEqual(applyThreads, [true])
        XCTAssertTrue(harness.controller.timelineInteractionState.isUnlocked)
        XCTAssertEqual(try persistedMessageCount(harness), baselineRows + 2)
        let expectedMessagePrimaries = [
            MessageStorageItem.genPrimary(
                messageId: "gap-partial-300",
                owner: harness.owner
            ),
            MessageStorageItem.genPrimary(
                messageId: "gap-partial-399",
                owner: harness.owner
            ),
            MessageStorageItem.genPrimary(
                messageId: "seed-partial-400",
                owner: harness.owner
            ),
            MessageStorageItem.genPrimary(
                messageId: "seed-partial-500",
                owner: harness.owner
            )
        ]
        assertStrictGapDatasource(
            harness.controller,
            expectedMessagePrimaries: expectedMessagePrimaries
        )
        XCTAssertEqual(
            try archiveState(harness).knownGaps,
            [
                RegularChatArchiveGap(
                    olderRangeNewestArchiveId: "200",
                    newerRangeOldestArchiveId: "300"
                ),
                RegularChatArchiveGap(
                    olderRangeNewestArchiveId: "500",
                    newerRangeOldestArchiveId: "700"
                )
            ]
        )

        let committedIDs = harness.controller.datasource.map(\.primary)
        let committedGeneration = harness.controller.timelineSession?.snapshot.generation
        _ = pipeline.mam.read(pipeline.stream, withIQ: final)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(harness.controller.datasource.map(\.primary), committedIDs)
        XCTAssertEqual(harness.controller.timelineSession?.snapshot.generation, committedGeneration)
        XCTAssertEqual(applyThreads, [true])
    }

    func testZeroRowGapTerminalClosesOnlyProvenEdgeAndDoesNotLoop() throws {
        let harness = try makeHarness(testSuffix: "zero")
        defer { harness.tearDown() }
        let queryId = "gap-zero-query"
        let pipeline = try armOlderGapPipeline(harness, queryId: queryId)
        defer { pipeline.tearDown() }
        let rowsBefore = harness.controller.datasource.map(\.primary)
        let stateBefore = try archiveStateSnapshot(harness)
        let targetGap = RegularChatArchiveGap(
            olderRangeNewestArchiveId: "200",
            newerRangeOldestArchiveId: "400"
        )
        let unrelatedGap = RegularChatArchiveGap(
            olderRangeNewestArchiveId: "500",
            newerRangeOldestArchiveId: "700"
        )
        XCTAssertEqual(stateBefore.knownGaps, [targetGap, unrelatedGap])

        let wrongCursorDecision = ChatArchiveCoverageCommitPolicy.resolve(
            direction: .older,
            snapshot: stateBefore,
            requestedCursorId: "999",
            observedCursorId: nil,
            transportFirst: "",
            transportLast: "",
            resultCount: 0,
            persistedRowsForQuery: 0,
            visibleRowsForConversation: 0,
            queryExhausted: true,
            canMutateOlderArchiveEnd: false,
            coverageUpdateKind: .gapRepairOlder(cursorArchiveId: "999")
        )
        XCTAssertNil(wrongCursorDecision.authoritativeEmptyGapCoverage)

        let nonExhaustedDecision = ChatArchiveCoverageCommitPolicy.resolve(
            direction: .older,
            snapshot: stateBefore,
            requestedCursorId: "400",
            observedCursorId: nil,
            transportFirst: "",
            transportLast: "",
            resultCount: 0,
            persistedRowsForQuery: 0,
            visibleRowsForConversation: 0,
            queryExhausted: false,
            canMutateOlderArchiveEnd: false,
            coverageUpdateKind: .gapRepairOlder(cursorArchiveId: "400")
        )
        XCTAssertNil(nonExhaustedDecision.authoritativeEmptyGapCoverage)

        let exactTerminalDecision = ChatArchiveCoverageCommitPolicy.resolve(
            direction: .older,
            snapshot: stateBefore,
            requestedCursorId: "400",
            observedCursorId: nil,
            transportFirst: "",
            transportLast: "",
            resultCount: 0,
            persistedRowsForQuery: 0,
            visibleRowsForConversation: 0,
            queryExhausted: true,
            canMutateOlderArchiveEnd: false,
            coverageUpdateKind: .gapRepairOlder(cursorArchiveId: "400")
        )
        XCTAssertEqual(
            exactTerminalDecision.authoritativeEmptyGapCoverage,
            ChatAuthoritativeEmptyGapCoverage(
                first: "200",
                last: "400",
                updateKind: .gapRepairOlder(cursorArchiveId: "400")
            )
        )

        let final = try archiveFinalIQ(
            queryId: queryId,
            complete: true,
            cardinality: 501,
            first: "",
            last: ""
        )
        XCTAssertTrue(pipeline.mam.read(pipeline.stream, withIQ: final))
        XCTAssertTrue(waitUntil {
            harness.controller.interactiveHistoryPageLoadContext == nil &&
                harness.controller.timelineInteractionState.isUnlocked
        })

        let state = try archiveState(harness)
        XCTAssertEqual(state.knownGaps, [unrelatedGap])
        XCTAssertFalse(state.olderArchiveEndReached)
        XCTAssertTrue(state.newerLiveEdgeReached)
        XCTAssertEqual(harness.controller.datasource.map(\.primary), rowsBefore)
        XCTAssertFalse(harness.controller.datasource.contains {
            ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .skeleton
        })

        XCTAssertNil(ChatArchiveGapPagingPolicy.loadDecision(
            direction: .older,
            currentWindow: ChatDatasetWindow(minIndex: 1, maxIndex: 2),
            requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 1),
            archivedIdsByIndex: ["200", "400"],
            knownGaps: state.knownGaps
        ), "the repaired 200...400 interval must not schedule another request")
        let generation = harness.controller.timelineSession?.snapshot.generation
        _ = pipeline.mam.read(pipeline.stream, withIQ: final)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(harness.controller.timelineSession?.snapshot.generation, generation)
        XCTAssertEqual(try archiveState(harness).knownGaps, [unrelatedGap])
    }

    func testGapFailureKeepsExistingRowsInteractiveAndGeometryUnchangedWithOneRetryPolicy() throws {
        let harness = try makeHarness(testSuffix: "failure")
        defer { harness.tearDown() }
        let queryId = "gap-failure-query"
        let pipeline = try armOlderGapPipeline(harness, queryId: queryId)
        defer { pipeline.tearDown() }
        harness.controller.messagesCollectionView.layoutIfNeeded()
        harness.controller.messagesCollectionView.contentOffset = CGPoint(x: 0, y: 17)

        let ids = harness.controller.datasource.map(\.primary)
        let window = harness.controller.visibleWindow()
        let size = harness.controller.messagesCollectionView.contentSize
        let offset = harness.controller.messagesCollectionView.contentOffset
        let generation = try XCTUnwrap(harness.controller.timelineSession).snapshot.generation
        let coverage = try archiveStateSnapshot(harness)
        var datasourceSetCount = 0
        harness.controller.datasourceDidSetForTests = { _ in
            datasourceSetCount += 1
        }

        XCTAssertTrue(pipeline.mam.read(
            pipeline.stream,
            withIQ: try archiveErrorIQ(queryId: queryId)
        ))
        XCTAssertTrue(waitUntil {
            harness.controller.interactiveHistoryPageLoadContext == nil &&
                harness.controller.timelineInteractionState.isUnlocked
        })

        XCTAssertEqual(harness.controller.datasource.map(\.primary), ids)
        XCTAssertEqual(harness.controller.visibleWindow(), window)
        XCTAssertEqual(harness.controller.messagesCollectionView.contentSize, size)
        XCTAssertEqual(harness.controller.messagesCollectionView.contentOffset, offset)
        XCTAssertEqual(harness.controller.timelineSession?.snapshot.generation, generation)
        XCTAssertEqual(try archiveStateSnapshot(harness), coverage)
        XCTAssertEqual(datasourceSetCount, 0)
        XCTAssertFalse(harness.controller.datasource.contains {
            ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .skeleton
        })
        XCTAssertTrue(harness.controller.messagesCollectionView.isUserInteractionEnabled)
        XCTAssertTrue(harness.controller.messagesCollectionView.isScrollEnabled)

        try insertOlderSideRowsForBoundaryPaging(harness)
        let retryBaseSnapshot = try XCTUnwrap(harness.controller.timelineSession).snapshot
        let retryMessages = MessageManager(withOwner: harness.owner, activeStream: false)
        retryMessages.updateSendingMessagesTimer?.invalidate()
        retryMessages.updateSendingMessagesTimer = nil
        retryMessages.unsubscribeSender()
        defer {
            harness.controller.interactiveRemoteArchiveRequestDispatcher =
                AccountSchedulerChatInteractiveRemoteArchiveRequestDispatcher()
            retryMessages.updateSendingMessagesTimer?.invalidate()
            retryMessages.updateSendingMessagesTimer = nil
            retryMessages.unsubscribeReceiver()
            retryMessages.unsubscribeSender()
        }
        let retryMAM = MessageArchiveManager(withOwner: harness.owner)
        let retryStream = XMPPStream()
        var retryAdmissionCount = 0
        var retryTransportStartCount = 0
        var admittedRetryQueryId: String?
        harness.controller.interactiveRemoteArchiveRequestDispatcher =
            ChatPerformanceFixtureInteractiveRemoteArchiveDispatcher { request in
                retryAdmissionCount += 1
                admittedRetryQueryId = request.queryId
                XCTAssertEqual(request.owner, harness.owner)
                XCTAssertEqual(request.direction, .older)
                XCTAssertEqual(request.cursorId, "400")
                XCTAssertEqual(request.pageSize, harness.controller.datasourcePageSize)
                XCTAssertTrue(request.shouldDispatch())
                request.schedulerLease.attach {}
                retryMessages.archiveQueryIdPersistenceResolver = {
                    $0 == request.queryId
                }
                XCTAssertEqual(
                    request.performanceFixtureSend?(
                        retryStream,
                        retryMAM,
                        retryMessages
                    ),
                    request.queryId
                )
                retryTransportStartCount += 1
                request.transportStarted(request.queryId, .primary, nil)
            }

        harness.controller.messagesCollectionView.layoutIfNeeded()
        harness.controller.messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: 0),
            at: .top,
            animated: false
        )
        harness.controller.messagesCollectionView.layoutIfNeeded()
        let retrySize = harness.controller.messagesCollectionView.contentSize
        let retryOffset = harness.controller.messagesCollectionView.contentOffset
        harness.controller.performInteractiveHistoryPaging(direction: .older)
        XCTAssertTrue(waitUntil {
            retryAdmissionCount == 1 &&
                retryTransportStartCount == 1 &&
                harness.controller.interactiveHistoryPageLoadContext?
                    .remoteFetchStarted == true
        })
        let retryQueryId = try XCTUnwrap(admittedRetryQueryId)
        let retryContext = try XCTUnwrap(
            harness.controller.interactiveHistoryPageLoadContext
        )
        XCTAssertEqual(retryContext.queryId, retryQueryId)
        XCTAssertEqual(retryContext.direction, .older)
        XCTAssertEqual(retryContext.requestedCursorId, "400")
        XCTAssertEqual(
            retryContext.coverageUpdateKind,
            .gapRepairOlder(cursorArchiveId: "400")
        )
        XCTAssertEqual(retryMAM.pendingArchiveRequestQueryIds(), [retryQueryId])
        XCTAssertEqual(harness.controller.remoteHistoryQueryCoordinator.activeQueryCount, 1)
        let armedGeneration = retryBaseSnapshot.generation &+ 1
        XCTAssertEqual(
            harness.controller.timelineSession?.snapshot.generation,
            armedGeneration,
            "remote gap admission owns exactly one session generation"
        )
        XCTAssertEqual(
            harness.controller.timelineSession?.snapshot.state.activeRemoteLoad?
                .queryId,
            retryQueryId
        )
        XCTAssertEqual(
            harness.controller.timelineSession?.snapshot.items.map(\.primary),
            retryBaseSnapshot.items.map(\.primary),
            "locally prepared rows remain provisional until the gap page succeeds"
        )
        XCTAssertEqual(
            harness.controller.virtualTimelineState.residentPrimaryKeys,
            retryBaseSnapshot.state.residentPrimaryKeys
        )
        XCTAssertEqual(harness.controller.visibleWindow(), window)
        XCTAssertEqual(harness.controller.datasource.map(\.primary), ids)
        XCTAssertEqual(harness.controller.messagesCollectionView.contentSize, retrySize)
        XCTAssertEqual(harness.controller.messagesCollectionView.contentOffset, retryOffset)
        XCTAssertEqual(datasourceSetCount, 0)

        harness.controller.performInteractiveHistoryPaging(direction: .older)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(retryAdmissionCount, 1)
        XCTAssertEqual(retryTransportStartCount, 1)
        XCTAssertEqual(
            harness.controller.interactiveHistoryPageLoadContext?.queryId,
            retryQueryId
        )
        XCTAssertEqual(harness.controller.remoteHistoryQueryCoordinator.activeQueryCount, 1)
        XCTAssertEqual(
            harness.controller.timelineSession?.snapshot.generation,
            armedGeneration,
            "a duplicate retry gesture must not publish another generation"
        )
        XCTAssertEqual(harness.controller.datasource.map(\.primary), ids)
        XCTAssertEqual(harness.controller.visibleWindow(), window)
        XCTAssertEqual(harness.controller.messagesCollectionView.contentSize, retrySize)
        XCTAssertEqual(harness.controller.messagesCollectionView.contentOffset, retryOffset)
        XCTAssertEqual(datasourceSetCount, 0)

        XCTAssertTrue(retryMAM.read(
            retryStream,
            withIQ: try archiveErrorIQ(queryId: retryQueryId)
        ))
        XCTAssertTrue(waitUntil {
            harness.controller.interactiveHistoryPageLoadContext == nil &&
                harness.controller.remoteHistoryQueryCoordinator.activeQueryCount == 0
        })
        XCTAssertEqual(harness.controller.remoteHistoryQueryCoordinator.activeQueryCount, 0)
        XCTAssertEqual(harness.controller.datasource.map(\.primary), ids)
        XCTAssertEqual(harness.controller.visibleWindow(), window)
        XCTAssertEqual(harness.controller.messagesCollectionView.contentSize, retrySize)
        XCTAssertEqual(harness.controller.messagesCollectionView.contentOffset, retryOffset)
        XCTAssertEqual(
            harness.controller.timelineSession?.snapshot.generation,
            armedGeneration &+ 1,
            "matching abort owns exactly one terminal session generation"
        )
        XCTAssertNil(harness.controller.timelineSession?.snapshot.state.activeRemoteLoad)
        XCTAssertEqual(
            harness.controller.timelineSession?.snapshot.items.map(\.primary),
            retryBaseSnapshot.items.map(\.primary)
        )
        XCTAssertEqual(try archiveStateSnapshot(harness), coverage)
        XCTAssertEqual(datasourceSetCount, 0)
        XCTAssertFalse(harness.controller.datasource.contains {
            ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .skeleton
        })
        XCTAssertTrue(harness.controller.messagesCollectionView.isUserInteractionEnabled)
        XCTAssertTrue(harness.controller.messagesCollectionView.isScrollEnabled)
    }

    private struct Harness {
        let owner: String
        let jid: String
        let controller: ChatViewController
        let store: RealmChatTimelineSessionStore

        func tearDown() {
            controller.performTerminalChatResourceTeardownForTesting()
        }
    }

    private struct Pipeline {
        let mam: MessageArchiveManager
        let messages: MessageManager
        let stream: XMPPStream

        func tearDown() {
            messages.updateSendingMessagesTimer?.invalidate()
            messages.updateSendingMessagesTimer = nil
            messages.unsubscribeReceiver()
            messages.unsubscribeSender()
        }
    }

    private func makeHarness(testSuffix: String) throws -> Harness {
        let owner = "gap-\(testSuffix)-owner@example.com"
        let jid = "gap-\(testSuffix)-peer@example.com"
        let realm = try WRealm.safe()
        try realm.write {
            let chat = LastChatsStorageItem()
            chat.primary = LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: .regular
            )
            chat.owner = owner
            chat.jid = jid
            chat.conversationType = .regular
            chat.isSynced = true
            chat.isInitialArchiveLoaded = true
            chat.messageDate = Date(timeIntervalSince1970: 1_775_000_000)
            realm.add(chat, update: .modified)

            let state = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: .regular,
                in: realm
            )
            state.mergeLoadedRange(
                first: "200",
                last: "100",
                updateKind: .bootstrapNewest
            )
            state.mergeLoadedRange(
                first: "500",
                last: "400",
                updateKind: .disjointWindow
            )
            state.mergeLoadedRange(
                first: "800",
                last: "700",
                updateKind: .disjointWindow
            )
            state.newerLiveEdgeReached = true

            for (index, archiveId) in ["400", "500"].enumerated() {
                let message = MessageStorageItem()
                message.primary = MessageStorageItem.genPrimary(
                    messageId: "seed-\(testSuffix)-\(archiveId)",
                    owner: owner
                )
                message.owner = owner
                message.opponent = jid
                message.conversationType = .regular
                message.messageId = "seed-\(testSuffix)-\(archiveId)"
                message.archivedId = archiveId
                message.body = "seed"
                message.date = Date(
                    timeIntervalSince1970:
                        (Double(archiveId) ?? Double(index)) / 1_000_000
                )
                message.sentDate = message.date
                message.outgoing = false
                realm.add(message, update: .modified)
            }
        }

        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: "Owner")
        controller.opponentSender = Sender(id: jid, displayName: "Peer")
        controller.loadViewIfNeeded()
        controller.messagesCollectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        // This harness enters after a committed local frame. `loadViewIfNeeded`
        // intentionally starts production in its blocking skeleton state, so
        // revoke that unrelated bootstrap mapping before capturing the real
        // gap-repair mapping context.
        controller.cancelBootstrapSkeletonMappingJobs()
        controller.setSkeletonVisible(false)
        controller.setDatasourceLoadingEnabled(false)
        controller.appliedBootstrapLoadingState = .content

        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let session = ChatTimelineSession(
            store: store,
            pageSize: 80,
            conversationKey: ChatTimelineConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            archiveState: controller.loadChatArchiveStateSnapshot(),
            observesStoreImmediately: false
        )
        controller.timelineSession = session
        let snapshot = session.openLatest(limit: 80)
        XCTAssertEqual(snapshot.items.count, 2)
        controller.virtualTimelineState = snapshot.state
        controller.boundedTimelineWindowState = ChatBoundedTimelineWindowState(
            virtualState: snapshot.state
        )
        controller.syncCurrentPage(
            with: ChatDatasetWindow(minIndex: 0, maxIndex: snapshot.items.count)
        )
        var didApply = false
        controller.mapAndApplyTimelineCurrent(
            mode: .windowReload(keepOffset: true),
            animated: false,
            completion: { didApply = true }
        )
        XCTAssertTrue(waitUntil { didApply })
        XCTAssertEqual(controller.datasource.filter { !$0.isFakeMessage }.count, 2)
        assertStrictGapDatasource(
            controller,
            expectedMessagePrimaries: ["400", "500"].map {
                MessageStorageItem.genPrimary(
                    messageId: "seed-\(testSuffix)-\($0)",
                    owner: owner
                )
            }
        )
        controller.hasCommittedTimelinePresentationInCurrentLifecycle = true
        controller.hasCommittedRealContentInCurrentLifecycle = true
        return Harness(owner: owner, jid: jid, controller: controller, store: store)
    }

    private func insertOlderSideRowsForBoundaryPaging(
        _ harness: Harness
    ) throws {
        let realm = try WRealm.safe()
        try realm.write {
            for (index, archiveId) in ["100", "200"].enumerated() {
                let message = MessageStorageItem()
                message.primary = MessageStorageItem.genPrimary(
                    messageId: "retry-older-\(archiveId)",
                    owner: harness.owner
                )
                message.owner = harness.owner
                message.opponent = harness.jid
                message.conversationType = .regular
                message.messageId = "retry-older-\(archiveId)"
                message.archivedId = archiveId
                message.body = "older side"
                message.date = Date(
                    timeIntervalSince1970:
                        (Double(archiveId) ?? Double(index)) / 1_000_000
                )
                message.sentDate = message.date
                message.outgoing = false
                realm.add(message, update: .modified)
            }
        }
    }

    private func armOlderGapPipeline(
        _ harness: Harness,
        queryId: String
    ) throws -> Pipeline {
        let controller = harness.controller
        let generation = Int(try XCTUnwrap(controller.timelineSession).snapshot.generation)
        controller.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
            queryId: queryId,
            generation: generation,
            direction: .older,
            chatPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: harness.jid,
                owner: harness.owner,
                conversationType: .regular
            ),
            persistedCursorId: "400",
            persistedFullArchiveLoaded: false,
            requestedCursorId: "400",
            requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 80),
            preLoadObserverCount: controller.timelineSession?.snapshot.items.count ?? 0,
            preLoadOldestArchivedId: "400",
            preLoadNewestArchivedId: "500",
            preLoadFullArchiveLoaded: false,
            preLoadNewerLiveEdgeReached: true,
            remoteFetchStarted: true,
            isArchiveEndVerificationProbe: false,
            canMutateOlderArchiveEnd: false,
            expectedWindowMaxIndex: 80,
            coverageUpdateKind: .gapRepairOlder(cursorArchiveId: "400")
        )
        controller.activeHistoryBoundaryPlaceholder = .top
        controller.timelineInteractionState.locked = true

        let descriptor = ChatRemoteHistoryQueryDescriptor(
            conversationKey: controller.chatTimelineConversationKey,
            queryId: queryId,
            direction: .older,
            cursorId: "400",
            generation: generation
        )
        XCTAssertTrue(controller.remoteHistoryQueryCoordinator.register(
            descriptor,
            persistenceCleanup: {
                ChatRemoteHistoryCompletionCoordinator.unregisterPersistenceSource(
                    owner: harness.owner,
                    queryId: queryId
                )
            }
        ) { page, completion in
            ChatRemoteHistoryCompletionCoordinator.flushQueryMessagesAsync(
                owner: harness.owner,
                queryId: queryId,
                state: page.state,
                conversationJid: harness.jid,
                conversationType: .regular
            ) { result in
                completion(.success(result))
            }
        })
        controller.registerRemoteHistoryEndPageDispatcher(queryId: queryId)
        controller.registerRemoteHistoryFailureDispatcher(queryId: queryId)

        let messages = MessageManager(withOwner: harness.owner, activeStream: false)
        messages.updateSendingMessagesTimer?.invalidate()
        messages.updateSendingMessagesTimer = nil
        messages.unsubscribeSender()
        messages.archiveQueryIdPersistenceResolver = { $0 == queryId }
        controller.registerRemoteHistoryPersistenceSource(messages, queryId: queryId)

        let mam = MessageArchiveManager(withOwner: harness.owner)
        let stream = XMPPStream()
        mam.requestArchive(
            stream,
            jid: harness.jid,
            isContinues: true,
            conversationType: .regular,
            purpose: .gapRepair,
            queryId: queryId,
            nextPage: "400",
            max: 80,
            coverageUpdateKind: .gapRepairOlder(cursorArchiveId: "400"),
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            deferCoverageCommitUntilConsumerProof: true
        )
        return Pipeline(mam: mam, messages: messages, stream: stream)
    }

    private func archiveEnvelope(
        harness: Harness,
        queryId: String,
        archiveId: String,
        messageId: String,
        stamp: String
    ) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: """
        <message to='\(harness.owner)' from='\(harness.owner)'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(queryId)' id='\(archiveId)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' from='\(harness.jid)' to='\(harness.owner)' type='chat' id='\(messageId)'>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(harness.owner)' id='\(archiveId)'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='\(messageId)'/>
                <body>gap repair</body>
              </message>
              <delay xmlns='urn:xmpp:delay' from='example.com' stamp='\(stamp)'/>
            </forwarded>
          </result>
        </message>
        """, options: 0)
        return try XMPPMessage(from: XCTUnwrap(document.rootElement()))
    }

    private func archiveFinalIQ(
        queryId: String,
        complete: Bool,
        cardinality: Int,
        first: String,
        last: String
    ) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' complete='\(complete ? "true" : "false")' queryid='\(queryId)'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>\(cardinality)</count>
              <first>\(first)</first>
              <last>\(last)</last>
            </set>
          </fin>
        </iq>
        """, options: 0)
        return try XMPPIQ(from: XCTUnwrap(document.rootElement()))
    }

    private func archiveErrorIQ(queryId: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type='error' id='\(queryId)'>
          <error type='wait'>
            <service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
          </error>
        </iq>
        """, options: 0)
        return try XMPPIQ(from: XCTUnwrap(document.rootElement()))
    }

    private func archiveState(_ harness: Harness) throws -> RegularChatArchiveSyncStateStorageItem {
        let realm = try WRealm.safe()
        realm.refresh()
        return try XCTUnwrap(realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                jid: harness.jid,
                owner: harness.owner,
                conversationType: .regular
            )
        ))
    }

    private func archiveStateSnapshot(_ harness: Harness) throws -> ChatArchiveStateSnapshot {
        let state = try archiveState(harness)
        return ChatArchiveStateSnapshot(
            primaryKey: state.primary,
            persistedCursorId: state.oldestLoadedArchiveId,
            fullArchiveLoaded: state.olderArchiveEndReached,
            newestCursorId: state.newestLoadedArchiveId,
            newerLiveEdgeReached: state.newerLiveEdgeReached,
            hasKnownNewerGap: state.knownGaps.isNotEmpty,
            knownGaps: state.knownGaps
        )
    }

    private func persistedMessageCount(_ harness: Harness) throws -> Int {
        let realm = try WRealm.safe()
        realm.refresh()
        return realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@",
            harness.owner,
            harness.jid,
            ClientSynchronizationManager.ConversationType.regular.rawValue
        ).count
    }

    private func assertStrictGapDatasource(
        _ controller: ChatViewController,
        expectedMessagePrimaries: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let messageRows = controller.datasource.filter {
            ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .message
        }
        let dateRows = controller.datasource.filter {
            ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .date
        }
        let skeletonRows = controller.datasource.filter {
            ChatVisiblePositionPolicy.rowKind(for: $0.kind) == .skeleton
        }
        XCTAssertEqual(
            messageRows.map(\.primary),
            expectedMessagePrimaries,
            file: file,
            line: line
        )
        XCTAssertEqual(
            dateRows.map(\.primary),
            expectedMessagePrimaries.first.map { ["\($0) date changed"] } ?? [],
            file: file,
            line: line
        )
        XCTAssertEqual(
            dateRows.first?.sentDate,
            messageRows.first?.sentDate,
            "The sole date separator must describe the first repaired message day",
            file: file,
            line: line
        )
        XCTAssertTrue(skeletonRows.isEmpty, file: file, line: line)
        XCTAssertEqual(
            controller.datasource.count,
            expectedMessagePrimaries.count + (expectedMessagePrimaries.isEmpty ? 0 : 1),
            "Only exact message rows plus one date separator may be visible",
            file: file,
            line: line
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }
}
