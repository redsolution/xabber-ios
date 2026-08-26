import XCTest
import RealmSwift
@testable import xabber

final class VCardRequestSingleFlightCoordinatorTests: XCTestCase {
    func testFailureResponseUpdatesExistingManagedCardWithoutReassigningPrimaryKey() throws {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "VCardManagedFailure-\(UUID().uuidString)"
        )
        configuration.objectTypes = [vCardStorageItem.self]
        let realm = try Realm(configuration: configuration)
        let jid = "alice@example.com"
        let previousOwner = "old-owner@example.com"
        let requestOwner = "request-owner@example.com"
        let failedAt = Date(timeIntervalSince1970: 42_000)

        try realm.write {
            let stored = vCardStorageItem()
            stored.jid = jid
            stored.owner = previousOwner
            stored.isLastUpdateErrorOccured = false
            realm.add(stored)
        }

        try realm.write {
            VCardTerminalStorageMutation.persistFailure(
                in: realm,
                owner: requestOwner,
                jid: jid,
                at: failedAt
            )
        }

        let stored = try XCTUnwrap(
            realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid)
        )
        XCTAssertEqual(stored.jid, jid)
        XCTAssertEqual(stored.owner, requestOwner)
        XCTAssertEqual(stored.lastUpdateDate, failedAt)
        XCTAssertTrue(stored.isLastUpdateErrorOccured)
        XCTAssertEqual(realm.objects(vCardStorageItem.self).count, 1)
    }

    func testDuplicateBareJIDJoinsOneGenerationScopedRequest() {
        let coordinator = makeCoordinator()
        var callbackResults: [(String, Bool)] = []

        let first = coordinator.submit(
            jid: "alice@example.com/phone",
            priority: .background
        ) { callbackResults.append(($0.jid, $1)) }
        let duplicate = coordinator.submit(
            jid: "alice@example.com",
            priority: .background
        ) { callbackResults.append(($0.jid, $1)) }

        guard case .enqueue(let request) = first,
              case .joined(let joined) = duplicate else {
            return XCTFail("Expected one enqueue followed by a joined request")
        }
        XCTAssertEqual(joined.elementID, request.elementID)
        XCTAssertEqual(joined.jid, "alice@example.com")
        XCTAssertEqual(coordinator.pendingCount, 1)

        XCTAssertTrue(coordinator.activate(request, schedulerFinish: {}))
        guard let receipt = coordinator.matchResponse(
            elementID: request.elementID,
            generation: request.generation,
            responseBareJID: "alice@example.com"
        ) else {
            return XCTFail("Expected matching response receipt")
        }
        coordinator.completeResponse(receipt, success: true)

        XCTAssertEqual(callbackResults.count, 2)
        XCTAssertTrue(callbackResults.allSatisfy {
            $0.0 == "alice@example.com" && $0.1
        })
    }

    func testQueuedDuplicatePromotesWithoutReplacingTransactionIdentity() {
        let coordinator = makeCoordinator()

        let first = coordinator.submit(jid: "alice@example.com", priority: .background)
        let promoted = coordinator.submit(jid: "alice@example.com", priority: .foreground)

        guard case .enqueue(let original) = first,
              case .promote(let replacement) = promoted else {
            return XCTFail("Expected queued priority promotion")
        }
        XCTAssertEqual(replacement.elementID, original.elementID)
        XCTAssertEqual(replacement.generation, original.generation)
        XCTAssertEqual(replacement.priority, .foreground)
        XCTAssertEqual(coordinator.pendingCount, 1)
    }

    func testForegroundDuplicateJoinsRunningBackgroundIQWithoutCancellation() {
        let coordinator = makeCoordinator()
        var didReleaseRunningLane = false
        guard case .enqueue(let running) = coordinator.submit(
            jid: "alice@example.com",
            priority: .background
        ) else {
            return XCTFail("Expected background request")
        }
        XCTAssertTrue(coordinator.activate(running) {
            didReleaseRunningLane = true
        })

        guard case .joined(let joined) = coordinator.submit(
            jid: "alice@example.com/phone",
            priority: .foreground
        ) else {
            return XCTFail("An already-running IQ must be joined")
        }
        XCTAssertEqual(joined.elementID, running.elementID)
        XCTAssertFalse(didReleaseRunningLane)
        XCTAssertEqual(coordinator.pendingCount, 1)

        guard let receipt = coordinator.matchResponse(
            elementID: running.elementID,
            generation: running.generation,
            responseBareJID: running.jid
        ) else {
            return XCTFail("Running IQ must still accept its response")
        }
        coordinator.completeResponse(receipt, success: true)
        XCTAssertTrue(didReleaseRunningLane)
    }

    func testVisiblePromotionMovesQueuedJIDAheadOfBackgroundFIFOWithoutCancellingRunningIQ() {
        let coordinator = makeCoordinator()
        let scheduler = AccountXMPPTaskScheduler(
            configuration: .test(
                defaultMaxConcurrent: 1,
                maxConcurrentByResource: [.vcard: 1],
                defaultCooldown: 0
            ),
            startsImmediately: false
        )
        let firstStarted = expectation(description: "running background IQ starts")
        let visibleStarted = expectation(description: "promoted visible IQ starts next")
        let earlierBackgroundStarted = expectation(description: "earlier background IQ starts last")
        let stateLock = NSLock()
        var startOrder: [String] = []

        guard case .enqueue(let running) = coordinator.submit(
            jid: "running@example.com",
            priority: .background
        ), case .enqueue(let earlierBackground) = coordinator.submit(
            jid: "earlier@example.com",
            priority: .background
        ), case .enqueue(let visibleBackground) = coordinator.submit(
            jid: "visible@example.com",
            priority: .background
        ) else {
            return XCTFail("Expected three independent queued flights")
        }

        func enqueue(
            _ request: VCardSingleFlightRequest,
            started: XCTestExpectation
        ) {
            scheduler.enqueue(
                priority: request.priority.schedulerPriority,
                resource: .vcard,
                deduplicationKey: request.deduplicationKey
            ) { finish in
                XCTAssertTrue(coordinator.activate(request, schedulerFinish: finish))
                stateLock.lock()
                startOrder.append(request.jid)
                stateLock.unlock()
                started.fulfill()
            }
        }

        enqueue(running, started: firstStarted)
        enqueue(earlierBackground, started: earlierBackgroundStarted)
        enqueue(visibleBackground, started: visibleStarted)
        scheduler.resume()
        wait(for: [firstStarted], timeout: 1)

        guard case .promote(let promotedVisible) = coordinator.submit(
            jid: visibleBackground.jid,
            priority: .foreground
        ) else {
            return XCTFail("Expected queued visible JID to promote")
        }
        scheduler.promotePendingTask(
            deduplicationKey: promotedVisible.deduplicationKey,
            to: promotedVisible.priority.schedulerPriority
        )

        stateLock.lock()
        XCTAssertEqual(startOrder, [running.jid])
        stateLock.unlock()
        guard let runningReceipt = coordinator.matchResponse(
            elementID: running.elementID,
            generation: running.generation,
            responseBareJID: running.jid
        ) else {
            return XCTFail("Running IQ must remain active after queued promotion")
        }
        coordinator.completeResponse(runningReceipt, success: true)

        wait(for: [visibleStarted], timeout: 1)
        stateLock.lock()
        XCTAssertEqual(startOrder, [running.jid, visibleBackground.jid])
        stateLock.unlock()
        guard let visibleReceipt = coordinator.matchResponse(
            elementID: visibleBackground.elementID,
            generation: visibleBackground.generation,
            responseBareJID: visibleBackground.jid
        ) else {
            return XCTFail("Promoted visible IQ must become active")
        }
        coordinator.completeResponse(visibleReceipt, success: true)

        wait(for: [earlierBackgroundStarted], timeout: 1)
        coordinator.fail(earlierBackground)
    }

    func testSchedulerVCardLaneRemainsOccupiedUntilParsedResponseIsCompleted() {
        let coordinator = makeCoordinator()
        let scheduler = AccountXMPPTaskScheduler(
            configuration: .test(
                defaultMaxConcurrent: 1,
                maxConcurrentByResource: [.vcard: 1],
                defaultCooldown: 0
            )
        )
        let firstStarted = expectation(description: "first vCard request started")
        let secondStarted = expectation(description: "second vCard request started")
        let secondMustWait = expectation(description: "second vCard request remains queued")
        secondMustWait.isInverted = true
        let stateLock = NSLock()
        var isCheckingInitialWait = true

        guard case .enqueue(let first) = coordinator.submit(
            jid: "alice@example.com",
            priority: .background
        ), case .enqueue(let second) = coordinator.submit(
            jid: "bob@example.com",
            priority: .background
        ) else {
            return XCTFail("Expected two independent requests")
        }

        scheduler.enqueue(
            priority: .background,
            resource: .vcard,
            deduplicationKey: first.deduplicationKey
        ) { finish in
            XCTAssertTrue(coordinator.activate(first, schedulerFinish: finish))
            firstStarted.fulfill()
        }
        scheduler.enqueue(
            priority: .background,
            resource: .vcard,
            deduplicationKey: second.deduplicationKey
        ) { finish in
            XCTAssertTrue(coordinator.activate(second, schedulerFinish: finish))
            stateLock.lock()
            let shouldFulfillInvertedExpectation = isCheckingInitialWait
            stateLock.unlock()
            if shouldFulfillInvertedExpectation {
                secondMustWait.fulfill()
            }
            secondStarted.fulfill()
        }

        wait(for: [firstStarted], timeout: 1)
        wait(for: [secondMustWait], timeout: 0.05)
        stateLock.lock()
        isCheckingInitialWait = false
        stateLock.unlock()

        guard let receipt = coordinator.matchResponse(
            elementID: first.elementID,
            generation: first.generation,
            responseBareJID: first.jid
        ) else {
            return XCTFail("Expected first response to match")
        }
        coordinator.completeResponse(receipt, success: true)

        wait(for: [secondStarted], timeout: 1)
        coordinator.fail(second)
    }

    func testOneHundredMissingVCardsNeverCreateMoreThanOneOutstandingIQ() {
        let coordinator = makeCoordinator(timeout: 5)
        let scheduler = AccountXMPPTaskScheduler(
            configuration: .test(
                defaultMaxConcurrent: 1,
                maxConcurrentByResource: [.vcard: 1],
                defaultCooldown: 0
            )
        )
        let allCompleted = expectation(description: "all vCard requests completed")
        allCompleted.expectedFulfillmentCount = 100
        let allSchedulerLanesReleased = expectation(
            description: "all vCard scheduler lanes released"
        )
        allSchedulerLanesReleased.expectedFulfillmentCount = 100
        let stateLock = NSLock()
        var activeCount = 0
        var maximumActiveCount = 0

        let requests: [VCardSingleFlightRequest] = (0..<100).compactMap { index in
            guard case .enqueue(let request) = coordinator.submit(
                jid: "missing-\(index)@example.com",
                priority: .background,
                completion: { _, success in
                    XCTAssertTrue(success)
                    allCompleted.fulfill()
                }
            ) else {
                XCTFail("Every distinct JID must create one queued flight")
                return nil
            }
            return request
        }
        XCTAssertEqual(requests.count, 100)

        requests.forEach { request in
            scheduler.enqueue(
                priority: .background,
                resource: .vcard,
                deduplicationKey: request.deduplicationKey
            ) { finish in
                stateLock.lock()
                activeCount += 1
                maximumActiveCount = max(maximumActiveCount, activeCount)
                stateLock.unlock()

                XCTAssertTrue(coordinator.activate(request, schedulerFinish: {
                    stateLock.lock()
                    activeCount -= 1
                    stateLock.unlock()
                    finish()
                    allSchedulerLanesReleased.fulfill()
                }))

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.001) {
                    guard let receipt = coordinator.matchResponse(
                        elementID: request.elementID,
                        generation: request.generation,
                        responseBareJID: request.jid
                    ) else {
                        return XCTFail("Active flight must accept its matching response")
                    }
                    coordinator.completeResponse(receipt, success: true)
                }
            }
        }

        wait(for: [allCompleted, allSchedulerLanesReleased], timeout: 5)
        stateLock.lock()
        let observedMaximum = maximumActiveCount
        let remainingActive = activeCount
        stateLock.unlock()
        XCTAssertEqual(observedMaximum, 1)
        XCTAssertEqual(remainingActive, 0)
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    func testResponseMatchesElementIDGenerationAndExpectedBareJID() {
        let coordinator = makeCoordinator()
        guard case .enqueue(let request) = coordinator.submit(
            jid: "alice@example.com/device",
            priority: .foreground
        ) else {
            return XCTFail("Expected request")
        }
        XCTAssertTrue(coordinator.activate(request, schedulerFinish: {}))

        XCTAssertNil(coordinator.matchResponse(
            elementID: "other-id",
            generation: request.generation,
            responseBareJID: request.jid
        ))
        XCTAssertNil(coordinator.matchResponse(
            elementID: request.elementID,
            generation: request.generation &+ 1,
            responseBareJID: request.jid
        ))
        XCTAssertNil(coordinator.matchResponse(
            elementID: request.elementID,
            generation: request.generation,
            responseBareJID: "mallory@example.com"
        ))
        XCTAssertNil(coordinator.matchResponse(
            elementID: request.elementID,
            generation: request.generation,
            responseBareJID: nil
        ))

        let receipt = coordinator.matchResponse(
            elementID: request.elementID,
            generation: request.generation,
            responseBareJID: request.jid
        )
        XCTAssertNotNil(receipt)
        if let receipt {
            coordinator.completeResponse(receipt, success: true)
        }
    }

    func testMatchedResponseDoesNotReleaseLaneUntilPersistenceCompletion() {
        let coordinator = makeCoordinator()
        var didReleaseSchedulerLane = false
        guard case .enqueue(let request) = coordinator.submit(
            jid: "alice@example.com",
            priority: .foreground
        ) else {
            return XCTFail("Expected request")
        }
        XCTAssertTrue(coordinator.activate(request, schedulerFinish: {
            didReleaseSchedulerLane = true
        }))

        guard let receipt = coordinator.matchResponse(
            elementID: request.elementID,
            generation: request.generation,
            responseBareJID: request.jid
        ) else {
            return XCTFail("Expected response receipt")
        }
        XCTAssertFalse(didReleaseSchedulerLane)

        coordinator.completeResponse(receipt, success: true)
        XCTAssertTrue(didReleaseSchedulerLane)
    }

    func testSelfResponseMayOmitFromWhenElementIDAndGenerationMatch() {
        let coordinator = makeCoordinator(owner: "me@example.com")
        guard case .enqueue(let request) = coordinator.submit(
            jid: "me@example.com/ios",
            priority: .foreground
        ) else {
            return XCTFail("Expected self vCard request")
        }
        XCTAssertTrue(coordinator.activate(request, schedulerFinish: {}))

        let receipt = coordinator.matchResponse(
            elementID: request.elementID,
            generation: request.generation,
            responseBareJID: nil
        )
        XCTAssertNotNil(receipt)
        if let receipt {
            coordinator.completeResponse(receipt, success: true)
        }
    }

    func testDisconnectReleasesLaneAndLateOldGenerationResponseIsIgnored() {
        let coordinator = makeCoordinator()
        let oldFinished = expectation(description: "old scheduler lane released")
        var callbackResult: Bool?
        guard case .enqueue(let oldRequest) = coordinator.submit(
            jid: "alice@example.com",
            priority: .foreground,
            completion: { _, success in callbackResult = success }
        ) else {
            return XCTFail("Expected old request")
        }
        XCTAssertTrue(coordinator.activate(oldRequest, schedulerFinish: {
            oldFinished.fulfill()
        }))

        coordinator.disconnect()
        wait(for: [oldFinished], timeout: 1)
        XCTAssertEqual(callbackResult, false)
        XCTAssertNil(coordinator.matchResponse(
            elementID: oldRequest.elementID,
            generation: oldRequest.generation,
            responseBareJID: oldRequest.jid
        ))

        coordinator.streamDidPrepare()
        guard case .enqueue(let replacement) = coordinator.submit(
            jid: oldRequest.jid,
            priority: .foreground
        ) else {
            return XCTFail("Expected replacement in new generation")
        }
        XCTAssertNotEqual(replacement.generation, oldRequest.generation)
        XCTAssertEqual(coordinator.pendingCount, 1)
    }

    func testTimeoutFailsRequestAndReleasesSchedulerLane() {
        let coordinator = makeCoordinator(timeout: 0.02)
        let finished = expectation(description: "timeout releases scheduler lane")
        let callback = expectation(description: "timeout reports failure")
        guard case .enqueue(let request) = coordinator.submit(
            jid: "alice@example.com",
            priority: .foreground,
            completion: { request, success in
                XCTAssertEqual(request.jid, "alice@example.com")
                XCTAssertFalse(success)
                callback.fulfill()
            }
        ) else {
            return XCTFail("Expected request")
        }

        XCTAssertTrue(coordinator.activate(request, schedulerFinish: {
            finished.fulfill()
        }))

        wait(for: [callback, finished], timeout: 1)
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    func testProductionTimeoutIsFifteenSeconds() {
        XCTAssertEqual(VCardRequestSingleFlightCoordinator.responseTimeout, 15)
    }

    private func makeCoordinator(
        owner: String = "me@example.com",
        timeout: TimeInterval = 1
    ) -> VCardRequestSingleFlightCoordinator {
        var nextID = 0
        return VCardRequestSingleFlightCoordinator(
            owner: owner,
            timeout: timeout,
            elementIDFactory: {
                defer { nextID += 1 }
                return "vcard-test-\(nextID)"
            }
        )
    }
}

