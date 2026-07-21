import XCTest
@testable import xabber

final class ChatRemoteMAMPersistenceCoordinatorTests: XCTestCase {
    private let conversationKey = ChatTimelineConversationKey(
        owner: "owner@example.com",
        jid: "chat@example.com",
        conversationType: .regular
    )

    func testFinalStartsPersistenceBarrierOffMainAndResolvesOnlyAfterCommit() {
        let coordinator = ChatRemoteHistoryQueryCoordinator(callbackQueue: .main)
        let descriptor = makeDescriptor(queryId: "mam-older", generation: 7, direction: .older, cursor: "42")
        let barrierStarted = expectation(description: "barrier started")
        let committed = expectation(description: "committed")
        let releaseBarrier = DispatchSemaphore(value: 0)
        var completionCount = 0

        XCTAssertTrue(coordinator.register(descriptor) { page, completion in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(page.first, "31")
            XCTAssertEqual(page.last, "21")
            barrierStarted.fulfill()
            XCTAssertEqual(releaseBarrier.wait(timeout: .now() + 2), .success)
            completion(.success(self.completionResult(persistedRows: 10)))
        })

        let disposition = coordinator.receiveFinal(
            queryId: descriptor.queryId,
            generation: descriptor.generation,
            page: makeFinalPage()
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            completionCount += 1
            guard case .success(let page) = result else {
                return XCTFail("Expected committed page")
            }
            XCTAssertEqual(page.descriptor, descriptor)
            XCTAssertEqual(page.persistence.persistenceSummary.persistedRows, 10)
            committed.fulfill()
        }

        XCTAssertEqual(disposition, .accepted)
        wait(for: [barrierStarted], timeout: 2)
        XCTAssertEqual(completionCount, 0)
        releaseBarrier.signal()
        wait(for: [committed], timeout: 2)
        XCTAssertEqual(completionCount, 1)
    }

    func testPersistenceAlreadyCommittedBeforeFinalStillResolvesAsynchronouslyOnce() {
        let coordinator = ChatRemoteHistoryQueryCoordinator(callbackQueue: .main)
        let descriptor = makeDescriptor(queryId: "mam-newer", generation: 9, direction: .newer, cursor: "91")
        let committed = expectation(description: "committed")
        var returnedFromReceiveFinal = false

        XCTAssertTrue(coordinator.register(descriptor) { _, completion in
            completion(.success(self.completionResult(persistedRows: 1)))
        })

        XCTAssertEqual(
            coordinator.receiveFinal(
                queryId: descriptor.queryId,
                generation: descriptor.generation,
                page: makeFinalPage()
            ) { result in
                XCTAssertTrue(returnedFromReceiveFinal)
                guard case .success(let committedPage) = result else {
                    return XCTFail("Expected success")
                }
                XCTAssertEqual(committedPage.descriptor.direction, .newer)
                committed.fulfill()
            },
            .accepted
        )
        returnedFromReceiveFinal = true

        wait(for: [committed], timeout: 2)
    }

    func testDuplicateFinalAndStaleGenerationCannotRunBarrierOrResolveTwice() {
        let coordinator = ChatRemoteHistoryQueryCoordinator(callbackQueue: .main)
        let descriptor = makeDescriptor(queryId: "mam-dedupe", generation: 12, direction: .older, cursor: "55")
        let barrierStarted = expectation(description: "barrier")
        let committed = expectation(description: "committed")
        let releaseBarrier = DispatchSemaphore(value: 0)
        var barrierCount = 0
        var completionCount = 0

        XCTAssertTrue(coordinator.register(descriptor) { _, completion in
            barrierCount += 1
            barrierStarted.fulfill()
            XCTAssertEqual(releaseBarrier.wait(timeout: .now() + 2), .success)
            completion(.success(self.completionResult(persistedRows: 1)))
        })

        XCTAssertEqual(
            coordinator.receiveFinal(queryId: descriptor.queryId, generation: 11, page: makeFinalPage()) { _ in
                XCTFail("Stale generation must not resolve")
            },
            .stale
        )
        XCTAssertEqual(
            coordinator.receiveFinal(queryId: descriptor.queryId, generation: 12, page: makeFinalPage()) { _ in
                completionCount += 1
                committed.fulfill()
            },
            .accepted
        )
        XCTAssertEqual(
            coordinator.receiveFinal(queryId: descriptor.queryId, generation: 12, page: makeFinalPage()) { _ in
                XCTFail("Duplicate final must not replace completion")
            },
            .duplicate
        )

        wait(for: [barrierStarted], timeout: 2)
        XCTAssertEqual(barrierCount, 1)
        releaseBarrier.signal()
        wait(for: [committed], timeout: 2)
        XCTAssertEqual(completionCount, 1)
    }

