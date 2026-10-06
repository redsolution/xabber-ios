import Foundation
import SignalProtocolObjC
import XMPPFramework
import XCTest
@testable import xabber

/// N06 protects the lifetime of consumed private OPKs across the actual
/// archive execution boundary, query persistence terminals and receive ingress.
final class OMEMO2NormativePreKeyCleanupTests: XCTestCase {
    private final class Keys {
        var consumed: Set<UInt32> = []
        var reads = 0
        var removed: [Set<UInt32>] = []
        var failRemoval = false
        var onRemoval: (() -> Void)?
        func coordinator() -> OMEMO2PreKeyCleanupCoordinator {
            OMEMO2PreKeyCleanupCoordinator(
                consumedIDs: { self.reads += 1; return self.consumed },
                removeConsumed: { ids in
                    if self.failRemoval { throw OMEMO2StorageError.persistenceFailed }
                    self.removed.append(ids)
                    self.consumed.subtract(ids)
                    self.onRemoval?()
                }
            )
        }
    }

    func testLogicalCatchUpKeepsConsumedKeysBetweenPagesUntilTheFinalChainTerminal() {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let chain = UUID()
        cleanup.beginCatchUp(id: chain)
        let firstQuery = cleanup.beginQuery(id: "page-1")
        keys.consumed = [1]
        cleanup.authenticatedReceiveDidCommit()

        cleanup.finishQuery(id: "page-1", token: firstQuery)
        XCTAssertEqual(keys.consumed, [1], "A raw page terminal is not the logical catch-up terminal")
        cleanup.retryEligibleCleanup()
        XCTAssertEqual(keys.consumed, [1], "The continuation gap must retain the same catch-up lease")
        let secondQuery = cleanup.beginQuery(id: "page-2")
        keys.consumed.insert(2)
        cleanup.authenticatedReceiveDidCommit()
        cleanup.finishQuery(id: "page-2", token: secondQuery)
        cleanup.finishCatchUp(id: chain)

        XCTAssertTrue(keys.consumed.isEmpty)
        XCTAssertEqual(keys.removed, [[1, 2]])
    }

    func testParallelCatchUpsRetainKeysUntilEveryOwnerChainHasFinished() {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let first = UUID(), second = UUID()
        cleanup.beginCatchUp(id: first)
        cleanup.beginCatchUp(id: second)
        keys.consumed = [3]
        cleanup.authenticatedReceiveDidCommit()

        cleanup.finishCatchUp(id: first)
        XCTAssertEqual(keys.consumed, [3])
        cleanup.finishCatchUp(id: first)
        XCTAssertEqual(keys.consumed, [3], "Duplicate completion cannot close another chain")
        cleanup.finishCatchUp(id: second)

        XCTAssertTrue(keys.consumed.isEmpty)
    }

    func testCancelledChainWaitsForItsQueryPersistenceTerminal() {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let chain = UUID()
        cleanup.beginCatchUp(id: chain)
        let query = cleanup.beginQuery(id: "cancelled-page")
        keys.consumed = [4]
        cleanup.authenticatedReceiveDidCommit()

        cleanup.finishCatchUp(id: chain)
        XCTAssertEqual(keys.consumed, [4])
        cleanup.finishQuery(id: "cancelled-page", token: query)

        XCTAssertTrue(keys.consumed.isEmpty)
    }

    func testQueryTerminalWaitsUntilDeferredReceiveAccountingHasFinished() {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let query = cleanup.beginQuery(id: "page")
        let ingress = cleanup.beginIngress()
        keys.consumed = [5]
        cleanup.authenticatedReceiveDidCommit()

        cleanup.finishQuery(id: "page", token: query)
        XCTAssertEqual(keys.consumed, [5], "Decrypt must remain protected until route/control accounting finishes")
        cleanup.finishIngress(id: ingress)

        XCTAssertTrue(keys.consumed.isEmpty)
    }

    func testAuthenticatedNonArchiveReceiveDeletesConsumedKeysAtItsIngressTerminal() {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let ingress = cleanup.beginIngress()
        keys.consumed = [6]

        cleanup.authenticatedReceiveDidCommit()
        XCTAssertEqual(keys.consumed, [6])
        cleanup.finishIngress(id: ingress)

        XCTAssertTrue(keys.consumed.isEmpty)
    }

    func testFailedProtectedRemovalKeepsEligibilityForAnExistingMaintenanceRetry() {
        let keys = Keys()
        let cleanup = keys.coordinator()
        keys.consumed = [7]
        keys.failRemoval = true

        cleanup.authenticatedReceiveDidCommit()
        XCTAssertEqual(keys.consumed, [7])
        XCTAssertTrue(keys.removed.isEmpty)
        keys.failRemoval = false
        cleanup.retryEligibleCleanup()

        XCTAssertTrue(keys.consumed.isEmpty)
        XCTAssertEqual(keys.removed, [[7]])
    }

    func testNewCatchUpAdoptsPersistedConsumedKeysWithoutDeletingThemAtRegistration() {
        let keys = Keys()
        keys.consumed = [8]
        let restarted = keys.coordinator()
        let chain = UUID()

        restarted.beginCatchUp(id: chain)
        let query = restarted.beginQuery(id: "startup")
        restarted.retryEligibleCleanup()
        XCTAssertEqual(keys.consumed, [8])
        restarted.finishQuery(id: "startup", token: query)
        XCTAssertEqual(keys.consumed, [8])
        restarted.finishCatchUp(id: chain)

        XCTAssertTrue(keys.consumed.isEmpty)
    }

