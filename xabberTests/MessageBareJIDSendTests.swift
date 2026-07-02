import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class MessageBareJIDSendTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "MessageBareJIDSendTests-\(name)-\(UUID().uuidString)"
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

    func testRegularTextSendWithFullJIDStoresAndQueuesBareDestination() throws {
        let owner = "owner@example.test"
        let fullContactJID = "contact@example.test/iPhone"
        let bareContactJID = "contact@example.test"
        let manager = MessageManager(withOwner: owner, activeStream: false)
        defer {
            manager.updateSendingMessagesTimer?.invalidate()
            manager.updateSendingMessagesTimer = nil
        }

        let originId = manager.sendSimpleMessage(
            "Hello",
            to: fullContactJID,
            forwarded: [],
            conversationType: .regular
        )

        let realm = try WRealm.safe()
        let message = try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: MessageStorageItem.genPrimary(messageId: originId, owner: owner)
        ))
        XCTAssertEqual(message.opponent, bareContactJID)
        XCTAssertEqual(message.state, .sending)
        XCTAssertEqual(message.body, "Hello")

        let queueItem = try XCTUnwrap(
            realm.objects(OutgoingMessageQueueItem.self)
                .filter("owner == %@ AND originId == %@", owner, originId)
                .first
        )
        XCTAssertEqual(queueItem.conversationJid, bareContactJID)

        let storedStanza = try XCTUnwrap(realm.object(
            ofType: MessageStanzaStorageItem.self,
            forPrimaryKey: "\(message.primary)_stanza"
        ))
        let stanza = try makeMessage(from: storedStanza.stanza)
        XCTAssertEqual(stanza.to?.bare, bareContactJID)
        XCTAssertNil(stanza.to?.resource)
    }

    func testRegularTextSendWithBareJIDKeepsBareDestination() throws {
        let owner = "owner@example.test"
        let bareContactJID = "contact@example.test"
        let manager = MessageManager(withOwner: owner, activeStream: false)
        defer {
            manager.updateSendingMessagesTimer?.invalidate()
            manager.updateSendingMessagesTimer = nil
        }

        let originId = manager.sendSimpleMessage(
            "Hello",
            to: bareContactJID,
            forwarded: [],
            conversationType: .regular
        )

        let realm = try WRealm.safe()
        let message = try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: MessageStorageItem.genPrimary(messageId: originId, owner: owner)
        ))
        XCTAssertEqual(message.opponent, bareContactJID)

        let storedStanza = try XCTUnwrap(realm.object(
            ofType: MessageStanzaStorageItem.self,
            forPrimaryKey: "\(message.primary)_stanza"
        ))
        let stanza = try makeMessage(from: storedStanza.stanza)
        XCTAssertEqual(stanza.to?.bare, bareContactJID)
        XCTAssertNil(stanza.to?.resource)
    }

    func testRegularReplayCanonicalizesLegacyFullJIDQueueDestination() throws {
        let recorder = MessageBareJIDSendRecorder()
        let coordinator = AccountSendCoordinator(
            environment: AccountSendCoordinator.Environment(
                owner: "owner@example.test",
                isSendReady: { true },
                decorateMessage: { message, _, _ in message },
                sendMessage: { message in
                    recorder.sentMessages.append(message.copy() as! XMPPMessage)
                },
                log: { _, _ in }
            )
        )

        try coordinator.enqueueRegularMessage(AccountQueuedMessageSendRequest(
            owner: "owner@example.test",
            conversationJid: "contact@example.test/iPhone",
            conversationType: .regular,
            messagePrimary: MessageStorageItem.genPrimary(messageId: "message-1", owner: "owner@example.test"),
            originId: "message-1",
            stanzaXML: """
            <message type='chat' to='contact@example.test/iPhone' id='message-1' from='owner@example.test'>
              <body>Hello</body>
              <origin-id xmlns='urn:xmpp:sid:0' id='message-1'/>
            </message>
            """,
            createdAt: Date(timeIntervalSince1970: 1),
            replayRequired: true
        ))

        let message = try XCTUnwrap(recorder.sentMessages.first)
        XCTAssertEqual(message.to?.bare, "contact@example.test")
        XCTAssertNil(message.to?.resource)
    }

    private func makeMessage(from xml: String) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        let root = try XCTUnwrap(document.rootElement())
        return XMPPMessage(from: root)
    }
}

private final class MessageBareJIDSendRecorder {
    var sentMessages: [XMPPMessage] = []
}