    func testSupersededFinalIsRejectedWithoutTheCurrentControllerContext() {
        let coordinator = ChatRemoteHistoryQueryCoordinator(callbackQueue: .main)
        let descriptor = makeDescriptor(
            queryId: "mam-superseded-unowned-final",
            generation: 15,
            direction: .older,
            cursor: "88"
        )
        XCTAssertTrue(coordinator.register(descriptor) { _, _ in
            XCTFail("A superseded query must not enter persistence")
        })
        XCTAssertTrue(coordinator.terminate(
            queryId: descriptor.queryId,
            generation: descriptor.generation,
            reason: .superseded
        ))

        XCTAssertEqual(
            coordinator.classifyUnhandledFinal(queryId: descriptor.queryId),
            .stale
        )
        XCTAssertEqual(
            coordinator.classifyUnhandledFinal(queryId: "unknown-query"),
            .unknown
        )
    }

    func testTerminalFailureMatrixUnlocksOnceAndIgnoresLatePersistenceAndFinal() {
        let reasons: [ChatRemoteHistoryTerminalReason] = [
            .timeout,
            .iqError,
            .disconnected,
            .persistenceFailed,
            .cancelled,
            .superseded
        ]

        for (index, reason) in reasons.enumerated() {
            let coordinator = ChatRemoteHistoryQueryCoordinator(callbackQueue: .main)
            let descriptor = makeDescriptor(
                queryId: "mam-terminal-\(index)",
                generation: index + 1,
                direction: index.isMultiple(of: 2) ? .older : .newer,
                cursor: "\(index)"
            )
            let barrierStarted = expectation(description: "barrier \(index)")
            let releaseBarrier = DispatchSemaphore(value: 0)
            var completionCount = 0

            XCTAssertTrue(coordinator.register(descriptor) { _, completion in
                barrierStarted.fulfill()
                XCTAssertEqual(releaseBarrier.wait(timeout: .now() + 2), .success)
                completion(.success(self.completionResult(persistedRows: 1)))
            })
            XCTAssertEqual(
                coordinator.receiveFinal(queryId: descriptor.queryId, generation: descriptor.generation, page: makeFinalPage()) { _ in
                    completionCount += 1
                },
                .accepted
            )
            wait(for: [barrierStarted], timeout: 2)
            XCTAssertTrue(coordinator.terminate(
                queryId: descriptor.queryId,
                generation: descriptor.generation,
                reason: reason
            ))
            XCTAssertFalse(coordinator.terminate(
                queryId: descriptor.queryId,
                generation: descriptor.generation,
                reason: reason
            ))
            releaseBarrier.signal()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            XCTAssertEqual(completionCount, 0)
            XCTAssertEqual(
                coordinator.receiveFinal(queryId: descriptor.queryId, generation: descriptor.generation, page: makeFinalPage()) { _ in
                    completionCount += 1
                },
                .stale
            )
        }
    }

    func testTerminalQueryTombstonesRemainBoundedAcrossLongPagingSessions() {
        let coordinator = ChatRemoteHistoryQueryCoordinator(callbackQueue: .main)

        for index in 0..<200 {
            let descriptor = makeDescriptor(
                queryId: "mam-terminal-bounded-\(index)",
                generation: index,
                direction: index.isMultiple(of: 2) ? .older : .newer,
                cursor: "\(index)"
            )
            XCTAssertTrue(coordinator.register(descriptor) { _, _ in
                XCTFail("A terminated query must not start persistence")
            })
            XCTAssertTrue(coordinator.terminate(
                queryId: descriptor.queryId,
                generation: descriptor.generation,
                reason: .cancelled
            ))
        }

        XCTAssertLessThanOrEqual(
            coordinator.trackedQueryCount,
            ChatRemoteHistoryQueryCoordinator.terminalTombstoneLimit
        )
        XCTAssertNil(coordinator.terminalReason(queryId: "mam-terminal-bounded-0"))
        XCTAssertEqual(coordinator.terminalReason(queryId: "mam-terminal-bounded-199"), .cancelled)
    }

