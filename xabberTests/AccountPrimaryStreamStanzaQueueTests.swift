import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class AccountPrimaryStreamStanzaQueueTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "AccountPrimaryStreamStanzaQueueTests-\(name)-\(UUID().uuidString)"
        )
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testTrackerRegistersBeforeSendAndAssignsMissingStanzaId() {
        let harness = makeTrackerHarness()
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: "juliet@example.com"), elementID: nil)
        var events: [String] = []

        let stanzaId = PrimaryStreamStanzaIdentifier.ensureID(on: message)
        let result = harness.tracker.track(
            stanzaId: stanzaId,
            kind: .message,
            replayPolicy: .notReplayable
        )
        events.append("tracked")
        events.append("sent")

        XCTAssertEqual(result, .tracked(stanzaId: stanzaId))
        XCTAssertEqual(message.elementID, stanzaId)
        XCTAssertEqual(events, ["tracked", "sent"])
        XCTAssertEqual(harness.tracker.snapshotTrackedPrimaryStanzas().map(\.stanzaId), [stanzaId])
    }

    func testAckRemovesOnlyAckedIdsAndLeavesPartialRemainderTracked() {
        let harness = makeTrackerHarness()
        _ = harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .notReplayable)
        _ = harness.tracker.track(stanzaId: "message-2", kind: .message, replayPolicy: .notReplayable)

        let removed = harness.tracker.noteAck(ids: ["message-1"])

        XCTAssertEqual(removed.map(\.stanzaId), ["message-1"])
        XCTAssertEqual(harness.tracker.snapshotTrackedPrimaryStanzas().map(\.stanzaId), ["message-2"])

        _ = harness.tracker.noteAck(ids: ["message-2"])

        XCTAssertTrue(harness.tracker.snapshotTrackedPrimaryStanzas().isEmpty)
    }

    func testAckTimeoutFiresOnceForSameOldestGeneration() {
        let harness = makeTrackerHarness()
        _ = harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .notReplayable)

        harness.scheduler.advance(by: 4.9)
        XCTAssertTrue(harness.timeouts.isEmpty)

        harness.scheduler.advance(by: 0.1)
        XCTAssertEqual(harness.timeouts.map(\.stanzaId), ["message-1"])

        harness.scheduler.advance(by: 20)
        XCTAssertEqual(harness.timeouts.map(\.stanzaId), ["message-1"])
    }

    func testDidFailToSendRemovesTrackedStanzaSafely() {
        let harness = makeTrackerHarness()
        _ = harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .notReplayable)

        let removed = harness.tracker.noteSendFailed(id: "message-1")
        let duplicateRemoval = harness.tracker.noteSendFailed(id: "message-1")

        XCTAssertEqual(removed?.stanzaId, "message-1")
        XCTAssertNil(duplicateRemoval)
        XCTAssertTrue(harness.tracker.snapshotTrackedPrimaryStanzas().isEmpty)
    }

    func testSuccessfulResumeReconcilesAckedIdsWithoutReplayRequests() {
        let harness = makeTrackerHarness()
        _ = harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .durableRegularMessage(originId: "message-1"))
        _ = harness.tracker.track(stanzaId: "message-2", kind: .message, replayPolicy: .durableRegularMessage(originId: "message-2"))

        let removed = harness.tracker.noteResumeSucceeded(ackedIds: ["message-1"])

        XCTAssertEqual(removed.map(\.stanzaId), ["message-1"])
        XCTAssertEqual(harness.tracker.snapshotTrackedPrimaryStanzas().map(\.stanzaId), ["message-2"])
    }

    func testFailedResumeFullReconnectLetsSendCoordinatorReplayRegularMessageWithRetry() throws {
        var isReady = true
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { isReady }, recorder: recorder)

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1"))
        isReady = false
        coordinator.streamDidDisconnect(canResume: true)
        coordinator.streamManagementResumeFailed()
        isReady = true
        coordinator.accountDidBecomeSendReady()

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-1"])
        XCTAssertNotNil(recorder.sentMessages.last?.element(forName: "retry", xmlns: "https://xabber.com/protocol/delivery"))
        XCTAssertEqual(
            recorder.sentMessages.last?.element(forName: "origin-id", xmlns: "urn:xmpp:sid:0")?.attributeStringValue(forName: "id"),
            "message-1"
        )
    }

    func testStreamManagementAckDoesNotDrainSendCoordinatorBeforeDeliveryReceipt() throws {
        let recorder = AccountPrimaryStreamSendCoordinatorRecorder()
        let coordinator = makeSendCoordinator(isReady: { true }, recorder: recorder)
        let harness = makeTrackerHarness()

        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-1", createdAt: Date(timeIntervalSince1970: 1)))
        try coordinator.enqueueRegularMessage(makeRequest(originId: "message-2", createdAt: Date(timeIntervalSince1970: 2)))
        _ = harness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .durableRegularMessage(originId: "message-1"))

        _ = harness.tracker.noteAck(ids: ["message-1"])

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1"])

        coordinator.deliveryReceiptReceived(originId: "message-1", stanzaId: "archive-1")

        XCTAssertEqual(recorder.sentMessages.map(\.elementID), ["message-1", "message-2"])
    }

    func testQueueCountAndRetainedXMLByteLimitsAreEnforcedWithoutCrashes() {
        let countHarness = makeTrackerHarness(
            configuration: .init(maxTrackedCount: 1, maxRetainedXMLBytes: 1024, ackTimeout: 5)
        )
        XCTAssertEqual(
            countHarness.tracker.track(stanzaId: "message-1", kind: .message, replayPolicy: .notReplayable),
            .tracked(stanzaId: "message-1")
        )
        XCTAssertEqual(
            countHarness.tracker.track(stanzaId: "message-2", kind: .message, replayPolicy: .notReplayable),
            .rejected(.countLimit(max: 1))
        )

        let byteHarness = makeTrackerHarness(
            configuration: .init(maxTrackedCount: 10, maxRetainedXMLBytes: 8, ackTimeout: 5)
        )
        XCTAssertEqual(
            byteHarness.tracker.track(
                stanzaId: "iq-1",
                kind: .iq,
                replayPolicy: .safeIdempotentIQ(retainedXML: "<iq id='iq-1'><query/></iq>")
            ),
            .rejected(.retainedXMLByteLimit(max: 8, attempted: 27))
        )
        XCTAssertTrue(byteHarness.tracker.snapshotTrackedPrimaryStanzas().isEmpty)
    }

    func testConcurrentSendAckAndTimeoutAccessIsRaceFree() {
        let harness = makeTrackerHarness(
            configuration: .init(maxTrackedCount: 300, maxRetainedXMLBytes: 1024, ackTimeout: 5)
        )
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.xabber.tests.primary-tracker.concurrent", attributes: .concurrent)

        for index in 0..<100 {
            group.enter()
            queue.async {
                _ = harness.tracker.track(stanzaId: "message-\(index)", kind: .message, replayPolicy: .notReplayable)
                group.leave()
            }
        }
        for index in 0..<100 {
            group.enter()
            queue.async {
                _ = harness.tracker.noteAck(ids: ["message-\(index)"])
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        harness.scheduler.advance(by: 5)
        XCTAssertLessThanOrEqual(harness.tracker.snapshotTrackedPrimaryStanzas().count, 100)
    }

    func testNonPrimaryStreamFallsBackToDirectSendRoute() {
        let stream = XMPPStream()

        XCTAssertNil(PrimaryStreamSendRouting.primaryAccount(owner: "missing@example.com", stream: stream))
    }

    private func makeTrackerHarness(
        configuration: AccountPrimaryStreamStanzaTracker.Configuration = .init(maxTrackedCount: 512, maxRetainedXMLBytes: 512 * 1024, ackTimeout: 5)
    ) -> AccountPrimaryStreamTrackerHarness {
        let scheduler = AccountPrimaryStreamTestScheduler()
        let box = AccountPrimaryStreamTimeoutBox()
        let tracker = AccountPrimaryStreamStanzaTracker(
            configuration: configuration,
            scheduler: scheduler,
            onAckTimeout: { stanza in
                box.timeouts.append(stanza)
            }
        )
        return AccountPrimaryStreamTrackerHarness(
            tracker: tracker,
            scheduler: scheduler,
            timeoutBox: box
        )
    }

    private func makeSendCoordinator(
        owner: String = "owner@example.com",
        isReady: @escaping () -> Bool,
        recorder: AccountPrimaryStreamSendCoordinatorRecorder
    ) -> AccountSendCoordinator {
        AccountSendCoordinator(
            environment: AccountSendCoordinator.Environment(
                owner: owner,
                isSendReady: isReady,
                decorateMessage: { message, retry, missRetryElement in
                    if retry && !missRetryElement {
                        message.addChild(DDXMLElement(name: "retry", xmlns: "https://xabber.com/protocol/delivery"))
                    }
                    return message
                },
                sendMessage: { message in
                    recorder.sentMessages.append(message.copy() as! XMPPMessage)
                },
                log: { _, _ in }
            )
        )
    }

    private func makeRequest(
        owner: String = "owner@example.com",
        opponent: String = "romeo@example.com",
        originId: String,
        createdAt: Date = Date(timeIntervalSince1970: 1)
    ) -> AccountQueuedMessageSendRequest {
        AccountQueuedMessageSendRequest(
            owner: owner,
            conversationJid: opponent,
            conversationType: .regular,
            messagePrimary: MessageStorageItem.genPrimary(messageId: originId, owner: owner),
            originId: originId,
            stanzaXML: """
            <message type='chat' to='\(opponent)' id='\(originId)' from='\(owner)'>
              <body>Hello</body>
              <origin-id xmlns='urn:xmpp:sid:0' id='\(originId)'/>
            </message>
            """,
            createdAt: createdAt,
            replayRequired: false
        )
    }
}

private struct AccountPrimaryStreamTrackerHarness {
    let tracker: AccountPrimaryStreamStanzaTracker
    let scheduler: AccountPrimaryStreamTestScheduler
    private let timeoutBox: AccountPrimaryStreamTimeoutBox

    init(
        tracker: AccountPrimaryStreamStanzaTracker,
        scheduler: AccountPrimaryStreamTestScheduler,
        timeoutBox: AccountPrimaryStreamTimeoutBox
    ) {
        self.tracker = tracker
        self.scheduler = scheduler
        self.timeoutBox = timeoutBox
    }

    var timeouts: [PrimaryStreamTrackedStanza] {
        timeoutBox.timeouts
    }
}

private final class AccountPrimaryStreamTimeoutBox {
    var timeouts: [PrimaryStreamTrackedStanza] = []
}

private final class AccountPrimaryStreamSendCoordinatorRecorder {
    var sentMessages: [XMPPMessage] = []
}

private final class AccountPrimaryStreamTestScheduler: AccountConnectionResilienceScheduling {
    private final class Scheduled: AccountConnectionResilienceCancellable {
        let id: Int
        let due: TimeInterval
        let block: () -> Void
        var isCancelled = false

        init(id: Int, due: TimeInterval, block: @escaping () -> Void) {
            self.id = id
            self.due = due
            self.block = block
        }

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var now: TimeInterval = 0
    private var nextID = 0
    private var scheduled: [Scheduled] = []

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> AccountConnectionResilienceCancellable {
        nextID += 1
        let scheduled = Scheduled(id: nextID, due: now + max(0, delay), block: block)
        self.scheduled.append(scheduled)
        return scheduled
    }

    func advance(by interval: TimeInterval) {
        now += interval
        while let next = scheduled
            .filter({ !$0.isCancelled && $0.due <= now })
            .sorted(by: { lhs, rhs in
                if lhs.due == rhs.due {
                    return lhs.id < rhs.id
                }
                return lhs.due < rhs.due
            })
            .first {
            next.cancel()
            next.block()
        }
        scheduled.removeAll { $0.isCancelled }
    }
}
