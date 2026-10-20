import Foundation
import RealmSwift
import XCTest
import XMPPFramework
import XabberCryptoSwift
@testable import xabber

final class OMEMO2NormativeReplayTests: XCTestCase {
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
    struct Fixture { let alice: OmemoManager; let bob: OmemoManager; let memory: Memory; let bobBundle: OMEMO2LocalBundle }
    private var previousRealm: Realm.Configuration!
    private var keeper: Realm!
    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "N04-Replay-\(UUID())")
        keeper = try WRealm.safe()
    }
    override func tearDown() {
        keeper = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        super.tearDown()
    }

    func testChangedKeyMACIsFailedAfterPreviouslyAuthenticatedCounter() throws {
        let f = try fixture(); let initial = try content(f)
        assertVerified(f.bob.prepareIncoming(initial))
        try exchangeReply(f)
        let wire = try content(f)
        assertVerified(f.bob.prepareIncoming(wire))
        let bad = XMPPMessage(from: wire.copy() as! DDXMLElement)
        let key = try XCTUnwrap(bad.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "header")?.element(forName: "keys")?.element(forName: "key"))
        var bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(key.stringValue)); XCTAssertEqual(Array(bytes.prefix(2)), [0x0a, 0x10]); bytes[2] ^= 1
        key.stringValue = bytes.base64EncodedString()
        assertFailedWithoutMutation(bad, f: f)
        assertDuplicateWithoutMutation(wire, f: f)
    }
    func testChangedPayloadIsFailedEvenWhenEncryptedKeyIsAnExactReplay() throws {
        let f = try fixture(); let wire = try content(f)
        assertVerified(f.bob.prepareIncoming(wire))
        let bad = XMPPMessage(from: wire.copy() as! DDXMLElement)
        let payload = try XCTUnwrap(bad.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "payload"))
        var bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(payload.stringValue)); bytes[0] ^= 1
        payload.stringValue = bytes.base64EncodedString()
        assertFailedWithoutMutation(bad, f: f)
    }
    func testRecipientBindingCannotBeChangedOnAnExactCiphertextReplay() throws {
        let f = try fixture(); let wire = try content(f)
        assertVerified(f.bob.prepareIncoming(wire))
        let bad = XMPPMessage(from: wire.copy() as! DDXMLElement)
        bad.addAttribute(withName: "to", stringValue: "another@example.test")
        assertFailedWithoutMutation(bad, f: f)
    }
    func testAuthenticatedOldDHKEXReplayRemainsDuplicateAfterRatchetTransitionAndRestart() throws {
        let f = try fixture(); let original = try content(f)
        assertVerified(f.bob.prepareIncoming(original))
        try exchangeReply(f)
        let next = try content(f, body: "next ratchet")
        assertVerified(f.bob.prepareIncoming(next))
        f.bob.omemo2Storage = try XabberOMEMO2Storage(owner: f.bob.owner, persistence: f.memory)
        assertDuplicateWithoutMutation(original, f: f)
        assertDuplicateWithoutMutation(next, f: f)
    }
    func testExactAuthenticatedReplayIsConsumedInLiveMAMAndBothCarbonRoutes() throws {
        let f = try fixture(); let wire = try content(f)
        assertVerified(f.bob.prepareIncoming(wire))
        let stamp = try XCTUnwrap(wire.element(forName: "time", xmlns: "https://xabber.com/protocol/delivery")?.attributeStringValue(forName: "stamp"))
        for route in ["live", "mam", "sent", "received"] {
            let packet: XMPPMessage
            if route == "live" { packet = wire }
            else if route == "mam" {
                packet = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.bob.owner)' to='\(f.bob.owner)'><result xmlns='urn:xmpp:mam:2' id='archive-\(route)' queryid='query'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(stamp)'/>\(wire.xmlString)</forwarded></result></message>")
            } else {
                packet = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.bob.owner)' to='\(f.bob.owner)'><\(route) xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(stamp)'/>\(wire.xmlString)</forwarded></\(route)></message>")
            }
            assertDuplicateWithoutMutation(packet, f: f)
        }
    }
    func testReplaySurvivesMultipleCandidateSnapshotsWithoutBeingReplacedByLastMACFailure() throws {
        let f = try fixture(); _ = try content(f) // Older, unused peer session.
        try initiate(f.alice, to: f.bob, bundle: f.bobBundle)
        let middle = try content(f)
        assertVerified(f.bob.prepareIncoming(middle))
        try exchangeReply(f)
        let regular = try content(f, body: "regular middle session")
        assertVerified(f.bob.prepareIncoming(regular))
        // A subsequent initiation selects a still published OPK. N06 now
        // erases the previously consumed private key after live ingress.
        let currentBundle = try XCTUnwrap(f.bob.omemo2Storage).localBundle()
        XCTAssertNotEqual(currentBundle.preKeys.first?.id, f.bobBundle.preKeys.first?.id)
        try initiate(f.alice, to: f.bob, bundle: currentBundle)
        assertVerified(f.bob.prepareIncoming(try content(f, body: "new receive-only session")))
        assertDuplicateWithoutMutation(regular, f: f)
    }
    func testFailedPayloadValidationDoesNotRecordReceiptOrAdvanceSnapshot() throws {
        let f = try fixture(); let wire = try content(f)
        let bad = XMPPMessage(from: wire.copy() as! DDXMLElement)
        let payload = try XCTUnwrap(bad.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "payload"))
        var bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(payload.stringValue)); bytes[0] ^= 1
        payload.stringValue = bytes.base64EncodedString()
        assertFailedWithoutMutation(bad, f: f)
        assertVerified(f.bob.prepareIncoming(wire))
        assertDuplicateWithoutMutation(wire, f: f)
    }
    func testFailedProtectedSaveDoesNotCreateAReplayReceipt() throws {
        let f = try fixture(); let wire = try content(f)
        f.memory.failWrites = true
        assertFailedWithoutMutation(wire, f: f)
        f.memory.failWrites = false
        assertVerified(f.bob.prepareIncoming(wire))
        assertDuplicateWithoutMutation(wire, f: f)
    }
    func testAuthenticatedEmptyControlHasExactReplayProofWithoutBubble() throws {
        let f = try fixture()
        let cipher = try XCTUnwrap(f.alice.omemo2Storage).encrypt(Data(repeating: 0, count: 32), jid: f.bob.owner, deviceID: 42)
        let wire = try message(cipher, payload: nil, from: f.alice.owner, to: f.bob.owner, sid: 41, rid: 42)
        guard case .consumed(.control) = f.bob.prepareIncoming(wire) else { return XCTFail("Expected verified empty control") }
        assertDuplicateWithoutMutation(wire, f: f)
        let bad = XMPPMessage(from: wire.copy() as! DDXMLElement)
        let payload = DDXMLElement(name: "payload", xmlns: OmemoManager.xmlns)
        payload.stringValue = Data([1]).base64EncodedString()
        bad.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.addChild(payload)
        assertFailedWithoutMutation(bad, f: f)
    }

    func testOuterKEXEncodingAliasesHaveOneReplayFingerprint() throws {
        let f = try fixture()
        let original = try content(f)
        let key = try keyElement(original)
        let bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(key.stringValue))
        let exchange = try OMEMOKeyExchange(serializedData: bytes)
        var aliasEK = exchange.ephemeralKey
        aliasEK[31] ^= 0x80
        let alias = try OMEMOKeyExchange(preKeyID: exchange.preKeyID, signedPreKeyID: exchange.signedPreKeyID,
            identityKey: exchange.identityKey, ephemeralKey: aliasEK, message: exchange.message)
        let originalFingerprint = try replayFingerprint(original, f: f)
        // Outer fields are unauthenticated protobuf metadata. None changes
        // the exact MAC-bearing message, identity, IDs or canonical EK.
        let encodedAliases = [
            try alias.serializedData(),
            Data([0x08, UInt8(exchange.preKeyID) | 0x80, 0]) + bytes.dropFirst(2),
            bytes + Data([0x98, 0x06, 0x01])
        ]
        for encoded in encodedAliases {
            let replay = XMPPMessage(from: original.copy() as! DDXMLElement)
            try keyElement(replay).stringValue = encoded.base64EncodedString()
            XCTAssertEqual(try replayFingerprint(replay, f: f), originalFingerprint)
        }
    }

    func testKEXReplayFingerprintKeepsMACAndExactAuthenticatedMessageBytes() throws {
        let f = try fixture()
        let original = try content(f)
        let bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(keyElement(original).stringValue))
        let exchange = try OMEMOKeyExchange(serializedData: bytes)
        var damagedMAC = exchange.message.mac
        damagedMAC[0] ^= 1
        let changedMessages = [
            try OMEMOAuthenticatedMessage(mac: damagedMAC, message: exchange.message.message),
            try OMEMOAuthenticatedMessage(mac: exchange.message.mac,
                message: exchange.message.message + Data([0xa0, 0x06, 0x01]))
        ]
        let originalFingerprint = try replayFingerprint(original, f: f)
        for message in changedMessages {
            let changed = try OMEMOKeyExchange(preKeyID: exchange.preKeyID, signedPreKeyID: exchange.signedPreKeyID,
                identityKey: exchange.identityKey, ephemeralKey: exchange.ephemeralKey, message: message)
            let packet = XMPPMessage(from: original.copy() as! DDXMLElement)
            try keyElement(packet).stringValue = changed.serializedData().base64EncodedString()
            XCTAssertNotEqual(try replayFingerprint(packet, f: f), originalFingerprint)
        }
    }

    func testEquivalentKEXReplayRemainsDuplicateAfterNativeSessionSnapshotIsPruned() throws {
        let f = try fixture()
        f.bob.omemo2PreKeyCleanup.beginCatchUp(id: UUID())
        let original = try content(f)
        assertVerified(f.bob.prepareIncoming(original))
        let storage = try XCTUnwrap(f.bob.omemo2Storage)
        XCTAssertFalse(try storage.consumedPreKeyIDs().isEmpty)
        let saved = try XCTUnwrap(f.memory.records[f.bob.owner])
        var state = try XCTUnwrap(PropertyListSerialization.propertyList(from: saved, format: nil) as? [String: Any])
        let receipts = try XCTUnwrap(state["authenticatedReceiveFingerprints"] as? [Data])
        XCTAssertTrue(receipts.contains(try replayFingerprint(original, f: f)))
        state["sessions"] = [String: Any]()
        state["currentSessions"] = [String: Any]()
        state["controlsNeeded"] = []
        f.memory.records[f.bob.owner] = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        XCTAssertFalse(try storage.sessionExists(jid: f.alice.owner, deviceID: 41))
        assertDuplicateWithoutMutation(original, f: f)
        let beforeReplay = f.memory.records[f.bob.owner]
        let consumedPreKeys = try storage.consumedPreKeyIDs()

        let replay = XMPPMessage(from: original.copy() as! DDXMLElement)
        let key = try keyElement(replay)
        let parsed = try OMEMOKeyExchange(serializedData: Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(key.stringValue)))
        var aliasEK = parsed.ephemeralKey
        aliasEK[31] ^= 0x80
        let aliased = try OMEMOKeyExchange(preKeyID: parsed.preKeyID, signedPreKeyID: parsed.signedPreKeyID,
            identityKey: parsed.identityKey, ephemeralKey: aliasEK, message: parsed.message)
        key.stringValue = try aliased.serializedData().base64EncodedString()

        XCTAssertEqual(try replayFingerprint(replay, f: f), try replayFingerprint(original, f: f))
        assertDuplicateWithoutMutation(replay, f: f)
        XCTAssertEqual(f.memory.records[f.bob.owner], beforeReplay)
        XCTAssertEqual(try storage.consumedPreKeyIDs(), consumedPreKeys)
    }

    private func keyElement(_ message: XMPPMessage) throws -> DDXMLElement {
        try XCTUnwrap(message.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?
            .element(forName: "header")?.element(forName: "keys")?.element(forName: "key"))
    }

    private func replayFingerprint(_ packet: XMPPMessage, f: Fixture) throws -> Data {
        try XCTUnwrap(OMEMO2ReplayProtection.fingerprint(for: packet, owner: f.bob.owner, localDeviceID: 42))
    }

    private func fixture() throws -> Fixture {
        let memory = Memory()
        let alice = OmemoManager(withOwner: "n04-alice-\(UUID().uuidString.lowercased())@example.test")
        let bob = OmemoManager(withOwner: "n04-bob-\(UUID().uuidString.lowercased())@example.test")
        let a = try XabberOMEMO2Storage(owner: alice.owner, persistence: memory)
        let b = try XabberOMEMO2Storage(owner: bob.owner, persistence: memory)
        _ = try a.prepare(deviceID: 41, preKeyCount: 5); let bundle = try b.prepare(deviceID: 42, preKeyCount: 5)
        alice.omemo2Storage = a; bob.omemo2Storage = b
        _ = try alice.ensureOMEMO2Prepared(); _ = try bob.ensureOMEMO2Prepared()
        try initiate(alice, to: bob, bundle: bundle)
        return Fixture(alice: alice, bob: bob, memory: memory, bobBundle: bundle)
    }
    private func initiate(_ sender: OmemoManager, to receiver: OmemoManager, bundle: OMEMO2LocalBundle) throws {
        let pk = try XCTUnwrap(bundle.preKeys.first)
        try XCTUnwrap(sender.omemo2Storage).initiateSession(jid: receiver.owner, deviceID: bundle.deviceID, bundle: OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey, signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature, preKey: pk.publicKey, preKeyID: pk.id))
    }
    private func content(_ f: Fixture, body: String = "verified replay") throws -> XMPPMessage {
        let xml = "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>\(body)</body></content><rpad/><from jid='\(f.alice.owner)'/><to jid='\(f.bob.owner)'/></envelope>"
        let sealed = try Omemo2PayloadCodec.seal(Omemo2PayloadCodec.prepareOutgoingXML(xml))
        let cipher = try XCTUnwrap(f.alice.omemo2Storage).encrypt(sealed.keyAndMAC, jid: f.bob.owner, deviceID: 42)
        return try message(cipher, payload: sealed.ciphertext, from: f.alice.owner, to: f.bob.owner, sid: 41, rid: 42)
    }
    private func exchangeReply(_ f: Fixture) throws {
        let cipher = try XCTUnwrap(f.bob.omemo2Storage).encrypt(Data(repeating: 0, count: 32), jid: f.alice.owner, deviceID: 41)
        let wire = try message(cipher, payload: nil, from: f.bob.owner, to: f.alice.owner, sid: 42, rid: 41)
        guard case .consumed(.control) = f.alice.prepareIncoming(wire) else { return XCTFail("Expected authenticated reply ratchet") }
    }
    private func message(_ cipher: OMEMO2Ciphertext, payload: Data?, from: String, to: String, sid: Int, rid: Int) throws -> XMPPMessage {
        let payloadXML = payload.map { "<payload>\($0.base64EncodedString())</payload>" } ?? ""
        return try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(from)' to='\(to)' id='\(UUID())'><time xmlns='https://xabber.com/protocol/delivery' by='\(to)' stamp='\(Date().XMPPFormattedDate)'/><encrypted xmlns='urn:xmpp:omemo:2'><header sid='\(sid)'><keys jid='\(to)'><key rid='\(rid)'\(cipher.isKeyExchange ? " kex='true'" : "")>\(cipher.data.base64EncodedString())</key></keys></header>\(payloadXML)</encrypted></message>")
    }
    private func assertVerified(_ result: OMEMOReceiveResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .verified = result else { return XCTFail("Expected successful authenticated content, got \(result)", file: file, line: line) }
    }
    private func assertFailedWithoutMutation(_ wire: XMPPMessage, f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        let before = f.memory.records[f.bob.owner]
        guard case .failed = f.bob.prepareIncoming(wire) else { return XCTFail("Unproven or tampered ciphertext must fail, never silent duplicate", file: file, line: line) }
        XCTAssertEqual(f.memory.records[f.bob.owner], before, file: file, line: line)
    }
    private func assertDuplicateWithoutMutation(_ wire: XMPPMessage, f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        let before = f.memory.records[f.bob.owner]
        guard case .consumed(.duplicate) = f.bob.prepareIncoming(wire) else { return XCTFail("Expected exact authenticated replay", file: file, line: line) }
        XCTAssertEqual(f.memory.records[f.bob.owner], before, file: file, line: line)
    }
}
