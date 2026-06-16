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
        owner = "romeo-\(UUID().uuidString)@example.com"
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
        disco.queryIds.insert("domain-feature-1")
        disco.serverFeatureQueryIds.insert("domain-feature-1")

        XCTAssertTrue(disco.read(withIQ: try makeIQ("""
        <iq type='result' from='example.com' id='domain-feature-1'>
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

        disco.queryIds.insert("domain-feature-2")
        disco.serverFeatureQueryIds.insert("domain-feature-2")

        XCTAssertTrue(disco.read(withIQ: try makeIQ("""
        <iq type='result' from='example.com' id='domain-feature-2'>
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
        let manager = XMPPMessageScheduleManager(withOwner: owner)
        manager.isAvailable = true
        let stream = ScheduleCapturingXMPPStream()
        stream.myJID = XMPPJID(string: "\(owner!)/ios")
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
        manager.queryIds.insert("list-1")

        XCTAssertTrue(manager.read(withIQ: try makeIQ("""
        <iq type='result' id='list-1'>
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
        XCTAssertNotNil(realm.object(
            ofType: XMPPMessageScheduleStorageItem.self,
            forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: "other-filter")
        ))
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
        <message from='juliet@example.com' to='\(owner!)' type='chat' id='delivered-1'>
          <body>Delivered</body>
          <deferred xmlns='\(XMPPMessageScheduleManager.namespace)' id='deferred-1' deliver-at='2026-06-10T10:00:00Z'/>
        </message>
        """)
        let storedMessage = MessageStorageItem()
        storedMessage.owner = owner

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

    override func send(_ element: DDXMLElement) {
        if let copy = element.copy() as? DDXMLElement {
            sentElements.append(copy)
        } else {
            sentElements.append(element)
        }
    }
}
