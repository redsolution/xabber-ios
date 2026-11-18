import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class XMPPMessageScheduleManagerTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private var owner: String!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "XMPPMessageScheduleManagerTests-\(name)-\(UUID().uuidString)"
        )
        owner = "romeo-\(UUID().uuidString.lowercased())@example.com"
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
        SettingManager.shared.removeItem(for: owner, scope: .messageSchedule, key: "node")
    }

    override func tearDown() {
        if let owner {
            SettingManager.shared.removeItem(for: owner, scope: .messageSchedule, key: "node")
        }
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        owner = nil
        super.tearDown()
    }

    func testAvailabilityFollowsAuthoritativeDomainDisco() throws {
        let disco = ServerDiscoManager(withOwner: owner)
        let stream = ScheduleCapturingXMPPStream()
        disco.requestServerFeatures(stream)
        let firstQueryID = try XCTUnwrap(
            stream.sentElements.last?.attributeStringValue(forName: "id")
        )

        XCTAssertTrue(disco.read(withIQ: try makeIQ("""
        <iq type='result' from='example.com' id='\(firstQueryID)'>
          <query xmlns='http://jabber.org/protocol/disco#info'>
            <feature var='\(XMPPMessageScheduleManager.namespace)'/>
          </query>
        </iq>
        """)))

        let manager = XMPPMessageScheduleManager(withOwner: owner)
        manager.checkAvailability()
        XCTAssertTrue(manager.isAvailable)
        XCTAssertEqual(
            SettingManager.shared.getKey(for: owner, scope: .messageSchedule, key: "node"),
            XMPPMessageScheduleManager.namespace
        )

        disco.requestServerFeatures(stream)
        let secondQueryID = try XCTUnwrap(
            stream.sentElements.last?.attributeStringValue(forName: "id")
        )

        XCTAssertTrue(disco.read(withIQ: try makeIQ("""
        <iq type='result' from='example.com' id='\(secondQueryID)'>
          <query xmlns='http://jabber.org/protocol/disco#info'>
            <feature var='urn:xmpp:mam:2'/>
          </query>
        </iq>
        """)))

        manager.checkAvailability()
        XCTAssertFalse(manager.isAvailable)
        XCTAssertNil(SettingManager.shared.getKey(for: owner, scope: .messageSchedule, key: "node"))
    }

    func testUnavailableScheduleDoesNotSendStanzaOrQueueOutgoingMessage() throws {
        let manager = XMPPMessageScheduleManager(withOwner: owner)
        let stream = ScheduleCapturingXMPPStream()
        stream.myJID = XMPPJID(string: "\(owner!)/ios")
        let payload = manager.makePlaintextMessagePayload(
            to: "juliet@example.com",
            body: "Later"
        )

        let queryId = manager.scheduleMessage(
            stream,
            conversation: "juliet@example.com",
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 10, hour: 10),
            payload: payload
        )

        XCTAssertNil(queryId)
        XCTAssertTrue(stream.sentElements.isEmpty)
        XCTAssertTrue(manager.queryIds.isEmpty)
        XCTAssertEqual(try WRealm.safe().objects(OutgoingMessageQueueItem.self).count, 0)
    }

    func testScheduleListAndCancelIQWireShape() throws {
        let manager = XMPPMessageScheduleManager(withOwner: owner)
        let deliverAt = makeDate(year: 2026, month: 6, day: 10, hour: 10)
        let payload = manager.makePlaintextMessagePayload(
            to: "juliet@example.com",
            body: "Meet later"
        )

        let scheduleIQ = manager.makeScheduleIQ(
            elementId: "schedule-1",
            conversation: "juliet@example.com",
            conversationType: .regular,
            deliverAt: deliverAt,
            payload: payload
        )

        let schedule = try XCTUnwrap(scheduleIQ.element(forName: "schedule", xmlns: XMPPMessageScheduleManager.namespace))
        let innerMessage = try XCTUnwrap(schedule.element(forName: "message", xmlns: "jabber:client"))
        XCTAssertEqual(scheduleIQ.iqType, .set)
        XCTAssertEqual(scheduleIQ.to?.bare, XMPPJID(string: owner)?.bare)
        XCTAssertEqual(schedule.attributeStringValue(forName: "conversation"), "juliet@example.com")
        XCTAssertEqual(schedule.attributeStringValue(forName: "type"), ClientSynchronizationManager.ConversationType.regular.rawValue)
        XCTAssertEqual(schedule.attributeStringValue(forName: "deliver-at"), "2026-06-10T10:00:00Z")
        XCTAssertEqual(innerMessage.attributeStringValue(forName: "to"), "juliet@example.com")
        XCTAssertEqual(innerMessage.element(forName: "body")?.stringValue, "Meet later")

        let listIQ = try manager.makeListIQ(
            elementId: "list-1",
            conversation: "juliet@example.com",
            conversationType: .regular
        )
        let query = try XCTUnwrap(listIQ.element(forName: "query", xmlns: XMPPMessageScheduleManager.namespace))
        XCTAssertEqual(listIQ.iqType, .get)
        XCTAssertEqual(listIQ.to?.bare, XMPPJID(string: owner)?.bare)
        XCTAssertEqual(query.attributeStringValue(forName: "conversation"), "juliet@example.com")
        XCTAssertEqual(query.attributeStringValue(forName: "type"), ClientSynchronizationManager.ConversationType.regular.rawValue)

        XCTAssertThrowsError(try manager.makeListIQ(
            elementId: "bad-list",
            conversation: "juliet@example.com",
            conversationType: nil
        )) { error in
            XCTAssertEqual(error as? XMPPMessageScheduleManager.ScheduleError, .invalidFilter)
        }

        let cancelIQ = manager.makeCancelIQ(elementId: "cancel-1", scheduledId: "scheduled-1")
        let cancel = try XCTUnwrap(cancelIQ.element(forName: "cancel", xmlns: XMPPMessageScheduleManager.namespace))
        XCTAssertEqual(cancelIQ.iqType, .set)
        XCTAssertEqual(cancelIQ.to?.bare, XMPPJID(string: owner)?.bare)
        XCTAssertEqual(cancel.attributeStringValue(forName: "id"), "scheduled-1")
    }

    func testScheduleResultStoresPendingRowWithoutOutgoingQueue() throws {
        let (manager, stream) = try availableManagerAndStream()
        let payload = manager.makePlaintextMessagePayload(
            to: "juliet@example.com",
            body: "Scheduled body"
        )

        let queryId = try XCTUnwrap(manager.scheduleMessage(
            stream,
            conversation: "juliet@example.com",
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 10, hour: 10),
            payload: payload
        ))

        XCTAssertEqual(stream.sentElements.count, 1)
        XCTAssertEqual(try WRealm.safe().objects(OutgoingMessageQueueItem.self).count, 0)

        XCTAssertTrue(manager.read(withIQ: try makeIQ("""
        <iq type='result' id='\(queryId)'>
          <scheduled xmlns='\(XMPPMessageScheduleManager.namespace)' id='scheduled-1' conversation='juliet@example.com' type='urn:xabber:chat' deliver-at='2026-06-10T10:00:00Z'/>
        </iq>
        """)))

        let stored = try XCTUnwrap(try WRealm.safe().object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "scheduled-1")
        ))
        XCTAssertEqual(stored.status, .pending)
        XCTAssertEqual(stored.conversation, "juliet@example.com")
        XCTAssertEqual(stored.conversationType, .regular)
        XCTAssertTrue(stored.messageXML.contains("Scheduled body"))
    }

    func testListResultParsesStatusesAndReconcilesFullOwnerSet() throws {
        let manager = XMPPMessageScheduleManager(withOwner: owner)
        try seedSchedule(id: "stale-1", conversation: "old@example.com", status: .pending)
        manager.isAvailable = true
        let stream = ScheduleCapturingXMPPStream()
        stream.myJID = XMPPJID(string: "\(owner!)/ios")
        let queryID = try XCTUnwrap(manager.listScheduledMessages(stream))

        XCTAssertTrue(manager.read(withIQ: try makeIQ("""
        <iq type='result' id='\(queryID)'>
          <query xmlns='\(XMPPMessageScheduleManager.namespace)'>
            <scheduled id='pending-1' conversation='juliet@example.com' type='urn:xabber:chat' deliver-at='2026-06-10T10:00:00Z'>
              <message xmlns='jabber:client' to='juliet@example.com' type='chat'><body>Pending</body></message>
            </scheduled>
            <scheduled id='failed-1' conversation='mercutio@example.com' type='urn:xabber:chat' status='failed' deliver-at='2026-06-10T11:00:00.123Z'>
              <message xmlns='jabber:client' to='mercutio@example.com' type='chat'><body>Failed</body></message>
            </scheduled>
          </query>
        </iq>
        """)))

        let realm = try WRealm.safe()
        XCTAssertNil(realm.object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "stale-1")
        ))
        let pending = try XCTUnwrap(realm.object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "pending-1")
        ))
        let failed = try XCTUnwrap(realm.object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "failed-1")
        ))
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(pending.messageXML.contains("Pending"))
        XCTAssertTrue(failed.messageXML.contains("Failed"))
    }

    func testFilteredListReconcilesOnlyRequestedConversation() throws {
        let manager = XMPPMessageScheduleManager(withOwner: owner)
        manager.isAvailable = true
        try seedSchedule(id: "same-filter-stale", conversation: "juliet@example.com", status: .pending)
        try seedSchedule(id: "other-filter", conversation: "mercutio@example.com", status: .pending)
        let stream = ScheduleCapturingXMPPStream()
        stream.myJID = XMPPJID(string: "\(owner!)/ios")

        let queryId = try XCTUnwrap(manager.listScheduledMessages(
            stream,
            conversation: "juliet@example.com",
            conversationType: .regular
        ))

        XCTAssertTrue(manager.read(withIQ: try makeIQ("""
        <iq type='result' id='\(queryId)'>
          <query xmlns='\(XMPPMessageScheduleManager.namespace)'>
            <scheduled id='same-filter-current' conversation='juliet@example.com' type='urn:xabber:chat' deliver-at='2026-06-10T10:00:00Z'/>
            <scheduled id='outside-scope' conversation='mercutio@example.com' type='urn:xabber:chat' deliver-at='2026-06-10T10:00:00Z'/>
          </query>
        </iq>
        """)))

        let realm = try WRealm.safe()
        XCTAssertNil(realm.object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "same-filter-stale")
        ))
        XCTAssertNotNil(realm.object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "same-filter-current")
        ))
        XCTAssertNotNil(try schedule("other-filter"))
        XCTAssertNil(try schedule("outside-scope"))
    }

    func testCancelSuccessAndItemNotFoundRemoveLocalRows() throws {
        let manager = XMPPMessageScheduleManager(withOwner: owner)
        manager.isAvailable = true
        let stream = ScheduleCapturingXMPPStream()
        stream.myJID = XMPPJID(string: "\(owner!)/ios")
        try seedSchedule(id: "cancel-success", conversation: "juliet@example.com", status: .pending)

        let successQueryId = try XCTUnwrap(manager.cancelScheduledMessage(stream, scheduledId: "cancel-success"))
        XCTAssertTrue(manager.read(withIQ: try makeIQ("<iq type='result' id='\(successQueryId)'/>")))
        XCTAssertNil(try WRealm.safe().object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "cancel-success")
        ))

        try seedSchedule(id: "cancel-missing", conversation: "juliet@example.com", status: .pending)
        let errorQueryId = try XCTUnwrap(manager.cancelScheduledMessage(stream, scheduledId: "cancel-missing"))
        XCTAssertTrue(manager.read(withIQ: try makeIQ("""
        <iq type='error' id='\(errorQueryId)'>
          <error type='cancel'>
            <item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
          </error>
        </iq>
        """)))
        XCTAssertNil(try WRealm.safe().object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "cancel-missing")
        ))
    }

    func testHeadlineScheduledCancelledAndFailedNotifications() throws {
        let manager = XMPPMessageScheduleManager(withOwner: owner)

        XCTAssertTrue(manager.read(headline: try makeMessage("""
        <message type='headline' from='example.com'>
          <scheduled xmlns='\(XMPPMessageScheduleManager.namespace)' id='headline-1' conversation='juliet@example.com' type='urn:xabber:chat' deliver-at='2026-06-10T10:00:00Z'>
            <message xmlns='jabber:client' to='juliet@example.com' type='chat'><body>Headline</body></message>
          </scheduled>
        </message>
        """)))
        var stored = try XCTUnwrap(try WRealm.safe().object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "headline-1")
        ))
        XCTAssertEqual(stored.status, .pending)
        XCTAssertTrue(stored.messageXML.contains("Headline"))

        XCTAssertTrue(manager.read(headline: try makeMessage("""
        <message type='headline' from='example.com'>
          <failed xmlns='\(XMPPMessageScheduleManager.namespace)' id='headline-1'/>
        </message>
        """)))
        stored = try XCTUnwrap(try WRealm.safe().object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "headline-1")
        ))
        XCTAssertEqual(stored.status, .failed)

        XCTAssertTrue(manager.read(headline: try makeMessage("""
        <message type='headline' from='example.com'>
          <cancelled xmlns='\(XMPPMessageScheduleManager.namespace)' id='headline-1'/>
        </message>
        """)))
        XCTAssertNil(try WRealm.safe().object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "headline-1")
        ))
    }

    func testDeferredMarkerMetadataAndPendingRemoval() throws {
        let manager = XMPPMessageScheduleManager(withOwner: owner)
        try seedSchedule(id: "deferred-1", conversation: "juliet@example.com", status: .pending)
        try seedSchedule(id: "deferred-failed", conversation: "juliet@example.com", status: .failed)

        let message = try makeMessage("""
        <message from='\(owner!)' to='juliet@example.com' type='chat' id='delivered-1'>
          <body>Delivered</body>
          <deferred xmlns='\(XMPPMessageScheduleManager.namespace)' id='deferred-1' deliver-at='2026-06-10T10:00:00Z'/>
        </message>
        """)
        let storedMessage = MessageStorageItem()
        storedMessage.owner = owner
        storedMessage.opponent = "juliet@example.com"
        storedMessage.outgoing = true

        XCTAssertTrue(XMPPMessageScheduleManager.applyDeferredMetadata(to: storedMessage, source: message))
        let metadata = try XCTUnwrap(storedMessage.systemMetadata?[XMPPMessageScheduleManager.metadataKey] as? [String: String])
        XCTAssertEqual(metadata["id"], "deferred-1")
        XCTAssertEqual(metadata["deliverAt"], "2026-06-10T10:00:00Z")

        manager.reconcileDeliveredScheduleMarkers(from: [storedMessage])
        XCTAssertNil(try WRealm.safe().object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "deferred-1")
        ))

        let failedMessage = MessageStorageItem()
        failedMessage.owner = owner
        failedMessage.opponent = "juliet@example.com"
        failedMessage.outgoing = true
        failedMessage.systemMetadata = [
            XMPPMessageScheduleManager.metadataKey: [
                "id": "deferred-failed",
                "deliverAt": "2026-06-10T10:00:00Z"
            ]
        ]
        manager.reconcileDeliveredScheduleMarkers(from: [failedMessage])
        XCTAssertNotNil(try WRealm.safe().object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "deferred-failed")
        ))
    }

    func testScheduleTimestampParserAcceptsLiteralZAndFractionalForms() throws {
        XCTAssertEqual(
            XMPPMessageScheduleManager.parseTimestamp("2026-06-10T10:00:00Z")?.XMPPFormattedDate,
            "2026-06-10T10:00:00Z"
        )
        XCTAssertEqual(
            XMPPMessageScheduleManager.parseTimestamp("2026-06-10T10:00:00.123Z")?.XMPPFormattedDate,
            "2026-06-10T10:00:00Z"
        )
        XCTAssertEqual(
            XMPPMessageScheduleManager.parseTimestamp("2026-06-10T10:00:00.123+0000")?.XMPPFormattedDate,
            "2026-06-10T10:00:00Z"
        )
    }

    func testWrongSenderDoesNotConsumeRequestAndWrongResultShapeCompletesOnlyOnce() throws {
        let (manager, stream) = try availableManagerAndStream()
        try seedSchedule(id: "pending", conversation: "juliet@example.com", status: .pending)
        var errors = [XMPPMessageScheduleManager.ScheduleError]()
        let id = try XCTUnwrap(manager.cancelScheduledMessage(stream, scheduledId: "pending") { result in
            if case .failure(let error) = result { errors.append(error) }
        })

        XCTAssertFalse(manager.read(withIQ: try makeIQ("<iq type='result' id='\(id)' from='juliet@example.com'/>")))
        XCTAssertFalse(manager.read(withIQ: try makeIQ("<iq type='result' id='\(id)' from='\(owner!)/other'/>")))
        XCTAssertFalse(manager.read(withIQ: try makeIQ("<iq type='result' id='\(id)' from='\(owner!)' to='\(owner!)/other'/>")))
        XCTAssertTrue(errors.isEmpty)
        let wrongShape = try makeIQ("""
        <iq type='result' id='\(id)' from='\(owner!)'>
          <query xmlns='\(XMPPMessageScheduleManager.namespace)'/>
        </iq>
        """)
        XCTAssertTrue(manager.read(withIQ: wrongShape))
        XCTAssertFalse(manager.read(withIQ: wrongShape))
        XCTAssertEqual(errors, [.invalidResponse])
        XCTAssertNotNil(try schedule("pending"))
    }

    func testTimedOutListCompletesOnlyOnceAndIgnoresLateResult() throws {
        let (manager, stream) = try availableManagerAndStream()
        manager.requestTimeout = 0.01
        let completed = expectation(description: "List timeout")
        let id = try XCTUnwrap(manager.listScheduledMessages(stream) { result in
            XCTAssertEqual(result, .failure(.timeout))
            completed.fulfill()
        })

        wait(for: [completed], timeout: 2)
        XCTAssertTrue(manager.queryIds.isEmpty)
        XCTAssertFalse(manager.read(withIQ: try listResponse(id: id, entries: "")))
        manager.clearSession()
    }

    func testSessionResetCompletesTrackedOperationsAndIgnoresLateResult() throws {
        let (manager, stream) = try availableManagerAndStream()
        var errors = [XMPPMessageScheduleManager.ScheduleError]()
        let id = try XCTUnwrap(manager.listScheduledMessages(stream) { result in
            if case .failure(let error) = result { errors.append(error) }
        })
        _ = manager.cancelScheduledMessage(stream, scheduledId: "pending") { result in
            if case .failure(let error) = result { errors.append(error) }
        }

        manager.clearSession()
        manager.clearSession()
        XCTAssertEqual(errors, [.disconnected, .disconnected])
        XCTAssertFalse(manager.read(withIQ: try listResponse(id: id, entries: "")))
    }

    func testStaleSnapshotPreservesNewHeadlineAndDoesNotResurrectCancelledEntry() throws {
        let (manager, stream) = try availableManagerAndStream()
        try seedSchedule(id: "cancelled", conversation: "juliet@example.com", status: .pending)
        try seedSchedule(id: "failed", conversation: "juliet@example.com", status: .pending)
        try seedSchedule(id: "unrelated", conversation: "juliet@example.com", status: .pending)
        let id = try XCTUnwrap(manager.listScheduledMessages(stream))
        let ns = XMPPMessageScheduleManager.namespace

        XCTAssertTrue(manager.read(headline: try makeMessage("""
        <message type='headline' from='\(owner!)'>
          <cancelled xmlns='\(ns)' id='cancelled'/>
        </message>
        """)))
        XCTAssertTrue(manager.read(headline: try makeMessage("""
        <message type='headline' from='\(owner!)'>
          <failed xmlns='\(ns)' id='failed'/>
        </message>
        """)))
        XCTAssertTrue(manager.read(headline: try makeMessage("""
        <message type='headline' from='\(owner!)'>
          <scheduled xmlns='\(ns)' id='fresh' conversation='juliet@example.com' type='urn:xabber:chat' deliver-at='2026-06-10T10:00:00Z'/>
        </message>
        """)))
        XCTAssertTrue(manager.read(withIQ: try listResponse(id: id, entries: listEntry("cancelled") + listEntry("failed"))))

        XCTAssertNil(try schedule("cancelled"))
        XCTAssertEqual(try schedule("failed")?.status, .failed)
        XCTAssertNotNil(try schedule("fresh"))
        XCTAssertNil(try schedule("unrelated"))
    }

    func testOlderFullSnapshotDoesNotOverwriteNewerFilteredScope() throws {
        let (manager, stream) = try availableManagerAndStream()
        let full = try XCTUnwrap(manager.listScheduledMessages(stream))
        let filter = try XCTUnwrap(manager.listScheduledMessages(
            stream, conversation: "juliet@example.com", conversationType: .regular
        ))

        XCTAssertTrue(manager.read(withIQ: try listResponse(id: filter, entries: "")))
        let entries = listEntry("stale") + listEntry("other", conversation: "mercutio@example.com")
        XCTAssertTrue(manager.read(withIQ: try listResponse(id: full, entries: entries)))

        XCTAssertNil(try schedule("stale"))
        XCTAssertNotNil(try schedule("other"))
    }

    func testInvalidListDoesNotReplaceLocalRows() throws {
        let (manager, stream) = try availableManagerAndStream()
        try seedSchedule(id: "pending", conversation: "juliet@example.com", status: .pending)
        var result: Result<[XMPPMessageScheduleManager.ScheduledEntry], XMPPMessageScheduleManager.ScheduleError>?
        let id = try XCTUnwrap(manager.listScheduledMessages(stream) { result = $0 })

        XCTAssertTrue(manager.read(withIQ: try listResponse(id: id, entries: "<scheduled id='invalid'/>")))
        XCTAssertEqual(result, .failure(.invalidResponse))
        XCTAssertNotNil(try schedule("pending"))
    }

    func testHeadlineFromAnotherAccountCannotCancelOwnEntry() throws {
        let manager = XMPPMessageScheduleManager(withOwner: owner)
        try seedSchedule(id: "pending", conversation: "juliet@example.com", status: .pending)
        XCTAssertFalse(manager.read(headline: try makeMessage("""
        <message type='headline' from='juliet@example.com' to='\(owner!)'>
          <cancelled xmlns='\(XMPPMessageScheduleManager.namespace)' id='pending'/>
        </message>
        """)))
        XCTAssertNotNil(try schedule("pending"))
    }

    func testOnlyMatchingOutgoingDeliveryRemovesPendingRowAndProtectsFromSnapshot() throws {
        let (manager, stream) = try availableManagerAndStream()
        try seedSchedule(id: "pending", conversation: "juliet@example.com", status: .pending)
        let id = try XCTUnwrap(manager.listScheduledMessages(stream))
        let message = MessageStorageItem()
        message.owner = owner
        message.opponent = "juliet@example.com"
        message.systemMetadata = [XMPPMessageScheduleManager.metadataKey: [
            "id": "pending",
            "deliverAt": "2026-06-10T10:00:00Z"
        ]]

        manager.reconcileDeliveredScheduleMarkers(from: [message])
        XCTAssertNotNil(try schedule("pending"))
        message.outgoing = true
        message.opponent = "mercutio@example.com"
        manager.reconcileDeliveredScheduleMarkers(from: [message])
        XCTAssertNotNil(try schedule("pending"))
        message.opponent = "juliet@example.com"
        message.conversationType = .group
        manager.reconcileDeliveredScheduleMarkers(from: [message])
        XCTAssertNotNil(try schedule("pending"))
        message.conversationType = .regular
        manager.reconcileDeliveredScheduleMarkers(from: [message])

        XCTAssertTrue(manager.read(withIQ: try listResponse(id: id, entries: listEntry("pending"))))
        XCTAssertNil(try schedule("pending"))
    }

    func testAutomaticListRefreshUsesCapabilityAndRunsOncePerSession() throws {
        let (manager, stream) = try availableManagerAndStream()
        stream.authenticated = true
        manager.isAvailable = false
        manager.requestSessionRefresh()
        manager.refreshScheduledMessages(stream)
        XCTAssertTrue(stream.sentElements.isEmpty)

        manager.isAvailable = true
        manager.refreshScheduledMessages(stream)
        manager.refreshScheduledMessages(stream)
        XCTAssertEqual(stream.sentElements.count, 1)
        let id = try XCTUnwrap(stream.sentElements.last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(manager.read(withIQ: try listResponse(id: id, entries: "")))
        manager.refreshScheduledMessages(stream)
        XCTAssertEqual(stream.sentElements.count, 1)

        manager.clearSession()
        manager.refreshScheduledMessages(stream)
        XCTAssertEqual(stream.sentElements.count, 1)
        manager.requestSessionRefresh()
        manager.refreshScheduledMessages(stream)
        XCTAssertEqual(stream.sentElements.count, 2)
        manager.clearSession()
    }

    func testGroupScheduleUsesBareConversationAndSuppressesCarbonsForInnerPayload() throws {
        let (manager, stream) = try availableManagerAndStream()
        let group = "group@groups.example.com"
        XCTAssertNotNil(manager.schedulePlaintextMessage(
            stream, conversation: group, conversationType: .group,
            deliverAt: Date(timeIntervalSinceNow: 3600), body: "Later"
        ))
        let request = try XCTUnwrap(stream.sentElements.first?.element(forName: "schedule", xmlns: XMPPMessageScheduleManager.namespace))
        let message = try XCTUnwrap(request.element(forName: "message", xmlns: "jabber:client"))
        XCTAssertEqual(request.attributeStringValue(forName: "conversation"), group)
        XCTAssertEqual(request.attributeStringValue(forName: "type"), ClientSynchronizationManager.ConversationType.group.rawValue)
        XCTAssertEqual(message.attributeStringValue(forName: "to"), group)
        XCTAssertEqual(message.attributeStringValue(forName: "type"), "chat")
        XCTAssertNotNil(message.element(forName: "private", xmlns: "urn:xmpp:carbons:2"))
        manager.clearSession()
    }

    func testReplacingPrimaryStreamPreventsOldScheduleIQFromTransmitting() throws {
        let account = Account(jid: owner, queue: DispatchQueue(label: owner))
        let old = ScheduleCapturingXMPPStream()
        let replacement = ScheduleCapturingXMPPStream()
        [old, replacement].forEach {
            $0.authenticated = true
            $0.myJID = XMPPJID(string: "\(owner!)/ios")
        }
        account.xmppStream = old
        account.sendReadiness.markStreamManagementEnabled()
        account.messageSchedule.isAvailable = true
        AccountManager.shared.users.append(account)
        defer {
            account.messageSchedule.clearSession()
            AccountManager.shared.users.removeAll { $0 === account }
        }

        let id = try XCTUnwrap(account.messageSchedule.listScheduledMessages(old))
        let request = try XCTUnwrap(old.sentElements.last as? XMPPIQ)
        XCTAssertEqual(request.elementID, id)
        account.xmppStream = replacement

        XCTAssertNil(account.xmppStream(old, willSend: request))
        var error: XMPPMessageScheduleManager.ScheduleError?
        XCTAssertNil(account.messageSchedule.listScheduledMessages(old) { result in
            if case .failure(let failure) = result { error = failure }
        })
        XCTAssertEqual(error, .sendRejected)
        XCTAssertEqual(old.sentElements.count, 1)
        XCTAssertTrue(replacement.sentElements.isEmpty)
    }

    func testScheduleWireTimestampUsesGregorianUTCForDateChosenInAnotherCalendar() throws {
        let manager = XMPPMessageScheduleManager(withOwner: owner)
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 7 * 3600))
        let local = DateComponents(year: 2569, month: 6, day: 11, hour: 2, minute: 15, second: 4)
        let selected = try XCTUnwrap(calendar.date(from: local))
        let payload = manager.makePlaintextMessagePayload(to: "juliet@example.com", body: "Later")
        let iq = manager.makeScheduleIQ(elementId: "date",
            conversation: "juliet@example.com", conversationType: .regular,
            deliverAt: selected, payload: payload)

        let schedule = try XCTUnwrap(iq.element(forName: "schedule", xmlns: XMPPMessageScheduleManager.namespace))
        XCTAssertEqual(schedule.attributeStringValue(forName: "deliver-at"), "2026-06-10T19:15:04Z")
    }

    private func availableManagerAndStream() throws -> (XMPPMessageScheduleManager, ScheduleCapturingXMPPStream) {
        let manager = XMPPMessageScheduleManager(withOwner: owner)
        manager.omemo2OptOutStorage = try XabberOMEMO2Storage(owner: owner, persistence: EmptyScheduleOptOutPersistence())
        manager.isAvailable = true
        let stream = ScheduleCapturingXMPPStream()
        stream.myJID = XMPPJID(string: "\(owner!)/ios")
        return (manager, stream)
    }

    private func schedule(_ id: String) throws -> XMPPMessageScheduleStorageItem? {
        try WRealm.safe().object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: id)
        )
    }

    private func listEntry(_ id: String, conversation: String = "juliet@example.com") -> String {
        "<scheduled id='\(id)' conversation='\(conversation)' type='urn:xabber:chat' deliver-at='2026-06-10T10:00:00Z'/>"
    }

    private func listResponse(id: String, entries: String) throws -> XMPPIQ {
        try makeIQ("""
        <iq type='result' id='\(id)'>
          <query xmlns='\(XMPPMessageScheduleManager.namespace)'>\(entries)</query>
        </iq>
        """)
    }

    private func seedSchedule(
        id: String,
        conversation: String,
        status: XMPPMessageScheduleStorageItem.Status
    ) throws {
        let item = XMPPMessageScheduleStorageItem()
        item.configure(
            owner: owner,
            scheduledId: id,
            conversation: conversation,
            conversationType: .regular,
            deliverAt: makeDate(year: 2026, month: 6, day: 10, hour: 10),
            status: status,
            messageXML: ""
        )
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(item, update: .modified)
        }
    }

    private func makeIQ(_ xml: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func makeMessage(_ xml: String) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPMessage(from: try XCTUnwrap(document.rootElement()))
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }
}

private final class ScheduleCapturingXMPPStream: XMPPStream {
    private(set) var sentElements: [DDXMLElement] = []
    var authenticated = false
    override var isAuthenticated: Bool { authenticated }

    override func send(_ element: DDXMLElement) {
        if let copy = element.copy() as? DDXMLElement {
            sentElements.append(copy)
        } else {
            sentElements.append(element)
        }
    }
}

private struct EmptyScheduleOptOutPersistence: OMEMO2StatePersistence {
    func load(owner: String) throws -> Data? { nil }
    func save(_ data: Data, owner: String) throws {}
    func remove(owner: String) throws {}
}