    func testDisconnectedPageRetriesWithNewQueryAndRejectsLateFinalWithoutDuplicateCommit() {
        let coordinator = ChatRemoteHistoryQueryCoordinator(callbackQueue: .main)
        let disconnected = makeDescriptor(
            queryId: "mam-network-disconnected",
            generation: 30,
            direction: .older,
            cursor: "500"
        )
        var disconnectedCleanupCount = 0
        var persistenceCount = 0
        var committedCount = 0

        XCTAssertTrue(coordinator.register(
            disconnected,
            persistenceCleanup: { disconnectedCleanupCount += 1 }
        ) { _, _ in
            persistenceCount += 1
            XCTFail("A disconnected query must not enter persistence")
        })
        XCTAssertTrue(coordinator.terminate(
            queryId: disconnected.queryId,
            generation: disconnected.generation,
            reason: .disconnected
        ))
        XCTAssertEqual(disconnectedCleanupCount, 1)
        XCTAssertEqual(coordinator.activeQueryCount, 0)
        XCTAssertEqual(coordinator.terminalReason(queryId: disconnected.queryId), .disconnected)
        XCTAssertEqual(
            coordinator.receiveFinal(
                queryId: disconnected.queryId,
                generation: disconnected.generation,
                page: makeFinalPage()
            ) { _ in
                XCTFail("A late final from the disconnected query must stay stale")
            },
            .stale
        )

        let retry = makeDescriptor(
            queryId: "mam-network-retry",
            generation: 31,
            direction: .older,
            cursor: disconnected.cursorId ?? ""
        )
        let committed = expectation(description: "retry committed once")
        XCTAssertTrue(coordinator.register(retry) { _, completion in
            persistenceCount += 1
            completion(.success(self.completionResult(persistedRows: 10)))
        })
        XCTAssertEqual(
            coordinator.receiveFinal(
                queryId: retry.queryId,
                generation: retry.generation,
                page: makeFinalPage()
            ) { result in
                guard case .success(let page) = result else {
                    return XCTFail("Recovered query must commit")
                }
                committedCount += 1
                XCTAssertEqual(page.descriptor.cursorId, disconnected.cursorId)
                committed.fulfill()
            },
            .accepted
        )
        XCTAssertEqual(
            coordinator.receiveFinal(
                queryId: retry.queryId,
                generation: retry.generation,
                page: makeFinalPage()
            ) { _ in
                XCTFail("Duplicate retry final must not replace completion")
            },
            .duplicate
        )

        wait(for: [committed], timeout: 2)
        XCTAssertEqual(persistenceCount, 1)
        XCTAssertEqual(committedCount, 1)
        XCTAssertEqual(coordinator.activeQueryCount, 0)
        XCTAssertEqual(coordinator.terminalReason(queryId: retry.queryId), .completed)
        XCTAssertLessThanOrEqual(
            coordinator.trackedQueryCount,
            ChatRemoteHistoryQueryCoordinator.terminalTombstoneLimit
        )
    }

    func testCoordinatorWatchdogRemainsArmedUntilPersistenceDelivery() {
        let coordinator = ChatRemoteHistoryQueryCoordinator(callbackQueue: .main)
        let descriptor = makeDescriptor(
            queryId: "mam-owned-timeout",
            generation: 21,
            direction: .newer,
            cursor: "700"
        )
        let barrierStarted = expectation(description: "persistence barrier started")
        let timeout = expectation(description: "watchdog fires while persistence is stalled")
        let committed = expectation(description: "late persistence must not commit")
        committed.isInverted = true
        let releaseBarrier = DispatchSemaphore(value: 0)

        XCTAssertTrue(coordinator.register(descriptor) { _, completion in
            barrierStarted.fulfill()
            XCTAssertEqual(releaseBarrier.wait(timeout: .now() + 2), .success)
            completion(.success(self.completionResult(persistedRows: 1)))
        })
        XCTAssertTrue(coordinator.scheduleTimeout(
            queryId: descriptor.queryId,
            generation: descriptor.generation,
            after: 0.05,
            terminalReason: .timeout
        ) {
            timeout.fulfill()
        })
        XCTAssertTrue(coordinator.hasScheduledTimeout(queryId: descriptor.queryId))
        XCTAssertEqual(
            coordinator.receiveFinal(
                queryId: descriptor.queryId,
                generation: descriptor.generation,
                page: makeFinalPage()
            ) { result in
                guard case .success = result else {
                    return XCTFail("Expected committed page")
                }
                committed.fulfill()
            },
            .accepted
        )
        XCTAssertTrue(
            coordinator.hasScheduledTimeout(queryId: descriptor.queryId),
            "raw <fin> only starts persistence and must not disarm the watchdog"
        )

        wait(for: [barrierStarted, timeout], timeout: 1)
        XCTAssertEqual(
            coordinator.terminalReason(queryId: descriptor.queryId),
            .timeout
        )
        releaseBarrier.signal()
        wait(for: [committed], timeout: 0.2)
    }

