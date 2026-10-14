import Foundation
import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

/// Actual-ciphertext coverage for receive-time sender trust and persisted warnings.
final class OMEMO2NormativeIncomingTrustTests: XCTestCase {
    final class Memory: OMEMO2StatePersistence {
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
    struct Fixture {
        let sender: XabberOMEMO2Storage
        let receiver: OmemoManager
        let memory: Memory
        let senderBundle: OMEMO2LocalBundle
        let receiverBundle: OMEMO2LocalBundle
        let peer: String
    }
    private var oldRealmConfiguration: Realm.Configuration!
    private var keeper: Realm!

    override func setUpWithError() throws {
        oldRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "N09-\(UUID())")
        keeper = try WRealm.safe()
    }
    override func tearDown() {
        keeper = nil
        Realm.Configuration.defaultConfiguration = oldRealmConfiguration
        super.tearDown()
    }

    func testTrustedExactAuthenticatedKeyKeepsBodyWithoutWarning() throws {
        let f = try fixture()
        try setTrust(f, key: f.senderBundle.identityKey, state: .trusted)
        let result = f.receiver.prepareIncoming(try packet(f))
        let sender = try XCTUnwrap(result.authenticatedSender)
        XCTAssertTrue(sender.isTrusted)
        XCTAssertEqual(sender.identityFingerprint, try Omemo2IdentityRepresentation.fingerprint(for: f.senderBundle.identityKey))
        XCTAssertEqual(sender.jid, f.peer)
        XCTAssertEqual(sender.deviceID, 41)
        let item = try materialize(result, f: f)
        XCTAssertEqual(item.body, "authenticated content")
        XCTAssertNil(item.messageWarningText)
        XCTAssertEqual(item.incomingEncryption, .authenticatedSCE(profile: .omemo2))
    }