    func testUnclaimedConsumedKeysAfterRestartHaveAFiniteIdleMaintenanceBoundary() {
        let keys = Keys()
        keys.consumed = [9]
        let restarted = keys.coordinator()

        restarted.retryEligibleCleanup()

        XCTAssertTrue(keys.consumed.isEmpty, "An absent hypothetical archive query cannot retain a private OPK forever")
    }

    func testPlaintextOrFailedIngressDoesNotAdoptUnclaimedPrivateKeysAfterRestart() {
        let keys = Keys()
        keys.consumed = [21]
        let restarted = keys.coordinator()

        for _ in 0..<3 {
            let ingress = restarted.beginIngress()
            restarted.finishIngress(id: ingress)
        }

        XCTAssertEqual(keys.consumed, [21])
        XCTAssertEqual(keys.reads, 0, "An unverified ingress must not introduce protected-state reads or eligibility")
        XCTAssertTrue(keys.removed.isEmpty)
        restarted.retryEligibleCleanup()
        XCTAssertTrue(keys.consumed.isEmpty, "The authenticated maintenance boundary still has finite cleanup")
    }

    func testStalePersistenceTerminalCannotReleaseANewRegistrationWithTheSameQueryID() {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let old = cleanup.beginQuery(id: "legacy-page")
        let new = cleanup.beginQuery(id: "legacy-page")
        keys.consumed = [13]
        cleanup.authenticatedReceiveDidCommit()

        cleanup.finishQuery(id: "legacy-page", token: old)
        cleanup.finishQuery(id: "legacy-page", token: old)
        XCTAssertEqual(keys.consumed, [13], "The next page owns a distinct registration even when the XML query ID is reused")
        cleanup.finishQuery(id: "another-query", token: new)
        XCTAssertEqual(keys.consumed, [13], "A mismatched query identity cannot retire the lease")
        cleanup.finishQuery(id: "legacy-page", token: new)

        XCTAssertTrue(keys.consumed.isEmpty)
    }