final class VCardRequestRefreshPolicyTests: XCTestCase {
    func testMissingCardRequestsImmediately() {
        XCTAssertTrue(VCardRequestRefreshPolicy.shouldRequest(
            persistedOwner: nil,
            requestOwner: "owner@example.com",
            lastRequestFailed: false,
            lastUpdateDate: .distantPast,
            now: Date(timeIntervalSince1970: 10_000)
        ))
    }

    func testSuccessfulPersistedCardIsANoOp() {
        XCTAssertFalse(VCardRequestRefreshPolicy.shouldRequest(
            persistedOwner: "owner@example.com",
            requestOwner: "owner@example.com",
            lastRequestFailed: false,
            lastUpdateDate: Date(timeIntervalSince1970: 1),
            now: Date(timeIntervalSince1970: 100_000)
        ))
    }

    func testFailedPersistedCardRetriesOnlyAfterBoundedCooldown() {
        let failureDate = Date(timeIntervalSince1970: 10_000)
        let cooldown = VCardRequestRefreshPolicy.failureRetryCooldown

        XCTAssertGreaterThan(cooldown, 0)
        XCTAssertLessThanOrEqual(cooldown, 5 * 60)
        XCTAssertFalse(VCardRequestRefreshPolicy.shouldRequest(
            persistedOwner: "owner@example.com",
            requestOwner: "owner@example.com",
            lastRequestFailed: true,
            lastUpdateDate: failureDate,
            now: failureDate.addingTimeInterval(cooldown - 0.001)
        ))
        XCTAssertTrue(VCardRequestRefreshPolicy.shouldRequest(
            persistedOwner: "owner@example.com",
            requestOwner: "owner@example.com",
            lastRequestFailed: true,
            lastUpdateDate: failureDate,
            now: failureDate.addingTimeInterval(cooldown)
        ))
    }

