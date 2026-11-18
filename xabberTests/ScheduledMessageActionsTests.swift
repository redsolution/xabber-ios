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

    func testPreparesAttachmentOnlyMessageWithoutChangingTheCallerReference() throws {
        let file = uploadedFile("https://files.example.test/a?p=one&other=two")
        let message = try XCTUnwrap(ScheduledMessageContent.makeMessage(
            owner: "alice@example.test", conversation: "bob@example.test", conversationType: .regular,
            body: "", references: [file]
        ))
        let content = try XCTUnwrap(ScheduledMessageContent.read(makeItem(message: message)))

        XCTAssertEqual(message.body, file.fileSharingURI)
        XCTAssertEqual(content.body, "")
        XCTAssertEqual(content.attachments.map { $0.reference.fileSharingURI }, [file.fileSharingURI])
        XCTAssertEqual(file.begin, 0)
        XCTAssertEqual(file.end, 0)
    }

    func testWebUTF16DecorationAndFileFallbackSurviveUnicodeAndEscaping() throws {
        let item = try webScheduledFile()
        let content = try XCTUnwrap(ScheduledMessageContent.read(item))
        let markup = try XCTUnwrap(content.references.first { $0.kind == .markup })

        XCTAssertEqual(content.body, "🙂 & bold")
        XCTAssertEqual((content.body as NSString).substring(with: markup.range), "bold")
        XCTAssertEqual(markup.metadata?["styles"] as? [String], ["bold", "uri"])
        XCTAssertEqual(content.attachments.first?.reference.fileSharingURI, "https://files.example.test/a?t=x&value=y")
    }

    func testEditedMarkupAndLinkRangesMoveWithTheirText() async throws {
        let service = Service()
        let item = try webScheduledFile()
        let initial = try XCTUnwrap(ScheduledMessageContent.read(item))
        let coordinator = makeCoordinator(service)

        try await coordinator.perform(.editContent(
            body: "New 🙂 & bold!",
            retainedAttachmentIDs: initial.attachments.map(\.id),
            addedAttachmentXML: []
        ), on: item).get()

        let message = try XCTUnwrap(service.payload)
        let content = try XCTUnwrap(ScheduledMessageContent.read(makeItem(message: message)))
        let markup = try XCTUnwrap(content.references.first { $0.kind == .markup })
        XCTAssertEqual(content.body, "New 🙂 & bold!")
        XCTAssertEqual((content.body as NSString).substring(with: markup.range), "bold")
        XCTAssertEqual(markup.fileSharingURI, "https://example.test/style")
        XCTAssertEqual(content.attachments.count, 1)
        XCTAssertEqual(message.element(forName: "custom", xmlns: "urn:example:future")?.stringValue, "retained")
        XCTAssertEqual(service.scheduledDate, item.deliverAt)
    }

    func testRemovingAnEditedGroupMentionAlsoRemovesItsNotificationTarget() throws {
        let message = try XMPPMessage(xmlString: """
            <message xmlns='jabber:client' type='chat' to='room@example.test' id='original'>
              <body>@Anna and @Bob</body>
              <mentions xmlns='https://xabber.com/protocol/groups'><user id='anna'/><user id='bob'/></mentions>
              <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='0' end='5'>
                <mention xmlns='https://xabber.com/protocol/markup'>xmpp:room@example.test?members;id=anna</mention>
              </reference>
              <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='10' end='14'>
                <mention xmlns='https://xabber.com/protocol/markup'>xmpp:room@example.test?members;id=bob</mention>
              </reference>
            </message>
            """)
        let edited = try XCTUnwrap(ScheduledMessageContent.edited(
            message, body: "Hello @Anna", retainedAttachmentIDs: [], addedAttachmentXML: []
        ))

        XCTAssertEqual(GroupMessageMentionsCodec.decode(from: edited), .members(["anna"]))
        let parsed = parseReferences(edited, primary: "", jid: "room@example.test", owner: "alice@example.test")
        XCTAssertEqual(GroupMessageMentionsCodec.memberIDs(from: parsed), ["anna"])
    }

    func testEditingInsideTwoIndependentStyledRangesPreservesBothStyles() throws {
        let message = try XMPPMessage(xmlString: """
            <message xmlns='jabber:client' type='chat' to='bob@example.test' id='original'>
              <body>abc / xyz</body>
              <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='0' end='3'>
                <bold xmlns='https://xabber.com/protocol/markup'/>
              </reference>
              <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='6' end='9'>
                <italic xmlns='https://xabber.com/protocol/markup'/>
              </reference>
            </message>
            """)
        let result = try XCTUnwrap(ScheduledMessageContent.edited(
            message, body: "aBBc / xYYz", retainedAttachmentIDs: [], addedAttachmentXML: []
        ))
        let content = try XCTUnwrap(ScheduledMessageContent.read(makeItem(message: result)))
        let styled = content.references.filter { $0.kind == .markup }

        XCTAssertEqual(styled.map { (content.body as NSString).substring(with: $0.range) }, ["aBBc", "xYYz"])
        XCTAssertEqual(styled.map { $0.metadata?["styles"] as? [String] ?? [] }, [["bold"], ["italic"]])
    }

    func testWebStickerCanBeMovedAndSentButCannotBeEdited() throws {
        let item = makeItem(extra: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='0'>
              <sticker xmlns='https://xabber.com/protocol/stickers' name='Wave'/>
            </reference>
            """)
        XCTAssertFalse(ScheduledMessageActionCoordinator.supports(.edit("Changed"), on: item))
        XCTAssertTrue(ScheduledMessageActionCoordinator.supports(.reschedule(now.addingTimeInterval(3600)), on: item))
        XCTAssertTrue(ScheduledMessageActionCoordinator.supports(.sendNow, on: item))
    }

    func testExplicitlyRemovingAllFilesDoesNotRestoreOmittedAttachments() async throws {
        let service = Service()
        let item = try webScheduledFile()
        let coordinator = makeCoordinator(service)

        try await coordinator.perform(.editContent(body: "Image removed", retainedAttachmentIDs: [],
                                                    addedAttachmentXML: []), on: item).get()

        let message = try XCTUnwrap(service.payload)
        let content = try XCTUnwrap(ScheduledMessageContent.read(makeItem(message: message)))
        XCTAssertEqual(message.body, "Image removed")
        XCTAssertTrue(content.attachments.isEmpty)
    }

    func testReplacementCanAddAnAlreadyUploadedFileWithoutTheOriginal() async throws {
        let service = Service()
        let item = try webScheduledFile()
        let added = uploadedFile("https://files.example.test/new")
        let newXML = try XCTUnwrap(ScheduledMessageContent.attachmentXML([added]))
        let coordinator = makeCoordinator(service)

        try await coordinator.perform(.editContent(body: "", retainedAttachmentIDs: [], addedAttachmentXML: newXML),
                                      on: item).get()

        let message = try XCTUnwrap(service.payload)
        let content = try XCTUnwrap(ScheduledMessageContent.read(makeItem(message: message)))
        XCTAssertEqual(message.body, added.fileSharingURI)
        XCTAssertEqual(content.attachments.map { $0.reference.fileSharingURI }, [added.fileSharingURI])
    }

    func testFileAndDecorationsAreNormalizedForImmediateNativeSend() async throws {
        let service = Service()
        let item = try webScheduledFile()
        let coordinator = makeCoordinator(service)

        try await coordinator.perform(.sendNow, on: item).get()

        let message = try XCTUnwrap(service.payload)
        let parsed = parseReferences(message, primary: "", jid: item.conversation, owner: item.owner)
        let markup = try XCTUnwrap(parsed.first { $0.kind == .markup })
        let body = MessageStorageItem().normalizedIncomingTextBody(from: message)
        XCTAssertEqual(body, "🙂 & bold")
        XCTAssertEqual((body as NSString).substring(with: markup.range), "bold")
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

    private func makeItem(message: XMPPMessage) -> ScheduledMessageListItem {
        ScheduledMessageListItem(
            scheduledId: "first", deliverAt: now.addingTimeInterval(600), status: .pending,
            bodyPreview: message.body ?? "", owner: "alice@example.test", conversation: "bob@example.test",
            conversationType: .regular, messageXML: message.xmlString
        )
    }

    private func uploadedFile(_ url: String) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.isUploaded = true
        reference.url = url
        reference.metadata = ["uri": url, "name": "Photo.jpg", "media-type": "image/jpeg"]
        return reference
    }

    private func webScheduledFile() throws -> ScheduledMessageListItem {
        let message = try XMPPMessage(xmlString: """
            <message xmlns='jabber:client' to='bob@example.test' type='chat'>
              <body>🙂 &amp; bold
            https://files.example.test/a?t=x&amp;value=y</body>
              <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='9' end='13'>
                <bold xmlns='https://xabber.com/protocol/markup'/>
                <link xmlns='https://xabber.com/protocol/markup'>https://example.test/style</link>
              </reference>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='14' end='58'>
                <file-sharing xmlns='https://xabber.com/protocol/files'>
                  <file><name>Photo.jpg</name><media-type>image/jpeg</media-type></file>
                  <sources><uri>https://files.example.test/a?t=x&amp;value=y</uri></sources>
                </file-sharing>
              </reference>
              <custom xmlns='urn:example:future'>retained</custom>
            </message>
            """)
        return makeItem(message: message)
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
            self.payload = payload
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
