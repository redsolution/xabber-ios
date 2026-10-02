import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

final class OMEMO2ReceiveRoutingTests: XCTestCase {
    private let owner = "sce-owner@example.test"
    private let peer = "sce-peer@example.test"
    private var previousConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "OMEMO2ReceiveRoutingTests-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousConfiguration
        super.tearDown()
    }

    func testRawEncryptedQueueCannotGainAuthenticationFromWireSuccessMarker() throws {
        let manager = receiver()
        manager.receiveRuntime(try incoming(extra: """
          <omemo-result__system result='true'/>
          <ephemeral xmlns='urn:xmpp:ephemeral:0' timer='600'/>
          <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='0' end='6'>
            <bold xmlns='https://xabber.com/protocol/markup'/>
          </reference>
        """))

        let item = try queued(manager)
        XCTAssertEqual(item.encryption, .unverifiedOMEMO)
        XCTAssertNil(item.message.element(forName: "omemo-result__system"))
        XCTAssertNil(item.message.element(forName: "body"))
        XCTAssertNil(item.message.element(forName: "reference"))
        XCTAssertNil(item.message.element(forName: "ephemeral"))
        let stored = try materialized(item, manager: manager)
        XCTAssertEqual(stored.messageError, "omemo")
        XCTAssertFalse(stored.incomingEncryption.isAuthenticated)
        XCTAssertEqual(stored.afterburnInterval, 0)
        XCTAssertTrue(stored.references.isEmpty)
    }

    func testFailedDecryptCannotBeOverriddenByExternalTimeSignature() throws {
        let manager = receiver()
        manager.receiveRuntime(try incoming(extra: """
          <time-signature xmlns='urn:xmpp:x509:0'/>
          <omemo-result__system result='true'/>
        """), encryption: .failedOMEMO)

        let item = try queued(manager)
        XCTAssertEqual(item.encryption, .failedOMEMO)
        XCTAssertNil(item.message.element(forName: "time-signature"))
        let stored = try materialized(item, manager: manager)
        XCTAssertEqual(stored.messageError, "omemo")
        XCTAssertEqual(stored.incomingEncryption, .failedOMEMO)
    }

    func testAuthenticatedRuntimeProvenanceReachesMaterializationWithoutXMLMarker() throws {
        let manager = receiver()
        manager.receiveRuntime(try incoming(), encryption: .authenticatedSCE(profile: .omemo2))

        let item = try queued(manager)
        XCTAssertTrue(item.encryption.isAuthenticated)
        XCTAssertNil(item.message.element(forName: "omemo-result__system"))
        let stored = try materialized(item, manager: manager)
        XCTAssertEqual(stored.body, "inside")
        XCTAssertNotEqual(stored.messageError, "omemo")
        XCTAssertEqual(stored.incomingEncryption, .authenticatedSCE(profile: .omemo2))
        XCTAssertEqual(stored.conversationType, .omemo)
    }

    func testAuthenticatedArchiveRetainsProvenanceAndArchiveIdentity() throws {
        let manager = receiver()
        manager.receiveArchived(try archive(), encryption: .authenticatedSCE(profile: .omemo2))

        let item = try queued(manager)
        XCTAssertEqual(item.encryption, .authenticatedSCE(profile: .omemo2))
        XCTAssertEqual(item.queryId, "sce-query")
        XCTAssertEqual(item.mamResultID, "sce-result")
        XCTAssertEqual(item.message.from?.bare, peer)
        let stored = try materialized(item, manager: manager)
        XCTAssertEqual(stored.body, "inside")
        XCTAssertEqual(stored.mamArchiveId, "sce-result")
        XCTAssertNotEqual(stored.messageError, "omemo")
    }

    func testAuthenticatedSentCarbonRetainsProvenanceAcrossXMLCopy() throws {
        let manager = receiver()
        manager.receiveCarbon(try carbon(sent: true), encryption: .authenticatedSCE(profile: .omemo2))

        let item = try queued(manager)
        XCTAssertTrue(item.encryption.isAuthenticated)
        XCTAssertEqual(item.message.from?.bare, owner)
        XCTAssertEqual(try materialized(item, manager: manager).body, "inside")
    }

    func testAuthenticatedReceivedCarbonRetainsProvenanceAcrossXMLCopy() throws {
        let manager = receiver()
        manager.receiveCarbonForwarded(try carbon(sent: false), encryption: .authenticatedSCE(profile: .omemo2))

        let item = try queued(manager)
        XCTAssertTrue(item.encryption.isAuthenticated)
        XCTAssertEqual(item.message.from?.bare, peer)
        XCTAssertEqual(try materialized(item, manager: manager).body, "inside")
    }

    func testDirectUnverifiedArchiveCannotPersistOuterPlaintext() throws {
        let manager = receiver()
        manager.receiveArchived(try archive())

        let item = try queued(manager)
        XCTAssertEqual(item.encryption, .unverifiedOMEMO)
        XCTAssertNil(item.message.element(forName: "body"))
        XCTAssertEqual(try materialized(item, manager: manager).messageError, "omemo")
    }

    func testLegacyAuthenticatedHistoryPreservesItsProvenance() throws {
        let manager = receiver()
        manager.receiveRuntime(try incoming(), encryption: .authenticatedSCE(profile: .legacySignal))

        let stored = try materialized(queued(manager), manager: manager)
        XCTAssertEqual(stored.body, "inside")
        XCTAssertEqual(stored.incomingEncryption, .authenticatedSCE(profile: .legacySignal))
        XCTAssertNotEqual(stored.messageError, "omemo")
    }

    func testPlaintextMessageAndForeignEncryptedLookalikeRemainPlaintext() throws {
        let manager = receiver()
        let message = try xml("""
          <message xmlns='jabber:client' from='\(peer)' to='\(owner)' type='chat' id='plain'>
            <body>plain</body><encrypted xmlns='urn:foreign:test'/>
          </message>
        """)
        manager.receiveRuntime(message)

        let item = try queued(manager)
        XCTAssertEqual(item.encryption, .plaintext)
        XCTAssertEqual(item.message.body, "plain")
        XCTAssertFalse(try materialized(item, manager: manager).incomingEncryption.isEncrypted)
    }

    func testQueueIdentityDistinguishesAuthenticatedAndUnverifiedContent() throws {
        let message = try incoming()
        let date = Date(timeIntervalSince1970: 100)
        func item(_ encryption: MessageEncryptionProvenance) -> MessageManager.MessageQueueItem {
            MessageManager.MessageQueueItem(message, messageId: "sce-message", archivedFrom: nil,
                isRead: false, date: date, state: .deliver, queryId: nil, encryption: encryption)
        }

        XCTAssertNotEqual(item(.authenticatedSCE(profile: .omemo2)), item(.unverifiedOMEMO))
        XCTAssertNotEqual(item(.authenticatedSCE(profile: .omemo2)), item(.authenticatedSCE(profile: .legacySignal)))
    }

    func testSearchMaterializationUsesAuthenticatedProvenance() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let delivered = expectation(description: "verified search row")
        installSearchCallback(manager) { item in
            XCTAssertEqual(item.body, "inside")
            XCTAssertNotEqual(item.messageError, "omemo")
            XCTAssertEqual(item.incomingEncryption, .authenticatedSCE(profile: .omemo2))
            delivered.fulfill()
        }

        XCTAssertTrue(manager.readMessage(try archive(), encryption: .authenticatedSCE(profile: .omemo2)))
        wait(for: [delivered], timeout: 2)
    }

    func testSearchMaterializationRejectsWireAuthenticationAndOuterTTL() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let delivered = expectation(description: "unverified search row")
        installSearchCallback(manager) { item in
            XCTAssertEqual(item.messageError, "omemo")
            XCTAssertFalse(item.incomingEncryption.isAuthenticated)
            XCTAssertEqual(item.afterburnInterval, 0)
            XCTAssertTrue(item.references.isEmpty)
            delivered.fulfill()
        }
        let wrapped = try archive()
        let inner = try XCTUnwrap(wrapped.element(forName: "result")?
            .element(forName: "forwarded")?.element(forName: "message"))
        let marker = DDXMLElement(name: "omemo-result__system")
        marker.addAttribute(withName: "result", stringValue: "true")
        inner.addChild(marker)
        let ttl = DDXMLElement(name: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")
        ttl.addAttribute(withName: "timer", stringValue: "600")
        inner.addChild(ttl)

        XCTAssertTrue(manager.readMessage(wrapped))
        wait(for: [delivered], timeout: 2)
    }

    func testAuthenticatedFavoritesPreservesProfileOutsideXML() throws {
        let favorites = XMPPFavoritesManager(withOwner: owner)
        let message = try savedMessage()
        let stored = try XCTUnwrap(favorites.receiveSaved(message: message,
            realm: WRealm.safe(), commitTransaction: true,
            favoritesNodeOverride: "favorites.example.test",
            encryption: .authenticatedSCE(profile: .omemo2)))

        XCTAssertEqual(stored.body, "inside")
        XCTAssertEqual(stored.conversationType, .saved)
        XCTAssertEqual(stored.incomingEncryption, .authenticatedSCE(profile: .omemo2))
        XCTAssertNil(stored.originalStanza?.element(forName: "omemo-result__system"))
    }

    func testUnverifiedFavoritesDoesNotInterpretOuterBodyOrReferences() throws {
        let favorites = XMPPFavoritesManager(withOwner: owner)
        let message = try savedMessage()
        let marker = DDXMLElement(name: "omemo-result__system")
        marker.addAttribute(withName: "result", stringValue: "true")
        message.addChild(marker)
        let ttl = DDXMLElement(name: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")
        ttl.addAttribute(withName: "timer", stringValue: "600")
        message.addChild(ttl)
        let stored = try XCTUnwrap(favorites.receiveSaved(message: message,
            realm: WRealm.safe(), commitTransaction: true,
            favoritesNodeOverride: "favorites.example.test"))

        XCTAssertEqual(stored.body, "")
        XCTAssertEqual(stored.messageError, "omemo")
        XCTAssertFalse(stored.incomingEncryption.isAuthenticated)
        XCTAssertTrue(stored.incomingEncryption.isEncrypted)
        XCTAssertLessThanOrEqual(stored.afterburnInterval, 0, "Unverified wire TTL must never activate deletion")
        XCTAssertTrue(stored.references.isEmpty)
        XCTAssertNil(stored.originalStanza?.element(forName: "ephemeral"))
    }

    func testPlaintextFavoritesKeepsExistingSavedSemantics() throws {
        let favorites = XMPPFavoritesManager(withOwner: owner)
        let message = try savedMessage()
        message.element(forName: "encrypted")?.detach()
        let stored = try XCTUnwrap(favorites.receiveSaved(message: message,
            realm: WRealm.safe(), commitTransaction: true,
            favoritesNodeOverride: "favorites.example.test"))

        XCTAssertEqual(stored.body, "inside")
        XCTAssertEqual(stored.conversationType, .saved)
        XCTAssertEqual(stored.incomingEncryption, .plaintext)
    }

    func testPrefixedMAMResultsKeepDeliveryConsumptionAndRoutingAccounting() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        installSearchCallback(manager) { _ in }
        let message = try xml("""
          <message xmlns='jabber:client' from='\(owner)' to='\(owner)'>
            <m:result xmlns:m='urn:xmpp:mam:2' queryid='sce-query' id='prefixed-result'>
              <f:forwarded xmlns:f='urn:xmpp:forward:0'>
                <delay xmlns='urn:xmpp:delay' stamp='2026-10-02T10:00:00Z'/>
                \(try incoming().xmlString)
              </f:forwarded>
            </m:result>
          </message>
        """)

        XCTAssertTrue(manager.recordDeferredArchiveResultDelivery(message))
        XCTAssertTrue(manager.recordDeferredArchiveControlConsumption(message))
        XCTAssertTrue(manager.recordDeferredArchivePersistenceRouting(message))
    }

    func testVoIPIngressCannotInterpretUnverifiedEncryptedAcceptOrReject() throws {
        let message = try incoming(extra: """
          <accept xmlns='urn:xmpp:jingle-message:0' id='call-id'/>
          <reject xmlns='urn:xmpp:jingle-message:0' id='call-id'/>
          <omemo-result__system result='true'/>
        """)

        let payload = try XCTUnwrap(VoIPCall.unwrapIncomingMessage(message))

        XCTAssertNil(payload.message.element(forName: "accept", xmlns: VoIPCall.namespace))
        XCTAssertNil(payload.message.element(forName: "reject", xmlns: VoIPCall.namespace))
        XCTAssertNil(payload.message.element(forName: "omemo-result__system"))
        XCTAssertTrue(SCEReceivePolicy.hasOMEMO2(payload.message))
    }

    func testVoIPDirectForwardCannotInterpretUnverifiedEncryptedLeaf() throws {
        let message = try xml("""
          <message xmlns='jabber:client' from='\(peer)' to='\(owner)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              \(try incoming(extra: "<reject xmlns='urn:xmpp:jingle-message:0' id='call-id'/>").xmlString)
            </forwarded>
          </message>
        """)

        let payload = try XCTUnwrap(VoIPCall.unwrapIncomingMessage(message))

        XCTAssertNil(payload.message.element(forName: "reject", xmlns: VoIPCall.namespace))
        XCTAssertTrue(SCEReceivePolicy.hasOMEMO2(payload.message))
    }

    func testVoIPPlaintextDirectForwardKeepsExistingCallControl() throws {
        let leaf = try incoming(extra: "<reject xmlns='urn:xmpp:jingle-message:0' id='call-id'/>")
        leaf.element(forName: "encrypted")?.detach()
        let message = try xml("""
          <message xmlns='jabber:client' from='\(peer)' to='\(owner)'>
            <forwarded xmlns='urn:xmpp:forward:0'>\(leaf.xmlString)</forwarded>
          </message>
        """)

        let payload = try XCTUnwrap(VoIPCall.unwrapIncomingMessage(message))

        XCTAssertEqual(payload.message.element(forName: "reject", xmlns: VoIPCall.namespace)?
            .attributeStringValue(forName: "id"), "call-id")
    }

    func testVoIPOwnStreamUnverifiedEncryptedRejectCannotEndActiveCall() throws {
        let call = VoIPCall(owner: owner, fullJid: peer, callId: "call-id",
                            callUUID: UUID(), outgoing: true)
        let initialState = call.state

        call.xmppStream(call.stream, didReceive: try incoming(
            extra: "<reject xmlns='urn:xmpp:jingle-message:0' id='call-id'/>"))

        XCTAssertEqual(call.state, initialState)
        XCTAssertNotEqual(call.state, .ended)
    }

    func testAuthenticatedTrustShareUsesPreparedLeafWithoutDecryptingAgain() throws {
        let manager = TrustSharingManager(withOwner: owner)
        let leaf = try incoming(extra: """
          <share xmlns='urn:xmpp:trustsharing:0' usage='urn:xmpp:omemo:2'/>
          <from xmlns='urn:test:foreign' jid='attacker@example.test'/>
        """)
        let message = try xml("""
          <message xmlns='jabber:client' from='\(owner)' to='\(owner)'>
            <received xmlns='urn:xmpp:carbons:2'>
              <forwarded xmlns='urn:xmpp:forward:0'>\(leaf.xmlString)</forwarded>
            </received>
          </message>
        """)
        var decryptCount = 0
        var appliedPublisher: String?

        let handled = manager.receiveListOfContactsDevices(message: message,
            encryption: .authenticatedSCE(profile: .omemo2),
            decryptMessage: { _ in decryptCount += 1; return nil },
            applyShare: { share, publisher in
                XCTAssertEqual(share.uri, TrustSharingSignature.xmlns)
                appliedPublisher = publisher
                return true
            })

        XCTAssertTrue(handled)
        XCTAssertEqual(decryptCount, 0)
        XCTAssertEqual(appliedPublisher, peer)
    }

    func testAuthenticatedTrustShareRejectsForeignShareQNameWithoutSecondDecrypt() throws {
        let manager = TrustSharingManager(withOwner: owner)
        var decryptCount = 0
        var applyCount = 0

        let handled = manager.receiveListOfContactsDevices(
            message: try incoming(extra: "<share xmlns='urn:test:foreign'/>"),
            encryption: .authenticatedSCE(profile: .legacySignal),
            decryptMessage: { _ in decryptCount += 1; return nil },
            applyShare: { _, _ in applyCount += 1; return true })

        XCTAssertFalse(handled)
        XCTAssertEqual(decryptCount, 0)
        XCTAssertEqual(applyCount, 0)
    }

    func testXENTrustShareStillDecryptsNestedCiphertextOnce() throws {
        let manager = TrustSharingManager(withOwner: owner)
        let message = try xml("""
          <message xmlns='jabber:client' from='server.example.test' to='\(owner)'>
            <notification xmlns='urn:xabber:xen:0'>
              <forwarded xmlns='urn:xmpp:forward:0'>\(try incoming().xmlString)</forwarded>
            </notification>
          </message>
        """)
        let decrypted = try XCTUnwrap(try DDXMLDocument(xmlString: """
          <envelope xmlns='urn:xmpp:sce:1'>
            <from jid='\(peer)'/><content><share xmlns='urn:xmpp:trustsharing:0'/></content>
          </envelope>
        """, options: 0).rootElement())
        var decryptCount = 0
        var appliedPublisher: String?

        let handled = manager.receiveListOfContactsDevices(message: message,
            encryption: .plaintext,
            decryptMessage: { inner in
                decryptCount += 1
                XCTAssertEqual(inner.from?.bare, self.peer)
                XCTAssertTrue(SCEReceivePolicy.hasOMEMO2(inner))
                return decrypted
            },
            applyShare: { _, publisher in appliedPublisher = publisher; return true })

        XCTAssertTrue(handled)
        XCTAssertEqual(decryptCount, 1)
        XCTAssertEqual(appliedPublisher, peer)
    }

    func testWireSuccessMarkerDoesNotBypassTrustShareDecrypt() throws {
        let manager = TrustSharingManager(withOwner: owner)
        var decryptCount = 0
        var applyCount = 0

        let handled = manager.receiveListOfContactsDevices(message: try incoming(extra: """
          <omemo-result__system result='true'/><share xmlns='urn:xmpp:trustsharing:0'/>
        """), encryption: .plaintext,
            decryptMessage: { _ in decryptCount += 1; return nil },
            applyShare: { _, _ in applyCount += 1; return true })

        XCTAssertFalse(handled)
        XCTAssertEqual(decryptCount, 1)
        XCTAssertEqual(applyCount, 0)
    }

    func testAuthenticatedMalformedTrustShareStillUsesExistingValidation() throws {
        let manager = TrustSharingManager(withOwner: owner)

        XCTAssertFalse(manager.didReceivedListOfContactsDevices(
            message: try incoming(extra: "<share xmlns='urn:xmpp:trustsharing:0'/>"),
            encryption: .authenticatedSCE(profile: .omemo2)))
    }

    private func savedMessage() throws -> XMPPMessage {
        let message = try incoming(from: owner, to: "favorites.example.test")
        let time = DDXMLElement(name: "time", xmlns: "https://xabber.com/protocol/delivery")
        time.addAttribute(withName: "stamp", stringValue: "2026-10-02T10:00:00Z")
        message.addChild(time)
        return message
    }

    private func installSearchCallback(_ manager: MessageArchiveManager,
                                       onMessage: @escaping (MessageStorageItem) -> Void) {
        manager.searchResultsQueries.insert("sce-query")
        let task = MessageArchiveManager.MAMRequestItem(jid: peer, messageId: nil,
            conversationType: .omemo, isContinues: false, searchText: "inside",
            queryId: "sce-query", afterId: nil, nextPage: nil, prevPage: nil,
            max: 50, tags: [], start: nil, end: nil, purpose: .engineSearchPage,
            retainsSealedTransportProofUntilBarrier: false)
        manager.upsertCallbackQueueItem(MessageArchiveManager.CallbackQueueItem(
            jid: peer, elementId: "sce-query", task: task, callback: nil,
            requestCallbacks: .init(onMessage: { item, _ in onMessage(item) })))
    }

    private func receiver() -> MessageManager {
        let manager = MessageManager(withOwner: owner, activeStream: false)
        manager.unsubscribeReceiver()
        return manager
    }

    private func queued(_ manager: MessageManager) throws -> MessageManager.MessageQueueItem {
        try XCTUnwrap(manager.performMessageQueueSync { manager.queuedMessages.first })
    }

    private func materialized(_ item: MessageManager.MessageQueueItem, manager: MessageManager) throws -> MessageStorageItem {
        var batch: MessageManager.ProcessedQueueBatch?
        manager.processQueue([item]) { batch = $0 }
        return try XCTUnwrap(batch?.messages.first)
    }

    private func incoming(extra: String = "", from: String? = nil, to: String? = nil) throws -> XMPPMessage {
        try xml("""
          <message xmlns='jabber:client' from='\(from ?? peer)' to='\(to ?? owner)' type='chat' id='sce-message'>
            <origin-id xmlns='urn:xmpp:sid:0' id='sce-message'/>
            <body>inside</body><encrypted xmlns='urn:xmpp:omemo:2'/>
            \(extra)
          </message>
        """)
    }

    private func archive() throws -> XMPPMessage {
        try xml("""
          <message xmlns='jabber:client' from='\(owner)' to='\(owner)'>
            <result xmlns='urn:xmpp:mam:2' queryid='sce-query' id='sce-result'>
              <forwarded xmlns='urn:xmpp:forward:0'>
                <delay xmlns='urn:xmpp:delay' stamp='2026-10-02T10:00:00Z'/>
                \(try incoming().xmlString)
              </forwarded>
            </result>
          </message>
        """)
    }

    private func carbon(sent: Bool) throws -> XMPPMessage {
        let direction = sent ? "sent" : "received"
        let inner = try incoming(from: sent ? owner : peer, to: sent ? peer : owner)
        return try xml("""
          <message xmlns='jabber:client' from='\(owner)' to='\(owner)'>
            <\(direction) xmlns='urn:xmpp:carbons:2'>
              <forwarded xmlns='urn:xmpp:forward:0'>\(inner.xmlString)</forwarded>
            </\(direction)>
          </message>
        """)
    }

    private func xml(_ string: String) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: string, options: 0)
        return XMPPMessage(from: try XCTUnwrap(document.rootElement()))
    }
}
