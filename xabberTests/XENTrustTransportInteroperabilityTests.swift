import Foundation
import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

/// Real mod_notify wire shape: a bare IQ routes to the server; only the server adds ofrom.
final class XENTrustTransportInteroperabilityTests: XCTestCase {
    private let owner = "owner@example.test"
    private let peer = "peer@example.test/phone"
    private let service = "notifications.example.test"
    private let sid = "AAECAwQFBgcICQoLDA0ODw=="
    private var previousRealm: Realm.Configuration!
    private var previousAccounts: [Account]!
    private var realm: Realm!
    private var account: Account!

    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "XENTrustTransport-\(UUID())")
        realm = try WRealm.safe()
        previousAccounts = AccountManager.shared.users
        account = Account(jid: owner, queue: DispatchQueue(label: "XENTrustTransport"))
        AccountManager.shared.users = previousAccounts + [account]
        account.notifications.node = service
    }

    override func tearDown() {
        account.messages.updateSendingMessagesTimer?.invalidate()
        account.messages.updateSendingMessagesTimer = nil
        AccountManager.shared.users = previousAccounts
        account = nil
        realm = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        super.tearDown()
    }

    private func message(_ xml: String) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPMessage(from: try XCTUnwrap(document.rootElement()))
    }

    private func pendingSession() throws -> VerificationSessionStorageItem {
        let value = VerificationSessionStorageItem()
        value.owner = owner; value.ownerJid = owner
        value.jid = "peer@example.test"; value.peerBareJid = value.jid
        value.sid = sid; value.primary = VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid)
        value.opponentDeviceId = 42; value.remoteDeviceId = 42
        value.fullJID = peer; value.peerFullJid = peer
        value.role = .initiator; value.state = .sentRequest; value.expires = 4_102_444_800
        try realm.write { realm.add(value) }
        return value
    }

    private func deliveredAbort(carrier: String, original: String, inner: String? = nil) throws -> XMPPMessage {
        try message("""
        <message xmlns='jabber:client' from='\(carrier)' to='\(owner)/tablet' id='\(UUID())'>
          <notification xmlns='urn:xabber:xen:0'><forwarded xmlns='urn:xmpp:forward:0'>
            <message xmlns='jabber:client' from='\(inner ?? peer)' to='\(owner)/tablet'>
              <abort xmlns='urn:xabber:trust' session-id='\(sid)' reason='cancel'/>
            </message>
          </forwarded></notification>
          <addresses xmlns='http://jabber.org/protocol/address'><address type='ofrom' jid='\(original)'/></addresses>
        </message>
        """)
    }

    func testOutboundWrapperContainsOnlyOneLogicalRecipientAddress() throws {
        let inner = try message("<message xmlns='jabber:client' from='\(owner)/web' to='\(peer)'><abort xmlns='urn:xabber:trust' session-id='\(sid)' reason='cancel'/></message>")
        let packet = account.notifications.formIQ(to: try XCTUnwrap(XMPPJID(string: peer)), child: inner)
        let notify = try XCTUnwrap(packet.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns))
        let addresses = try XCTUnwrap(notify.element(forName: "addresses", xmlns: "http://jabber.org/protocol/address"))
        let values = addresses.elements(forName: "address")
        XCTAssertEqual(values.count, 1, "mod_notify only accepts one client-supplied to address")
        XCTAssertEqual(values.first?.attributeStringValue(forName: "type"), "to")
        XCTAssertEqual(values.first?.attributeStringValue(forName: "jid"), peer)
        XCTAssertFalse(values.contains { $0.attributeStringValue(forName: "type") == "ofrom" })
    }

    func testOutboundWrapperRoutesToBareServerHandlerAndPreservesFullPayloadTarget() throws {
        let inner = try message("<message xmlns='jabber:client' from='\(owner)/web' to='\(peer)'><abort xmlns='urn:xabber:trust' session-id='\(sid)' reason='cancel'/></message>")
        let originalXML = inner.xmlString
        let packet = account.notifications.formIQ(to: try XCTUnwrap(XMPPJID(string: peer)), child: inner)
        XCTAssertEqual(packet.attributeStringValue(forName: "to"), "peer@example.test")
        let notify = try XCTUnwrap(packet.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns))
        let notification = try XCTUnwrap(notify.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns))
        let forwarded = try XCTUnwrap(notification.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0"))
        let payload = try XCTUnwrap(forwarded.element(forName: "message"))
        XCTAssertEqual(payload.attributeStringValue(forName: "to"), peer)
        XCTAssertEqual(payload.xmlString, originalXML)
        XCTAssertEqual(inner.xmlString, originalXML)
    }

    func testServerAuthoredBareOriginalSenderCancelsPinnedFullResourceSession() throws {
        let session = try pendingSession()
        let handled = account.akeManager.didReceivedVerificationMessage(message: try deliveredAbort(carrier: service, original: "peer@example.test"))
        XCTAssertTrue(handled)
        XCTAssertEqual(session.state, .rejected)
        XCTAssertEqual(session.peerFullJid, peer)
    }

    func testExactOwnServerDomainCanDeliverBareOriginalSender() throws {
        account.notifications.node = nil
        let session = try pendingSession()
        XCTAssertTrue(account.akeManager.didReceivedVerificationMessage(message: try deliveredAbort(carrier: "example.test", original: "peer@example.test")))
        XCTAssertEqual(session.state, .rejected)
    }

    func testPeerCannotForgeNotificationCarrierEvenWithMatchingForwardedSender() throws {
        let session = try pendingSession()
        XCTAssertFalse(account.akeManager.didReceivedVerificationMessage(message: try deliveredAbort(carrier: "attacker@example.test/evil", original: peer)))
        XCTAssertEqual(session.state, .sentRequest)
    }

    func testUnknownNotificationServiceCannotAuthorizeForwardedSender() throws {
        account.notifications.node = nil
        let session = try pendingSession()
        XCTAssertFalse(account.akeManager.didReceivedVerificationMessage(message: try deliveredAbort(carrier: service, original: peer)))
        XCTAssertEqual(session.state, .sentRequest)
    }

    func testConfiguredServiceWithUnexpectedResourceCannotAuthorizeForwardedSender() throws {
        let session = try pendingSession()
        XCTAssertFalse(account.akeManager.didReceivedVerificationMessage(message: try deliveredAbort(carrier: service + "/spoof", original: peer)))
        XCTAssertEqual(session.state, .sentRequest)
    }

    func testServerCarrierCannotHideConflictingFullOriginalResource() throws {
        let session = try pendingSession()
        XCTAssertFalse(account.akeManager.didReceivedVerificationMessage(message: try deliveredAbort(carrier: service, original: "peer@example.test/other")))
        XCTAssertEqual(session.state, .sentRequest)
    }

    func testAuthenticatedCarrierWithInconsistentPinnedInnerResourceAbortsSession() throws {
        let session = try pendingSession()
        XCTAssertTrue(account.akeManager.didReceivedVerificationMessage(message: try deliveredAbort(carrier: service, original: "peer@example.test", inner: "peer@example.test/other")))
        XCTAssertEqual(session.state, .failed)
    }

    func testDirectPinnedPeerDoesNotRequireANotificationService() throws {
        account.notifications.node = nil
        let session = try pendingSession()
        let direct = try message("<message from='\(peer)' to='\(owner)/tablet'><abort xmlns='urn:xabber:trust' session-id='\(sid)' reason='cancel'/></message>")
        XCTAssertTrue(account.akeManager.didReceivedVerificationMessage(message: direct))
        XCTAssertEqual(session.state, .rejected)
    }

    func testArchivedNotificationUsesStoredServiceCarrierAndKeepsInnerFullSender() throws {
        let delivery = try deliveredAbort(carrier: service, original: "peer@example.test")
        let archive = try message("<message from='\(owner)' to='\(owner)/tablet'><result xmlns='urn:xmpp:mam:2' id='archived'><forwarded xmlns='urn:xmpp:forward:0'>\(delivery.xmlString)</forwarded></result></message>")
        let extracted = try XCTUnwrap(XEPTrustForwardedExtractor.trustMessage(from: archive, trustedNotificationSenders: [service], owner: owner))
        XCTAssertEqual(extracted.from?.full, peer)
        XCTAssertEqual(XEPTrustEnvelope.parse(from: extracted)?.sid, sid)
    }

    func testCarbonNotificationUsesStoredServiceCarrierAndKeepsInnerFullSender() throws {
        let delivery = try deliveredAbort(carrier: service, original: "peer@example.test")
        let carbon = try message("<message from='\(owner)' to='\(owner)/tablet'><received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>\(delivery.xmlString)</forwarded></received></message>")
        let extracted = try XCTUnwrap(XEPTrustForwardedExtractor.trustMessage(from: carbon, trustedNotificationSenders: [service], owner: owner))
        XCTAssertEqual(extracted.from?.full, peer)
    }

    func testArchiveCarrierCannotAuthorizeForgedInnerNotificationService() throws {
        let delivery = try deliveredAbort(carrier: "attacker@example.test", original: peer)
        let archive = try message("<message from='\(owner)' to='\(owner)/tablet'><result xmlns='urn:xmpp:mam:2' id='archived'><forwarded xmlns='urn:xmpp:forward:0'>\(delivery.xmlString)</forwarded></result></message>")
        XCTAssertNil(XEPTrustForwardedExtractor.trustMessage(from: archive, trustedNotificationSenders: [service], owner: owner))
    }

    func testExtractorWithoutExplicitCarrierContextCannotAuthorizeXEN() throws {
        XCTAssertNil(XEPTrustForwardedExtractor.trustMessage(from: try deliveredAbort(carrier: service, original: peer)))
    }

    func testPubSubNodeOrServiceResourceIsNotReinterpretedAsNotificationAuthority() {
        for node in ["urn:xabber:xen:0", "notifications.example.test/other", " notifications.example.test"] {
            XCTAssertEqual(XEPTrustForwardedExtractor.notificationSenders(owner: owner, configuredService: node), ["example.test"])
        }
    }

    func testUserOnOwnServerDomainDoesNotInheritServerCarrierAuthority() throws {
        let session = try pendingSession()
        XCTAssertFalse(account.akeManager.didReceivedVerificationMessage(message: try deliveredAbort(carrier: "attacker@example.test", original: peer)))
        XCTAssertEqual(session.state, .sentRequest)
    }

    func testForgedMAMWrapperCannotSupplyAClaimedNotificationService() throws {
        let session = try pendingSession()
        let delivery = try deliveredAbort(carrier: service, original: peer)
        let forged = try message("<message from='attacker@example.test/evil' to='\(owner)/tablet'><result xmlns='urn:xmpp:mam:2' id='fake'><forwarded xmlns='urn:xmpp:forward:0'>\(delivery.xmlString)</forwarded></result></message>")
        XCTAssertFalse(account.akeManager.didReceivedVerificationMessage(message: forged))
        XCTAssertEqual(session.state, .sentRequest)
    }

    func testForgedPriorityWrapperCannotSupplyAClaimedNotificationService() throws {
        let session = try pendingSession()
        let delivery = try deliveredAbort(carrier: service, original: peer)
        let forged = try message("<message from='attacker@example.test/evil' to='\(owner)/tablet'><priority-message xmlns='https://xabber.com/protocol/priority'><forwarded xmlns='urn:xmpp:forward:0'>\(delivery.xmlString)</forwarded></priority-message></message>")
        XCTAssertFalse(account.akeManager.didReceivedVerificationMessage(message: forged))
        XCTAssertEqual(session.state, .sentRequest)
    }

    func testCarbonWrapperCannotDeriveAuthorityFromItsAttackerControlledRecipient() throws {
        let session = try pendingSession()
        let delivery = try deliveredAbort(carrier: service, original: peer)
        let forged = try message("<message from='attacker@example.test' to='attacker@example.test/evil'><received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>\(delivery.xmlString)</forwarded></received></message>")
        XCTAssertFalse(account.akeManager.didReceivedVerificationMessage(message: forged))
        XCTAssertEqual(session.state, .sentRequest)
    }

    func testActualXMPPMessageConstructorKeepsClientNamespaceAfterWireRoundTrip() throws {
        let target = try XCTUnwrap(XMPPJID(string: peer))
        let inner = XMPPMessage(type: "chat", to: target)
        inner.addAttribute(withName: "from", stringValue: owner + "/web")
        inner.addChild(XEPTrustEnvelope.makeTrustElement(sid: sid, expires: 4_102_444_800, kind: .abort(reason: .cancel)))
        XCTAssertTrue(inner.xmlns()?.isEmpty ?? true, "Exercise the actual SDK constructor used by native sendTrustElement")
        let before = inner.xmlString
        let outgoing = account.notifications.formIQ(to: target, child: inner)
        let reparsed = try DDXMLElement(xmlString: outgoing.xmlString)
        let notification = try XCTUnwrap(reparsed.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns)?.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns))
        let forwarded = try XCTUnwrap(notification.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0"))
        let payload = try XCTUnwrap(SCEReceivePolicy.children(of: forwarded, named: "message", xmlns: "jabber:client").first,
            "A native constructor message must not inherit urn:xmpp:forward:0 on the actual wire")
        XCTAssertEqual(payload.attributeStringValue(forName: "to"), peer)
        XCTAssertEqual(payload.attributeStringValue(forName: "from"), owner + "/web")
        XCTAssertNotNil(XEPTrustEnvelope.parse(from: XMPPMessage(from: payload)))
        XCTAssertEqual(inner.xmlString, before, "Transport namespace normalization must not mutate the original message")
    }

    func testExplicitForeignPayloadNamespaceIsNotPromotedToClientMessage() throws {
        let inner = try DDXMLElement(xmlString: "<message xmlns='urn:foreign' from='\(owner)/web' to='\(peer)'/>")
        let outgoing = account.notifications.formIQ(to: try XCTUnwrap(XMPPJID(string: peer)), child: inner)
        let reparsed = try DDXMLElement(xmlString: outgoing.xmlString)
        let notification = try XCTUnwrap(reparsed.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns)?.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns))
        let forwarded = try XCTUnwrap(notification.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0"))
        XCTAssertTrue(SCEReceivePolicy.children(of: forwarded, named: "message", xmlns: "jabber:client").isEmpty)
        XCTAssertEqual(forwarded.element(forName: "message")?.xmlns(), "urn:foreign")
    }
}