    func testIndependentAccountCoordinatorCannotReleaseAnotherOwnersKeys() {
        let firstKeys = Keys(), secondKeys = Keys()
        let first = firstKeys.coordinator(), second = secondKeys.coordinator()
        let chain = UUID()
        first.beginCatchUp(id: chain)
        firstKeys.consumed = [10]
        secondKeys.consumed = [11]
        first.authenticatedReceiveDidCommit()

        second.authenticatedReceiveDidCommit()
        XCTAssertTrue(secondKeys.consumed.isEmpty)
        XCTAssertEqual(firstKeys.consumed, [10])
        second.finishCatchUp(id: chain)
        XCTAssertEqual(firstKeys.consumed, [10])
        first.finishCatchUp(id: chain)

        XCTAssertTrue(firstKeys.consumed.isEmpty)
    }

    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var failWrites = false
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws {
            if failWrites { throw OMEMO2StorageError.persistenceFailed }
            records[owner] = data
        }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }

    private struct Fixture {
        let alice: XabberOMEMO2Storage
        let bob: XabberOMEMO2Storage
        let memory: Memory
        let chosen: OMEMO2Bundle
        let preKeyID: UInt32
        func cleanup(storage: XabberOMEMO2Storage? = nil) -> OMEMO2PreKeyCleanupCoordinator {
            let store = storage ?? bob
            return OMEMO2PreKeyCleanupCoordinator(
                consumedIDs: { try store.consumedPreKeyIDs() },
                removeConsumed: { try store.removeConsumedPreKeys(ids: $0) }
            )
        }
    }

    func testFiniteCleanupPreservesKnownEKAndRejectsNewEKUsingDeletedPrivateOPK() throws {
        let f = try fixture()
        let cleanup = f.cleanup()
        let chain = UUID()
        cleanup.beginCatchUp(id: chain)
        let query = cleanup.beginQuery(id: "first-page")
        let first = try f.alice.encrypt(Data(repeating: 1, count: 48), jid: f.bob.owner, deviceID: 2)
        let delayedKnownEK = try f.alice.encrypt(Data(repeating: 2, count: 48), jid: f.bob.owner, deviceID: 2)
        XCTAssertEqual(try f.bob.decrypt(first, jid: f.alice.owner, deviceID: 1), Data(repeating: 1, count: 48))
        cleanup.authenticatedReceiveDidCommit()
        XCTAssertEqual(try f.bob.consumedPreKeyIDs(), [f.preKeyID])
        cleanup.finishQuery(id: "first-page", token: query)
        XCTAssertEqual(try f.bob.consumedPreKeyIDs(), [f.preKeyID])

        cleanup.finishCatchUp(id: chain)

        XCTAssertTrue(try f.bob.consumedPreKeyIDs().isEmpty)
        XCTAssertEqual(try f.bob.localBundle().preKeys.count, 2)
        XCTAssertEqual(try f.bob.decrypt(delayedKnownEK, jid: f.alice.owner, deviceID: 1), Data(repeating: 2, count: 48))
        try f.alice.initiateSession(jid: f.bob.owner, deviceID: 2, bundle: f.chosen)
        let freshUnknownEK = try f.alice.encrypt(Data(repeating: 3, count: 48), jid: f.bob.owner, deviceID: 2)
        XCTAssertThrowsError(try f.bob.decrypt(freshUnknownEK, jid: f.alice.owner, deviceID: 1))
    }

    func testSelectiveCleanupNeverDeletesAnUnconsumedPrivatePreKey() throws {
        let f = try fixture()
        let all = Set(try f.bob.localBundle().preKeys.map(\.id))
        let first = try f.alice.encrypt(Data(repeating: 4, count: 48), jid: f.bob.owner, deviceID: 2)
        _ = try f.bob.decrypt(first, jid: f.alice.owner, deviceID: 1)

        try f.bob.removeConsumedPreKeys(ids: all)

        XCTAssertTrue(try f.bob.consumedPreKeyIDs().isEmpty)
        XCTAssertEqual(Set(try f.bob.localBundle().preKeys.map(\.id)), all.subtracting([f.preKeyID]))
    }

    func testCleanupProtectedSaveFailurePreservesKnownSessionAndRetriesWithoutRatcheting() throws {
        let f = try fixture()
        let first = try f.alice.encrypt(Data(repeating: 5, count: 48), jid: f.bob.owner, deviceID: 2)
        _ = try f.bob.decrypt(first, jid: f.alice.owner, deviceID: 1)
        let cleanup = f.cleanup()
        let before = f.memory.records[f.bob.owner]
        let metadata = try XCTUnwrap(f.bob.sessionMetadata(jid: f.alice.owner, deviceID: 1))
        f.memory.failWrites = true

        cleanup.authenticatedReceiveDidCommit()

        XCTAssertEqual(f.memory.records[f.bob.owner], before)
        XCTAssertEqual(try f.bob.consumedPreKeyIDs(), [f.preKeyID])
        f.memory.failWrites = false
        cleanup.retryEligibleCleanup()
        XCTAssertTrue(try f.bob.consumedPreKeyIDs().isEmpty)
        let after = try XCTUnwrap(f.bob.sessionMetadata(jid: f.alice.owner, deviceID: 1))
        XCTAssertEqual(after.ephemeralKey, metadata.ephemeralKey)
        XCTAssertEqual(after.receiveCounter, metadata.receiveCounter)
        XCTAssertEqual(after.sendCounter, metadata.sendCounter)
    }

    func testRestartAdoptsActualPersistedConsumedKeysWhileCatchUpIsRegistered() throws {
        let f = try fixture()
        let first = try f.alice.encrypt(Data(repeating: 6, count: 48), jid: f.bob.owner, deviceID: 2)
        _ = try f.bob.decrypt(first, jid: f.alice.owner, deviceID: 1)
        let restarted = try XabberOMEMO2Storage(owner: f.bob.owner, persistence: f.memory)
        let cleanup = f.cleanup(storage: restarted)
        let chain = UUID()

        cleanup.beginCatchUp(id: chain)
        cleanup.retryEligibleCleanup()
        XCTAssertEqual(try restarted.consumedPreKeyIDs(), [f.preKeyID])
        cleanup.finishCatchUp(id: chain)

        XCTAssertTrue(try restarted.consumedPreKeyIDs().isEmpty)
        XCTAssertTrue(try restarted.sessionExists(jid: f.alice.owner, deviceID: 1))
        XCTAssertEqual(try restarted.pendingControlAddresses(), [OMEMO2PeerAddress(jid: f.alice.owner, deviceID: 1)])
    }

    func testRejectedPayloadDoesNotConsumeAnOPKOrCreateCleanupEligibility() throws {
        let f = try fixture()
        let first = try f.alice.encrypt(Data(repeating: 7, count: 48), jid: f.bob.owner, deviceID: 2)
        let before = f.memory.records[f.bob.owner]

        XCTAssertThrowsError(try f.bob.decrypt(first, jid: f.alice.owner, deviceID: 1, validating: { _ in
            throw OMEMO2StorageError.persistenceFailed
        }))
        f.cleanup().retryEligibleCleanup()

        XCTAssertEqual(f.memory.records[f.bob.owner], before)
        XCTAssertTrue(try f.bob.consumedPreKeyIDs().isEmpty)
        XCTAssertFalse(try f.bob.sessionExists(jid: f.alice.owner, deviceID: 1))
        XCTAssertEqual(try f.bob.localBundle().preKeys.count, 3)
    }

    func testDeletedOPKDoesNotRemoveTheDurableEmptyReplyRequirement() throws {
        let f = try fixture()
        let first = try f.alice.encrypt(Data(repeating: 8, count: 48), jid: f.bob.owner, deviceID: 2)
        _ = try f.bob.decrypt(first, jid: f.alice.owner, deviceID: 1)

        f.cleanup().authenticatedReceiveDidCommit()

        XCTAssertEqual(try f.bob.pendingControlAddresses(), [OMEMO2PeerAddress(jid: f.alice.owner, deviceID: 1)])
        let reply = try f.bob.encrypt(Data(repeating: 0, count: 32), jid: f.alice.owner, deviceID: 1)
        XCTAssertEqual(try f.alice.decrypt(reply, jid: f.bob.owner, deviceID: 2), Data(repeating: 0, count: 32))
        XCTAssertTrue(try f.bob.pendingControlAddresses().isEmpty)
    }

    func testActualArchiveExecutionRetainsEligibilityUntilRepositoryCommitAndLogicalFinish() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let transport = PausedTransport(cleanup: cleanup, keys: keys)
        let engine = AccountArchiveEngine(owner: "bob@example.test", repository: EmptyRepository(),
            transport: transport, admissionProvider: Admission(), preKeyCleanup: cleanup, retryClock: .immediate)
        let conversation = ArchiveConversationKey(owner: "bob@example.test", jid: "alice@example.test", conversationType: .regular)
        await engine.connectionDidBecomeReady(generation: 1)
        await engine.attachPresentationDemand(for: conversation, demandID: UUID())
        await engine.submit(ArchiveWindowIntent(conversation: conversation, locator: .latest,
            contextBefore: 20, contextAfter: 0, priority: .visibleIntegrity))
        let started = await waitForRequest(transport)
        XCTAssertTrue(started)
        XCTAssertEqual(keys.consumed, [12], "The production engine execution must own the catch-up hold")

        await transport.complete()
        await engine.waitUntilIdleForTesting()

        XCTAssertTrue(keys.consumed.isEmpty)
        guard case .authoritativeEmpty = await engine.currentState(for: conversation) else {
            return XCTFail("Expected the repository commit to complete the execution")
        }
    }

    func testEngineDisconnectReleasesChainButOutstandingQueryKeepsKeysUntilPersistenceTerminal() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let transport = PausedTransport(cleanup: cleanup, keys: keys)
        let engine = AccountArchiveEngine(owner: "bob@example.test", repository: EmptyRepository(),
            transport: transport, admissionProvider: Admission(), preKeyCleanup: cleanup, retryClock: .immediate)
        let conversation = ArchiveConversationKey(owner: "bob@example.test", jid: "alice@example.test", conversationType: .regular)
        await engine.connectionDidBecomeReady(generation: 1)
        await engine.attachPresentationDemand(for: conversation, demandID: UUID())
        await engine.submit(ArchiveWindowIntent(conversation: conversation, locator: .latest,
            contextBefore: 20, contextAfter: 0, priority: .visibleIntegrity))
        let started = await waitForRequest(transport)
        XCTAssertTrue(started)

        await engine.connectionDidDisconnect()
        XCTAssertEqual(keys.consumed, [12], "The pending child-query lease survives engine cancellation")
        await transport.complete()

        XCTAssertTrue(keys.consumed.isEmpty, "The bounded child persistence terminal closes the cancelled execution")
    }

    func testActualEngineConsumedOnlyContinuationKeepsTheSameLifetimeAcrossTwoPages() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let transport = PausedTransport(cleanup: cleanup, keys: keys)
        let engine = AccountArchiveEngine(owner: "bob@example.test", repository: EmptyRepository(consumedPages: true),
            transport: transport, admissionProvider: Admission(), preKeyCleanup: cleanup, retryClock: .immediate)
        let conversation = ArchiveConversationKey(owner: "bob@example.test", jid: "alice@example.test", conversationType: .regular)
        await engine.connectionDidBecomeReady(generation: 1)
        await engine.attachPresentationDemand(for: conversation, demandID: UUID())
        await engine.submit(ArchiveWindowIntent(conversation: conversation, locator: .latest,
            contextBefore: 20, contextAfter: 0, priority: .target))
        let firstStarted = await waitForRequest(transport)
        XCTAssertTrue(firstStarted)

        await transport.complete(consumedArchiveID: "200", complete: false)
        let secondStarted = await waitForRequest(transport, minimum: 2)

        let stateAfterFirstPage = await engine.currentState(for: conversation)
        XCTAssertTrue(secondStarted, "Consumed-only continuation state: \(String(describing: stateAfterFirstPage))")
        guard secondStarted else { await engine.connectionDidDisconnect(); return }
        XCTAssertEqual(keys.consumed, [12], "The first page cannot delete the OPK needed by the continuation")
        XCTAssertTrue(keys.removed.isEmpty)
        await transport.complete(consumedArchiveID: "100", complete: true)
        await engine.waitUntilIdleForTesting()
        XCTAssertTrue(keys.consumed.isEmpty)
    }

    func testStandaloneMAMRegistrationHoldsKeysUntilRawFinAndPersistenceTerminal() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let mam = MessageArchiveManager(withOwner: "cleanup-\(UUID())@example.test")
        let messages = MessageManager(withOwner: mam.owner, activeStream: false)
        messages.unsubscribeReceiver()
        mam.omemo2PreKeyCleanup = cleanup
        mam.omemo2CleanupMessages = messages
        let stream = RecordingStream()
        mam.requestArchive(stream, jid: "alice@example.test", isContinues: false,
            conversationType: .regular, purpose: .latest, queryId: "standalone")
        keys.consumed = [14]
        cleanup.authenticatedReceiveDidCommit()
        XCTAssertEqual(keys.consumed, [14], "Production request registration owns a query lease before send")
        let removed = expectation(description: "standalone query bounded terminal")
        keys.onRemoval = { removed.fulfill() }

        XCTAssertTrue(mam.read(stream, withIQ: try mamFinal(owner: mam.owner, queryID: "standalone", count: 0)))
        await fulfillment(of: [removed], timeout: 2)

        XCTAssertTrue(keys.consumed.isEmpty)
        XCTAssertEqual(stream.elements.count, 1)
    }

    func testMAMRawFinCannotDeleteKeysWhileTheStreamReceiveDeferStillOwnsIngress() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let mam = MessageArchiveManager(withOwner: "cleanup-\(UUID())@example.test")
        let messages = MessageManager(withOwner: mam.owner, activeStream: false)
        messages.unsubscribeReceiver()
        mam.omemo2PreKeyCleanup = cleanup
        mam.omemo2CleanupMessages = messages
        let stream = RecordingStream()
        mam.requestArchive(stream, jid: "alice@example.test", isContinues: false,
            conversationType: .regular, purpose: .latest, queryId: "ingress")
        let ingress = cleanup.beginIngress()
        keys.consumed = [15]
        cleanup.authenticatedReceiveDidCommit()

        XCTAssertTrue(mam.read(stream, withIQ: try mamFinal(owner: mam.owner, queryID: "ingress", count: 0)))
        let persisted = expectation(description: "existing batch terminal observer")
        messages.finishArchiveQueryBatchAsync(queryId: "ingress") { _ in persisted.fulfill() }
        await fulfillment(of: [persisted], timeout: 2)
        XCTAssertEqual(keys.consumed, [15])
        cleanup.finishIngress(id: ingress)

        XCTAssertTrue(keys.consumed.isEmpty)
    }

    func testControlAccountingAfterRawFinUpdatesSealedProofAndAllowsFiniteCleanup() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let mam = MessageArchiveManager(withOwner: "cleanup-\(UUID())@example.test")
        let messages = MessageManager(withOwner: mam.owner, activeStream: false)
        messages.unsubscribeReceiver()
        mam.omemo2PreKeyCleanup = cleanup
        mam.omemo2CleanupMessages = messages
        let stream = RecordingStream()
        mam.requestArchive(stream, jid: "alice@example.test", isContinues: false,
            conversationType: .regular, purpose: .latest, queryId: "control")
        let control = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(mam.owner)' to='\(mam.owner)'><result xmlns='urn:xmpp:mam:2' queryid='control' id='100'><forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' from='alice@example.test' to='\(mam.owner)'/></forwarded></result></message>")
        XCTAssertTrue(mam.recordDeferredArchiveResultDelivery(control))
        let ingress = cleanup.beginIngress()
        keys.consumed = [16]
        cleanup.authenticatedReceiveDidCommit()
        let removed = expectation(description: "late control accounting releases query")
        keys.onRemoval = { removed.fulfill() }

        XCTAssertTrue(mam.read(stream, withIQ: try mamFinal(owner: mam.owner, queryID: "control", count: 1)))
        XCTAssertEqual(keys.consumed, [16])
        XCTAssertTrue(mam.recordDeferredArchiveControlConsumption(control), "The delegate defer may run after fin sealed the transport proof")
        cleanup.finishIngress(id: ingress)
        await fulfillment(of: [removed], timeout: 2)

        XCTAssertTrue(keys.consumed.isEmpty)
    }

    func testConnectedStandaloneQueryWithoutAnyServerTerminalHasBoundedCleanup() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let mam = MessageArchiveManager(withOwner: "cleanup-\(UUID())@example.test")
        let messages = MessageManager(withOwner: mam.owner, activeStream: false)
        messages.unsubscribeReceiver()
        mam.omemo2PreKeyCleanup = cleanup
        mam.omemo2CleanupMessages = messages
        mam.omemo2CleanupTimeoutPolicy = .init(request: 0.05, persistence: 0.05)
        let stream = RecordingStream()
        let removed = expectation(description: "connected unanswered request retires")
        keys.onRemoval = { removed.fulfill() }
        mam.requestArchive(stream, jid: "alice@example.test", isContinues: true,
            conversationType: .regular, purpose: .latest, queryId: "unanswered")
        keys.consumed = [17]
        cleanup.authenticatedReceiveDidCommit()
        XCTAssertEqual(keys.consumed, [17])

        await fulfillment(of: [removed], timeout: 2)

        XCTAssertTrue(keys.consumed.isEmpty)
        XCTAssertTrue(mam.pendingArchiveRequestQueryIds().isEmpty)
        XCTAssertEqual(stream.elements.count, 1)
    }

    func testStandaloneFinWithMissingExpectedIngressHasABoundedPersistenceTerminal() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let mam = MessageArchiveManager(withOwner: "cleanup-\(UUID())@example.test")
        let messages = MessageManager(withOwner: mam.owner, activeStream: false)
        messages.unsubscribeReceiver()
        mam.omemo2PreKeyCleanup = cleanup
        mam.omemo2CleanupMessages = messages
        mam.omemo2CleanupTimeoutPolicy = .init(request: 1, persistence: 0.05)
        let stream = RecordingStream()
        mam.requestArchive(stream, jid: "alice@example.test", isContinues: false,
            conversationType: .regular, purpose: .latest, queryId: "missing-ingress")
        let result = try XMPPMessage(xmlString: "<message xmlns='jabber:client'><result xmlns='urn:xmpp:mam:2' queryid='missing-ingress' id='100'/></message>")
        XCTAssertTrue(mam.recordDeferredArchiveResultDelivery(result))
        keys.consumed = [18]
        cleanup.authenticatedReceiveDidCommit()
        let removed = expectation(description: "missing ingress reaches persistence timeout")
        keys.onRemoval = { removed.fulfill() }

        XCTAssertTrue(mam.read(stream, withIQ: try mamFinal(owner: mam.owner, queryID: "missing-ingress", count: 1)))
        await fulfillment(of: [removed], timeout: 2)

        XCTAssertTrue(keys.consumed.isEmpty)
    }

    func testLegacyContinuationSurvivesAnUnrelatedQueryRegistrationDuringThePageGap() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let mam = MessageArchiveManager(withOwner: "cleanup-\(UUID())@example.test")
        let messages = MessageManager(withOwner: mam.owner, activeStream: false)
        messages.unsubscribeReceiver()
        mam.omemo2PreKeyCleanup = cleanup
        mam.omemo2CleanupMessages = messages
        let stream = RecordingStream()
        let completed = expectation(description: "overall legacy callback waits for the final page")
        var callbackCount = 0
        mam.requestArchive(stream, jid: "alice@example.test", isContinues: true,
            conversationType: .regular, purpose: .latest, queryId: "legacy", callback: {
                callbackCount += 1
                completed.fulfill()
            })
        let result = try XMPPMessage(xmlString: "<message xmlns='jabber:client'><result xmlns='urn:xmpp:mam:2' queryid='legacy' id='100'/></message>")
        XCTAssertTrue(mam.recordDeferredArchiveResultDelivery(result))
        XCTAssertTrue(mam.recordDeferredArchiveControlConsumption(result))
        keys.consumed = [19]
        cleanup.authenticatedReceiveDidCommit()
        XCTAssertTrue(mam.read(stream, withIQ: try mamFinal(owner: mam.owner, queryID: "legacy", count: 1, complete: false)))
        let continued = expectation(description: "legacy second page survives unrelated query")
        stream.onSend = { element in if element.attributeStringValue(forName: "id") == "legacy" { continued.fulfill() } }

        mam.requestArchive(stream, jid: "carol@example.test", isContinues: false,
            conversationType: .regular, purpose: .latest, queryId: "parallel")
        XCTAssertTrue(mam.read(stream, withIQ: try mamFinal(owner: mam.owner, queryID: "parallel", count: 0)))
        await fulfillment(of: [continued], timeout: 3)

        XCTAssertEqual(keys.consumed, [19])
        XCTAssertEqual(callbackCount, 0, "A nonfinal page cannot invoke the overall request callback")
        let removed = expectation(description: "legacy final page ends the same chain")
        keys.onRemoval = { removed.fulfill() }
        XCTAssertTrue(mam.read(stream, withIQ: try mamFinal(owner: mam.owner, queryID: "legacy", count: 0)))
        await fulfillment(of: [removed, completed], timeout: 2)
        XCTAssertTrue(keys.consumed.isEmpty)
        XCTAssertEqual(callbackCount, 1)
    }

    func testLegacyResetDuringThePageGapClosesTheChainAndCannotReopenItLater() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let mam = MessageArchiveManager(withOwner: "cleanup-\(UUID())@example.test")
        let messages = MessageManager(withOwner: mam.owner, activeStream: false)
        messages.unsubscribeReceiver()
        mam.omemo2PreKeyCleanup = cleanup
        mam.omemo2CleanupMessages = messages
        let stream = RecordingStream()
        let completed = expectation(description: "reset completes the legacy caller once")
        var callbackCount = 0
        mam.requestArchive(stream, jid: "alice@example.test", isContinues: true,
            conversationType: .regular, purpose: .latest, queryId: "abandoned", callback: {
                callbackCount += 1
                completed.fulfill()
            })
        let result = try XMPPMessage(xmlString: "<message xmlns='jabber:client'><result xmlns='urn:xmpp:mam:2' queryid='abandoned' id='100'/></message>")
        XCTAssertTrue(mam.recordDeferredArchiveResultDelivery(result))
        XCTAssertTrue(mam.recordDeferredArchiveControlConsumption(result))
        keys.consumed = [20]
        cleanup.authenticatedReceiveDidCommit()
        XCTAssertTrue(mam.read(stream, withIQ: try mamFinal(owner: mam.owner, queryID: "abandoned", count: 1, complete: false)))
        let removed = expectation(description: "abandoned continuation is finite")
        keys.onRemoval = { removed.fulfill() }
        let noNextPage = expectation(description: "abandoned next page must not reopen")
        noNextPage.isInverted = true
        stream.onSend = { _ in noNextPage.fulfill() }

        mam.didResetState()
        await fulfillment(of: [removed, noNextPage, completed], timeout: 2.2)

        XCTAssertTrue(keys.consumed.isEmpty)
        XCTAssertEqual(stream.elements.count, 1)
        XCTAssertEqual(callbackCount, 1)
    }

    func testCleanupLeaseRegistryRetirementNeverBlocksThePersistenceQueue() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let messages = MessageManager(withOwner: "cleanup-\(UUID())@example.test", activeStream: false)
        messages.unsubscribeReceiver()
        let retirementStarted = expectation(description: "registry retirement reached its owner")
        let queueReturned = expectation(description: "message queue is free for overlapping registration")
        let releaseRetirement = DispatchSemaphore(value: 0)
        defer { releaseRetirement.signal() }
        let lease = OMEMO2CleanupQueryLease(id: "old-page", chainID: nil, cleanup: cleanup,
            messages: messages, policy: .production) { _, _, _ in
                retirementStarted.fulfill()
                _ = releaseRetirement.wait(timeout: .now() + 3)
            }

        messages.queue.async {
            lease.finish()
            queueReturned.fulfill()
        }
        await fulfillment(of: [retirementStarted, queueReturned], timeout: 1)

        // The retirement callback deliberately waits for an owner-side lock;
        // another query can still synchronize this actual message queue.
        XCTAssertEqual(messages.performMessageQueueSync { 42 }, 42)
    }

    func testLegacyNextPageWaitsForThePredecessorPersistenceTerminalBeforeThePageGap() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let mam = MessageArchiveManager(withOwner: "cleanup-\(UUID())@example.test")
        let messages = MessageManager(withOwner: mam.owner, activeStream: false)
        messages.unsubscribeReceiver()
        mam.omemo2PreKeyCleanup = cleanup
        mam.omemo2CleanupMessages = messages
        let stream = RecordingStream()
        mam.requestArchive(stream, jid: "alice@example.test", isContinues: true,
            conversationType: .regular, purpose: .latest, queryId: "slow-page")
        let result = try XMPPMessage(xmlString: "<message xmlns='jabber:client'><result xmlns='urn:xmpp:mam:2' queryid='slow-page' id='100'/></message>")
        XCTAssertTrue(mam.recordDeferredArchiveResultDelivery(result))
        keys.consumed = [22]
        cleanup.authenticatedReceiveDidCommit()
        XCTAssertTrue(mam.read(stream, withIQ: try mamFinal(owner: mam.owner, queryID: "slow-page", count: 1, complete: false)))
        let noEarlyPage = expectation(description: "raw fin cannot reuse a query while persistence is pending")
        noEarlyPage.isInverted = true
        stream.onSend = { _ in noEarlyPage.fulfill() }

        await fulfillment(of: [noEarlyPage], timeout: 2.2)
        XCTAssertEqual(keys.consumed, [22])
        let continued = expectation(description: "late accounting closes predecessor then starts page gap")
        stream.onSend = { _ in continued.fulfill() }
        XCTAssertTrue(mam.recordDeferredArchiveControlConsumption(result))
        await fulfillment(of: [continued], timeout: 3)

        XCTAssertEqual(stream.elements.count, 2)
        let removed = expectation(description: "second page closes logical catch-up")
        keys.onRemoval = { removed.fulfill() }
        XCTAssertTrue(mam.read(stream, withIQ: try mamFinal(owner: mam.owner, queryID: "slow-page", count: 0)))
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertTrue(keys.consumed.isEmpty)
    }

    func testLegacyNonfinalPersistenceTimeoutCompletesTheOverallRequestOnceWithoutANextPage() async throws {
        let keys = Keys()
        let cleanup = keys.coordinator()
        let mam = MessageArchiveManager(withOwner: "cleanup-\(UUID())@example.test")
        let messages = MessageManager(withOwner: mam.owner, activeStream: false)
        messages.unsubscribeReceiver()
        mam.omemo2PreKeyCleanup = cleanup
        mam.omemo2CleanupMessages = messages
        mam.omemo2CleanupTimeoutPolicy = .init(request: 5, persistence: 0.05)
        let stream = RecordingStream()
        let completed = expectation(description: "nonfinal persistence timeout completes the legacy caller")
        let failed = expectation(description: "nonfinal persistence timeout reports one failure")
        var callbackCount = 0
        var failureCount = 0
        mam.requestArchive(stream, jid: "alice@example.test", isContinues: true,
            conversationType: .regular, purpose: .latest, queryId: "timed-out-page", callback: {
                callbackCount += 1
                completed.fulfill()
            }, requestCallbacks: .init(onFailure: { event in
                XCTAssertEqual(event.reason, .timeout)
                failureCount += 1
                failed.fulfill()
            }))
        let result = try XMPPMessage(xmlString: "<message xmlns='jabber:client'><result xmlns='urn:xmpp:mam:2' queryid='timed-out-page' id='100'/></message>")
        XCTAssertTrue(mam.recordDeferredArchiveResultDelivery(result))
        keys.consumed = [23]
        cleanup.authenticatedReceiveDidCommit()
        let removed = expectation(description: "timed-out legacy chain releases consumed keys")
        keys.onRemoval = { removed.fulfill() }
        XCTAssertTrue(mam.read(stream, withIQ: try mamFinal(owner: mam.owner, queryID: "timed-out-page", count: 1, complete: false)))
        XCTAssertEqual(callbackCount, 0)
        let noNextPage = expectation(description: "timed-out nonfinal page cannot continue")
        noNextPage.isInverted = true
        stream.onSend = { _ in noNextPage.fulfill() }

        await fulfillment(of: [completed, failed, removed, noNextPage], timeout: 2.2)

        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(failureCount, 1)
        XCTAssertTrue(keys.consumed.isEmpty)
        XCTAssertEqual(stream.elements.count, 1)
    }

    private final class RecordingStream: XMPPStream {
        var elements: [DDXMLElement] = []
        var onSend: ((DDXMLElement) -> Void)?
        override func send(_ element: DDXMLElement) { elements.append(element.copy() as! DDXMLElement); onSend?(element) }
    }

    private func mamFinal(owner: String, queryID: String, count: Int, complete: Bool = true) throws -> XMPPIQ {
        try XMPPIQ(xmlString: "<iq xmlns='jabber:client' from='\(owner)' type='result' id='\(queryID)'><fin xmlns='urn:xmpp:mam:2' queryid='\(queryID)' complete='\(complete)'><set xmlns='http://jabber.org/protocol/rsm'><first>100</first><last>100</last><count>\(count)</count></set></fin></iq>")
    }

    private struct Admission: ArchiveConversationAdmissionProviding {
        func connectionDidBecomeReady(generation: UInt64) async {}
        func connectionDidDisconnect() async {}
        func admit(_ conversation: ArchiveConversationKey, connectionGeneration: UInt64) async throws -> ArchiveConversationAdmissionResult { .notRequired }
    }

    private struct EmptyRepository: ArchiveCoverageRepository {
        var consumedPages = false
        func verifiedAdmission(for intent: ArchiveWindowIntent, freshnessToken: ArchiveFreshnessToken) async throws -> ArchiveRepositoryAdmission? { nil }
        func commit(_ page: ValidatedArchiveTransportPage, request: ArchiveTransportRequest,
                    freshnessToken: ArchiveFreshnessToken) async throws -> ArchiveRepositoryCommit {
            guard consumedPages, let segment = page.segment else { return .authoritativeEmpty }
            return .verified(ArchiveWindowSnapshot(messagePrimaryIDs: [], target: request.locator,
                verifiedSegment: segment, coverageGeneration: 1, freshnessToken: freshnessToken))
        }
        func commitAnchorWindow(intent: ArchiveWindowIntent, anchor: ArchiveMaterializedAnchor,
            exactPage: ValidatedArchiveTransportPage, olderPage: ValidatedArchiveTransportPage,
            newerPage: ValidatedArchiveTransportPage, freshnessToken: ArchiveFreshnessToken) async throws -> ArchiveWindowSnapshot {
            throw ArchiveTransportError.protocolViolation
        }
        func materializedAnchor(conversation: ArchiveConversationKey, locator: ArchiveWindowLocator,
                                candidateArchiveIDs: [String]) async throws -> ArchiveMaterializedAnchor? { nil }
        func extendLiveEdge(for intent: ArchiveWindowIntent, primaryID: String,
                            freshnessToken: ArchiveFreshnessToken) async throws -> ArchiveWindowSnapshot? { nil }
    }

    private actor PausedTransport: ArchiveTransport {
        let cleanup: OMEMO2PreKeyCleanupCoordinator
        let keys: Keys
        var request: ArchiveTransportRequest?
        var requestCount = 0
        var queryToken: UUID?
        var continuation: CheckedContinuation<ArchiveTransportReceipt, Error>?
        init(cleanup: OMEMO2PreKeyCleanupCoordinator, keys: Keys) { self.cleanup = cleanup; self.keys = keys }
        var didStart: Bool { continuation != nil }
        func request(_ request: ArchiveTransportRequest, priority: ArchiveIntentPriority) async throws -> ArchiveTransportReceipt {
            self.request = request
            requestCount += 1
            queryToken = cleanup.beginQuery(id: request.queryID)
            keys.consumed = [12]
            cleanup.authenticatedReceiveDidCommit()
            return try await withCheckedThrowingContinuation { self.continuation = $0 }
        }
        func complete(consumedArchiveID: String? = nil, complete: Bool = true) {
            guard let request, let continuation, let queryToken else { return }
            self.continuation = nil
            self.queryToken = nil
            cleanup.finishQuery(id: request.queryID, token: queryToken)
            continuation.resume(returning: ArchiveTransportReceipt(queryID: request.queryID,
                connectionGeneration: request.connectionGeneration, resultArchiveIDs: consumedArchiveID.map { [$0] } ?? [], messagePrimaryIDs: [],
                first: consumedArchiveID ?? "", last: consumedArchiveID ?? "", complete: complete, cheapPageCount: consumedArchiveID == nil ? 0 : 1,
                deliveredResultCount: consumedArchiveID == nil ? 0 : 1, persistedResultCount: 0,
                intentionallyConsumedResultCount: consumedArchiveID == nil ? 0 : 1, failedPersistenceCount: 0, finalReceived: true))
        }
        func searchPage(_ request: ArchiveSearchTransportRequest, priority: ArchiveIntentPriority) async throws -> ArchiveSearchTransportReceipt {
            throw ArchiveTransportError.protocolViolation
        }
        func promote(descriptor: ArchiveIntentDescriptor, connectionGeneration: UInt64, to priority: ArchiveIntentPriority) async {}
    }

    private func waitForRequest(_ transport: PausedTransport, minimum: Int = 1) async -> Bool {
        for _ in 0..<2_000 {
            if await transport.didStart, await transport.requestCount >= minimum { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await transport.didStart
        let count = await transport.requestCount
        return started && count >= minimum
    }

    private func fixture() throws -> Fixture {
        let memory = Memory()
        let token = UUID().uuidString.lowercased()
        let alice = try XabberOMEMO2Storage(owner: "alice-\(token)@example.test", persistence: memory)
        let bob = try XabberOMEMO2Storage(owner: "bob-\(token)@example.test", persistence: memory)
        _ = try alice.prepare(deviceID: 1, preKeyCount: 3)
        let bundle = try bob.prepare(deviceID: 2, preKeyCount: 3)
        let preKey = try XCTUnwrap(bundle.preKeys.first)
        let chosen = try OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
            signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature,
            preKey: preKey.publicKey, preKeyID: preKey.id)
        try alice.initiateSession(jid: bob.owner, deviceID: 2, bundle: chosen)
        return Fixture(alice: alice, bob: bob, memory: memory, chosen: chosen, preKeyID: preKey.id)
    }
}
