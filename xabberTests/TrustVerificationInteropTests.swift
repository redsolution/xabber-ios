import CryptoSwift
import CryptoKit
import Foundation
import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

/// Fixtures follow the current XEP-TRUST document, independently of the builder.
final class TrustVerificationInteropTests: XCTestCase {
    private let sid = "AAECAwQFBgcICQoLDA0ODw=="
    private let cipher = Data(repeating: 7, count: 48).base64EncodedString()
    private let iv = Data(repeating: 8, count: 16).base64EncodedString()
    private let mac = Data(repeating: 9, count: 32).base64EncodedString()
    private var previousRealm: Realm.Configuration!
    private var realm: Realm!
    private let owner = "owner@example.test"
    private let peer = "peer@example.test"

    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "TrustVerificationInterop-\(UUID())")
        realm = try WRealm.safe()
    }
    override func tearDown() {
        realm = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        super.tearDown()
    }
    private func message(_ payload: String, from: String = "peer@example.test/phone") throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: "<message from='\(from)' to='\(owner)/tablet' id='\(UUID())'>\(payload)</message>", options: 0)
        return XMPPMessage(from: try XCTUnwrap(document.rootElement()))
    }
    private func request(_ attrs: String = "") -> String {
        "<request xmlns='urn:xabber:trust' session-id='\(sid)' protocol='urn:xmpp:omemo:2' device-id='42' expires='4102444800' \(attrs)/>"
    }
    private func session(role: VerificationSessionStorageItem.VerificationRole, state: VerificationSessionStorageItem.VerififcationState) throws -> VerificationSessionStorageItem {
        let value = VerificationSessionStorageItem()
        value.owner = owner; value.ownerJid = owner; value.jid = peer; value.peerBareJid = peer
        value.sid = sid; value.primary = VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid)
        value.opponentDeviceId = 42; value.remoteDeviceId = 42
        value.fullJID = "\(peer)/phone"; value.peerFullJid = value.fullJID
        value.role = role; value.state = state; value.expires = 4_102_444_800
        try realm.write { realm.add(value) }
        return value
    }
    func testPublishedRequestUsesCurrentProtocolAndTarget() {
        let element = XEPTrustEnvelope.makeTrustElement(sid: sid, expires: 4_102_444_800,
            kind: .request(deviceId: 11, targetDeviceId: 42))
        XCTAssertEqual(element.name, "request")
        XCTAssertEqual(element.xmlns(), "urn:xabber:trust")
        XCTAssertEqual(element.attributeStringValue(forName: "session-id"), sid)
        XCTAssertEqual(element.attributeStringValue(forName: "protocol"), "urn:xmpp:omemo:2")
        XCTAssertEqual(element.attributeStringValue(forName: "target"), "42")
    }
    func testCurrentRequestParsesTarget() throws {
        let envelope = try XCTUnwrap(XEPTrustEnvelope.parse(from: message(request("target='11'"))))
        guard case let .request(deviceID, target) = envelope.kind else { return XCTFail("Wrong kind") }
        XCTAssertEqual(deviceID, 42); XCTAssertEqual(target, 11)
    }
    func testCurrentChallengeParsesNonceAndIV() throws {
        let envelope = try XCTUnwrap(XEPTrustEnvelope.parse(from: message("<challenge xmlns='urn:xabber:trust' session-id='\(sid)' device-id='42'><nonce iv='\(iv)'>\(cipher)</nonce></challenge>")))
        guard case let .challenge(id, ciphertext, parsedIV) = envelope.kind else { return XCTFail("Wrong kind") }
        XCTAssertEqual(id, 42); XCTAssertEqual(ciphertext, cipher); XCTAssertEqual(parsedIV, iv)
    }
    func testResponseBuilderUsesNonceAndKeyMACWithoutUnboundDeviceID() {
        let element = XEPTrustEnvelope.makeTrustElement(sid: sid, expires: 4_102_444_800,
            kind: .response(deviceId: 11, ciphertext: cipher, iv: iv, hmac: mac))
        XCTAssertEqual(element.name, "response")
        XCTAssertEqual(element.element(forName: "nonce")?.stringValue, cipher)
        XCTAssertEqual(element.element(forName: "nonce")?.attributeStringValue(forName: "iv"), iv)
        XCTAssertEqual(element.element(forName: "key-mac")?.stringValue, mac)
        XCTAssertNil(element.attributeStringValue(forName: "device-id"))
    }
    func testCurrentResponseUsesSessionBoundDevice() throws {
        let envelope = try XCTUnwrap(XEPTrustEnvelope.parse(from: message("<response xmlns='urn:xabber:trust' session-id='\(sid)'><nonce iv='\(iv)'>\(cipher)</nonce><key-mac>\(mac)</key-mac></response>")))
        guard case let .response(id, ciphertext, parsedIV, parsedMAC) = envelope.kind else { return XCTFail("Wrong kind") }
        XCTAssertEqual(id, 0); XCTAssertEqual(ciphertext, cipher); XCTAssertEqual(parsedIV, iv); XCTAssertEqual(parsedMAC, mac)
    }
    func testLegacyWrapperIsRejected() throws {
        XCTAssertNil(XEPTrustEnvelope.parse(from: try message("<trust xmlns='urn:xmpp:trust:0' sid='\(sid)' timestamp='1' expires='4102444800'><request device-id='42'/></trust>")))
    }
    func testWrongProtocolRequestIsRejected() throws {
        XCTAssertNil(XEPTrustEnvelope.parse(from: try message(request().replacingOccurrences(of: "urn:xmpp:omemo:2", with: "urn:other"))))
    }
    func testRequestRequiresProtocol() throws {
        XCTAssertNil(XEPTrustEnvelope.parse(from: try message(request().replacingOccurrences(of: " protocol='urn:xmpp:omemo:2'", with: ""))))
    }
    func testDuplicateSessionPayloadIsRejected() throws {
        XCTAssertNil(XEPTrustEnvelope.parse(from: try message(request() + request())))
    }
    func testInvalidTargetIsRejectedRatherThanBroadcast() throws {
        XCTAssertNil(XEPTrustEnvelope.parse(from: try message(request("target='bad'"))))
    }
    func testInconsistentSenderAbortsWithoutReplacingPinnedChallengePeer() throws {
        let value = try session(role: .initiator, state: .sentRequest)
        let manager = AuthenticatedKeyExchangeManager(withOwner: owner)
        _ = manager.didReceivedVerificationMessage(message: try message("<challenge xmlns='urn:xabber:trust' session-id='\(sid)' device-id='42'><nonce iv='\(iv)'>\(cipher)</nonce></challenge>", from: "attacker@example.test/phone"))
        XCTAssertEqual(value.jid, peer); XCTAssertEqual(value.state, .failed)
    }
    func testInconsistentDeviceAbortsWithoutReplacingTargetedChallengePeer() throws {
        let value = try session(role: .initiator, state: .sentRequest)
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message("<challenge xmlns='urn:xabber:trust' session-id='\(sid)' device-id='99'><nonce iv='\(iv)'>\(cipher)</nonce></challenge>"))
        XCTAssertEqual(value.opponentDeviceId, 42); XCTAssertEqual(value.state, .failed)
    }
    func testInconsistentAbortSenderFailsRatherThanCancelsCurrentSession() throws {
        let value = try session(role: .initiator, state: .sentRequest)
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message("<abort xmlns='urn:xabber:trust' session-id='\(sid)' reason='cancel'/>", from: "attacker@example.test/phone"))
        XCTAssertEqual(value.state, .failed)
    }
    func testEarlySuccessCannotEstablishTrust() throws {
        let value = try session(role: .responder, state: .receivedRequest)
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message("<success xmlns='urn:xabber:trust' session-id='\(sid)'/>"))
        XCTAssertEqual(value.state, .receivedRequest)
    }
    func testMissingIdentityCannotBeMarkedTrusted() throws {
        let device = SignalDeviceStorageItem()
        device.owner = owner; device.jid = peer; device.deviceId = 42
        device.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: peer, deviceId: 42)
        device.fingerprint = String(repeating: "a", count: 64)
        try realm.write { realm.add(device) }
        AuthenticatedKeyExchangeManager(withOwner: owner).writeTrustedDevice(jid: peer, deviceId: 42)
        XCTAssertEqual(device.state, .unknown)
    }
    func testXENRequiresOriginalSender() throws {
        let outer = try message("<notification xmlns='urn:xabber:xen:0'><forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' from='\(peer)/phone'>\(request())</message></forwarded></notification>", from: "relay.example.test")
        XCTAssertNil(XEPTrustForwardedExtractor.trustMessage(from: outer, trustedNotificationSenders: ["relay.example.test"]))
    }
    func testXENRejectsDuplicateOriginalSenderEvenWhenLastValueMatches() throws {
        let outer = try message("<notification xmlns='urn:xabber:xen:0'><forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' from='\(peer)/phone'>\(request())</message></forwarded></notification><addresses xmlns='http://jabber.org/protocol/address'><address type='ofrom' jid='attacker@example.test/p'/><address type='ofrom' jid='\(peer)/phone'/></addresses>", from: "relay.example.test")
        XCTAssertNil(XEPTrustForwardedExtractor.trustMessage(from: outer, trustedNotificationSenders: ["relay.example.test"]))
    }
    func testQuotedForwardCannotSupplyVerificationSender() throws {
        let outer = try message("<forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' from='\(peer)/phone'>\(request())</message></forwarded>", from: "attacker@example.test/p")
        XCTAssertNil(XEPTrustForwardedExtractor.trustMessage(from: outer, trustedNotificationSenders: ["relay.example.test"]))
    }
    func testOwnSiblingAcceptanceClosesOnlyResponderRequest() throws {
        let value = try session(role: .responder, state: .receivedRequest)
        try realm.write { value.jid = owner; value.peerBareJid = owner }
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message("<accept xmlns='urn:xabber:trust' session-id='\(sid)' device-id='99'/>", from: "\(owner)/sibling"))
        XCTAssertEqual(value.state, .cancelled)
    }
    func testPrefixedCurrentPayloadParsesByNamespaceURI() throws {
        let xml = "<t:request xmlns:t='urn:xabber:trust' session-id='\(sid)' protocol='urn:xmpp:omemo:2' device-id='42' expires='4102444800'/>"
        XCTAssertNotNil(XEPTrustEnvelope.parse(from: try message(xml)))
    }
    private func withPreparedPeer(_ body: (Account, CryptoKit.Curve25519.Signing.PrivateKey, SignalDeviceStorageItem, OMEMO2LocalBundle) throws -> Void) throws {
        let previousAccounts = AccountManager.shared.users
        let account = Account(jid: owner, queue: DispatchQueue(label: "TrustVerificationPositive"))
        AccountManager.shared.users = previousAccounts + [account]
        defer {
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            AccountManager.shared.users = previousAccounts
        }
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: Memory())
        let bundle = try storage.prepare(deviceID: 11, preKeyCount: 2)
        account.omemo.omemo2Storage = storage
        try account.omemo.localStore.bindExistingDevice(deviceID: 11)
        let peerKey = CryptoKit.Curve25519.Signing.PrivateKey()
        var peerDevice: SignalDeviceStorageItem!
        try realm.write {
            for (jid, id, key) in [(peer, 42, peerKey.publicKey.rawRepresentation), (owner, 11, bundle.identityKey)] {
                let stored = SignalIdentityStorageItem()
                stored.owner = owner; stored.jid = jid; stored.deviceId = id
                stored.primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: jid, deviceId: id)
                stored.identityKey = key.base64EncodedString()
                let device = SignalDeviceStorageItem()
                device.owner = owner; device.jid = jid; device.deviceId = id; device.primary = stored.primary
                device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: key)
                device.lastTrustedItemsUpdateTimestamp = "1234"
                realm.add(stored); realm.add(device)
                if jid == peer { peerDevice = device }
            }
        }
        try body(account, peerKey, peerDevice, bundle)
    }

    private final class RecordingManager: AuthenticatedKeyExchangeManager {
        var sent: [XMPPMessage] = []
        override func getSignalMessagePacket(message: XMPPMessage, to: XMPPJID, ttl: Int) -> DDXMLElement {
            sent.append(XMPPMessage(from: SCEReceivePolicy.canonicalElementCopy(message)))
            return super.getSignalMessagePacket(message: message, to: to, ttl: ttl)
        }
        var kinds: [String] {
            sent.compactMap { ($0.children ?? []).compactMap { $0 as? DDXMLElement }
                .first { $0.uri == XEPTrustEnvelope.xmlns }?.localName }
        }
    }

    func testResponderBroadcastsAcceptBeforeSendingChallenge() throws {
        try withPreparedPeer { account, _, _, _ in
            let manager = RecordingManager(withOwner: owner)
            account.akeManager = manager
            let value = try session(role: .responder, state: .receivedRequest)
            try realm.write { value.myDeviceId = 11; value.localDeviceId = 11 }
            XCTAssertNotNil(manager.acceptVerificationRequest(jid: peer, sid: sid))
            XCTAssertEqual(manager.kinds, ["accept", "challenge"], "XEP-TRUST §§11–12 coordinate responder siblings before challenging the initiator")
            XCTAssertEqual(manager.sent.first?.to?.full, owner)
            XCTAssertEqual(manager.sent.last?.to?.full, "\(peer)/phone")
        }
    }

    func testInvalidDecryptedResponseNonceAbortsLocalSessionAndNotifiesPinnedPeer() throws {
        try withPreparedPeer { account, peerKey, device, bundle in
            let manager = RecordingManager(withOwner: owner)
            account.akeManager = manager
            let value = try session(role: .responder, state: .receivedRequest)
            try realm.write { value.myDeviceId = 11; value.localDeviceId = 11 }
            let code = try XCTUnwrap(manager.acceptVerificationRequest(jid: peer, sid: sid))
            let shared = try Omemo2IdentityRepresentation.sharedSecret(privateKey: peerKey.rawRepresentation, peerIdentity: bundle.identityKey)
            let key = Data(SHA256.hash(data: shared + Data(code.utf8) + Data(sid.utf8)))
            let remoteIV = Data(repeating: 29, count: 16)
            // Valid CBC and padding, but not the required 32-octet nonce.
            let ciphertext = try AES(key: Array(key), blockMode: CBC(iv: Array(remoteIV)))
                .encrypt(Array(Data(repeating: 23, count: 35)))
            XCTAssertEqual(ciphertext.count, 48)
            let payload = "<response xmlns='urn:xabber:trust' session-id='\(sid)'><nonce iv='\(remoteIV.base64EncodedString())'>\(Data(ciphertext).base64EncodedString())</nonce><key-mac>\(mac)</key-mac></response>"
            _ = manager.didReceivedVerificationMessage(message: try message(payload))
            XCTAssertEqual(value.state, .failed)
            XCTAssertEqual(device.state, .unknown)
            XCTAssertEqual(manager.kinds.last, "abort")
            XCTAssertEqual(manager.sent.last?.to?.full, "\(peer)/phone")
            XCTAssertEqual(manager.sent.last?.element(forName: "abort", xmlns: XEPTrustEnvelope.xmlns)?.attributeStringValue(forName: "reason"), "fail")
        }
    }

    func testInconsistentPinnedResourceAbortsToOriginalPeerOnly() throws {
        let value = try session(role: .initiator, state: .sentRequest)
        let manager = RecordingManager(withOwner: owner)
        _ = manager.didReceivedVerificationMessage(message: try message("<challenge xmlns='urn:xabber:trust' session-id='\(sid)' device-id='42'><nonce iv='\(iv)'>\(cipher)</nonce></challenge>", from: "\(peer)/other"))
        XCTAssertEqual(value.state, .failed)
        XCTAssertEqual(value.peerFullJid, "\(peer)/phone")
        XCTAssertEqual(manager.kinds, ["abort"])
        XCTAssertEqual(manager.sent.last?.to?.full, "\(peer)/phone")
    }

    func testReusedCurrentSessionIDWithDifferentInitiatorAbortsRatherThanReplacingSession() throws {
        let value = try session(role: .responder, state: .receivedRequest)
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message(request(), from: "other@example.test/device"))
        XCTAssertEqual(value.state, .failed)
        XCTAssertEqual(value.jid, peer)
        XCTAssertEqual(value.opponentDeviceId, 42)
    }

    func testReusedCurrentSessionIDWithDifferentInitiatorDeviceAborts() throws {
        let value = try session(role: .responder, state: .receivedRequest)
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message(request().replacingOccurrences(of: "device-id='42'", with: "device-id='99'")))
        XCTAssertEqual(value.state, .failed)
        XCTAssertEqual(value.opponentDeviceId, 42)
    }

    func testLocalRequestEchoDoesNotAbortOwnDeviceVerification() throws {
        try withPreparedPeer { account, _, _, _ in
            account.xmppStream.myJID = XMPPJID(string: "\(owner)/tablet")
            let value = try session(role: .initiator, state: .sentRequest)
            try realm.write { value.jid = owner; value.peerBareJid = owner; value.peerFullJid = ""; value.fullJID = "" }
            let local = request("target='42'").replacingOccurrences(of: "device-id='42'", with: "device-id='11'")
            _ = account.akeManager.didReceivedVerificationMessage(message: try message(local, from: "\(owner)/tablet"))
            XCTAssertEqual(value.state, .sentRequest)
        }
    }

    func testUnknownSessionIDDoesNotAbortAnUnrelatedCurrentSession() throws {
        let value = try session(role: .initiator, state: .sentRequest)
        let unknown = Data(repeating: 99, count: 16).base64EncodedString()
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message("<abort xmlns='urn:xabber:trust' session-id='\(unknown)' reason='fail'/>"))
        XCTAssertEqual(value.state, .sentRequest)
    }

    func testMalformedChallengeNonceAbortsKnownSessionWithoutReplacingPeer() throws {
        let value = try session(role: .initiator, state: .sentRequest)
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message("<challenge xmlns='urn:xabber:trust' session-id='\(sid)' device-id='42'><nonce iv='\(iv)'>not-base64!</nonce></challenge>"))
        XCTAssertEqual(value.state, .failed)
        XCTAssertEqual(value.peerFullJid, "\(peer)/phone")
    }

    func testMalformedVerifyMACAbortsKnownSession() throws {
        let value = try session(role: .initiator, state: .responseSent)
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message("<verify xmlns='urn:xabber:trust' session-id='\(sid)'><key-mac>bad!</key-mac></verify>"))
        XCTAssertEqual(value.state, .failed)
    }

    func testReusedSessionIDWithUnsupportedProtocolIsRejectedWithoutChangingItsContext() throws {
        let value = try session(role: .responder, state: .receivedRequest)
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message(request().replacingOccurrences(of: "urn:xmpp:omemo:2", with: "urn:unsupported")))
        XCTAssertEqual(value.state, .receivedRequest)
        XCTAssertEqual(value.jid, peer)
    }

    func testAcceptingAnExpiredExistingRequestImmediatelyAbortsAsTimeout() throws {
        try withPreparedPeer { account, _, device, _ in
            let manager = RecordingManager(withOwner: owner)
            account.akeManager = manager
            let value = try session(role: .responder, state: .receivedRequest)
            try realm.write { value.myDeviceId = 11; value.localDeviceId = 11; value.expires = Date().timeIntervalSince1970 - 1 }
            XCTAssertNil(account.akeManager.acceptVerificationRequest(jid: peer, sid: sid))
            XCTAssertEqual(value.state, .timeout)
            XCTAssertEqual(device.state, .unknown)
            XCTAssertEqual(manager.kinds, ["abort"])
            XCTAssertEqual(manager.sent.last?.element(forName: "abort", xmlns: XEPTrustEnvelope.xmlns)?.attributeStringValue(forName: "reason"), "timeout")
        }
    }

    func testEnteringCodeAfterDeadlineImmediatelyAbortsAsTimeout() throws {
        let value = try session(role: .initiator, state: .receivedRequestAccept)
        try realm.write { value.expires = Date().timeIntervalSince1970 - 1 }
        AuthenticatedKeyExchangeManager(withOwner: owner).processSecretCode(code: "123456", sid: sid)
        XCTAssertEqual(value.state, .timeout)
    }
    private func exchangeAsResponder(account: Account, peerKey: CryptoKit.Curve25519.Signing.PrivateKey,
                                     peerDevice: SignalDeviceStorageItem, bundle: OMEMO2LocalBundle, corruptMAC: Bool = false) throws -> VerificationSessionStorageItem {
        let value = try session(role: .responder, state: .receivedRequest)
        try realm.write { value.myDeviceId = 11; value.localDeviceId = 11 }
        let code = try XCTUnwrap(account.akeManager.acceptVerificationRequest(jid: peer, sid: sid))
        let localNonce = try XCTUnwrap(Data(base64Encoded: value.localNonce))
        let remoteNonce = Data(repeating: 23, count: 32), remoteIV = Data(repeating: 29, count: 16)
        let shared = try Omemo2IdentityRepresentation.sharedSecret(privateKey: peerKey.rawRepresentation, peerIdentity: bundle.identityKey)
        let encryptionKey = Data(SHA256.hash(data: shared + Data(code.utf8) + Data(sid.utf8)))
        let encrypted = try AES(key: Array(encryptionKey), blockMode: CBC(iv: Array(remoteIV))).encrypt(Array(remoteNonce))
        let trustedKey = Data("42::\(peerDevice.fingerprint.replacingOccurrences(of: " ", with: ""))".utf8)
        var mac = Data(CryptoKit.HMAC<SHA256>.authenticationCode(for: trustedKey + remoteNonce + localNonce,
            using: SymmetricKey(data: encryptionKey)))
        if corruptMAC { mac[0] ^= 1 }
        let xml = "<response xmlns='urn:xabber:trust' session-id='\(sid)'><nonce iv='\(remoteIV.base64EncodedString())'>\(Data(encrypted).base64EncodedString())</nonce><key-mac>\(mac.base64EncodedString())</key-mac></response>"
        _ = account.akeManager.didReceivedVerificationMessage(message: try message(xml))
        return value
    }
    func testRealCodeExchangeCommitsTrustOnlyAfterVerifiedSuccess() throws {
        try withPreparedPeer { account, peerKey, device, bundle in
            let value = try exchangeAsResponder(account: account, peerKey: peerKey, peerDevice: device, bundle: bundle)
            XCTAssertEqual(value.state, .verifySent)
            XCTAssertEqual(device.state, .unknown)
            _ = account.akeManager.didReceivedVerificationMessage(message: try message("<success xmlns='urn:xabber:trust' session-id='\(sid)'/>"))
            XCTAssertEqual(value.state, .trusted); XCTAssertEqual(device.state, .trusted)
            XCTAssertGreaterThan(device.lastTrustSharingTimestamp, 0)
            XCTAssertEqual(device.lastTrustedItemsUpdateTimestamp, "1234")
        }
    }
    func testIncorrectMACDoesNotEstablishTrust() throws {
        try withPreparedPeer { account, peerKey, device, bundle in
            let value = try exchangeAsResponder(account: account, peerKey: peerKey, peerDevice: device, bundle: bundle, corruptMAC: true)
            XCTAssertEqual(value.state, .failed); XCTAssertEqual(device.state, .unknown)
        }
    }
    func testIdentityReplacementBeforeSuccessCannotInheritVerification() throws {
        try withPreparedPeer { account, peerKey, device, bundle in
            let value = try exchangeAsResponder(account: account, peerKey: peerKey, peerDevice: device, bundle: bundle)
            XCTAssertEqual(value.state, .verifySent)
            let replacement = CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
            let stored = try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: device.primary))
            try realm.write {
                stored.identityKey = replacement.base64EncodedString()
                device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: replacement)
            }
            _ = account.akeManager.didReceivedVerificationMessage(message: try message("<success xmlns='urn:xabber:trust' session-id='\(sid)'/>"))
            XCTAssertEqual(device.state, .unknown); XCTAssertNotEqual(value.state, .trusted)
        }
    }
    func testTrustedDeviceCanBeVerifiedAgainByCode() throws {
        try withPreparedPeer { account, _, device, _ in
            try realm.write { device.state = .trusted }
            _ = account.akeManager.didReceivedVerificationMessage(message: try message(request()))
            let value = realm.object(ofType: VerificationSessionStorageItem.self,
                forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid))
            XCTAssertEqual(value?.state, .receivedRequest)
        }
    }
    func testExpiredBoundChallengeImmediatelyClosesSessionAsTimeout() throws {
        let value = try session(role: .initiator, state: .sentRequest)
        try realm.write { value.expires = Date().timeIntervalSince1970 - 10 }
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message("<challenge xmlns='urn:xabber:trust' session-id='\(sid)' device-id='42'><nonce iv='\(iv)'>\(cipher)</nonce></challenge>"))
        XCTAssertEqual(value.state, .timeout)
    }
    func testInconsistentSenderCannotKeepExpiredCurrentSessionOpen() throws {
        let value = try session(role: .initiator, state: .sentRequest)
        try realm.write { value.expires = Date().timeIntervalSince1970 - 10 }
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message("<challenge xmlns='urn:xabber:trust' session-id='\(sid)' device-id='42'><nonce iv='\(iv)'>\(cipher)</nonce></challenge>", from: "attacker@example.test/p"))
        XCTAssertEqual(value.state, .failed)
    }
    func testLocalTrustDecisionAdvancesBeyondPriorClockWithoutResettingPublisherCursor() throws {
        try withPreparedPeer { account, _, device, _ in
            let previous = Int64(Date().timeIntervalSince1970) + 30
            try realm.write { device.lastTrustSharingTimestamp = previous }
            XCTAssertTrue(account.akeManager.writeTrustedDevice(jid: peer, deviceId: 42))
            XCTAssertEqual(device.lastTrustSharingTimestamp, previous + 1)
            XCTAssertEqual(device.lastTrustedItemsUpdateTimestamp, "1234")
        }
    }
    func testChangedFingerprintLocalDecisionDoesNotInheritPreviousTargetClock() throws {
        try withPreparedPeer { account, _, device, _ in
            try realm.write {
                device.state = .fingerprintChanged
                device.lastTrustSharingTimestamp = 5_000_000_000
            }
            let before = Int64(Date().timeIntervalSince1970)

            XCTAssertTrue(account.akeManager.writeTrustedDevice(jid: peer, deviceId: 42))

            XCTAssertEqual(device.state, .trusted)
            XCTAssertGreaterThanOrEqual(device.lastTrustSharingTimestamp, before)
            XCTAssertLessThanOrEqual(device.lastTrustSharingTimestamp, Int64(Date().timeIntervalSince1970) + 1,
                "A different full SID/fingerprint target has an independent decision clock")
        }
    }
    private final class BackgroundRotationResult: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func record(_ value: Error) { lock.lock(); error = value; lock.unlock() }
        func rethrowError() throws { lock.lock(); defer { lock.unlock() }; if let error { throw error } }
    }

    private func cancelSessionOnBackgroundRealm(primary: String) throws {
        let configuration = realm.configuration
        let done = DispatchSemaphore(value: 0)
        let result = BackgroundRotationResult()
        Thread {
            autoreleasepool {
                do {
                    let background = try Realm(configuration: configuration)
                    let value = try XCTUnwrap(background.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: primary))
                    try background.write { value.state = .cancelled }
                } catch { result.record(error) }
            }
            done.signal()
        }.start()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        try result.rethrowError()
    }

    func testStaleRealmChallengeCannotResurrectCancelledSession() throws {
        let value = try session(role: .initiator, state: .sentRequest)
        realm.autorefresh = false
        defer { realm.autorefresh = true }
        try cancelSessionOnBackgroundRealm(primary: value.primary)
        XCTAssertEqual(value.state, .sentRequest, "Prove the foreground read is stale")
        _ = AuthenticatedKeyExchangeManager(withOwner: owner).didReceivedVerificationMessage(message: try message("<challenge xmlns='urn:xabber:trust' session-id='\(sid)' device-id='42'><nonce iv='\(iv)'>\(cipher)</nonce></challenge>"))
        realm.refresh()
        XCTAssertEqual(value.state, .cancelled)
    }

    func testStaleRealmAcceptCannotResurrectCancelledSessionOrSendChallenge() throws {
        try withPreparedPeer { account, _, _, _ in
            let manager = RecordingManager(withOwner: owner)
            account.akeManager = manager
            let value = try session(role: .responder, state: .receivedRequest)
            try realm.write { value.myDeviceId = 11; value.localDeviceId = 11 }
            realm.autorefresh = false
            defer { realm.autorefresh = true }
            try cancelSessionOnBackgroundRealm(primary: value.primary)
            XCTAssertEqual(value.state, .receivedRequest, "Prove the foreground read is stale")
            XCTAssertNil(manager.acceptVerificationRequest(jid: peer, sid: sid))
            realm.refresh()
            XCTAssertEqual(value.state, .cancelled)
            XCTAssertTrue(manager.sent.isEmpty)
        }
    }

    /// Keep the foreground read version stale while a genuinely different
    /// Realm/thread rotates both public identity and its displayed fingerprint.
    private func rotatePeerOnBackgroundRealm(primary: String) throws -> Data {
        let replacement = CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let replacementFingerprint = try Omemo2IdentityRepresentation.fingerprint(for: replacement)
        let configuration = realm.configuration
        let done = DispatchSemaphore(value: 0)
        let result = BackgroundRotationResult()
        Thread {
            autoreleasepool {
                do {
                    let background = try Realm(configuration: configuration)
                    let identity = try XCTUnwrap(background.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary))
                    let device = try XCTUnwrap(background.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary))
                    try background.write {
                        identity.identityKey = replacement.base64EncodedString()
                        device.fingerprint = replacementFingerprint
                        device.state = .unknown
                    }
                } catch { result.record(error) }
            }
            done.signal()
        }.start()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        try result.rethrowError()
        return replacement
    }

    func testStaleRealmManualTrustCannotAuthorizeRotatedIdentity() throws {
        try withPreparedPeer { account, peerKey, device, _ in
            realm.autorefresh = false
            defer { realm.autorefresh = true }
            let oldFingerprint = device.fingerprint
            _ = try rotatePeerOnBackgroundRealm(primary: device.primary)
            XCTAssertEqual(device.fingerprint, oldFingerprint)
            XCTAssertEqual(account.akeManager.getUsersIdentityKey(jid: peer, deviceId: 42), peerKey.publicKey.rawRepresentation)
            XCTAssertFalse(account.akeManager.writeTrustedDevice(jid: peer, deviceId: 42))
            realm.refresh()
            XCTAssertEqual(device.state, .unknown)
            XCTAssertNotEqual(device.fingerprint, oldFingerprint)
        }
    }

    func testStaleRealmSuccessCannotTrustRotatedIdentity() throws {
        try withPreparedPeer { account, peerKey, device, bundle in
            let value = try exchangeAsResponder(account: account, peerKey: peerKey, peerDevice: device, bundle: bundle)
            XCTAssertEqual(value.state, .verifySent)
            realm.autorefresh = false
            defer { realm.autorefresh = true }
            _ = try rotatePeerOnBackgroundRealm(primary: device.primary)
            XCTAssertEqual(account.akeManager.getUsersIdentityKey(jid: peer, deviceId: 42), peerKey.publicKey.rawRepresentation)
            _ = account.akeManager.didReceivedVerificationMessage(message: try message("<success xmlns='urn:xabber:trust' session-id='\(sid)'/>"))
            realm.refresh()
            XCTAssertEqual(device.state, .unknown)
            XCTAssertEqual(value.state, .failed)
        }
    }

    func testStaleRealmVerifyCannotTrustRotatedIdentity() throws {
        try withPreparedPeer { account, peerKey, device, bundle in
            let value = try session(role: .initiator, state: .sentRequest)
            try realm.write { value.myDeviceId = 11; value.localDeviceId = 11 }
            let code = "123456", remoteNonce = Data(repeating: 23, count: 32), remoteIV = Data(repeating: 29, count: 16)
            let shared = try Omemo2IdentityRepresentation.sharedSecret(privateKey: peerKey.rawRepresentation, peerIdentity: bundle.identityKey)
            let encryptionKey = Data(SHA256.hash(data: shared + Data(code.utf8) + Data(sid.utf8)))
            let encrypted = try AES(key: Array(encryptionKey), blockMode: CBC(iv: Array(remoteIV))).encrypt(Array(remoteNonce))
            _ = account.akeManager.didReceivedVerificationMessage(message: try message("<challenge xmlns='urn:xabber:trust' session-id='\(sid)' device-id='42'><nonce iv='\(remoteIV.base64EncodedString())'>\(Data(encrypted).base64EncodedString())</nonce></challenge>"))
            account.akeManager.processSecretCode(code: code, sid: sid)
            XCTAssertEqual(value.state, .responseSent)
            let localNonce = try XCTUnwrap(Data(base64Encoded: value.localNonce))
            let trustedKey = Data("42::\(device.fingerprint.replacingOccurrences(of: " ", with: ""))".utf8)
            let mac = Data(CryptoKit.HMAC<SHA256>.authenticationCode(for: trustedKey + remoteNonce + localNonce,
                using: SymmetricKey(data: encryptionKey)))
            realm.autorefresh = false
            defer { realm.autorefresh = true }
            _ = try rotatePeerOnBackgroundRealm(primary: device.primary)
            XCTAssertEqual(account.akeManager.getUsersIdentityKey(jid: peer, deviceId: 42), peerKey.publicKey.rawRepresentation)
            _ = account.akeManager.didReceivedVerificationMessage(message: try message("<verify xmlns='urn:xabber:trust' session-id='\(sid)'><key-mac>\(mac.base64EncodedString())</key-mac></verify>"))
            realm.refresh()
            XCTAssertEqual(device.state, .unknown)
            XCTAssertEqual(value.state, .failed)
        }
    }

    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }
    func testMACInputIsTrustedKeyAndOrderedNoncesWithoutExtraLabels() throws {
        let previousAccounts = AccountManager.shared.users
        let account = Account(jid: owner, queue: DispatchQueue(label: "TrustVerificationInterop"))
        AccountManager.shared.users = previousAccounts + [account]
        defer {
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            AccountManager.shared.users = previousAccounts
        }
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: Memory())
        _ = try storage.prepare(deviceID: 11, preKeyCount: 2)
        account.omemo.omemo2Storage = storage
        let identity = CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let stored = SignalIdentityStorageItem()
        stored.owner = owner; stored.jid = peer; stored.deviceId = 42
        stored.primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: peer, deviceId: 42)
        stored.identityKey = identity.base64EncodedString()
        let device = SignalDeviceStorageItem()
        device.owner = owner; device.jid = peer; device.deviceId = 42; device.primary = stored.primary
        device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: identity)
        try realm.write { realm.add(stored); realm.add(device) }
        let shared = try Omemo2IdentityRepresentation.sharedSecret(privateKey: storage.identity().privateKey, peerIdentity: identity)
        let code = "ABC234"
        let encryptionKey = Data(SHA256.hash(data: shared + Data(code.utf8) + Data(sid.utf8)))
        let first = Data(repeating: 3, count: 32), second = Data(repeating: 4, count: 32)
        let trustedKey = Data("42::\(device.fingerprint.replacingOccurrences(of: " ", with: ""))".utf8)
        let expected = Data(CryptoKit.HMAC<SHA256>.authenticationCode(for: trustedKey + first + second, using: SymmetricKey(data: encryptionKey)))
        let actual = account.akeManager.makeHMAC(label: "trustedKey_A1", trustedJid: peer, trustedDeviceId: 42,
            sharedJid: peer, sharedDeviceId: 42, firstNonce: Array(first), secondNonce: Array(second), code: code, sid: sid)
        XCTAssertEqual(actual.map { Data($0) }, expected)
    }
    func testXENForwardedCurrentRequestExtractsOriginalSender() throws {
        let outer = try message("<notification xmlns='urn:xabber:xen:0'><forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' from='\(peer)/phone'>\(request())</message></forwarded></notification><addresses xmlns='http://jabber.org/protocol/address'><address type='ofrom' jid='\(peer)/phone'/></addresses>", from: "relay.example.test")
        let inner = try XCTUnwrap(XEPTrustForwardedExtractor.trustMessage(from: outer, trustedNotificationSenders: ["relay.example.test"]))
        XCTAssertEqual(inner.from?.full, "\(peer)/phone")
        XCTAssertNotNil(XEPTrustEnvelope.parse(from: inner))
    }
}
