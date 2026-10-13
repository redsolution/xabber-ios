import Foundation
import XCTest
import CryptoSwift
import RealmSwift
@testable import xabber

final class PushIngressReconciliationTests: XCTestCase {
    private let owner = "owner@example.invalid"
    private let key = Array(repeating: UInt8(11), count: 32)
    private var nodes: [String] = []
    private var savedRealmConfiguration: Realm.Configuration?

    override func setUp() {
        super.setUp()
        savedRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "push-ingress-\(UUID().uuidString)")
    }

    override func tearDown() {
        nodes.forEach { CredentialsManager.shared.removePushCredentials(for: $0) }
        if let savedRealmConfiguration { Realm.Configuration.defaultConfiguration = savedRealmConfiguration }
        super.tearDown()
    }

    func testBareAcceptFromOwnPushNodeEndsIncomingCallAsAnsweredElsewhere() throws {
        let node = try installCredentials(owner: owner)
        let manager = VoIPManager()
        let call = makeCall(outgoing: false)
        let context = manager.registerSession(callId: call.callId, callUUID: call.callUUID,
                                              owner: owner, jid: call.jid, outgoing: false, phase: .ringing)
        manager.currentCall = call
        let payload = try makePayload(node: node, xml: "<accept xmlns='urn:xmpp:jingle-message:0' id='active-call'/>")

        XCTAssertTrue(manager.onReceivePushUpdate(payload))

        XCTAssertNil(manager.currentCall)
        XCTAssertEqual(context.lastTerminationReason, .answeredElsewhere)
        XCTAssertFalse(call.shouldSendReject)
    }

    func testBareAcceptDoesNotTerminateOutgoingCall() throws {
        let node = try installCredentials(owner: owner)
        let manager = VoIPManager()
        let call = makeCall(outgoing: true)
        manager.currentCall = call

        XCTAssertFalse(manager.onReceivePushUpdate(try makePayload(node: node,
            xml: "<accept xmlns='urn:xmpp:jingle-message:0' id='active-call'/>")))

        XCTAssertTrue(manager.currentCall === call)
    }

    func testBareRejectPreservesDetailedTerminationReason() throws {
        let node = try installCredentials(owner: owner)
        let manager = VoIPManager()
        let call = makeCall(outgoing: true)
        let context = manager.registerSession(callId: call.callId, callUUID: call.callUUID,
                                              owner: owner, jid: call.jid, outgoing: true, phase: .waitingRemoteOffer)
        manager.currentCall = call
        let xml = "<reject xmlns='urn:xmpp:jingle-message:0' id='active-call'><call end-reason='busy' initiator='\(owner)'/></reject>"

        XCTAssertTrue(manager.onReceivePushUpdate(try makePayload(node: node, xml: xml)))

        XCTAssertNil(manager.currentCall)
        XCTAssertEqual(context.lastTerminationReason, .rejectedByCallee)
        XCTAssertFalse(call.shouldSendReject)
    }

    func testOtherAccountsUpdateCannotMutateMatchingCallID() throws {
        let node = try installCredentials(owner: "other@example.invalid")
        let manager = VoIPManager()
        let call = makeCall(outgoing: false)
        manager.currentCall = call

        XCTAssertFalse(manager.onReceivePushUpdate(try makePayload(node: node,
            xml: "<reject xmlns='urn:xmpp:jingle-message:0' id='active-call'/>")))

        XCTAssertTrue(manager.currentCall === call)
        XCTAssertTrue(call.shouldSendReject)
    }

    func testForeignNamespaceRejectCannotMutateCall() throws {
        let node = try installCredentials(owner: owner)
        let manager = VoIPManager()
        let call = makeCall(outgoing: false)
        manager.currentCall = call

        XCTAssertFalse(manager.onReceivePushUpdate(try makePayload(node: node,
            xml: "<reject xmlns='https://foreign.invalid' id='active-call'/>")))

        XCTAssertTrue(manager.currentCall === call)
    }

    func testStaleCallIDCannotMutateCurrentCall() throws {
        let node = try installCredentials(owner: owner)
        let manager = VoIPManager()
        let call = makeCall(outgoing: false)
        manager.currentCall = call

        XCTAssertFalse(manager.onReceivePushUpdate(try makePayload(node: node,
            xml: "<reject xmlns='urn:xmpp:jingle-message:0' id='stale-call'/>")))

        XCTAssertTrue(manager.currentCall === call)
    }

    func testCanonicalDisplayedUsesDecryptedTypeAndCompletesExactlyOnce() throws {
        let node = try installCredentials(owner: owner)
        let manager = APNSManager()
        let completion = expectation(description: "Displayed processing completes")
        completion.assertForOverFulfill = true
        var count = 0
        let payload = try makePayload(node: node, xml: "<displayed xmlns='urn:xmpp:chat-markers:0' id='unknown-message'/>", type: "message")

        let result = try manager.receive(payload) {
            count += 1
            completion.fulfill()
        }

        XCTAssertEqual(result, .displayed)
        wait(for: [completion], timeout: 2)
        XCTAssertEqual(count, 1)
    }

    func testCanonicalDataUpdateCompletesWhenThereIsNoActiveCall() throws {
        let node = try installCredentials(owner: owner)
        var count = 0
        let result = try APNSManager().receive(try makePayload(node: node,
            xml: "<reject xmlns='urn:xmpp:jingle-message:0' id='stale-call'/>", type: "data")) { count += 1 }

        XCTAssertEqual(result, .data)
        XCTAssertEqual(count, 1)
    }

    func testBase64JSONRelayDisplayedDispatchesDespiteUnknownMetadataAndCompletes() throws {
        let node = try installCredentials(owner: owner)
        let canonical = try makePayload(node: node,
            xml: "<displayed xmlns='urn:xmpp:chat-markers:0' id='unknown-message'/>")
        let body = try XCTUnwrap(canonical["body"] as? String)
        let encrypted = try XCTUnwrap(EncryptedPushDate(body).encrypted)
        let json = try JSONSerialization.data(withJSONObject: ["action": "unknown-info-hint", "encrypted": encrypted])
        let completion = expectation(description: "Relay displayed completes")
        completion.assertForOverFulfill = true

        let result = try APNSManager().receive(["target": node, "body": json.base64EncodedString()]) {
            completion.fulfill()
        }

        XCTAssertEqual(result, .displayed)
        wait(for: [completion], timeout: 2)
    }

    func testUnknownJSONRelayWithInvalidEncryptedContentIsIgnoredSafely() throws {
        let node = try installCredentials(owner: owner)
        let body = try JSONSerialization.data(withJSONObject: ["action": "unknown-info-hint", "encrypted": "malformed-fixture"])
        var count = 0

        let result = try APNSManager().receive(["target": node, "body": body.base64EncodedString()]) { count += 1 }

        XCTAssertEqual(result, .ignored)
        XCTAssertEqual(count, 0)
    }

    func testKnownJSONRelayWithInvalidEncryptedContentRemainsInvalidPayload() throws {
        let node = try installCredentials(owner: owner)
        let body = try JSONSerialization.data(withJSONObject: ["action": "displayed", "encrypted": "malformed-fixture"])

        XCTAssertThrowsError(try APNSManager().receive(["target": node, "body": body.base64EncodedString()], completionHandler: nil)) { error in
            guard case APNSManager.APNSError.invalidPayload = error else {
                return XCTFail("Expected invalid payload for a recognized encrypted event")
            }
        }
    }

    private func makeCall(outgoing: Bool) -> VoIPCall {
        VoIPCall(owner: owner, fullJid: "peer@example.invalid/device", callId: "active-call",
                 callUUID: UUID(), outgoing: outgoing)
    }

    private func installCredentials(owner: String) throws -> String {
        let node = "push-ingress-\(UUID().uuidString)"
        nodes.append(node)
        try CredentialsManager.shared.storePushCredentials(node: node, jid: owner,
            host: "example.invalid", secret: Data(key).base64EncodedString(),
            service: "https://archive.example.invalid", jwt: "opaque-fixture", keyEncoding: .base64)
        return node
    }

    private func makePayload(node: String, xml: String, type: String = "data") throws -> [AnyHashable: Any] {
        let iv = Array(repeating: UInt8(7), count: 16)
        var plaintext = Array(xml.utf8)
        plaintext += Array(repeating: 0, count: 16 - plaintext.count % 16)
        let ciphertext = try AES(key: key, blockMode: CBC(iv: iv), padding: .noPadding).encrypt(plaintext)
        let encrypted = Data(iv + ciphertext).base64EncodedString()
        let body = "<encrypted xmlns='https://xabber.com/protocol/push' iv-length='16'>\(encrypted)</encrypted>"
            + "<x xmlns='jabber:x:data' type='result'><field var='FORM_TYPE'><value>https://xabber.com/protocol/push#info</value></field><field var='type'><value>\(type)</value></field></x>"
        return ["target_type": "node", "target": node, "body": body]
    }
}