    func testPersistenceErrorIsDeliveredOnceWithoutCommittedPage() {
        struct PersistenceFailure: Error {}

        let coordinator = ChatRemoteHistoryQueryCoordinator(callbackQueue: .main)
        let descriptor = makeDescriptor(queryId: "mam-persistence-error", generation: 17, direction: .older, cursor: "8")
        let failed = expectation(description: "failed")

        XCTAssertTrue(coordinator.register(descriptor) { _, completion in
            completion(.failure(PersistenceFailure()))
        })
        XCTAssertEqual(
            coordinator.receiveFinal(queryId: descriptor.queryId, generation: descriptor.generation, page: makeFinalPage()) { result in
                guard case .failure = result else {
                    return XCTFail("Persistence failure must not produce a committed page")
                }
                failed.fulfill()
            },
            .accepted
        )

        wait(for: [failed], timeout: 2)
        XCTAssertEqual(coordinator.terminalReason(queryId: descriptor.queryId), .persistenceFailed)
    }

    func testBoundaryLoadingPresentationHasZeroTimelineGeometryDelta() {
        XCTAssertFalse(ChatBoundaryLoadingPresentationPolicy.usesTimelineRow)
        XCTAssertEqual(
            ChatBoundaryLoadingPresentationPolicy.geometryDelta(
                messageRowCount: 100,
                contentHeight: 4_200
            ),
            .zero
        )
    }

