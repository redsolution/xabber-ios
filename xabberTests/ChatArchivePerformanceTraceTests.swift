import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class ChatArchivePerformanceTraceTests: XCTestCase {
    private var recorder: ChatPerformanceTraceRecorder!
    private var recorderInstallation: ChatPerformanceTraceRecorderInstallation!
    private var registry: ChatArchivePerformanceTraceRegistry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        recorder = ChatPerformanceTraceRecorder()
        recorderInstallation = ChatPerformanceSignposts.installRecorderForTesting(recorder)
        registry = ChatArchivePerformanceTraceRegistry(terminalCapacity: 8)
        ChatArchivePerformanceTraceRegistry.shared.cancelAllForTesting()
    }

    override func tearDownWithError() throws {
        registry.cancelAllForTesting()
        ChatArchivePerformanceTraceRegistry.shared.cancelAllForTesting()
        recorderInstallation.cancel()
        registry = nil
        recorderInstallation = nil
        recorder = nil
        try super.tearDownWithError()
    }

    func testLeaseEmitsQueuedTransportPersistenceCommittedInOrder() throws {
        let context = try makeContext(traceID: 301, generation: 11)

        XCTAssertEqual(
            registry.register(
                owner: "private-owner@example.com",
                queryID: "private-query-id",
                context: context,
                operation: .initialOpen
            ),
            .started
        )
        XCTAssertTrue(registry.transportStarted(
            owner: "private-owner@example.com",
            queryID: "private-query-id",
            context: context
        ))
        XCTAssertTrue(registry.rawFinal(
            owner: "private-owner@example.com",
            queryID: "private-query-id",
            context: context,
            deliveredCount: 2
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: "private-owner@example.com",
            queryID: "private-query-id",
            context: context,
            expectedCount: 2
        ))
        XCTAssertTrue(registry.recordIngress(
            owner: "private-owner@example.com",
            queryID: "private-query-id",
            context: context,
            receivedCount: 2
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: "private-owner@example.com",
            queryID: "private-query-id",
            context: context,
            terminal: .committed,
            persistedCount: 2,
            failedCount: 0
        ))

        let records = recorder.snapshot()
        XCTAssertEqual(
            records.map { "\($0.kind):\($0.phase.rawValue)" },
            [
                "begin:chat.lease_queued",
                "end:chat.lease_queued",
                "begin:chat.lease_transport",
                "end:chat.lease_transport",
                "event:chat.raw_final",
                "begin:chat.lease_persistence",
                "event:chat.ingress_complete",
                "event:chat.persistence_terminal",
                "end:chat.lease_persistence"
            ]
        )
        XCTAssertTrue(records.allSatisfy { $0.context == context })
        XCTAssertTrue(records.allSatisfy(\.isPrivacySafe))
        XCTAssertEqual(records.filter { $0.phase == .persistenceTerminal }.first?.terminal, .committed)
        XCTAssertFalse(records.contains { record in
            record.sortedCounterNames.contains { name in
                name.localizedCaseInsensitiveContains("owner") ||
                    name.localizedCaseInsensitiveContains("query")
            }
        })
    }

    func testSkeletonOpenRecordsReceiptBeforeTheInitialLeaseCanQueue() throws {
        let context = try makeContext(traceID: 3011, generation: 111)
        let lifecycle = ChatOpenPerformanceTraceLifecycle()

        XCTAssertTrue(lifecycle.accept(
            context: context,
            emitsOpenRequest: true
        ))
        XCTAssertTrue(lifecycle.recordPresentationReceipt(
            .skeleton,
            context: context,
            schedulesStableFrame: false
        ))
        XCTAssertEqual(registry.register(
            owner: "private-owner@example.com",
            queryID: "private-skeleton-query",
            context: context,
            operation: .initialOpen
        ), .started)

        XCTAssertEqual(
            recorder.snapshot().filter { $0.context == context }.map(\.phase),
            [.openRequest, .skeletonReceipt, .leaseQueued]
        )
    }

    func testRawFinalBeforeIngressEmitsIngressCompleteThenOnePersistenceTerminalOnSameTrace() throws {
        let context = try makeContext(traceID: 302, generation: 12)
        registerStartedTransport(context: context)

        XCTAssertTrue(registry.rawFinal(
            owner: "owner",
            queryID: "query",
            context: context,
            deliveredCount: 2
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: "owner",
            queryID: "query",
            context: context,
            expectedCount: 2
        ))
        XCTAssertFalse(registry.recordIngress(
            owner: "owner",
            queryID: "query",
            context: context,
            receivedCount: 1
        ))
        XCTAssertTrue(registry.recordIngress(
            owner: "owner",
            queryID: "query",
            context: context,
            receivedCount: 2
        ))
        XCTAssertFalse(registry.recordIngress(
            owner: "owner",
            queryID: "query",
            context: context,
            receivedCount: 3
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: "owner",
            queryID: "query",
            context: context,
            terminal: .committed,
            persistedCount: 2,
            failedCount: 0
        ))
        XCTAssertFalse(registry.persistenceTerminal(
            owner: "owner",
            queryID: "query",
            context: context,
            terminal: .committed,
            persistedCount: 2,
            failedCount: 0
        ))

        let records = recorder.snapshot()
        XCTAssertEqual(records.filter { $0.phase == .ingressComplete }.count, 1)
        XCTAssertEqual(records.filter { $0.phase == .persistenceTerminal }.count, 1)
        XCTAssertTrue(records.allSatisfy { $0.context == context })
    }

    func testIngressAlreadyCompleteAtSealStillEmitsExactlyOneIngressComplete() throws {
        let context = try makeContext(traceID: 303, generation: 13)
        registerStartedTransport(context: context)
        XCTAssertFalse(registry.recordIngress(
            owner: "owner",
            queryID: "query",
            context: context,
            receivedCount: 2
        ))
        XCTAssertTrue(registry.rawFinal(
            owner: "owner",
            queryID: "query",
            context: context,
            deliveredCount: 2
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: "owner",
            queryID: "query",
            context: context,
            expectedCount: 2
        ))
        XCTAssertFalse(registry.sealExpectedIngress(
            owner: "owner",
            queryID: "query",
            context: context,
            expectedCount: 2
        ))

        XCTAssertEqual(
            recorder.snapshot().filter { $0.phase == .ingressComplete }.count,
            1
        )
    }

    func testPersistenceFailureClosesIntervalsOnceWithoutCommittedEvent() throws {
        let context = try makeContext(traceID: 304, generation: 14)
        registerStartedTransport(context: context)
        XCTAssertTrue(registry.rawFinal(
            owner: "owner",
            queryID: "query",
            context: context,
            deliveredCount: 0
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: "owner",
            queryID: "query",
            context: context,
            expectedCount: 0
        ))

        XCTAssertTrue(registry.persistenceTerminal(
            owner: "owner",
            queryID: "query",
            context: context,
            terminal: .failed,
            persistedCount: 0,
            failedCount: 1
        ))
        XCTAssertFalse(registry.terminate(
            owner: "owner",
            queryID: "query",
            context: context,
            terminal: .cancelled
        ))

        let records = recorder.snapshot()
        let persistenceEnds = records.filter {
            $0.phase == .leasePersistence && $0.kind == .end
        }
        XCTAssertEqual(persistenceEnds.count, 1)
        XCTAssertEqual(persistenceEnds.first?.terminal, .failed)
        XCTAssertEqual(
            records.filter {
                $0.phase == .persistenceTerminal && $0.terminal == .committed
            }.count,
            0
        )
    }

    func testPagePresentationRequiresItsCommittedPersistenceTombstone() throws {
        let committedContext = try makeContext(
            traceID: 3041,
            generation: 141,
            kindCode: ChatOpenPerformanceTraceKind.paging.rawValue
        )
        XCTAssertEqual(registry.register(
            owner: "page-owner",
            queryID: "page-committed",
            context: committedContext,
            operation: .olderPage
        ), .started)
        XCTAssertFalse(registry.permitsPagePresentation(
            owner: "page-owner",
            queryID: "page-committed",
            context: committedContext
        ))
        XCTAssertTrue(registry.transportStarted(
            owner: "page-owner",
            queryID: "page-committed",
            context: committedContext
        ))
        XCTAssertTrue(registry.rawFinal(
            owner: "page-owner",
            queryID: "page-committed",
            context: committedContext,
            deliveredCount: 0
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: "page-owner",
            queryID: "page-committed",
            context: committedContext,
            expectedCount: 0
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: "page-owner",
            queryID: "page-committed",
            context: committedContext,
            terminal: .committed,
            persistedCount: 0,
            failedCount: 0
        ))
        XCTAssertTrue(registry.permitsPagePresentation(
            owner: "page-owner",
            queryID: "page-committed",
            context: committedContext
        ))

        let cancelledContext = try makeContext(
            traceID: 3042,
            generation: 142,
            kindCode: ChatOpenPerformanceTraceKind.paging.rawValue
        )
        XCTAssertEqual(registry.register(
            owner: "page-owner",
            queryID: "page-cancelled",
            context: cancelledContext,
            operation: .newerPage
        ), .started)
        XCTAssertTrue(registry.terminate(
            owner: "page-owner",
            queryID: "page-cancelled",
            context: cancelledContext,
            terminal: .cancelled
        ))
        XCTAssertFalse(registry.permitsPagePresentation(
            owner: "page-owner",
            queryID: "page-cancelled",
            context: cancelledContext
        ))
    }

    func testDuplicateFinalDoesNotEmitSecondTerminal() throws {
        let context = try makeContext(traceID: 305, generation: 15)
        registerStartedTransport(context: context)

        XCTAssertTrue(registry.rawFinal(
            owner: "owner",
            queryID: "query",
            context: context,
            deliveredCount: 1
        ))
        XCTAssertFalse(registry.rawFinal(
            owner: "owner",
            queryID: "query",
            context: context,
            deliveredCount: 1
        ))

        XCTAssertEqual(recorder.snapshot().filter { $0.phase == .rawFinal }.count, 1)
        XCTAssertEqual(
            recorder.snapshot().filter {
                $0.phase == .leaseTransport && $0.kind == .end
            }.count,
            1
        )
    }

    func testCancellationClosesQueuedTraceExactlyOnceWithoutPersistenceTerminal() throws {
        let context = try makeContext(traceID: 316, generation: 26)
        XCTAssertEqual(registry.register(
            owner: "cancel-private-owner@example.com",
            queryID: "cancel-private-query",
            context: context,
            operation: .initialOpen
        ), .started)

        XCTAssertTrue(registry.terminate(
            owner: "cancel-private-owner@example.com",
            queryID: "cancel-private-query",
            context: context,
            terminal: .cancelled
        ))
        XCTAssertFalse(registry.terminate(
            owner: "cancel-private-owner@example.com",
            queryID: "cancel-private-query",
            context: context,
            terminal: .failed
        ))

        let records = recorder.snapshot().filter { $0.context == context }
        XCTAssertEqual(records.map(\.kind), [.begin, .end])
        XCTAssertEqual(records.map(\.phase), [.leaseQueued, .leaseQueued])
        XCTAssertEqual(records.last?.terminal, .cancelled)
        XCTAssertFalse(records.contains { $0.phase == .persistenceTerminal })
    }

    func testOperationKindMismatchCannotRegisterOrEmitIntervals() throws {
        let pagingContext = try makeContext(
            traceID: 317,
            generation: 27,
            kindCode: ChatOpenPerformanceTraceKind.paging.rawValue
        )

        XCTAssertEqual(registry.register(
            owner: "kind-private-owner@example.com",
            queryID: "kind-private-query",
            context: pagingContext,
            operation: .initialOpen
        ), .rejected)
        XCTAssertFalse(recorder.snapshot().contains { $0.context == pagingContext })
    }

    func testStaleGenerationCannotEmitRawFinalIngressOrPersistenceTerminal() throws {
        let current = try makeContext(traceID: 306, generation: 16)
        let stale = try makeContext(traceID: 306, generation: 15)
        registerStartedTransport(context: current)
        let baselineCount = recorder.snapshot().count

        XCTAssertFalse(registry.rawFinal(
            owner: "owner",
            queryID: "query",
            context: stale,
            deliveredCount: 1
        ))
        XCTAssertFalse(registry.sealExpectedIngress(
            owner: "owner",
            queryID: "query",
            context: stale,
            expectedCount: 1
        ))
        XCTAssertFalse(registry.persistenceTerminal(
            owner: "owner",
            queryID: "query",
            context: stale,
            terminal: .committed,
            persistedCount: 1,
            failedCount: 0
        ))

        XCTAssertEqual(recorder.snapshot().count, baselineCount)
    }

    func testRemoteOlderPageEmitsPlanQueryPersistInOneGeneration() throws {
        let context = try makeContext(traceID: 307, generation: 17, kindCode: 2)

        XCTAssertEqual(
            registry.register(
                owner: "owner",
                queryID: "older-query",
                context: context,
                operation: .olderPage
            ),
            .started
        )
        XCTAssertTrue(registry.transportStarted(
            owner: "owner",
            queryID: "older-query",
            context: context
        ))
        XCTAssertTrue(registry.rawFinal(
            owner: "owner",
            queryID: "older-query",
            context: context,
            deliveredCount: 1
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: "owner",
            queryID: "older-query",
            context: context,
            expectedCount: 1
        ))
        XCTAssertTrue(registry.recordIngress(
            owner: "owner",
            queryID: "older-query",
            context: context,
            receivedCount: 1
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: "owner",
            queryID: "older-query",
            context: context,
            terminal: .committed,
            persistedCount: 1,
            failedCount: 0
        ))

        let records = recorder.snapshot()
        XCTAssertEqual(records.filter { $0.phase == .pagePlan }.count, 1)
        XCTAssertEqual(records.filter { $0.phase == .pageQuery && $0.kind == .begin }.count, 1)
        XCTAssertEqual(records.filter { $0.phase == .pageQuery && $0.kind == .end }.count, 1)
        XCTAssertEqual(records.filter { $0.phase == .pagePersist && $0.kind == .begin }.count, 1)
        XCTAssertEqual(records.filter { $0.phase == .pagePersist && $0.kind == .end }.count, 1)
        XCTAssertTrue(records.allSatisfy { $0.context == context })
    }

    func testLocalPagePlanDoesNotEmitRemoteQueryOrPersist() throws {
        let context = try makeContext(traceID: 308, generation: 18, kindCode: 2)

        XCTAssertTrue(registry.recordLocalPagePlan(context: context, directionCode: 1))

        let records = recorder.snapshot()
        XCTAssertEqual(records.map(\.phase), [.pagePlan])
        XCTAssertEqual(records.first?.context, context)
    }

    func testRealMessageManagerRequestCarriesOpaqueContextAndEmitsLateIngressTerminalOnce() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatArchivePerformanceTraceTests-manager-\(name)"
        )
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }
        let owner = "manager-private-owner@example.com"
        let queryID = "manager-private-query"
        let context = try makeContext(traceID: 309, generation: 19)
        let shared = ChatArchivePerformanceTraceRegistry.shared
        XCTAssertEqual(
            shared.register(
                owner: owner,
                queryID: queryID,
                context: context,
                operation: .initialOpen
            ),
            .started
        )
        XCTAssertTrue(shared.transportStarted(
            owner: owner,
            queryID: queryID,
            context: context
        ))
        XCTAssertTrue(shared.rawFinal(
            owner: owner,
            queryID: queryID,
            context: context,
            deliveredCount: 1
        ))

        let manager = MessageManager(withOwner: owner, activeStream: false)
        manager.updateSendingMessagesTimer?.invalidate()
        manager.updateSendingMessagesTimer = nil
        manager.unsubscribeSender()
        manager.unsubscribeReceiver()
        manager.archiveQueryIdPersistenceResolver = { $0 == queryID }
        manager.beginArchiveQueryBatch(queryId: queryID, priority: .interactive)
        manager.queue.suspend()
        var isQueueSuspended = true
        defer {
            if isQueueSuspended { manager.queue.resume() }
            manager.unsubscribeReceiver()
        }

        let terminal = expectation(description: "query persistence terminal")
        terminal.assertForOverFulfill = true
        manager.sealArchiveQueryBatch(
            queryId: queryID,
            priority: .interactive,
            expectedReceivedCount: 1
        ) { summary in
            XCTAssertEqual(summary.received, 1)
            XCTAssertEqual(summary.persistedRows, 1)
            terminal.fulfill()
        }
        manager.archivePersistenceSchedulingLock.lock()
        let sealedContext = manager
            .sealedArchivePersistenceRequestsByQueryId[queryID]?
            .traceContext
        manager.archivePersistenceSchedulingLock.unlock()
        XCTAssertEqual(sealedContext, context)

        manager.queue.resume()
        isQueueSuspended = false
        manager.receiveArchived(try makeArchivedMessage(
            index: 1,
            owner: owner,
            queryID: queryID
        ))
        wait(for: [terminal], timeout: 3)
        manager.performMessageQueueSync {}

        let records = recorder.snapshot().filter { $0.context == context }
        XCTAssertEqual(records.filter { $0.phase == .ingressComplete }.count, 1)
        XCTAssertEqual(records.filter { $0.phase == .persistenceTerminal }.count, 1)
        XCTAssertEqual(
            records.first { $0.phase == .persistenceTerminal }?.terminal,
            .committed
        )
        XCTAssertTrue(records.allSatisfy(\.isPrivacySafe))
    }

    func testRealMessageManagerIngressAlreadyCompleteAtSealEmitsOneIngressBeforeTerminal() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatArchivePerformanceTraceTests-early-ingress-\(name)"
        )
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }
        let owner = "early-private-owner@example.com"
        let queryID = "early-private-query"
        let context = try makeContext(traceID: 310, generation: 20)
        let shared = ChatArchivePerformanceTraceRegistry.shared
        XCTAssertEqual(shared.register(
            owner: owner,
            queryID: queryID,
            context: context,
            operation: .initialOpen
        ), .started)
        XCTAssertTrue(shared.transportStarted(owner: owner, queryID: queryID, context: context))

        let manager = MessageManager(withOwner: owner, activeStream: false)
        manager.updateSendingMessagesTimer?.invalidate()
        manager.updateSendingMessagesTimer = nil
        manager.unsubscribeSender()
        manager.unsubscribeReceiver()
        manager.archiveQueryIdPersistenceResolver = { $0 == queryID }
        manager.beginArchiveQueryBatch(queryId: queryID, priority: .interactive)
        manager.receiveArchived(try makeArchivedMessage(
            index: 2,
            owner: owner,
            queryID: queryID
        ))
        XCTAssertTrue(shared.rawFinal(
            owner: owner,
            queryID: queryID,
            context: context,
            deliveredCount: 1
        ))

        let terminal = expectation(description: "already-ingressed terminal")
        manager.sealArchiveQueryBatch(
            queryId: queryID,
            priority: .interactive,
            expectedReceivedCount: 1
        ) { _ in terminal.fulfill() }
        wait(for: [terminal], timeout: 3)

        let records = recorder.snapshot().filter { $0.context == context }
        let ingressIndex = try XCTUnwrap(records.firstIndex { $0.phase == .ingressComplete })
        let terminalIndex = try XCTUnwrap(records.firstIndex { $0.phase == .persistenceTerminal })
        XCTAssertLessThan(ingressIndex, terminalIndex)
        XCTAssertEqual(records.filter { $0.phase == .ingressComplete }.count, 1)
        XCTAssertEqual(records.filter { $0.phase == .persistenceTerminal }.count, 1)
    }

    func testRealMAMFinalParserEmitsOneRawFinalBetweenTransportAndPersistence() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatArchivePerformanceTraceTests-mam-final-\(name)"
        )
        defer { Realm.Configuration.defaultConfiguration = previousConfiguration }
        let owner = "mam-private-owner@example.com"
        let peer = "mam-private-peer@example.com"
        let queryID = "mam-private-query"
        let context = try makeContext(traceID: 311, generation: 21)
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: peer,
            owner: owner,
            conversationType: .regular
        )
        chat.owner = owner
        chat.jid = peer
        chat.conversationType = .regular
        chat.isSynced = false
        chat.isInitialArchiveLoaded = false
        try realm.write { realm.add(chat) }

        XCTAssertEqual(
            ChatArchivePerformanceTraceRegistry.shared.register(
                owner: owner,
                queryID: queryID,
                context: context,
                operation: .initialOpen
            ),
            .started
        )
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        XCTAssertEqual(
            manager.syncChat(
                stream,
                jid: peer,
                conversationType: .regular,
                queryId: queryID,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryID)
        )
        let final = try finalIQ(queryID: queryID, count: 0)
        XCTAssertTrue(manager.read(stream, withIQ: final))
        _ = manager.read(stream, withIQ: final)

        let records = recorder.snapshot().filter { $0.context == context }
        XCTAssertEqual(records.filter { $0.phase == .rawFinal }.count, 1)
        let transportEnd = try XCTUnwrap(records.firstIndex {
            $0.phase == .leaseTransport && $0.kind == .end
        })
        let rawFinal = try XCTUnwrap(records.firstIndex { $0.phase == .rawFinal })
        let persistenceBegin = try XCTUnwrap(records.firstIndex {
            $0.phase == .leasePersistence && $0.kind == .begin
        })
        XCTAssertLessThan(transportEnd, rawFinal)
        XCTAssertLessThan(rawFinal, persistenceBegin)
        XCTAssertTrue(records.allSatisfy(\.isPrivacySafe))
    }

    func testBootstrapLeaseCarriesOneContextAndDuplicateJoinCannotReplaceIt() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false,
            performanceTraceRegistry: registry
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "lease-private-owner@example.com",
            jid: "lease-private-peer@example.com",
            conversationType: .regular
        )
        let original = try makeContext(traceID: 312, generation: 22)
        let replacement = try makeContext(traceID: 313, generation: 23)

        guard case .start(let firstLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "lease-private-query",
            timeout: 45,
            performanceTraceContext: original,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("first acquire must start")
        }
        guard case .joined(let joinedLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "must-not-replace-query",
            timeout: 45,
            performanceTraceContext: replacement,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("duplicate acquire must join")
        }

        XCTAssertEqual(firstLease.performanceTraceContext, original)
        XCTAssertEqual(joinedLease.performanceTraceContext, original)
        XCTAssertEqual(
            recorder.snapshot().filter {
                $0.phase == .leaseQueued && $0.kind == .begin && $0.context == original
            }.count,
            1
        )
        XCTAssertFalse(recorder.snapshot().contains { $0.context == replacement })
        XCTAssertTrue(coordinator.complete(key: key, queryId: firstLease.queryId))
    }

    func testReopenedSameTargetCanAdoptActiveLeaseContextBeforeEmittingAnotherOpen() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false,
            performanceTraceRegistry: registry
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "reopen-private-owner@example.com",
            jid: "reopen-private-peer@example.com",
            conversationType: .regular
        )
        let target = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .latest,
            boundary: nil
        )
        let context = try makeContext(traceID: 318, generation: 28)
        let firstLifecycle = ChatOpenPerformanceTraceLifecycle()
        XCTAssertTrue(firstLifecycle.accept(
            context: context,
            emitsOpenRequest: true
        ))
        XCTAssertTrue(firstLifecycle.recordPresentationReceipt(
            .skeleton,
            context: context,
            schedulesStableFrame: false
        ))
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "reopen-private-query",
            timeout: 45,
            targetFingerprint: target,
            performanceTraceContext: context,
            performanceSemanticTargetFingerprint: .latest,
            performanceSkeletonReceiptWasCommitted: true,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("first acquire must start")
        }

        let adoption = try XCTUnwrap(
            coordinator.activePerformanceTraceAdoption(
                for: key,
                targetFingerprint: target,
                semanticTargetFingerprint: .latest
            )
        )
        XCTAssertEqual(adoption.context, context)
        XCTAssertTrue(adoption.hasSkeletonReceipt)
        let reopenedLifecycle = ChatOpenPerformanceTraceLifecycle()
        XCTAssertTrue(reopenedLifecycle.accept(
            context: adoption.context,
            emitsOpenRequest: false
        ))
        XCTAssertTrue(reopenedLifecycle.adoptPresentationReceipt(
            .skeleton,
            context: adoption.context
        ))
        XCTAssertFalse(reopenedLifecycle.recordPresentationReceipt(
            .skeleton,
            context: adoption.context,
            schedulesStableFrame: false
        ))
        XCTAssertEqual(
            recorder.snapshot().filter {
                $0.context == context && $0.phase == .openRequest
            }.count,
            1
        )
        XCTAssertEqual(
            recorder.snapshot().filter {
                $0.context == context && $0.phase == .skeletonReceipt
            }.count,
            1
        )
        XCTAssertTrue(coordinator.complete(key: key, queryId: lease.queryId))
    }

    func testReopenedSameTargetCommittedReceiptAllowsFreshUIContext() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false,
            performanceTraceRegistry: registry
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "committed-reopen-owner@example.com",
            jid: "committed-reopen-peer@example.com",
            conversationType: .regular
        )
        let target = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .latest,
            boundary: nil
        )
        let retiredTransportContext = try makeContext(
            traceID: 3181,
            generation: 281
        )
        guard case .start(let originalLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "committed-reopen-original",
            timeout: 45,
            targetFingerprint: target,
            performanceTraceContext: retiredTransportContext,
            performanceSemanticTargetFingerprint: .latest,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the original route must start the bootstrap lease")
        }
        XCTAssertTrue(coordinator.requiresControllerPerformanceTraceContextMatch(
            key: key,
            queryId: originalLease.queryId
        ))

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: originalLease.queryId,
            hasDurableCoverage: true,
            resultCount: 1,
            persistedRowsForQuery: 1,
            visibleRowsForConversation: 1,
            hasPresentationMaterialization: true
        )
        XCTAssertNil(
            coordinator.activePerformanceTraceAdoption(
                for: key,
                targetFingerprint: target,
                semanticTargetFingerprint: .latest
            ),
            "a terminal receipt must not suppress the fresh route's open generation"
        )

        let freshUIContext = try makeContext(traceID: 3182, generation: 282)
        guard case .joined(let reopenedLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "committed-reopen-fresh-route",
            timeout: 45,
            targetFingerprint: target,
            performanceTraceContext: freshUIContext,
            performanceSemanticTargetFingerprint: .latest,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the fresh route must reuse the retained committed receipt")
        }

        XCTAssertEqual(reopenedLease.queryId, originalLease.queryId)
        XCTAssertEqual(
            reopenedLease.performanceTraceContext,
            retiredTransportContext,
            "the retained transport receipt keeps its immutable original context"
        )
        XCTAssertNotEqual(reopenedLease.performanceTraceContext, freshUIContext)
        XCTAssertFalse(
            coordinator.requiresControllerPerformanceTraceContextMatch(
                key: key,
                queryId: reopenedLease.queryId
            ),
            "committed receipt reuse must not compare a retired transport context with a fresh UI generation"
        )
        XCTAssertTrue(coordinator.releaseInteractiveCommittedJoinReservation(
            key: key,
            queryId: reopenedLease.queryId
        ))
    }

    func testReopenedMismatchedTargetCannotAdoptOldLeaseContextOrPublishLateUIReceipt() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false,
            performanceTraceRegistry: registry
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "mismatch-private-owner@example.com",
            jid: "mismatch-private-peer@example.com",
            conversationType: .regular
        )
        let latest = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .latest,
            boundary: nil
        )
        let explicit = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .firstUnread(afterArchiveId: "private-archive-id"),
            boundary: nil
        )
        let oldContext = try makeContext(traceID: 319, generation: 29)
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "mismatch-private-query",
            timeout: 45,
            targetFingerprint: latest,
            performanceTraceContext: oldContext,
            performanceSemanticTargetFingerprint: .latest,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("first acquire must start")
        }

        XCTAssertNil(coordinator.activePerformanceTraceContext(
            for: key,
            targetFingerprint: explicit,
            semanticTargetFingerprint: .latest
        ))
        let freshContext = try makeContext(traceID: 320, generation: 30)
        let lifecycle = ChatOpenPerformanceTraceLifecycle()
        XCTAssertTrue(lifecycle.accept(context: oldContext, emitsOpenRequest: false))
        XCTAssertTrue(lifecycle.beginPresenting(context: oldContext))
        XCTAssertTrue(lifecycle.accept(context: freshContext, emitsOpenRequest: true))
        XCTAssertFalse(lifecycle.recordPresentationReceipt(
            .content,
            context: oldContext,
            schedulesStableFrame: true
        ))
        XCTAssertFalse(lifecycle.consumeStableFrame(
            context: oldContext,
            eligibility: .eligible
        ))

        let oldUIRecords = recorder.snapshot().filter {
            $0.context == oldContext && [
                ChatPerformanceSignpostPhase.contentReceipt,
                .emptyReceipt,
                .stableFrame
            ].contains($0.phase)
        }
        XCTAssertTrue(oldUIRecords.isEmpty)
        XCTAssertTrue(coordinator.complete(key: key, queryId: lease.queryId))
    }

    func testExactAnchorMismatchRollsFreshFullyBoundTraceAfterOldLeaseWithoutContextMixing() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false,
            performanceTraceRegistry: registry
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "anchor-private-owner@example.com",
            jid: "anchor-private-peer@example.com",
            conversationType: .regular
        )
        let transportTarget = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .latest,
            boundary: nil
        )
        let anchorA = makeExactAnchorRequest(
            owner: key.owner,
            jid: key.jid,
            archivedId: "private-anchor-a"
        )
        let anchorB = makeExactAnchorRequest(
            owner: key.owner,
            jid: key.jid,
            archivedId: "private-anchor-b"
        )
        let contextA = try makeContext(traceID: 321, generation: 31)
        let contextB = try makeContext(traceID: 322, generation: 32)
        let lifecycle = ChatOpenPerformanceTraceLifecycle()
        XCTAssertTrue(lifecycle.accept(context: contextA, emitsOpenRequest: true))
        XCTAssertTrue(lifecycle.beginPresenting(context: contextA))
        guard case .start(let leaseA) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "anchor-private-query-a",
            timeout: 45,
            targetFingerprint: transportTarget,
            performanceTraceContext: contextA,
            performanceSemanticTargetFingerprint: .message(anchorA),
            observer: { _, _, _ in }
        ) else {
            return XCTFail("first exact-anchor acquire must start")
        }

        XCTAssertEqual(coordinator.activePerformanceTraceContext(
            for: key,
            targetFingerprint: transportTarget,
            semanticTargetFingerprint: .message(anchorA)
        ), contextA)
        XCTAssertNil(coordinator.activePerformanceTraceContext(
            for: key,
            targetFingerprint: transportTarget,
            semanticTargetFingerprint: .message(anchorB)
        ))

        XCTAssertTrue(lifecycle.accept(context: contextB, emitsOpenRequest: true))
        XCTAssertTrue(lifecycle.recordPresentationReceipt(
            .skeleton,
            context: contextB,
            schedulesStableFrame: false
        ))
        guard case .joined(let joinedA) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "anchor-private-query-b-must-follow",
            timeout: 45,
            targetFingerprint: transportTarget,
            performanceTraceContext: contextB,
            performanceSemanticTargetFingerprint: .message(anchorB),
            observer: { _, _, _ in }
        ) else {
            return XCTFail("B must preserve A single-flight until A commits")
        }
        XCTAssertEqual(joinedA.performanceTraceContext, contextA)
        XCTAssertEqual(
            coordinator.pendingFollowUpRequest(for: key)?
                .performanceSemanticTargetFingerprint,
            .message(anchorB)
        )
        XCTAssertFalse(
            ChatInitialBootstrapFollowUpTargetPolicy.matchesActiveLease(
                coordinatorRequest: coordinator.pendingFollowUpRequest(for: key),
                activeTargetFingerprint: transportTarget,
                activePerformanceSemanticTargetFingerprint: .message(anchorA)
            ),
            "equal .latest transport targets must not hide an exact-anchor supersession"
        )

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: leaseA.queryId,
            hasDurableCoverage: false,
            resultCount: 1,
            confirmsEmptyConversation: false,
            hasPresentationMaterialization: true
        )
        guard case .start(let leaseB) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "anchor-private-query-b",
            timeout: 45,
            targetFingerprint: transportTarget,
            performanceTraceContext: contextB,
            performanceSemanticTargetFingerprint: .message(anchorB),
            observer: { _, _, _ in }
        ) else {
            return XCTFail("committed A must roll one fresh B lease")
        }
        XCTAssertEqual(leaseB.performanceTraceContext, contextB)
        XCTAssertEqual(
            leaseB.performanceSemanticTargetFingerprint,
            .message(anchorB)
        )

        XCTAssertTrue(registry.transportStarted(
            owner: key.owner,
            queryID: leaseB.queryId,
            context: contextB
        ))
        XCTAssertTrue(registry.rawFinal(
            owner: key.owner,
            queryID: leaseB.queryId,
            context: contextB,
            deliveredCount: 1
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: key.owner,
            queryID: leaseB.queryId,
            context: contextB,
            expectedCount: 1
        ))
        XCTAssertTrue(registry.recordIngress(
            owner: key.owner,
            queryID: leaseB.queryId,
            context: contextB,
            receivedCount: 1
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: key.owner,
            queryID: leaseB.queryId,
            context: contextB,
            terminal: .committed,
            persistedCount: 1,
            failedCount: 0
        ))
        ChatPerformanceSignposts.measure(.localHistoryQuery, context: contextB) {}
        ChatPerformanceSignposts.measure(.mapDataset, context: contextB) {}
        XCTAssertTrue(lifecycle.beginPresenting(context: contextB))
        XCTAssertTrue(lifecycle.endPresenting(
            context: contextB,
            terminal: .committed
        ))
        XCTAssertTrue(lifecycle.recordPresentationReceipt(
            .content,
            context: contextB,
            schedulesStableFrame: true
        ))
        XCTAssertTrue(lifecycle.consumeStableFrame(
            context: contextB,
            eligibility: .eligible
        ))

        let recordsB = recorder.snapshot().filter { $0.context == contextB }
        XCTAssertEqual(recordsB.map(\.phase), [
            .openRequest,
            .skeletonReceipt,
            .leaseQueued, .leaseQueued,
            .leaseTransport, .leaseTransport,
            .rawFinal,
            .leasePersistence,
            .ingressComplete,
            .persistenceTerminal,
            .leasePersistence,
            .localHistoryQuery, .localHistoryQuery,
            .mapDataset, .mapDataset,
            .presenting, .presenting,
            .contentReceipt,
            .stableFrame
        ])
        let recordsA = recorder.snapshot().filter { $0.context == contextA }
        XCTAssertFalse(recordsA.contains {
            [.contentReceipt, .emptyReceipt, .stableFrame].contains($0.phase)
        })
        XCTAssertEqual(
            recordsA.filter {
                $0.phase == .presenting && $0.terminal == .cancelled
            }.count,
            1
        )
        XCTAssertTrue(coordinator.complete(key: key, queryId: leaseB.queryId))
    }

    func testBootstrapResolveStartAndFailureCloseOneContextExactlyOnce() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false,
            performanceTraceRegistry: registry
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "failure-private-owner@example.com",
            jid: "failure-private-peer@example.com",
            conversationType: .regular
        )
        let context = try makeContext(traceID: 314, generation: 24)
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "failure-private-query",
            timeout: 45,
            performanceTraceContext: context,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("first acquire must start")
        }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: {}
        )
        let event = MessageArchiveRequestFailureEvent(
            owner: key.owner,
            queryId: lease.queryId,
            streamKind: .primary,
            reason: .requestStartFailed,
            errorDescription: nil,
            pendingQueryCount: 1
        )

        XCTAssertTrue(coordinator.recordFailure(key: key, event: event, publishEvent: false))
        XCTAssertFalse(coordinator.recordFailure(key: key, event: event, publishEvent: false))

        let records = recorder.snapshot().filter { $0.context == context }
        XCTAssertEqual(records.filter { $0.phase == .leaseQueued && $0.kind == .end }.count, 1)
        let transportEnds = records.filter {
            $0.phase == .leaseTransport && $0.kind == .end
        }
        XCTAssertEqual(transportEnds.count, 1)
        XCTAssertEqual(transportEnds.first?.terminal, .failed)
        XCTAssertEqual(records.filter { $0.kind == .end }.count, 2)
    }

    func testBootstrapEmptyPageWithoutMessageManagerPreservesRealTerminalOrder() throws {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false,
            performanceTraceRegistry: registry
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "empty-private-owner@example.com",
            jid: "empty-private-peer@example.com",
            conversationType: .regular
        )
        let context = try makeContext(traceID: 315, generation: 25)
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "empty-private-query",
            timeout: 45,
            performanceTraceContext: context,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("empty bootstrap acquire must start")
        }
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: nil,
            cancelTransport: {}
        )

        XCTAssertTrue(registry.rawFinal(
            owner: key.owner,
            queryID: lease.queryId,
            context: context,
            deliveredCount: 0
        ))
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(
            MessageArchiveEndPageEvent(
                owner: key.owner,
                queryId: lease.queryId,
                state: MessageArchivePageEndState(
                    queryExhausted: true,
                    archiveEnded: true,
                    persistedMessageCount: 0
                ),
                first: "",
                last: "",
                count: 0,
                streamKind: .primary,
                source: .localCallback
            )
        ))

        let records = recorder.snapshot().filter { $0.context == context }
        let rawFinalIndex = try XCTUnwrap(
            records.firstIndex { $0.phase == .rawFinal }
        )
        let ingressIndex = try XCTUnwrap(
            records.firstIndex { $0.phase == .ingressComplete }
        )
        let terminalIndex = try XCTUnwrap(
            records.firstIndex { $0.phase == .persistenceTerminal }
        )
        XCTAssertLessThan(rawFinalIndex, ingressIndex)
        XCTAssertLessThan(ingressIndex, terminalIndex)
        XCTAssertEqual(
            records.filter { $0.phase == .persistenceTerminal }.count,
            1
        )
        XCTAssertEqual(records[terminalIndex].terminal, .committed)
        XCTAssertTrue(coordinator.complete(key: key, queryId: lease.queryId))
        XCTAssertEqual(
            recorder.snapshot().filter {
                $0.context == context && $0.phase == .persistenceTerminal
            }.count,
            1
        )
    }

    func testCommittedMessageManagerTerminalRejectsCoordinatorDuplicateFailureClose() throws {
        let context = try makeContext(traceID: 316, generation: 26)
        registerStartedTransport(context: context)
        XCTAssertTrue(registry.rawFinal(
            owner: "owner",
            queryID: "query",
            context: context,
            deliveredCount: 0
        ))
        XCTAssertTrue(registry.sealExpectedIngress(
            owner: "owner",
            queryID: "query",
            context: context,
            expectedCount: 0
        ))
        XCTAssertTrue(registry.persistenceTerminal(
            owner: "owner",
            queryID: "query",
            context: context,
            terminal: .committed,
            persistedCount: 0,
            failedCount: 0
        ))

        XCTAssertFalse(registry.terminate(
            owner: "owner",
            queryID: "query",
            context: context,
            terminal: .failed
        ))

        let records = recorder.snapshot().filter { $0.context == context }
        XCTAssertEqual(records.filter {
            $0.phase == .persistenceTerminal && $0.terminal == .committed
        }.count, 1)
        XCTAssertFalse(records.contains { $0.terminal == .failed })
        XCTAssertEqual(records.filter {
            $0.phase == .leasePersistence && $0.kind == .end
        }.count, 1)
    }

    private func registerStartedTransport(context: ChatOpenPerformanceTraceContext) {
        XCTAssertEqual(
            registry.register(
                owner: "owner",
                queryID: "query",
                context: context,
                operation: .initialOpen
            ),
            .started
        )
        XCTAssertTrue(registry.transportStarted(
            owner: "owner",
            queryID: "query",
            context: context
        ))
    }

    private func makeContext(
        traceID: UInt64,
        generation: UInt64,
        kindCode: UInt64 = 1
    ) throws -> ChatOpenPerformanceTraceContext {
        try XCTUnwrap(ChatOpenPerformanceTraceContext(
            traceID: traceID,
            generation: generation,
            kindCode: kindCode,
            purposeCode: 1
        ))
    }

    private func makeExactAnchorRequest(
        owner: String,
        jid: String,
        archivedId: String
    ) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: .regular,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: archivedId,
                messageId: "message-\(archivedId)",
                authorId: "private-author@example.com",
                bodyFingerprint: "private-body-fingerprint-\(archivedId)",
                sourceDate: Date(timeIntervalSince1970: 1_711_283_200)
            ),
            highlight: true,
            markReadOnVisible: true,
            source: .pushNotification
        )
    }

    private func makeArchivedMessage(
        index: Int,
        owner: String,
        queryID: String
    ) throws -> XMPPMessage {
        let root = try DDXMLElement(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='\(owner)'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='result-\(index)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' from='trace-peer@example.com' to='\(owner)' type='chat' id='row-\(index)'>
                <archived xmlns='urn:xmpp:mam:tmp' by='\(owner)' id='stored-\(index)'/>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='stored-\(index)'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='row-\(index)'/>
                <body>fixture</body>
              </message>
              <delay xmlns='urn:xmpp:delay' from='example.com' stamp='2026-08-01T10:00:00Z'/>
            </forwarded>
          </result>
        </message>
        """)
        return try XMPPMessage(from: root)
    }

    private func finalIQ(queryID: String, count: Int) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryID)'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryID)'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>\(count)</count>
            </set>
          </fin>
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }
}
