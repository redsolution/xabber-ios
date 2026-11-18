import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

@MainActor
final class ScheduledMessageActionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testEditKeepsOriginalTimeAndUsesAcknowledgedCancel() async throws {
        let service = Service()
        let item = makeItem()
        let coordinator = makeCoordinator(service)

        try await coordinator.perform(.edit("Changed & ready"), on: item).get()

        XCTAssertEqual(service.events, ["cancel:alice@example.test:first", "schedule:first"])
        XCTAssertEqual(service.scheduledDate, item.deliverAt)
        XCTAssertEqual(service.payload?.body, "Changed & ready")
    }

    func testReschedulePreservesUnknownExtensionAndBody() async throws {
        let service = Service()
        let item = makeItem(extra: "<custom xmlns='urn:example:future'><a>opaque</a></custom>")
        let newTime = now.addingTimeInterval(5_000)
        let coordinator = makeCoordinator(service)

        try await coordinator.perform(.reschedule(newTime), on: item).get()

        XCTAssertEqual(service.scheduledDate, newTime)
        XCTAssertEqual(service.payload?.body, "Before")
        XCTAssertEqual(service.payload?.element(forName: "custom", xmlns: "urn:example:future")?.stringValue, "opaque")
    }

    func testPastTimeProtectedContentAndDeniedRouteDoNotCancel() async {
        let service = Service()
        let coordinator = makeCoordinator(service)

        assertFailure(await coordinator.perform(.reschedule(now), on: makeItem()), .notAcceptable)
        assertFailure(
            await coordinator.perform(.sendNow, on: makeItem(extra: "<encrypted xmlns='urn:xmpp:omemo:2'/>")),
            .malformedPayload
        )
        service.preflightError = .forbidden
        assertFailure(await coordinator.perform(.sendNow, on: makeItem()), .forbidden)

        XCTAssertTrue(service.events.isEmpty)
    }

    func testCancelItemNotFoundAndTimeoutDoNotSendAndRefresh() async {
        let service = Service()
        let coordinator = makeCoordinator(service)
        let item = makeItem()

        service.cancelError = .itemNotFound
        assertFailure(await coordinator.perform(.sendNow, on: item), .itemNotFound)
        service.cancelError = .timeout
        assertFailure(await coordinator.perform(.sendNow, on: item), .timeout)

        XCTAssertEqual(service.events, [
            "cancel:alice@example.test:first", "list:alice@example.test",
            "cancel:alice@example.test:first", "list:alice@example.test"
        ])
    }

    func testFailedReplacementRetainsEditedContentAndRetriesWithoutAnotherCancel() async throws {
        let service = Service()
        service.scheduleError = .resourceConstraint
        let coordinator = makeCoordinator(service)
        let item = makeItem()

        let result = await coordinator.perform(.edit("Keep my new text"), on: item)
        let failure = try XCTUnwrap(assertFailure(result, .resourceConstraint))
        let recovery = try XCTUnwrap(failure.recovery)
        XCTAssertEqual(recovery.action, .edit("Keep my new text"))
        XCTAssertFalse(recovery.requiresRefresh)
        XCTAssertEqual(coordinator.recoveries(owner: item.owner, conversation: item.conversation,
                                              conversationType: item.conversationType).count, 1)

        service.scheduleError = nil
        try await coordinator.retry(recovery).get()

        XCTAssertEqual(service.events, ["cancel:alice@example.test:first", "schedule:first", "schedule:first"])
        XCTAssertEqual(service.payload?.body, "Keep my new text")
        XCTAssertTrue(coordinator.recoveries(owner: item.owner, conversation: item.conversation,
                                             conversationType: item.conversationType).isEmpty)
    }

    func testUnknownReplacementCannotBeRetriedWithoutConfirmingOutcome() async throws {
        let service = Service()
        service.scheduleError = .timeout
        let coordinator = makeCoordinator(service)
        let item = makeItem()

        let result = await coordinator.perform(.edit("Text to recover"), on: item)
        let failure = try XCTUnwrap(assertFailure(result, .timeout))
        let recovery = try XCTUnwrap(failure.recovery)
        XCTAssertTrue(recovery.requiresRefresh)
        _ = await coordinator.retry(recovery)

        XCTAssertEqual(service.events.filter { $0 == "schedule:first" }.count, 1)
        XCTAssertTrue(service.events.contains("list:alice@example.test"))
    }

    func testRecoveryPersistsAcrossReopeningAndIsScopedToItsChat() async throws {
        let service = Service()
        service.scheduleError = .forbidden
        let item = makeItem()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = ScheduledMessageActionCoordinator(
            service: service, now: { self.now }, journal: ScheduledMessageActionJournal(directory: directory)
        )
        let result = await original.perform(.edit("Retained text"), on: item)
        let recovery = try XCTUnwrap(assertFailure(result, .forbidden)?.recovery)
        let reopened = ScheduledMessageActionCoordinator(
            service: service, now: { self.now }, journal: ScheduledMessageActionJournal(directory: directory)
        )

        XCTAssertEqual(reopened.recoveries(owner: item.owner, conversation: item.conversation, conversationType: .regular), [recovery])
        XCTAssertTrue(reopened.recoveries(owner: "second@example.test", conversation: item.conversation, conversationType: .regular).isEmpty)
        XCTAssertTrue(reopened.recoveries(owner: item.owner, conversation: item.conversation, conversationType: .omemo).isEmpty)
    }

    func testJournalWipeClearsCachedAndPersistedRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = makeItem()
        let journal = ScheduledMessageActionJournal(directory: directory)
        XCTAssertTrue(journal.begin(item: item, action: .edit("Sensitive draft")))
        XCTAssertNotNil(journal.record(for: item))

        try journal.invalidateAll()

        XCTAssertNil(journal.record(for: item))
        XCTAssertNil(ScheduledMessageActionJournal(directory: directory).record(for: item))
    }

    func testSendNowUsesFreshOriginAndRetriesTheSameNormalOutgoingRow() throws {
        let originalConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        defer { Realm.Configuration.defaultConfiguration = originalConfiguration }
        let realm = try WRealm.safe()
        let owner = "sender-\(UUID().uuidString.lowercased())@example.test"
        let peer = "bob@example.test"
        let manager = MessageManager(withOwner: owner, activeStream: false)
        defer {
            manager.updateSendingMessagesTimer?.invalidate()
            manager.updateSendingMessagesTimer = nil
        }
        manager.localOutgoingAdmissionPublisher = { _ in }
        let payload = try XMPPMessage(xmlString: """
            <message xmlns='jabber:client' to='\(peer)' type='chat' id='scheduled-id'>
              <body>Before &amp; after</body>
              <origin-id xmlns='urn:xmpp:sid:0' id='scheduled-id'/>
              <custom xmlns='urn:example:future'>retained</custom>
              <deferred xmlns='https://xabber.com/protocol/schedule' id='schedule-row'/>
            </message>
            """)

        XCTAssertTrue(manager.admitScheduledMessageForImmediateSend(payload, to: peer, conversationType: .regular))
        let stored = try XCTUnwrap(realm.objects(MessageStorageItem.self).filter("owner == %@", owner).first)
        let wire = try XCTUnwrap(MessageManager.preparedForwardingContent(for: stored, in: realm))
        XCTAssertEqual(wire.body, "Before & after")
        XCTAssertEqual(wire.to?.bare, peer)
        XCTAssertNotEqual(wire.elementID, "scheduled-id")
        XCTAssertEqual(getOriginId(wire), stored.messageId)
        XCTAssertEqual(wire.element(forName: "custom", xmlns: "urn:example:future")?.stringValue, "retained")
        XCTAssertNil(wire.element(forName: "deferred", xmlns: XMPPMessageScheduleManager.namespace))

        manager.retrySending(item: stored.primary)

        XCTAssertEqual(realm.objects(MessageStorageItem.self).filter("owner == %@", owner).count, 1)
        let queued = realm.objects(OutgoingMessageQueueItem.self).filter("owner == %@", owner)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.originId, stored.messageId)
    }

    func testBulkSendSortsByDateAndContinuesAfterOneFailedItem() async {
        let service = Service()
        service.cancelFailures = ["earlier": .itemNotFound]
        let coordinator = makeCoordinator(service)
        let earlier = makeItem(id: "earlier", offset: 300)
        let later = makeItem(id: "later", owner: "second@example.test", offset: 600)

        let results = await coordinator.perform(.sendNow, on: [later, earlier, later])

        XCTAssertEqual(results.map { $0.item.scheduledId }, ["earlier", "later"])
        XCTAssertEqual(service.events, [
            "cancel:alice@example.test:earlier", "list:alice@example.test",
            "cancel:second@example.test:later", "send:second@example.test:later"
        ])
    }

    func testInFlightActionCannotCancelSameScheduleTwice() async throws {
        let service = Service()
        service.holdCancel = true
        let coordinator = makeCoordinator(service)
        let item = makeItem()

        let original = Task { await coordinator.perform(.sendNow, on: item) }
        while service.pendingCancel == nil { await Task.yield() }
        _ = await coordinator.perform(.delete, on: item)
        service.pendingCancel?(.success(item.scheduledId))
        try await original.value.get()

        XCTAssertEqual(service.events, ["cancel:alice@example.test:first", "send:alice@example.test:first"])
    }

    private func makeCoordinator(_ service: Service) -> ScheduledMessageActionCoordinator {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ScheduledMessageActionCoordinator(
            service: service, now: { self.now }, journal: ScheduledMessageActionJournal(directory: directory)
        )
    }

    private func makeItem(
        id: String = "first",
        owner: String = "alice@example.test",
        offset: TimeInterval = 600,
        extra: String = ""
    ) -> ScheduledMessageListItem {
        ScheduledMessageListItem(
            scheduledId: id, deliverAt: now.addingTimeInterval(offset), status: .pending,
            bodyPreview: "Before", owner: owner, conversation: "bob@example.test",
            conversationType: .regular,
            messageXML: "<message xmlns='jabber:client' to='bob@example.test' type='chat'><body>Before</body>\(extra)</message>"
        )
    }

    @discardableResult
    private func assertFailure(
        _ result: Result<Void, ScheduledMessageActionFailure>,
        _ expected: XMPPMessageScheduleManager.ScheduleError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ScheduledMessageActionFailure? {
        guard case .failure(let failure) = result else {
            XCTFail("Expected failure", file: file, line: line)
            return nil
        }
        XCTAssertEqual(failure.error, expected, file: file, line: line)
        return failure
    }

    private final class Service: ChatScheduledMessageServicing {
        typealias Manager = XMPPMessageScheduleManager
        var events: [String] = []
        var preflightError: Manager.ScheduleError?
        var cancelError: Manager.ScheduleError?
        var cancelFailures: [String: Manager.ScheduleError] = [:]
        var scheduleError: Manager.ScheduleError?
        var payload: XMPPMessage?
        var scheduledDate: Date?
        var holdCancel = false
        var pendingCancel: Manager.CancelCallback?

        func isScheduleAvailable(owner: String) -> Bool { true }

        func validateScheduledAction(_ action: ScheduledMessageAction, on item: ScheduledMessageListItem) -> Manager.ScheduleError? {
            preflightError
        }

        func schedulePlaintextMessage(_ request: ChatScheduledMessageSendRequest, callback: Manager.ScheduleCallback?) -> String? {
            XCTFail("Mutations should use the prepared packet")
            return nil
        }

        func schedulePreparedMessage(_ payload: XMPPMessage, for item: ScheduledMessageListItem,
                                     deliverAt: Date, callback: Manager.ScheduleCallback?) -> String? {
            events.append("schedule:\(item.scheduledId)")
            self.payload = payload
            scheduledDate = deliverAt
            if let scheduleError {
                callback?(.failure(scheduleError))
            } else {
                callback?(.success(Manager.ScheduledEntry(
                    scheduledId: "replacement", conversation: item.conversation, conversationType: item.conversationType,
                    deliverAt: deliverAt, status: .pending, messageXML: payload.xmlString
                )))
            }
            return "schedule-iq"
        }

        func sendScheduledMessageNow(_ payload: XMPPMessage, for item: ScheduledMessageListItem,
                                     completion: @escaping (Result<Void, Manager.ScheduleError>) -> Void) {
            events.append("send:\(item.owner):\(item.scheduledId)")
            completion(.success(()))
        }

        func listScheduledMessages(owner: String, conversation: String,
                                   conversationType: ClientSynchronizationManager.ConversationType,
                                   callback: Manager.ListCallback?) -> String? {
            events.append("list:\(owner)")
            callback?(.success([]))
            return "list-iq"
        }

        func cancelScheduledMessage(owner: String, scheduledId: String, callback: Manager.CancelCallback?) -> String? {
            events.append("cancel:\(owner):\(scheduledId)")
            if holdCancel {
                pendingCancel = callback
            } else if let error = cancelFailures[scheduledId] ?? cancelError {
                callback?(.failure(error))
            } else {
                callback?(.success(scheduledId))
            }
            return "cancel-iq"
        }
    }
}
