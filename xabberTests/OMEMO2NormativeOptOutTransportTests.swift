import Foundation
import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

/// Queue-level coverage complements authenticated opt-out receive fixtures.
/// The permission closure models the protected decision changing at each seam.
final class OMEMO2NormativeOptOutTransportTests: XCTestCase {
    private var previousRealm: Realm.Configuration!
    private var keeper: Realm!
    private let owner = "n08-transport-owner@example.test"
    private let peer = "n08-transport-peer@example.test"

    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "N08-transport-\(UUID())")
        keeper = try WRealm.safe()
    }

    override func tearDown() {
        keeper = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        super.tearDown()
    }

    func testPendingPeerDoesNotReserveQueuedMessageOrArmReceiptTimeout() throws {
        let scheduler = Scheduler()
        var sent = 0
        let coordinator = makeCoordinator(scheduler: scheduler, allows: { _ in false }, send: { _ in sent += 1 })
        XCTAssertTrue(try coordinator.enqueueRegularMessage(request()))
        let item = try queued()
        XCTAssertEqual(item.state, .queued)
        XCTAssertEqual(item.attemptCount, 0)
        XCTAssertNil(item.lastAttemptAt)
        XCTAssertNil(item.lastError)
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testDecisionChangingAfterReservationRestoresPreviousAttemptMetadata() throws {
        let scheduler = Scheduler()
        var allowed = true
        var sent = 0
        XCTAssertTrue(try AccountSendCoordinator.persistRegularMessage(request(replay: true)))
        let item = try queued()
        let earlier = Date(timeIntervalSince1970: 7)
        try keeper.write {
            item.attemptCount = 2
            item.lastAttemptAt = earlier
            item.lastError = "previous attempt metadata"
        }
        let coordinator = makeCoordinator(scheduler: scheduler, allows: { _ in allowed }, decorate: { message in
            allowed = false
            return message
        }, send: { _ in sent += 1 })
        coordinator.drainReadyQueue()
        XCTAssertEqual(item.state, .queued)
        XCTAssertEqual(item.attemptCount, 2)
        XCTAssertEqual(item.lastAttemptAt, earlier)
        XCTAssertEqual(item.lastError, "previous attempt metadata")
        XCTAssertTrue(item.replayRequired)
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testFinalStreamFilterCancelsTimeoutAndNeutrallyRollsBackUntransmittedReservation() throws {
        let scheduler = Scheduler()
        var coordinator: AccountSendCoordinator!
        var handled = false
        var finalChecks = 0
        coordinator = makeCoordinator(scheduler: scheduler, allows: { _ in true }, send: { message in
            finalChecks += 1
            handled = coordinator.localSendBlocked(message: message)
        })
        XCTAssertTrue(try coordinator.enqueueRegularMessage(request()))
        let item = try queued()
        XCTAssertTrue(handled)
        XCTAssertEqual(finalChecks, 1)
        XCTAssertEqual(item.state, .queued)
        XCTAssertEqual(item.attemptCount, 0)
        XCTAssertNil(item.lastAttemptAt)
        XCTAssertNil(item.lastError)
        XCTAssertFalse(item.replayRequired)
        XCTAssertEqual(scheduler.activeCount, 0)
        scheduler.advance(by: 20)
        XCTAssertEqual(finalChecks, 1, "A filtered stanza must not become a timeout retry")
        XCTAssertEqual(item.state, .queued)
    }

    func testExplicitResolutionCanResumeSuspendedQueueAsFirstActualAttempt() throws {
        let scheduler = Scheduler()
        var allowed = false
        var sent = 0
        let coordinator = makeCoordinator(scheduler: scheduler, allows: { _ in allowed }, send: { _ in sent += 1 })
        XCTAssertTrue(try coordinator.enqueueRegularMessage(request()))
        XCTAssertEqual(try queued().attemptCount, 0)
        allowed = true
        coordinator.drainReadyQueue()
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(try queued().state, .awaitingReceipt)
        XCTAssertEqual(try queued().attemptCount, 1)
        XCTAssertEqual(scheduler.activeCount, 1)
    }

    func testFilteredPrimaryMessageAndIQReleaseTrackingWithoutAckTimeout() {
        let scheduler = Scheduler()
        var timeouts = 0
        let tracker = AccountPrimaryStreamStanzaTracker(scheduler: scheduler, onAckTimeout: { _ in timeouts += 1 })
        for (id, kind) in [("blocked-message", PrimaryStreamStanzaKind.message), ("blocked-iq", .iq)] {
            XCTAssertEqual(tracker.track(stanzaId: id, kind: kind, replayPolicy: .notReplayable), .tracked(stanzaId: id))
            XCTAssertEqual(tracker.noteSendFiltered(id: id)?.stanzaId, id)
            XCTAssertFalse(tracker.contains(stanzaId: id))
        }
        XCTAssertTrue(tracker.snapshotTrackedPrimaryStanzas().isEmpty)
        scheduler.advance(by: 20)
        XCTAssertEqual(timeouts, 0)
    }

    func testFilteringReusedIDRetainsTrackingForEarlierTransmittedAttempt() {
        let scheduler = Scheduler()
        var timeouts = 0
        let tracker = AccountPrimaryStreamStanzaTracker(scheduler: scheduler, onAckTimeout: { _ in timeouts += 1 })
        for (id, kind) in [("already-sent-message", PrimaryStreamStanzaKind.message), ("already-sent-iq", .iq)] {
            XCTAssertEqual(tracker.track(stanzaId: id, kind: kind, replayPolicy: .notReplayable), .tracked(stanzaId: id))
            tracker.noteDidSend(id: id)
            XCTAssertEqual(tracker.track(stanzaId: id, kind: kind, replayPolicy: .notReplayable), .tracked(stanzaId: id))
            XCTAssertNil(tracker.noteSendFiltered(id: id), "Blocking a later same-ID retry must not discard the real outstanding ACK")
            XCTAssertTrue(tracker.contains(stanzaId: id))
            XCTAssertEqual(tracker.noteAck(ids: [id]).first?.stanzaId, id)
        }
        scheduler.advance(by: 20)
        XCTAssertEqual(timeouts, 0)
    }

    func testDelayedDidSendCannotReleaseNewReservationWithTheSameOriginID() throws {
        let scheduler = Scheduler()
        var messages: [XMPPMessage] = []
        let coordinator = makeCoordinator(scheduler: scheduler, allows: { _ in true }, send: { messages.append($0) })
        XCTAssertTrue(try coordinator.enqueueRegularMessage(request()))
        XCTAssertEqual(messages.count, 1)
        scheduler.advance(by: 5)
        XCTAssertEqual(messages.count, 2)
        let earlier = try XCTUnwrap(messages.first)
        let retry = try XCTUnwrap(messages.last)
        XCTAssertFalse(earlier === retry)
        coordinator.localSendDidTransmit(message: earlier)
        XCTAssertTrue(coordinator.localSendBlocked(message: retry), "Only didSend for this exact stanza may release its reservation")
        let item = try queued()
        XCTAssertEqual(item.state, .queued)
        XCTAssertEqual(item.attemptCount, 1)
        XCTAssertNil(item.lastAttemptAt)
        XCTAssertEqual(item.lastError, AccountSendCoordinator.deliveryReceiptTimeoutErrorCode)
        XCTAssertTrue(item.replayRequired)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testFilteredNonqueuedEncryptedBubbleUsesLocalErrorAndRetainsContentForRetry() throws {
        let bubble = try persistBubble(id: "encrypted-race", owner: owner, outgoing: true, state: .sending)
        let coordinator = makeCoordinator(scheduler: Scheduler(), allows: { _ in false }, send: { _ in XCTFail("Blocked") })
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: peer), elementID: bubble.messageId)
        XCTAssertTrue(coordinator.localSendBlocked(message: message))
        XCTAssertEqual(bubble.state, .error)
        XCTAssertEqual(bubble.messageErrorCode, "omemo-opt-out-pending")
        XCTAssertNotNil(bubble.messageError)
        XCTAssertEqual(bubble.body, "Retain encrypted draft")
        XCTAssertEqual(bubble.conversationType, .omemo)
        XCTAssertTrue(keeper.objects(OutgoingMessageQueueItem.self).isEmpty, "No new outbox for encrypted messages")
    }

    func testNeutralFilterCannotChangeIncomingDeliveredOrAnotherOwnersBubble() throws {
        let incoming = try persistBubble(id: "incoming", owner: owner, outgoing: false, state: .sending)
        let delivered = try persistBubble(id: "delivered", owner: owner, outgoing: true, state: .deliver)
        let otherOwner = try persistBubble(id: "other-account", owner: "another@example.test", outgoing: true, state: .sending)
        let coordinator = makeCoordinator(scheduler: Scheduler(), allows: { _ in false }, send: { _ in XCTFail("Blocked") })
        for bubble in [incoming, delivered, otherOwner] {
            let previous = bubble.state
            let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: peer), elementID: bubble.messageId)
            XCTAssertFalse(coordinator.localSendBlocked(message: message))
            XCTAssertEqual(bubble.state, previous)
            XCTAssertNil(bubble.messageErrorCode)
        }
    }

    private func persistBubble(id: String, owner bubbleOwner: String, outgoing: Bool,
                               state: MessageStorageItem.MessageSendingState) throws -> MessageStorageItem {
        let bubble = MessageStorageItem()
        bubble.conversationType = .omemo
        bubble.configureOutgoingMessage("Retain encrypted draft", legacy: "Retain encrypted draft", messageId: id,
            owner: bubbleOwner, opponent: peer, references: [], inlineForwards: [])
        bubble.outgoing = outgoing
        bubble.state = state
        try keeper.write { keeper.add(bubble, update: .modified) }
        return bubble
    }

    private func request(replay: Bool = false) -> AccountQueuedMessageSendRequest {
        .init(owner: owner, conversationJid: peer, conversationType: .regular,
              messagePrimary: MessageStorageItem.genPrimary(messageId: "queued-n08", owner: owner),
              originId: "queued-n08", stanzaXML: "<message xmlns='jabber:client' to='\(peer)' id='queued-n08'><body>Unsent content</body></message>",
              createdAt: Date(timeIntervalSince1970: 1), replayRequired: replay)
    }

    private func queued() throws -> OutgoingMessageQueueItem {
        try XCTUnwrap(keeper.objects(OutgoingMessageQueueItem.self).filter("owner == %@", owner).first)
    }

    private func makeCoordinator(scheduler: Scheduler, allows: @escaping (String) -> Bool,
                                 decorate: @escaping (XMPPMessage) -> XMPPMessage = { $0 },
                                 send: @escaping (XMPPMessage) -> Void) -> AccountSendCoordinator {
        AccountSendCoordinator(environment: .init(owner: owner, isSendReady: { true },
            allowsMessage: allows, decorateMessage: { message, _, _ in decorate(message) },
            sendMessage: send, scheduler: scheduler, receiptTimeout: 5,
            now: { Date(timeIntervalSince1970: scheduler.now) }, log: { _, _ in }))
    }

    private final class Scheduler: AccountConnectionResilienceScheduling {
        private final class Job: AccountConnectionResilienceCancellable {
            let due: TimeInterval
            let block: () -> Void
            var cancelled = false
            init(due: TimeInterval, block: @escaping () -> Void) { self.due = due; self.block = block }
            func cancel() { cancelled = true }
        }
        var now: TimeInterval = 10
        private var jobs: [Job] = []
        var activeCount: Int { jobs.filter { !$0.cancelled }.count }
        func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> AccountConnectionResilienceCancellable {
            let job = Job(due: now + delay, block: block)
            jobs.append(job)
            return job
        }
        func advance(by interval: TimeInterval) {
            now += interval
            let ready = jobs.filter { !$0.cancelled && $0.due <= now }
            for job in ready { job.cancel(); job.block() }
        }
    }
}