    func testPersistedCardFromAnotherAccountIsTreatedAsCacheMiss() {
        XCTAssertTrue(VCardRequestRefreshPolicy.shouldRequest(
            persistedOwner: "other-owner@example.com",
            requestOwner: "owner@example.com",
            lastRequestFailed: false,
            lastUpdateDate: Date(),
            now: Date()
        ))
    }
}

final class VCardVisibleRetrySchedulerTests: XCTestCase {
    func testVisibleFailureRetriesAfterCooldownWithoutAnotherVisibilityEvent() {
        let queue = DispatchQueue(label: "vcard-visible-retry-test")
        let scheduler = VCardVisibleRetryScheduler(queue: queue)
        let identity = VCardPresentationIdentity(
            owner: "me@example.com",
            jid: "alice@example.com"
        )!
        let managerEpoch = UUID()
        let retried = expectation(description: "visible vCard retries")
        var observedProof: VCardVisibleRetryProof?

        scheduler.schedule(
            identity: identity,
            proof: VCardVisibleRetryProof(
                managerEpoch: managerEpoch,
                generation: 7
            ),
            deadline: Date().addingTimeInterval(0.02),
            isStillVisible: { true },
            retry: { _, proof in
                observedProof = proof
                retried.fulfill()
            }
        )

        wait(for: [retried], timeout: 1)
        XCTAssertEqual(
            observedProof,
            VCardVisibleRetryProof(managerEpoch: managerEpoch, generation: 7)
        )
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testRetryIsDroppedWhenRowIsNoLongerVisible() {
        let queue = DispatchQueue(label: "vcard-hidden-retry-test")
        let scheduler = VCardVisibleRetryScheduler(queue: queue)
        let identity = VCardPresentationIdentity(
            owner: "me@example.com",
            jid: "alice@example.com"
        )!
        let mustNotRetry = expectation(description: "hidden vCard does not retry")
        mustNotRetry.isInverted = true

        scheduler.schedule(
            identity: identity,
            proof: VCardVisibleRetryProof(
                managerEpoch: UUID(),
                generation: 9
            ),
            deadline: Date().addingTimeInterval(0.01),
            isStillVisible: { false },
            retry: { _, _ in mustNotRetry.fulfill() }
        )

        wait(for: [mustNotRetry], timeout: 0.08)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testDuplicateFailureCoalescesToLatestGeneration() {
        let queue = DispatchQueue(label: "vcard-coalesced-retry-test")
        let scheduler = VCardVisibleRetryScheduler(queue: queue)
        let identity = VCardPresentationIdentity(
            owner: "me@example.com",
            jid: "alice@example.com"
        )!
        let firstManagerEpoch = UUID()
        let latestManagerEpoch = UUID()
        let retried = expectation(description: "one coalesced retry")
        var observedProofs: [VCardVisibleRetryProof] = []

        scheduler.schedule(
            identity: identity,
            proof: VCardVisibleRetryProof(
                managerEpoch: firstManagerEpoch,
                generation: 3
            ),
            deadline: Date().addingTimeInterval(0.05),
            isStillVisible: { true },
            retry: { _, proof in
                observedProofs.append(proof)
                retried.fulfill()
            }
        )
        scheduler.schedule(
            identity: identity,
            proof: VCardVisibleRetryProof(
                managerEpoch: latestManagerEpoch,
                generation: 4
            ),
            deadline: Date().addingTimeInterval(0.01),
            isStillVisible: { true },
            retry: { _, proof in
                observedProofs.append(proof)
                retried.fulfill()
            }
        )

        wait(for: [retried], timeout: 1)
        queue.sync {}
        XCTAssertEqual(
            observedProofs,
            [VCardVisibleRetryProof(
                managerEpoch: latestManagerEpoch,
                generation: 4
            )]
        )
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testRetryGuardRequiresCurrentManagerAuthenticatedStreamAndExactGeneration() {
        let managerEpoch = UUID()
        XCTAssertTrue(VCardVisibleRetryRequestGuard.shouldSubmit(
            expectedManagerEpoch: managerEpoch,
            currentManagerEpoch: managerEpoch,
            expectedGeneration: 11,
            currentGeneration: 11,
            isCurrentAccountManager: true,
            isStreamAuthenticated: true
        ))
        XCTAssertFalse(VCardVisibleRetryRequestGuard.shouldSubmit(
            expectedManagerEpoch: managerEpoch,
            currentManagerEpoch: UUID(),
            expectedGeneration: 11,
            currentGeneration: 11,
            isCurrentAccountManager: true,
            isStreamAuthenticated: true
        ))
        XCTAssertFalse(VCardVisibleRetryRequestGuard.shouldSubmit(
            expectedManagerEpoch: managerEpoch,
            currentManagerEpoch: managerEpoch,
            expectedGeneration: 10,
            currentGeneration: 11,
            isCurrentAccountManager: true,
            isStreamAuthenticated: true
        ))
        XCTAssertFalse(VCardVisibleRetryRequestGuard.shouldSubmit(
            expectedManagerEpoch: managerEpoch,
            currentManagerEpoch: managerEpoch,
            expectedGeneration: 11,
            currentGeneration: 11,
            isCurrentAccountManager: false,
            isStreamAuthenticated: true
        ))
        XCTAssertFalse(VCardVisibleRetryRequestGuard.shouldSubmit(
            expectedManagerEpoch: managerEpoch,
            currentManagerEpoch: managerEpoch,
            expectedGeneration: 11,
            currentGeneration: 11,
            isCurrentAccountManager: true,
            isStreamAuthenticated: false
        ))
    }
}

final class VCardPresentationProjectionStoreTests: XCTestCase {
    func testSameJIDKeepsIndependentTitlesForTwoAccounts() {
        let store = VCardPresentationProjectionStore()

        XCTAssertTrue(store.apply(
            owner: "romeo@example.com",
            jid: "juliet@example.net/mobile",
            title: "Juliet for Romeo"
        ))
        XCTAssertTrue(store.apply(
            owner: "mercutio@example.com",
            jid: "juliet@example.net",
            title: "Juliet for Mercutio"
        ))

        XCTAssertEqual(
            store.title(owner: "romeo@example.com", jid: "juliet@example.net"),
            "Juliet for Romeo"
        )
        XCTAssertEqual(
            store.title(owner: "mercutio@example.com", jid: "juliet@example.net"),
            "Juliet for Mercutio"
        )
    }

    func testRemovingOneAccountDoesNotEraseAnotherAccountsProjection() {
        let store = VCardPresentationProjectionStore()
        store.apply(
            owner: "romeo@example.com",
            jid: "juliet@example.net",
            title: "Juliet A"
        )
        store.apply(
            owner: "mercutio@example.com",
            jid: "juliet@example.net",
            title: "Juliet B"
        )

        store.removeAll(for: "romeo@example.com")

        XCTAssertNil(
            store.title(owner: "romeo@example.com", jid: "juliet@example.net")
        )
        XCTAssertEqual(
            store.title(owner: "mercutio@example.com", jid: "juliet@example.net"),
            "Juliet B"
        )
    }
}

final class VCardPersistenceEventTests: XCTestCase {
    func testSuccessEventCarriesOnlyOwnerAndBareJID() {
        let notificationCenter = NotificationCenter()
        let received = expectation(description: "vCard persistence event")
        var captured: Notification?
        let token = notificationCenter.addObserver(
            forName: VCardManager.didPersistVCardNotification,
            object: nil,
            queue: nil
        ) { notification in
            captured = notification
            received.fulfill()
        }
        defer { notificationCenter.removeObserver(token) }

        VCardManager.emitDidPersistVCard(
            owner: "me@example.com",
            jid: "alice@example.com/phone",
            notificationCenter: notificationCenter
        )

        wait(for: [received], timeout: 1)
        XCTAssertNil(captured?.object)
        XCTAssertEqual(
            captured?.userInfo?[VCardManager.persistedOwnerUserInfoKey] as? String,
            "me@example.com"
        )
        XCTAssertEqual(
            captured?.userInfo?[VCardManager.persistedJIDUserInfoKey] as? String,
            "alice@example.com"
        )
        XCTAssertEqual(captured?.userInfo?.count, 2)
    }

    func testVisibleFailureEventCarriesRequestGenerationAndCooldownOrigin() {
        let notificationCenter = NotificationCenter()
        let received = expectation(description: "visible vCard failure event")
        let failedAt = Date(timeIntervalSince1970: 12_345)
        let managerEpoch = UUID()
        var captured: Notification?
        let token = notificationCenter.addObserver(
            forName: VCardManager.didFailVisibleVCardRequestNotification,
            object: nil,
            queue: nil
        ) { notification in
            captured = notification
            received.fulfill()
        }
        defer { notificationCenter.removeObserver(token) }

        VCardManager.emitDidFailVisibleVCardRequest(
            owner: "me@example.com/ios",
            jid: "alice@example.com/phone",
            managerEpoch: managerEpoch,
            generation: 42,
            failedAt: failedAt,
            notificationCenter: notificationCenter
        )

        wait(for: [received], timeout: 1)
        XCTAssertEqual(
            captured?.userInfo?[VCardManager.failedOwnerUserInfoKey] as? String,
            "me@example.com"
        )
        XCTAssertEqual(
            captured?.userInfo?[VCardManager.failedJIDUserInfoKey] as? String,
            "alice@example.com"
        )
        XCTAssertEqual(
            captured?.userInfo?[VCardManager.failedManagerEpochUserInfoKey] as? UUID,
            managerEpoch
        )
        XCTAssertEqual(
            captured?.userInfo?[VCardManager.failedGenerationUserInfoKey] as? UInt64,
            42
        )
        XCTAssertEqual(
            captured?.userInfo?[VCardManager.failedAtUserInfoKey] as? Date,
            failedAt
        )
    }
}

final class VCardSingleFlightSourceContractTests: XCTestCase {
    func testLegacyLazyReservationRouteIsPhysicallyRemoved() throws {
        let source = try String(
            contentsOf: sourceRoot().appendingPathComponent("xabber/xmpp/vCard/vCardManager.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("VCardLazyLoadScheduleState"))
        XCTAssertFalse(source.contains("continueLazyLoadMissedVCards"))
        XCTAssertTrue(source.contains("account.sendPrimaryStanza("))
    }

    func testLazyAndExplicitRequestsHaveDifferentSchedulerPriorities() throws {
        let source = try String(
            contentsOf: sourceRoot().appendingPathComponent("xabber/xmpp/vCard/vCardManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("scheduleRequest(jid: jid, priority: .background"))
        XCTAssertTrue(source.contains("scheduleRequest(jid: jid, priority: .foreground"))
    }

    func testVisibleChatRowsSubmitForegroundVCardDemandAndPreserveSkeletonAnimation() throws {
        let root = sourceRoot()
        let datasource = try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/last_chats_list/LastChatsViewController+UITableViewDatasource.swift"
            ),
            encoding: .utf8
        )
        let manager = try String(
            contentsOf: root.appendingPathComponent("xabber/xmpp/vCard/vCardManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(datasource.contains("requestVisibleVCard"))
        XCTAssertTrue(datasource.contains("(cell as? SkeletonCell)?.animate()"))
        XCTAssertTrue(manager.contains("scheduleRequest(jid: jid, priority: .foreground"))
    }

    func testVisibleVCardFailureHasAutomaticCooldownRetryWithoutScrollCallback() throws {
        let controller = try String(
            contentsOf: sourceRoot().appendingPathComponent(
                "xabber/controllers/chats/last_chats_list/LastChatsViewController.swift"
            ),
            encoding: .utf8
        )
        let manager = try String(
            contentsOf: sourceRoot().appendingPathComponent(
                "xabber/xmpp/vCard/vCardManager.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(controller.contains("didFailVisibleVCardRequestNotification"))
        XCTAssertTrue(controller.contains("visibleVCardRetryScheduler.schedule"))
        XCTAssertTrue(controller.contains("retryVisibleIfNeeded"))
        XCTAssertTrue(manager.contains("expectedGeneration"))
        XCTAssertTrue(manager.contains("VCardVisibleRetryRequestGuard.shouldSubmit"))
    }

    func testSuccessNotificationIsEmittedOnlyFromSuccessfulPersistencePath() throws {
        let source = try String(
            contentsOf: sourceRoot().appendingPathComponent("xabber/xmpp/vCard/vCardManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("emitDidPersistVCard("))
        XCTAssertTrue(source.contains("guard didPersist else"))
        XCTAssertFalse(source.contains("persistVCardFailure(for: requestJID)\n            VCardManager.emitDidPersistVCard"))
    }

    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