    func testFinalIQControllerPathDoesNotCallSynchronousPersistenceFlush() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("ChatRemoteHistoryCompletionCoordinator.flushQueryMessages("))
        XCTAssertTrue(source.contains("ChatRemoteHistoryCompletionCoordinator.flushQueryMessagesAsync("))
        XCTAssertTrue(source.contains("remoteHistoryQueryCoordinator.classifyUnhandledFinal("))
    }

    func testHistoryPagingUsesSemanticRequestAdapterAndRemovesLegacyDirectionNames() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "xabber/xmpp/messages/message_archive/MessageArchiveManager.swift",
            "xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift",
            "xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
        ]
        let sources = try relativePaths.map {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent($0),
                encoding: .utf8
            )
        }

        XCTAssertFalse(sources.contains { $0.contains("getPrevHistory(") })
        XCTAssertFalse(sources.contains { $0.contains("getNextHistory(") })
        XCTAssertTrue(sources.contains { $0.contains("requestOlderHistoryPage(") })
        XCTAssertTrue(sources.contains { $0.contains("requestNewerHistoryPage(") })
    }

    func testBackgroundContextPrefetchUsesExplicitDetachedPersistenceQueries() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
            ),
            encoding: .utf8
        )
        let methodStart = try XCTUnwrap(source.range(
            of: "private func startBackgroundContextPrefetchIfNeeded("
        ))
        let methodEnd = try XCTUnwrap(source.range(
            of: "private func revealLocalContentForSavedPositionIfNeeded(",
            range: methodStart.upperBound..<source.endIndex
        ))
        let methodSource = String(source[methodStart.lowerBound..<methodEnd.lowerBound])

        XCTAssertTrue(methodSource.contains("ChatDetachedRemoteHistoryPersistenceTransaction("))
        XCTAssertTrue(methodSource.contains("queryIds: queryIds"))
        XCTAssertTrue(methodSource.contains("detachedPersistenceTransaction: persistenceTransaction"))
        XCTAssertTrue(methodSource.contains("requestCallbacks: persistenceTransaction.requestCallbacks"))
        XCTAssertFalse(
            methodSource.contains("queryId: nil"),
            "background context MAM must register an explicit query-scoped persistence batch before send"
        )
    }

    func testDetachedPersistenceTerminalRunsOnlyAfterFlushAndUnregisterAndDedupesLateFinal() {
        let queryId = "MAM next history: detached-order"
        var events: [String] = []
        var finishFlush: (() -> Void)?
        var finishUnregister: (() -> Void)?
        let transaction = ChatDetachedRemoteHistoryPersistenceTransaction(
            owner: "owner@example.com",
            jid: "chat@example.com",
            conversationType: .regular,
            queryIds: [queryId],
            terminal: { events.append("terminal:\($0)") },
            flush: { receivedQueryId, _, completion in
                events.append("flush:\(receivedQueryId)")
                finishFlush = completion
            },
            unregister: { receivedQueryId, completion in
                events.append("unregister:\(receivedQueryId)")
                finishUnregister = completion
            }
        )
        let state = MessageArchivePageEndState(
            queryExhausted: false,
            archiveEnded: false,
            persistedMessageCount: 0
        )

        transaction.requestCallbacks.onEndPage?(queryId, state, "first", "last", 81)
        transaction.requestCallbacks.onEndPage?(queryId, state, "first", "last", 81)
        XCTAssertEqual(events, ["flush:\(queryId)"])

        finishFlush?()
        XCTAssertEqual(events, ["flush:\(queryId)", "unregister:\(queryId)"])

        finishUnregister?()
        XCTAssertEqual(
            events,
            ["flush:\(queryId)", "unregister:\(queryId)", "terminal:\(queryId)"]
        )

        transaction.requestCallbacks.onEndPage?(queryId, state, "first", "last", 81)
        XCTAssertEqual(
            events,
            ["flush:\(queryId)", "unregister:\(queryId)", "terminal:\(queryId)"],
            "a final delivered after controller teardown or terminal completion must be inert"
        )
    }

    func testInteractiveOlderPageDoesNotReleaseMamSchedulerOnRawFinal() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift"
            ),
            encoding: .utf8
        )
        let olderPageStart = try XCTUnwrap(
            source.range(of: "case .remote(.remoteOlderPage):")
        )
        let newerPageStart = try XCTUnwrap(
            source.range(
                of: "case .remote(.remoteNewerPage):",
                range: olderPageStart.upperBound..<source.endIndex
            )
        )
        let olderPageSource = String(
            source[olderPageStart.lowerBound..<newerPageStart.lowerBound]
        )

        XCTAssertTrue(
            olderPageSource.contains("deferCoverageCommitUntilConsumerProof: true"),
            "interactive older paging must keep query-scoped consumer persistence ownership"
        )
        XCTAssertFalse(
            olderPageSource.contains("callback: finish"),
            "raw MAM final must not release the shared .mamArchive scheduler lease before query persistence terminates"
        )
    }

    func testMamSchedulerLeaseReleasesExactlyOnceAfterPersistenceTerminal() {
        let coordinator = ChatRemoteHistoryQueryCoordinator(callbackQueue: .main)
        let descriptor = makeDescriptor(
            queryId: "mam-scheduler-persistence-terminal",
            generation: 41,
            direction: .older,
            cursor: "900"
        )
        let lease = ChatInteractiveRemoteArchiveSchedulerLease()
        let barrierStarted = expectation(description: "persistence barrier started")
        let leaseReleased = expectation(description: "scheduler lease released")
        let committed = expectation(description: "committed page delivered")
        let releaseBarrier = DispatchSemaphore(value: 0)
        let countLock = NSLock()
        var releaseCount = 0

        lease.attach {
            countLock.lock()
            releaseCount += 1
            countLock.unlock()
            leaseReleased.fulfill()
        }
        XCTAssertTrue(coordinator.register(
            descriptor,
            persistenceCleanup: lease.complete
        ) { _, completion in
            barrierStarted.fulfill()
            XCTAssertEqual(releaseBarrier.wait(timeout: .now() + 2), .success)
            completion(.success(self.completionResult(persistedRows: 81)))
        })

        XCTAssertEqual(
            coordinator.receiveFinal(
                queryId: descriptor.queryId,
                generation: descriptor.generation,
                page: makeFinalPage()
            ) { result in
                guard case .success = result else {
                    return XCTFail("Expected a persisted committed page")
                }
                committed.fulfill()
            },
            .accepted
        )

        wait(for: [barrierStarted], timeout: 2)
        countLock.lock()
        XCTAssertEqual(releaseCount, 0, "raw final must not release the scheduler lane")
        countLock.unlock()

        releaseBarrier.signal()
        wait(for: [leaseReleased, committed], timeout: 2)
        lease.complete()
        coordinator.remove(queryId: descriptor.queryId)
        countLock.lock()
        XCTAssertEqual(releaseCount, 1)
        countLock.unlock()
    }

    func testTerminalCleanupFlushesPartialBatchBeforeCancellingQueryAndReleasingMamLane() {
        let lease = ChatInteractiveRemoteArchiveSchedulerLease()
        var events: [String] = []
        var finishPersistence: (() -> Void)?

        lease.attach {
            events.append("scheduler-release")
        }

        ChatInteractiveRemoteArchiveTerminalCleanup.perform(
            flushPersistence: { completion in
                events.append("persistence-flush-start")
                finishPersistence = completion
            },
            cancelPendingRequest: {
                events.append("query-cancel")
            },
            completeSchedulerLease: lease.complete
        )

        XCTAssertEqual(events, ["persistence-flush-start"])

        finishPersistence?()
        finishPersistence?()
        lease.complete()

        XCTAssertEqual(
            events,
            ["persistence-flush-start", "query-cancel", "scheduler-release"],
            "timeout/disconnect teardown must persist the partial page before removing transport state and releasing .mamArchive"
        )
    }

    func testMamSchedulerLeaseHandlesTerminalBeforeSchedulerDequeue() {
        let lease = ChatInteractiveRemoteArchiveSchedulerLease()
        lease.complete()

        var releaseCount = 0
        lease.attach {
            releaseCount += 1
        }
        lease.complete()

        XCTAssertEqual(releaseCount, 1)
    }

    func testUnavailableSendReadinessDispatchesFailureAndReleasesMamLane() {
        let owner = "interactive-mam-not-ready-\(UUID().uuidString)@example.com"
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatRemoteMAMPersistenceCoordinatorTests.\(UUID().uuidString)")
        )
        AccountManager.shared.users.append(account)
        defer {
            account.xmppTaskScheduler.reset()
            AccountManager.shared.users.removeAll { $0.jid == owner }
        }

        XCTAssertFalse(account.sendReadiness.snapshot.canFlushApplicationStanzas)

        let unavailable = expectation(description: "not-ready request reports dispatch unavailable")
        let mamLaneReleased = expectation(description: "not-ready request releases MAM lane")
        let stateLock = NSLock()
        var didAttemptSend = false
        var unavailableReason: String?

        let request = ChatInteractiveRemoteArchiveDispatchRequest(
            owner: owner,
            queryId: "interactive-not-ready",
            direction: .older,
            cursorId: "archive-cursor",
            pageSize: 250,
            priority: .interactive,
            resource: .mamArchive,
            deduplicationKey: "interactive-not-ready",
            schedulerLease: ChatInteractiveRemoteArchiveSchedulerLease(),
            shouldDispatch: { true },
            send: { _, _ in
                stateLock.lock()
                didAttemptSend = true
                stateLock.unlock()
                return nil
            },
            transportStarted: { _, _, _ in
                XCTFail("transport cannot start while application stanzas are not send-ready")
            },
            dispatchUnavailable: { reason in
                stateLock.lock()
                unavailableReason = reason
                stateLock.unlock()
                unavailable.fulfill()
            }
        )

        AccountSchedulerChatInteractiveRemoteArchiveRequestDispatcher().enqueue(request)
        account.xmppTaskScheduler.enqueue(
            priority: .interactive,
            resource: .mamArchive,
            deduplicationKey: "after-interactive-not-ready"
        ) { finish in
            mamLaneReleased.fulfill()
            finish()
        }

        wait(for: [unavailable, mamLaneReleased], timeout: 1)
        stateLock.lock()
        let attemptedSend = didAttemptSend
        let reason = unavailableReason
        stateLock.unlock()
        XCTAssertFalse(attemptedSend)
        XCTAssertFalse(reason?.isEmpty ?? true)
    }

    private func makeDescriptor(
        queryId: String,
        generation: Int,
        direction: ChatHistoryPageDirection,
        cursor: String
    ) -> ChatRemoteHistoryQueryDescriptor {
        ChatRemoteHistoryQueryDescriptor(
            conversationKey: conversationKey,
            queryId: queryId,
            direction: direction,
            cursorId: cursor,
            generation: generation
        )
    }

    private func makeFinalPage() -> ChatRemoteHistoryFinalPage {
        ChatRemoteHistoryFinalPage(
            state: MessageArchivePageEndState(
                queryExhausted: false,
                archiveEnded: false,
                persistedMessageCount: 0,
                requestCursorId: "42"
            ),
            first: "31",
            last: "21",
            count: 10
        )
    }

    private func completionResult(persistedRows: Int) -> ChatRemoteHistoryCompletionResult {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.savedNew = persistedRows
        return ChatRemoteHistoryCompletionResult(
            state: MessageArchivePageEndState(
                queryExhausted: false,
                archiveEnded: false,
                persistedMessageCount: persistedRows,
                requestCursorId: "42"
            ),
            flushedMessageCount: persistedRows,
            persistenceSummary: summary
        )
    }
}