    func testUnknownAuthenticatedKeyShowsWarningWithoutTrustGrant() throws {
        let f = try fixture()
        let result = f.receiver.prepareIncoming(try packet(f))
        XCTAssertFalse(try XCTUnwrap(result.authenticatedSender).isTrusted)
        XCTAssertEqual(try materialize(result, f: f).messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
        XCTAssertEqual(try device(f).state, .unknown)
    }

    func testDistrustedActualKeyRemainsDistrusted() throws {
        let f = try fixture()
        try setTrust(f, key: f.senderBundle.identityKey, state: .distrusted)
        let result = f.receiver.prepareIncoming(try packet(f))
        XCTAssertFalse(try XCTUnwrap(result.authenticatedSender).isTrusted)
        XCTAssertEqual(try materialize(result, f: f).messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
        XCTAssertEqual(try device(f).state, .distrusted)
    }

    func testRegularCandidateFingerprintMismatchWarnsWithoutMutatingTrust() throws {
        let f = try fixture()
        try setTrust(f, key: f.senderBundle.identityKey, state: .trusted)
        _ = try verified(f.receiver.prepareIncoming(try packet(f)))
        try reply(f)
        let oldFingerprint = try device(f).fingerprint
        try keeper.write { try device(f).fingerprint = "not the authenticated key" }
        let result = f.receiver.prepareIncoming(try packet(f))
        XCTAssertFalse(try XCTUnwrap(result.authenticatedSender).isTrusted)
        XCTAssertEqual(try materialize(result, f: f).messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
        XCTAssertEqual(try device(f).state, .trusted)
        XCTAssertEqual(try device(f).fingerprint, "not the authenticated key")
        XCTAssertNotEqual(try XCTUnwrap(result.authenticatedSender).identityFingerprint, "not the authenticated key")
        XCTAssertNotEqual(oldFingerprint, "not the authenticated key")
    }

    func testMissingDeviceProjectionOnRegularReceiveIsUntrustedAndReadOnly() throws {
        let f = try fixture()
        _ = try verified(f.receiver.prepareIncoming(try packet(f)))
        try reply(f)
        try keeper.write { keeper.delete(try device(f)) }
        let result = f.receiver.prepareIncoming(try packet(f))
        XCTAssertFalse(try XCTUnwrap(result.authenticatedSender).isTrusted)
        XCTAssertEqual(try materialize(result, f: f).messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
        XCTAssertNil(keeper.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary(f)))
    }

    func testRemovedMembershipDoesNotChangeTrustOfAuthenticatedHistoryKey() throws {
        let f = try fixture()
        try setTrust(f, key: f.senderBundle.identityKey, state: .trusted, member: false)
        let result = f.receiver.prepareIncoming(try packet(f))
        XCTAssertTrue(try XCTUnwrap(result.authenticatedSender).isTrusted)
        XCTAssertNil(try materialize(result, f: f).messageWarningText)
        XCTAssertFalse(try device(f).isInDeviceList)
    }

    func testArchivedRegularDecryptEvaluatesItsActualOldKeyNotCurrentKey() throws {
        let f = try fixture()
        try setTrust(f, key: f.senderBundle.identityKey, state: .trusted)
        _ = try verified(f.receiver.prepareIncoming(try packet(f)))
        try reply(f)
        let late = try packet(f, body: "old delayed content")
        let replacement = try newSender(f)
        _ = try verified(f.receiver.prepareIncoming(try packet(f, sender: replacement.storage)))
        try setTrust(f, key: replacement.bundle.identityKey, state: .trusted)
        let publicFingerprint = try device(f).fingerprint
        let result = f.receiver.prepareIncoming(try archive(late, owner: f.receiver.owner), context: .archive)
        let sender = try XCTUnwrap(result.authenticatedSender)
        XCTAssertEqual(sender.identityFingerprint, try Omemo2IdentityRepresentation.fingerprint(for: f.senderBundle.identityKey))
        XCTAssertFalse(sender.isTrusted)
        XCTAssertEqual(try device(f).fingerprint, publicFingerprint)
        XCTAssertEqual(try device(f).state, .trusted)
        XCTAssertEqual(try f.receiver.omemo2Storage?.sessionMetadata(jid: f.peer, deviceID: 41)?.remoteIdentityKey, replacement.bundle.identityKey)
        let item = try materialize(result, f: f, route: "mam")
        XCTAssertEqual(item.body, "old delayed content")
        XCTAssertEqual(item.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
        XCTAssertEqual(item.mamArchiveId, "n09-archive-result")
    }

    func testTrustedArchivedActualKeyIsNotOverriddenByDifferentCurrentSession() throws {
        let f = try fixture()
        _ = try verified(f.receiver.prepareIncoming(try packet(f)))
        try reply(f)
        let late = try packet(f)
        let replacement = try newSender(f)
        _ = try verified(f.receiver.prepareIncoming(try packet(f, sender: replacement.storage)))
        try setTrust(f, key: f.senderBundle.identityKey, state: .trusted)
        let result = f.receiver.prepareIncoming(try archive(late, owner: f.receiver.owner), context: .archive)
        XCTAssertTrue(try XCTUnwrap(result.authenticatedSender).isTrusted)
        XCTAssertNil(try materialize(result, f: f, route: "mam").messageWarningText)
        XCTAssertEqual(try f.receiver.omemo2Storage?.sessionMetadata(jid: f.peer, deviceID: 41)?.remoteIdentityKey, replacement.bundle.identityKey)
    }

    func testReceiveOnlyKEXReportsActualKeyWithoutUpdatingCurrentTrust() throws {
        let f = try fixture()
        let cleanup = f.receiver.omemo2PreKeyCleanup
        let chain = UUID()
        cleanup.beginCatchUp(id: chain)
        defer { cleanup.finishCatchUp(id: chain) }
        try setTrust(f, key: f.senderBundle.identityKey, state: .trusted)
        _ = try verified(f.receiver.prepareIncoming(try packet(f)))
        let replacement = try newSender(f, bundle: f.receiverBundle)
        let result = f.receiver.prepareIncoming(try packet(f, sender: replacement.storage))
        XCTAssertFalse(try XCTUnwrap(result.authenticatedSender).isTrusted)
        XCTAssertEqual(result.authenticatedSender?.identityFingerprint, try Omemo2IdentityRepresentation.fingerprint(for: replacement.bundle.identityKey))
        XCTAssertEqual(try device(f).state, .trusted)
        XCTAssertEqual(try device(f).fingerprint, try Omemo2IdentityRepresentation.fingerprint(for: f.senderBundle.identityKey))
        XCTAssertEqual(try f.receiver.omemo2Storage?.sessionMetadata(jid: f.peer, deviceID: 41)?.remoteIdentityKey, f.senderBundle.identityKey)
    }

    func testOuterTrustAndXMLSuccessMarkerCannotGrantTrustIndication() throws {
        let f = try fixture()
        let wire = try packet(f)
        wire.addAttribute(withName: "trusted", stringValue: "true")
        let trusted = DDXMLElement(name: "trusted", xmlns: "urn:test:foreign")
        trusted.stringValue = "true"
        wire.addChild(trusted)
        let marker = DDXMLElement(name: "omemo-result__system")
        marker.addAttribute(withName: "result", stringValue: "true")
        wire.addChild(marker)
        let result = f.receiver.prepareIncoming(wire)
        XCTAssertFalse(try XCTUnwrap(result.authenticatedSender).isTrusted)
        XCTAssertNil(result.message?.element(forName: "trusted"))
        XCTAssertNil(result.message?.element(forName: "omemo-result__system"))
        XCTAssertEqual(try materialize(result, f: f).messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
    }

    func testMACFailureAndProtectedSaveFailureExposeNoAuthenticatedSender() throws {
        let f = try fixture()
        let wire = try packet(f)
        let bad = XMPPMessage(from: wire.copy() as! DDXMLElement)
        let payload = try XCTUnwrap(bad.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "payload"))
        var data = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(payload.stringValue)); data[0] ^= 1
        payload.stringValue = data.base64EncodedString()
        let before = f.memory.records[f.receiver.owner]
        let failedMAC = f.receiver.prepareIncoming(bad)
        guard case .failed = failedMAC else { return XCTFail("Expected MAC failure") }
        XCTAssertNil(failedMAC.authenticatedSender)
        XCTAssertEqual(f.memory.records[f.receiver.owner], before)
        f.memory.failWrites = true
        let failedSave = f.receiver.prepareIncoming(wire)
        guard case .failed = failedSave else { return XCTFail("Expected protected save failure") }
        XCTAssertNil(failedSave.authenticatedSender)
        XCTAssertEqual(f.memory.records[f.receiver.owner], before)
        f.memory.failWrites = false
        XCTAssertNotNil(f.receiver.prepareIncoming(wire).authenticatedSender)
    }

    func testAuthenticatedControlAndExactReplayHaveNoBubbleOrTrustMetadata() throws {
        let f = try fixture()
        let cipher = try f.sender.encrypt(Data(repeating: 0, count: 32), jid: f.receiver.owner, deviceID: 42)
        let wire = try message(cipher, payload: nil, f: f)
        let control = f.receiver.prepareIncoming(wire)
        guard case .consumed(.control) = control else { return XCTFail("Expected consumed key control") }
        XCTAssertNil(control.message)
        XCTAssertNil(control.authenticatedSender)
        let duplicate = f.receiver.prepareIncoming(wire)
        guard case .consumed(.duplicate) = duplicate else { return XCTFail("Expected consumed duplicate") }
        XCTAssertNil(duplicate.message)
        XCTAssertNil(duplicate.authenticatedSender)
    }

    func testLiveMAMAndReceivedCarbonPreserveActualSenderWarning() throws {
        for route in ["live", "mam", "received"] {
            let f = try fixture()
            let wire = try packet(f)
            let packet = route == "mam" ? try archive(wire, owner: f.receiver.owner) :
                route == "received" ? try carbon(wire, owner: f.receiver.owner, sent: false) : wire
            let result = f.receiver.prepareIncoming(packet, context: route == "mam" ? .archive : route == "received" ? .carbon : .live)
            XCTAssertEqual(result.authenticatedSender?.jid, f.peer, route)
            XCTAssertEqual(result.authenticatedSender?.isTrusted, false, route)
            let item = try materialize(result, f: f, route: route)
            XCTAssertEqual(item.body, "authenticated content", route)
            XCTAssertEqual(item.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText, route)
        }
    }

    func testSentCarbonPreservesActualOwnDeviceWarningOnOutgoingBubble() throws {
        let f = try fixture(ownSender: true)
        let wire = try packet(f, to: "contact@example.test")
        let result = f.receiver.prepareIncoming(try carbon(wire, owner: f.receiver.owner, sent: true), context: .carbon)
        XCTAssertEqual(result.authenticatedSender?.jid, f.receiver.owner)
        XCTAssertFalse(try XCTUnwrap(result.authenticatedSender).isTrusted)
        let item = try materialize(result, f: f, route: "sent")
        XCTAssertTrue(item.outgoing)
        XCTAssertEqual(item.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
    }

    func testSearchMaterializerRetainsActualSenderWarningAndArchiveID() throws {
        let f = try fixture()
        let result = f.receiver.prepareIncoming(try archive(packet(f), owner: f.receiver.owner), context: .archive)
        let archive = MessageArchiveManager(withOwner: f.receiver.owner)
        archive.searchResultsQueries.insert("n09-search-query")
        let task = MessageArchiveManager.MAMRequestItem(jid: f.peer, messageId: nil,
            conversationType: .omemo, isContinues: false, searchText: "authenticated",
            queryId: "n09-search-query", afterId: nil, nextPage: nil, prevPage: nil,
            max: 50, tags: [], start: nil, end: nil, purpose: .engineSearchPage,
            retainsSealedTransportProofUntilBarrier: false)
        var materialized: MessageStorageItem?
        let delivered = expectation(description: "Search receive callback")
        archive.upsertCallbackQueueItem(MessageArchiveManager.CallbackQueueItem(jid: f.peer,
            elementId: "n09-search-query", task: task, callback: nil,
            requestCallbacks: .init(onMessage: { item, _ in
                materialized = item
                delivered.fulfill()
            })))
        let clean = try verified(result)
        XCTAssertTrue(archive.readMessage(clean, encryption: result.provenance,
            authenticatedSender: result.authenticatedSender))
        wait(for: [delivered], timeout: 2)
        let item = try XCTUnwrap(materialized)
        XCTAssertEqual(item.body, "authenticated content")
        XCTAssertEqual(item.mamArchiveId, "n09-archive-result")
        XCTAssertEqual(item.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
    }

    func testSyncCompanionSurvivesInternalValueButCannotBeRebuiltFromXML() throws {
        let f = try fixture()
        let wire = try packet(f)
        let conversation = try XCTUnwrap(try DDXMLDocument(xmlString: """
            <conversation xmlns='https://xabber.com/protocol/synchronization' jid='\(f.peer)' type='urn:xmpp:omemo:2'>
              <metadata node='https://xabber.com/protocol/synchronization'><last-message>\(wire.xmlString)</last-message></metadata>
            </conversation>
            """, options: 0).rootElement())
        let value = f.receiver.prepareSyncConversation(conversation)
        XCTAssertEqual(value.lastMessageEncryption, .authenticatedSCE(profile: .omemo2))
        XCTAssertFalse(try XCTUnwrap(value.lastMessageAuthenticatedSender).isTrusted)
        XCTAssertEqual(value.lastMessageAuthenticatedSender?.jid, f.peer)
        let reserialized = ClientSyncConversationValue(try XCTUnwrap(value.materializedElement()))
        XCTAssertEqual(reserialized.lastMessageEncryption, .plaintext)
        XCTAssertNil(reserialized.lastMessageAuthenticatedSender)
    }

    func testAttachmentOnlyAuthenticatedMessageRetainsSenderWarning() throws {
        let f = try fixture()
        let reference = "<reference xmlns='urn:xmpp:reference:0' type='data' uri='https://example.test/file'/>"
        let result = f.receiver.prepareIncoming(try packet(f, content: reference))
        let item = try materialize(result, f: f)
        XCTAssertEqual(item.body, "")
        XCTAssertFalse(try XCTUnwrap(result.authenticatedSender).isTrusted)
        XCTAssertEqual(item.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
    }

    func testReceiveTimeWarningPersistsWithoutCurrentDeviceProjection() throws {
        let f = try fixture()
        let result = f.receiver.prepareIncoming(try packet(f))
        var primary = ""
        do {
            let item = try configuredItem(result, f: f)
            item.applyIncomingSenderTrust(try knownSender(f), encryption: result.provenance)
            primary = item.primary
            try persist(item)
        }
        let row = try XCTUnwrap(keeper.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        XCTAssertEqual(row.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
        let persisted = MessageStorageItem(value: row)
        XCTAssertNil(persisted.originalStanza)
        XCTAssertEqual(persisted.incomingEncryption, .plaintext)
        XCTAssertEqual(persisted.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
        try setTrust(f, key: f.senderBundle.identityKey, state: .trusted)
        XCTAssertEqual(persisted.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText,
            "Rendering preserves the local receive-time snapshot")
    }

    func testExactExistingCiphertextReceivesPersistedWarningWithoutReplacingBody() throws {
        let f = try fixture()
        let result = f.receiver.prepareIncoming(try packet(f))
        let initial = try configuredItem(result, f: f)
        try persist(initial)
        let authenticated = try configuredItem(result, f: f)
        authenticated.applyIncomingSenderTrust(try knownSender(f), encryption: result.provenance)
        try persist(authenticated)
        let row = try XCTUnwrap(keeper.object(ofType: MessageStorageItem.self, forPrimaryKey: initial.primary))
        XCTAssertEqual(row.body, "authenticated content")
        XCTAssertEqual(row.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
    }

    func testSameMessageIDWithDifferentContentCannotApplyIncomingWarningToCachedRow() throws {
        let f = try fixture()
        let result = f.receiver.prepareIncoming(try packet(f))
        let clean = try verified(result)
        let unrelated = XMPPMessage(from: clean.copy() as! DDXMLElement)
        unrelated.element(forName: "body", xmlns: "jabber:client")?.stringValue = "unrelated cached plaintext"
        let initial = configuredItem(unrelated, f: f)
        try persist(initial)
        let authenticated = try configuredItem(result, f: f)
        authenticated.applyIncomingSenderTrust(try knownSender(f), encryption: result.provenance)
        try persist(authenticated)
        let row = try XCTUnwrap(keeper.object(ofType: MessageStorageItem.self, forPrimaryKey: initial.primary))
        XCTAssertEqual(row.body, "unrelated cached plaintext")
        XCTAssertNil(row.messageWarningText)
    }

    func testUnverifiedExistingRowArrivalCannotErasePersistedSenderWarning() throws {
        let f = try fixture()
        let result = f.receiver.prepareIncoming(try packet(f))
        let initial = try configuredItem(result, f: f)
        initial.applyIncomingSenderTrust(try knownSender(f), encryption: result.provenance)
        try persist(initial)
        let unverified = try configuredItem(result, f: f)
        unverified.incomingEncryption = .unverifiedOMEMO
        unverified.applyIncomingSenderTrust(nil, encryption: .unverifiedOMEMO)
        try persist(unverified)
        let row = try XCTUnwrap(keeper.object(ofType: MessageStorageItem.self, forPrimaryKey: initial.primary))
        XCTAssertEqual(row.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
    }

    func testWarningHelperRejectsUnsupportedProofAndMismatchedSenderScope() throws {
        let f = try fixture()
        let result = f.receiver.prepareIncoming(try packet(f))
        let sender = try knownSender(f)
        for proof in [MessageEncryptionProvenance.plaintext, .unverifiedOMEMO, .failedOMEMO,
                      .authenticatedSCE(profile: .legacySignal)] {
            let item = try configuredItem(result, f: f)
            item.applyIncomingSenderTrust(sender, encryption: proof)
            XCTAssertNil(item.messageWarningText)
        }
        for invalid in [
            OMEMOAuthenticatedSender(owner: "other-owner@example.test", jid: sender.jid,
                deviceID: sender.deviceID, identityFingerprint: sender.identityFingerprint, isTrusted: false),
            OMEMOAuthenticatedSender(owner: sender.owner, jid: "other-peer@example.test",
                deviceID: sender.deviceID, identityFingerprint: sender.identityFingerprint, isTrusted: false),
            OMEMOAuthenticatedSender(owner: sender.owner, jid: sender.jid,
                deviceID: 99, identityFingerprint: sender.identityFingerprint, isTrusted: false)
        ] {
            let item = try configuredItem(result, f: f)
            item.applyIncomingSenderTrust(invalid, encryption: result.provenance)
            XCTAssertNil(item.messageWarningText)
        }
    }

    func testSenderWarningKeepsIndependentSkippedRecipientWarning() throws {
        let f = try fixture(ownSender: true)
        let result = f.receiver.prepareIncoming(try packet(f))
        let item = try configuredItem(result, f: f)
        item.markOmemoUntrustedContactDevicesWarning()
        item.applyIncomingSenderTrust(try knownSender(f), encryption: result.provenance)
        let warnings = try XCTUnwrap(item.messageWarningText)
        XCTAssertTrue(warnings.contains(MessageStorageItem.omemoUntrustedContactDevicesWarningText))
        XCTAssertTrue(warnings.contains(MessageStorageItem.omemoUntrustedSenderWarningText))
        XCTAssertEqual(item.systemMetadata?[MessageStorageItem.messageWarningMetadataKey] as? String,
            MessageStorageItem.omemoUntrustedContactDevicesWarningCode)
    }

    func testEncryptedRewriteAppliesSenderWarningToTheActualEditedRow() throws {
        let f = try fixture()
        let original = MessageStorageItem()
        original.owner = f.receiver.owner; original.opponent = f.peer
        original.messageId = "n09-original"; original.updatePrimary()
        original.archivedId = "n09-original-archive"; original.conversationType = .omemo
        original.body = "original history"; original.legacyBody = original.body
        original.date = Date(); original.sentDate = original.date
        try keeper.write { keeper.add(original) }
        let content = "<body xmlns='jabber:client'>authenticated edit</body><replaced xmlns='\(MessageDeleteManager.namespace)' stamp='2026-10-06T10:00:00Z'/>"
        let wire = try packet(f, content: content)
        let wrapper = try XMPPMessage(xmlString: """
            <message xmlns='jabber:client' from='\(f.receiver.owner)' to='\(f.receiver.owner)' type='headline'>
              <replace xmlns='https://xabber.com/protocol/rewrite#notify' conversation='\(f.peer)' type='urn:xmpp:omemo:2' id='n09-original-archive' version='n09-edit-version'>\(wire.xmlString)</replace>
            </message>
            """)
        let result = f.receiver.prepareIncoming(wrapper)
        let rewrite = MessageDeleteManager(withOwner: f.receiver.owner)
        XCTAssertTrue(rewrite.readRewriteNotify(try verified(result), encryption: result.provenance,
            authenticatedSender: try knownSender(f)))
        XCTAssertEqual(original.body, "authenticated edit")
        XCTAssertEqual(original.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
        XCTAssertEqual(original.archivedId, "n09-original-archive")
        XCTAssertEqual(rewrite.version, "n09-edit-version")
    }

    func testDirectSavedMessageRetainsSenderWarningAfterPersistence() throws {
        let f = try fixture(ownSender: true)
        let result = f.receiver.prepareIncoming(try savedWire(f))
        let manager = XMPPFavoritesManager(withOwner: f.receiver.owner)
        let clean = try verified(result)
        let sender = try knownSender(f)
        let saved = try manager.receiveSaved(message: clean, realm: keeper,
            commitTransaction: true, favoritesNodeOverride: "favorites.example.test",
            encryption: result.provenance, authenticatedSender: sender)
        let row = try XCTUnwrap(saved)
        XCTAssertEqual(row.body, "authenticated content")
        XCTAssertEqual(row.conversationType, .saved)
        XCTAssertEqual(row.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
        XCTAssertEqual(MessageStorageItem(value: row).messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
    }

    func testSavedForwardDoesNotApplyOuterAuthenticatedSenderToNestedPlaintext() throws {
        let f = try fixture(ownSender: true)
        let content = """
            <body xmlns='jabber:client'>forwarded copy</body>
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='14'>
              <forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2026-10-06T10:00:00Z'/>
                <message xmlns='jabber:client' from='nested-peer@example.test' to='\(f.receiver.owner)' type='chat' id='n09-nested'><body>nested plaintext</body></message>
              </forwarded>
            </reference>
            """
        let result = f.receiver.prepareIncoming(try savedWire(f, content: content))
        let manager = XMPPFavoritesManager(withOwner: f.receiver.owner)
        let clean = try verified(result)
        let sender = try knownSender(f)
        let saved = try manager.receiveSaved(message: clean, realm: keeper,
            commitTransaction: true, favoritesNodeOverride: "favorites.example.test",
            encryption: result.provenance, authenticatedSender: sender)
        let row = try XCTUnwrap(saved)
        XCTAssertTrue(row.isSavedForward)
        XCTAssertEqual(row.body, "nested plaintext")
        XCTAssertNil(row.messageWarningText)
    }

    func testSavedExistingSameIDRequiresExactStanzaBeforeApplyingWarning() throws {
        for exact in [false, true] {
            let f = try fixture(ownSender: true)
            let result = f.receiver.prepareIncoming(try savedWire(f))
            let clean = try verified(result)
            let initial = XMPPMessage(from: clean.copy() as! DDXMLElement)
            if !exact { initial.element(forName: "body", xmlns: "jabber:client")?.stringValue = "unrelated saved body" }
            let manager = XMPPFavoritesManager(withOwner: f.receiver.owner)
            let row = try XCTUnwrap(manager.receiveSaved(message: initial, realm: keeper,
                commitTransaction: true, favoritesNodeOverride: "favorites.example.test", encryption: result.provenance))
            _ = try manager.receiveSaved(message: clean, realm: keeper,
                commitTransaction: true, favoritesNodeOverride: "favorites.example.test",
                encryption: result.provenance, authenticatedSender: knownSender(f))
            row.originalStanza = nil
            _ = try manager.receiveSaved(message: clean, realm: keeper,
                commitTransaction: true, favoritesNodeOverride: "favorites.example.test",
                encryption: result.provenance, authenticatedSender: knownSender(f))
            XCTAssertEqual(row.body, exact ? "authenticated content" : "unrelated saved body")
            XCTAssertEqual(row.messageWarningText, exact ? MessageStorageItem.omemoUntrustedSenderWarningText : nil)
        }
    }

    func testRepeatedCachedBodyCollisionCannotGainWarningAfterIgnoredStanzaIsLost() throws {
        for referenceCollision in [false, true] {
            let f = try fixture()
            let result = f.receiver.prepareIncoming(try packet(f))
            let clean = try verified(result)
            let unrelated = XMPPMessage(from: clean.copy() as! DDXMLElement)
            let retainedBody = referenceCollision ? "authenticated content" : "unrelated retained body"
            unrelated.element(forName: "body", xmlns: "jabber:client")?.stringValue = retainedBody
            if referenceCollision {
                unrelated.addChild(try DDXMLElement(xmlString: """
                    <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='0'>
                      <geoloc xmlns='http://jabber.org/protocol/geoloc'>
                        <lat>51.5</lat><lon>-0.12</lon><text>Unrelated retained location</text>
                      </geoloc>
                    </reference>
                    """))
            }
            let initial = configuredItem(unrelated, f: f)
            if referenceCollision { XCTAssertEqual(initial.references.count, 1) }
            try persist(initial)
            let first = try configuredItem(result, f: f)
            first.applyIncomingSenderTrust(try knownSender(f), encryption: result.provenance)
            try persist(first)
            let row = try XCTUnwrap(keeper.object(ofType: MessageStorageItem.self, forPrimaryKey: initial.primary))
            XCTAssertNil(row.messageWarningText)
            let persistedStanza = try XCTUnwrap(keeper.object(ofType: MessageStanzaStorageItem.self,
                forPrimaryKey: "\(row.primary)_stanza"))
            XCTAssertEqual(persistedStanza.stanza, clean.xmlString,
                "A later authenticated arrival may have replaced the raw history XML")
            row.originalStanza = nil
            XCTAssertNil(row.originalStanza)
            let repeated = try configuredItem(result, f: f)
            repeated.applyIncomingSenderTrust(try knownSender(f), encryption: result.provenance)
            try persist(repeated)
            XCTAssertEqual(row.body, retainedBody)
            XCTAssertNil(row.messageWarningText,
                "Raw XML from a later arrival cannot authenticate a different retained body")
            if referenceCollision { XCTAssertEqual(row.references.count, 1) }
        }
    }

    func testDirectSavedExactBodyReceivesWarningUsingPersistedStanzaAfterRestart() throws {
        let f = try fixture(ownSender: true)
        let result = f.receiver.prepareIncoming(try savedWire(f))
        let clean = try verified(result)
        let manager = XMPPFavoritesManager(withOwner: f.receiver.owner)
        let initial = try manager.receiveSaved(message: clean, realm: keeper,
            commitTransaction: true, favoritesNodeOverride: "favorites.example.test", encryption: result.provenance)
        let row = try XCTUnwrap(initial)
        XCTAssertNil(row.messageWarningText)
        let persistedStanza = try XCTUnwrap(keeper.object(ofType: MessageStanzaStorageItem.self,
            forPrimaryKey: "\(row.primary)_stanza"))
        XCTAssertEqual(persistedStanza.owner, f.receiver.owner)
        XCTAssertEqual(persistedStanza.stanza, clean.xmlString)
        row.originalStanza = nil
        XCTAssertNil(row.originalStanza)
        _ = try manager.receiveSaved(message: clean, realm: keeper,
            commitTransaction: true, favoritesNodeOverride: "favorites.example.test",
            encryption: result.provenance, authenticatedSender: knownSender(f))
        XCTAssertEqual(row.body, "authenticated content")
        XCTAssertEqual(row.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
    }

    func testRepeatedCachedReferenceMetadataCollisionCannotGainWarningAfterRestart() throws {
        for isContact in [false, true] {
          for exact in [false, true] {
            let f = try fixture()
            let payload = isContact
                ? "<contact xmlns='https://xabber.com/protocol/contact-sharing' jid='contact@example.test' entity='contact'><nickname>Authenticated name</nickname></contact>"
                : "<geoloc xmlns='http://jabber.org/protocol/geoloc'><lat>51.5</lat><lon>-0.12</lon><text>Authenticated location</text></geoloc>"
            let reference = "<reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='0'>\(payload)</reference>"
            let wire = try packet(f, content: "<body xmlns='jabber:client'/>\(reference)")
            let result = f.receiver.prepareIncoming(wire)
            let clean = try verified(result)
            let unrelated = XMPPMessage(from: clean.copy() as! DDXMLElement)
            let ref = try XCTUnwrap(unrelated.element(forName: "reference", xmlns: "https://xabber.com/protocol/references"))
            let payloadElement = try XCTUnwrap(ref.element(forName: isContact ? "contact" : "geoloc",
                xmlns: isContact ? "https://xabber.com/protocol/contact-sharing" : "http://jabber.org/protocol/geoloc"))
            let label = try XCTUnwrap(payloadElement.element(forName: isContact ? "nickname" : "text"))
            if !exact { label.stringValue = "Unrelated retained metadata" }
            let initial = configuredItem(unrelated, f: f)
            let expectedKind: MessageReferenceStorageItem.Kind = isContact ? .contact : .geoloc
            XCTAssertEqual(initial.body, "")
            XCTAssertEqual(initial.legacyBody, "")
            XCTAssertEqual(initial.references.count, 1)
            let retainedReference = try XCTUnwrap(initial.references.first)
            XCTAssertEqual(retainedReference.kind, expectedKind)
            try persist(initial)
            let first = try configuredItem(result, f: f)
            XCTAssertEqual(first.body, initial.body)
            XCTAssertEqual(first.legacyBody, initial.legacyBody)
            let authenticReference = try XCTUnwrap(first.references.first)
            XCTAssertNotEqual(authenticReference.primary, retainedReference.primary)
            XCTAssertEqual(authenticReference.kind, retainedReference.kind)
            XCTAssertEqual(authenticReference.url, retainedReference.url)
            XCTAssertEqual(authenticReference.metadata?[isContact ? "nickname" : "text"] as? String ==
                retainedReference.metadata?[isContact ? "nickname" : "text"] as? String, exact)
            try persist(first)
            let row = try XCTUnwrap(keeper.object(ofType: MessageStorageItem.self, forPrimaryKey: initial.primary))
            XCTAssertNil(row.messageWarningText)
            let persistedStanza = try XCTUnwrap(keeper.object(ofType: MessageStanzaStorageItem.self,
                forPrimaryKey: "\(row.primary)_stanza"))
            XCTAssertEqual(persistedStanza.stanza, clean.xmlString)
            row.originalStanza = nil
            let repeated = try configuredItem(result, f: f)
            repeated.applyIncomingSenderTrust(try knownSender(f), encryption: result.provenance)
            try persist(repeated)
            XCTAssertEqual(row.body, "")
            XCTAssertEqual(row.legacyBody, "")
            XCTAssertEqual(row.references.first?.metadata?[isContact ? "nickname" : "text"] as? String,
                exact ? (isContact ? "Authenticated name" : "Authenticated location") : "Unrelated retained metadata")
            XCTAssertEqual(row.messageWarningText, exact ? MessageStorageItem.omemoUntrustedSenderWarningText : nil,
                "A later proof must match retained reference metadata, independent of random reference IDs")
          }
        }
    }

    private func knownSender(_ f: Fixture, trusted: Bool = false) throws -> OMEMOAuthenticatedSender {
        OMEMOAuthenticatedSender(owner: f.receiver.owner, jid: f.peer, deviceID: 41,
            identityFingerprint: try Omemo2IdentityRepresentation.fingerprint(for: f.senderBundle.identityKey), isTrusted: trusted)
    }
    private func configuredItem(_ result: OMEMOReceiveResult, f: Fixture) throws -> MessageStorageItem {
        let item = configuredItem(try verified(result), f: f)
        item.incomingEncryption = result.provenance
        return item
    }
    private func configuredItem(_ clean: XMPPMessage, f: Fixture) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.configureIncomingMessage(clean, owner: f.receiver.owner, opponent: f.peer,
            outgoing: f.peer == f.receiver.owner, isRead: false, date: Date(), isEncrypted: true)
        return item
    }
    private func persist(_ item: MessageStorageItem) throws {
        try keeper.write {
            _ = item.applyMessagePersistence(in: keeper, silentNotifications: true)
            item.storeStanza(in: keeper)
        }
    }
    private func savedWire(_ f: Fixture, content: String? = nil) throws -> XMPPMessage {
        try packet(f, content: content, to: "favorites.example.test")
    }

    private func fixture(ownSender: Bool = false) throws -> Fixture {
        let receiver = OmemoManager(withOwner: "n09-local-\(UUID().uuidString.lowercased())@example.test")
        let peer = ownSender ? receiver.owner : "n09-peer-\(UUID().uuidString.lowercased())@example.test"
        let memory = Memory()
        let store = try XabberOMEMO2Storage(owner: receiver.owner, persistence: memory)
        let receiverBundle = try store.prepare(deviceID: 42, preKeyCount: 8)
        receiver.omemo2Storage = store
        _ = try receiver.ensureOMEMO2Prepared()
        let sender = try XabberOMEMO2Storage(owner: peer, persistence: Memory())
        let senderBundle = try sender.prepare(deviceID: 41, preKeyCount: 8)
        try initiate(sender, to: receiver.owner, bundle: receiverBundle)
        return Fixture(sender: sender, receiver: receiver, memory: memory,
            senderBundle: senderBundle, receiverBundle: receiverBundle, peer: peer)
    }
    private func newSender(_ f: Fixture, bundle: OMEMO2LocalBundle? = nil) throws -> (storage: XabberOMEMO2Storage, bundle: OMEMO2LocalBundle) {
        let sender = try XabberOMEMO2Storage(owner: f.peer, persistence: Memory())
        let own = try sender.prepare(deviceID: 41, preKeyCount: 8)
        let receiver = try XCTUnwrap(f.receiver.omemo2Storage)
        let recipientBundle = try bundle ?? receiver.localBundle()
        try initiate(sender, to: f.receiver.owner, bundle: recipientBundle)
        return (sender, own)
    }
    private func initiate(_ sender: XabberOMEMO2Storage, to owner: String, bundle: OMEMO2LocalBundle) throws {
        let prekey = try XCTUnwrap(bundle.preKeys.first)
        try sender.initiateSession(jid: owner, deviceID: 42,
            bundle: OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
                signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature,
                preKey: prekey.publicKey, preKeyID: prekey.id))
    }
    private func packet(_ f: Fixture, sender: XabberOMEMO2Storage? = nil,
        body: String = "authenticated content", content: String? = nil, to: String? = nil) throws -> XMPPMessage {
        let recipient = to ?? f.receiver.owner
        let xml = "<envelope xmlns='urn:xmpp:sce:1'><content>\(content ?? "<body xmlns='jabber:client'>\(body)</body>")</content><rpad/><from jid='\(f.peer)'/><to jid='\(recipient)'/></envelope>"
        let sentAt = Date()
        let preparedXML = try Omemo2PayloadCodec.prepareOutgoingXML(xml, encryptionTime: sentAt)
        let sealed = try Omemo2PayloadCodec.seal(preparedXML)
        let ciphertext = try (sender ?? f.sender).encrypt(sealed.keyAndMAC, jid: f.receiver.owner, deviceID: 42)
        let wire = try message(ciphertext, payload: sealed.ciphertext, f: f, to: recipient)
        wire.addChild(try DDXMLElement(xmlString: "<time xmlns='https://xabber.com/protocol/delivery' stamp='\(sentAt.XMPPFormattedDate)'/>"))
        return wire
    }
    private func message(_ cipher: OMEMO2Ciphertext, payload: Data?, f: Fixture, to: String? = nil) throws -> XMPPMessage {
        let payloadXML = payload.map { "<payload>\($0.base64EncodedString())</payload>" } ?? ""
        return try XMPPMessage(xmlString: "<message xmlns='jabber:client' type='chat' from='\(f.peer)' to='\(to ?? f.receiver.owner)' id='\(UUID())'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='41'><keys jid='\(f.receiver.owner)'><key rid='42'\(cipher.isKeyExchange ? " kex='true'" : "")>\(cipher.data.base64EncodedString())</key></keys></header>\(payloadXML)</encrypted></message>")
    }
    private func reply(_ f: Fixture) throws {
        let receiver = try XCTUnwrap(f.receiver.omemo2Storage)
        let cipher = try receiver.encrypt(Data(repeating: 0, count: 32), jid: f.peer, deviceID: 41)
        XCTAssertFalse(cipher.isKeyExchange)
        XCTAssertEqual(try f.sender.decrypt(cipher, jid: f.receiver.owner, deviceID: 42), Data(repeating: 0, count: 32))
    }
    private func primary(_ f: Fixture) -> String { SignalDeviceStorageItem.genPrimary(owner: f.receiver.owner, jid: f.peer, deviceId: 41) }
    private func device(_ f: Fixture) throws -> SignalDeviceStorageItem { try XCTUnwrap(keeper.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary(f))) }
    private func setTrust(_ f: Fixture, key: Data, state: SignalDeviceStorageItem.TrustState, member: Bool = true) throws {
        let device = keeper.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary(f)) ?? SignalDeviceStorageItem()
        let identity = keeper.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary(f)) ?? SignalIdentityStorageItem()
        if device.realm == nil {
            device.owner = f.receiver.owner; device.jid = f.peer; device.deviceId = 41; device.primary = primary(f)
        }
        if identity.realm == nil {
            identity.owner = f.receiver.owner; identity.jid = f.peer; identity.deviceId = 41; identity.primary = primary(f)
        }
        try keeper.write {
            device.state = state; device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: key); device.isInDeviceList = member
            identity.identityKey = key.base64EncodedString(); identity.protocolProfile = OmemoManager.xmlns
            keeper.add(device, update: .modified); keeper.add(identity, update: .modified)
        }
    }
    private func verified(_ result: OMEMOReceiveResult) throws -> XMPPMessage {
        guard case .verified = result else {
            switch result {
            case .failed(_, let error):
                throw NSError(domain: "N09", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture decrypt failed: \(error)", NSUnderlyingErrorKey: error])
            case .consumed(let reason):
                throw NSError(domain: "N09", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fixture unexpectedly consumed: \(reason)"])
            case .notEncrypted:
                throw NSError(domain: "N09", code: 3, userInfo: [NSLocalizedDescriptionKey: "Fixture lost its encrypted leaf"])
            case .verified: break
            }
            throw NSError(domain: "N09", code: 4)
        }
        return try XCTUnwrap(result.message)
    }
    private func archive(_ wire: XMPPMessage, owner: String) throws -> XMPPMessage {
        let stamp = try XCTUnwrap(wire.element(forName: "time", xmlns: "https://xabber.com/protocol/delivery")?.attributeStringValue(forName: "stamp"))
        return try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(owner)' to='\(owner)'><result xmlns='urn:xmpp:mam:2' queryid='n09-search-query' id='n09-archive-result'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(stamp)'/>\(wire.xmlString)</forwarded></result></message>")
    }
    private func carbon(_ wire: XMPPMessage, owner: String, sent: Bool) throws -> XMPPMessage {
        let direction = sent ? "sent" : "received"
        return try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(owner)' to='\(owner)'><\(direction) xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>\(wire.xmlString)</forwarded></\(direction)></message>")
    }
    private func materialize(_ result: OMEMOReceiveResult, f: Fixture, route: String = "live") throws -> MessageStorageItem {
        let message = try verified(result)
        let manager = MessageManager(withOwner: f.receiver.owner, activeStream: false)
        manager.unsubscribeReceiver()
        switch route {
        case "mam": manager.receiveArchived(message, encryption: result.provenance, authenticatedSender: result.authenticatedSender)
        case "sent": manager.receiveCarbon(message, encryption: result.provenance, authenticatedSender: result.authenticatedSender)
        case "received": manager.receiveCarbonForwarded(message, encryption: result.provenance, authenticatedSender: result.authenticatedSender)
        default: manager.receiveRuntime(message, encryption: result.provenance, authenticatedSender: result.authenticatedSender)
        }
        let queue = try XCTUnwrap(manager.performMessageQueueSync { manager.queuedMessages.first })
        var batch: MessageManager.ProcessedQueueBatch?
        manager.processQueue([queue]) { batch = $0 }
        return try XCTUnwrap(batch?.messages.first)
    }
}
