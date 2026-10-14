import Foundation
import XCTest
import XabberCryptoSwift
@testable import xabber

/// Exercises the real client storage/payload adapter against an ordinary-import
/// package peer. Every identity and session is isolated synthetic test material.
final class OMEMO2XabberCryptoIntegrationTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var failWrites = false
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws {
            if failWrites { throw OMEMO2StorageError.persistenceFailed }
            records[owner] = data
        }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }

    private struct Fixture {
        let app: XabberOMEMO2Storage
        let memory: Memory
        let crypto: XabberCrypto
        let peer: IdentityKeyPair
        let preKeys: OMEMOLocalPreKeys
        let context: OMEMOSessionContext
    }

    func testAppInitialPayloadIsAuthenticatedByPublicPeerForBothIdentityRepresentations() throws {
        for representation in IdentityPrivateKeyRepresentation.allCases {
            let f = try fixture(peerRepresentation: representation)
            let plaintext = "Привет, OMEMO 🔐"
            let xml = envelope(plaintext, from: f.app.owner, to: "peer@example.test")
            let payload = try Omemo2PayloadCodec.seal(xml)
            let wire = try f.app.encrypt(payload.keyAndMAC, jid: "peer@example.test", deviceID: 42)
            let received = try f.crypto.accept(exchange(wire), identity: f.peer,
                preKeys: f.preKeys, context: f.context)

            XCTAssertTrue(wire.isKeyExchange)
            XCTAssertEqual(received.authenticated.peerIdentity.rawRepresentation, try f.app.identity().publicKey)
            XCTAssertNotNil(received.effects.opkConsumption)
            XCTAssertEqual(try f.crypto.payloads.open(payload.ciphertext,
                keyMaterial: material(received.material)), Data(xml.utf8))
        }
    }

    func testPublicPeerControlConfirmsAppKEXAndBidirectionalPayloadsContinue() throws {
        let f = try fixture()
        let first = try f.app.encrypt(Data(repeating: 0, count: 32), jid: "peer@example.test", deviceID: 42)
        let accepted = try f.crypto.accept(exchange(first), identity: f.peer,
            preKeys: f.preKeys, context: f.context)
        let ack = try f.crypto.encrypt(.control, from: accepted.candidateSession)
        XCTAssertEqual(try f.app.decrypt(ciphertext(ack), jid: "peer@example.test", deviceID: 42), Data(repeating: 0, count: 32))
        XCTAssertFalse(try XCTUnwrap(f.app.sessionMetadata(jid: "peer@example.test", deviceID: 42)).keyExchangePending)

        let appXML = envelope("app → package", from: f.app.owner, to: "peer@example.test")
        let appPayload = try Omemo2PayloadCodec.seal(appXML)
        let sent = try f.app.encrypt(appPayload.keyAndMAC, jid: "peer@example.test", deviceID: 42)
        XCTAssertFalse(sent.isKeyExchange)
        let peerReceived = try f.crypto.decrypt(serializedEnvelope: sent.data, keyExchange: false, from: ack.candidateSession)
        XCTAssertEqual(try f.crypto.payloads.open(appPayload.ciphertext,
            keyMaterial: material(peerReceived.material)), Data(appXML.utf8))

        let reply = try f.crypto.payloads.seal(Data(envelope("package → app", from: "peer@example.test", to: f.app.owner).utf8))
        let peerSent = try f.crypto.encrypt(.payload(reply.keyMaterial), from: peerReceived.candidateSession)
        let unwrapped = try f.app.decrypt(ciphertext(peerSent), jid: "peer@example.test", deviceID: 42,
            validating: { _ = try openPayload(reply.ciphertext, keyAndMAC: $0, from: "peer@example.test", to: f.app.owner) })
        XCTAssertEqual(try openPayload(reply.ciphertext, keyAndMAC: unwrapped, from: "peer@example.test", to: f.app.owner), "package → app")
    }

    func testOutOfOrderAppMessagesAndBothPeersRestartWithoutLosingRatchetState() throws {
        let f = try fixture()
        let first = try f.app.encrypt(Data(repeating: 0, count: 32), jid: "peer@example.test", deviceID: 42)
        let accepted = try f.crypto.accept(exchange(first), identity: f.peer,
            preKeys: f.preKeys, context: f.context)
        let ack = try f.crypto.encrypt(.control, from: accepted.candidateSession)
        _ = try f.app.decrypt(ciphertext(ack), jid: "peer@example.test", deviceID: 42)
        let late = try f.app.encrypt(Data(repeating: 0x11, count: 48), jid: "peer@example.test", deviceID: 42)
        let later = try f.app.encrypt(Data(repeating: 0x22, count: 48), jid: "peer@example.test", deviceID: 42)
        let advanced = try f.crypto.decrypt(serializedEnvelope: later.data, keyExchange: false, from: ack.candidateSession)
        let snapshot = try f.crypto.snapshot(advanced.candidateSession)
        let restartedCrypto = XabberCrypto()
        let restored = try restartedCrypto.restore(OMEMOSnapshot(secretData: snapshot.exportSecretData()),
            context: f.context, expectedRevision: advanced.candidateSession.revision)
        let delayed = try restartedCrypto.decrypt(serializedEnvelope: late.data, keyExchange: false, from: restored)
        XCTAssertEqual(try material(delayed.material).serializedData(), Data(repeating: 0x11, count: 48))
        XCTAssertThrowsError(try restartedCrypto.decrypt(serializedEnvelope: late.data, keyExchange: false,
            from: delayed.candidateSession))

        let restartedApp = try XabberOMEMO2Storage(owner: f.app.owner, persistence: f.memory)
        let reply = try restartedCrypto.encrypt(.control, from: delayed.candidateSession)
        XCTAssertEqual(try restartedApp.decrypt(ciphertext(reply), jid: "peer@example.test", deviceID: 42), Data(repeating: 0, count: 32))
        XCTAssertEqual(try restartedApp.localBundle().identityKey, try f.app.localBundle().identityKey)
    }

    func testPackageInitialKEXAuthenticatesInAppAndDamagedMACDoesNotConsumePreKey() throws {
        for representation in IdentityPrivateKeyRepresentation.allCases {
            let memory = Memory()
            let app = try XabberOMEMO2Storage(owner: "receiver@example.test", persistence: memory)
            let bundle = try app.prepare(deviceID: 42, preKeyCount: 3)
            let crypto = XabberCrypto()
            let peer = try crypto.keys.generateIdentity(representation: representation)
            let selected = try selectedBundle(bundle)
            let context = try OMEMOSessionContext(scope: Data("isolated-public-sender".utf8),
                localIdentity: peer.publicKey, peerIdentity: selected.identityKey,
                localIdentityRepresentation: peer.representation)
            let sealed = try crypto.payloads.seal(Data(envelope("authenticated initial", from: "sender@example.test", to: app.owner).utf8))
            let sent = try crypto.initiate(identity: peer, peerBundle: selected,
                material: .payload(sealed.keyMaterial), context: context)
            let valid = try ciphertext(sent)
            let parsed = try exchange(valid)
            var damagedMAC = parsed.message.mac
            damagedMAC[0] ^= 1
            let damaged = try OMEMOKeyExchange(preKeyID: parsed.preKeyID, signedPreKeyID: parsed.signedPreKeyID,
                identityKey: parsed.identityKey, ephemeralKey: parsed.ephemeralKey,
                message: OMEMOAuthenticatedMessage(mac: damagedMAC, message: parsed.message.message))
            let before = memory.records[app.owner]

            XCTAssertThrowsError(try app.decrypt(OMEMO2Ciphertext(data: damaged.serializedData(), keyExchange: true),
                jid: "sender@example.test", deviceID: 41))
            XCTAssertEqual(memory.records[app.owner], before)
            XCTAssertEqual(try app.localBundle().preKeys.count, 3)
            let material = try app.decrypt(valid, jid: "sender@example.test", deviceID: 41,
                validating: { _ = try openPayload(sealed.ciphertext, keyAndMAC: $0, from: "sender@example.test", to: app.owner) })
            XCTAssertEqual(try openPayload(sealed.ciphertext, keyAndMAC: material, from: "sender@example.test", to: app.owner), "authenticated initial")
            XCTAssertEqual(try app.localBundle().preKeys.count, 2)
        }
    }

    func testOuterPayloadFailureRollsBackAppStateAndTheAuthenticPacketCanRetry() throws {
        let memory = Memory()
        let app = try XabberOMEMO2Storage(owner: "receiver@example.test", persistence: memory)
        let bundle = try app.prepare(deviceID: 42, preKeyCount: 3)
        let crypto = XabberCrypto()
        let peer = try crypto.keys.generateIdentity(representation: .ed25519Seed)
        let selected = try selectedBundle(bundle)
        let context = try OMEMOSessionContext(scope: Data("isolated-payload-sender".utf8),
            localIdentity: peer.publicKey, peerIdentity: selected.identityKey,
            localIdentityRepresentation: peer.representation)
        let payload = try crypto.payloads.seal(Data(envelope("payload integrity", from: "sender@example.test", to: app.owner).utf8))
        let sent = try crypto.initiate(identity: peer, peerBundle: selected,
            material: .payload(payload.keyMaterial), context: context)
        var corrupted = payload.ciphertext
        corrupted[0] ^= 1
        let before = memory.records[app.owner]

        XCTAssertThrowsError(try app.decrypt(ciphertext(sent), jid: "sender@example.test", deviceID: 41,
            validating: { _ = try openPayload(corrupted, keyAndMAC: $0, from: "sender@example.test", to: app.owner) }))
        XCTAssertEqual(memory.records[app.owner], before)
        XCTAssertEqual(try app.localBundle().preKeys.count, 3)
        let accepted = try app.decrypt(ciphertext(sent), jid: "sender@example.test", deviceID: 41,
            validating: { _ = try openPayload(payload.ciphertext, keyAndMAC: $0, from: "sender@example.test", to: app.owner) })
        XCTAssertEqual(try openPayload(payload.ciphertext, keyAndMAC: accepted, from: "sender@example.test", to: app.owner), "payload integrity")
    }

    func testDelayedSkippedOldRatchetDoesNotResetCurrentCountersAfterManyDHRoundTripsAndRestart() throws {
        let context = try OMEMO2Context(error: ())
        let aliceIdentity = try context.generateIdentity(representation: .ed25519Seed)
        let bobIdentity = try context.generateIdentity(representation: .ed25519Seed)
        let signed = try context.generateKeyPair()
        let preKey = try context.generateKeyPair()
        let bundle = try OMEMO2Bundle(identityKey: bobIdentity.publicKey, signedPreKey: signed.publicKey,
            signedPreKeyID: 7, signature: context.sign(signed.publicKey, identity: bobIdentity),
            preKey: preKey.publicKey, preKeyID: 9)
        let alice = try context.initiateSession(withIdentity: aliceIdentity, bundle: bundle)
        let control = Data(repeating: 0, count: 32)
        let initial = try alice.encryptData(control)
        var firstPlaintext: NSData?
        let bob = try context.acceptKeyExchange(initial, identity: bobIdentity,
            signedPreKey: signed, signedPreKeyID: 7, preKey: preKey, preKeyID: 9,
            plaintext: &firstPlaintext)
        let delayed = try alice.encryptData(Data(repeating: 0x42, count: 48))
        _ = try bob.decryptCiphertext(alice.encryptData(control))
        _ = try alice.decryptCiphertext(bob.encryptData(control))

        // The old skipped key remains younger than the native 2000-receive
        // lifetime after its DH fingerprint passed the former 1001-entry cap.
        for _ in 0..<1002 {
            _ = try bob.decryptCiphertext(alice.encryptData(control))
            _ = try alice.decryptCiphertext(bob.encryptData(control))
        }
        let restored = try context.restoreSession(with: bob.serializedData())
        let sendCounter = restored.sendCounter
        let receiveCounter = restored.receiveCounter
        XCTAssertEqual(sendCounter, 1)
        XCTAssertEqual(receiveCounter, 1)

        XCTAssertEqual(try restored.decryptCiphertext(delayed), Data(repeating: 0x42, count: 48))
        XCTAssertEqual(restored.sendCounter, sendCounter)
        XCTAssertEqual(restored.receiveCounter, receiveCounter)
    }

    private func envelope(_ body: String, from: String, to: String) -> String {
        "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>\(body)</body></content><rpad>padding</rpad><from jid='\(from)'/><to jid='\(to)'/></envelope>"
    }

    private func openPayload(_ ciphertext: Data, keyAndMAC: Data, from: String, to: String) throws -> String? {
        guard let opened = try Omemo2PayloadCodec.openVerified(ciphertext,
            keyAndMAC: keyAndMAC, expectedFrom: from, expectedTo: to, requireTo: true) else {
            throw OMEMO2StorageError.invalidState
        }
        return opened.content.element(forName: "body", xmlns: "jabber:client")?.stringValue
    }

    private func fixture(peerRepresentation: IdentityPrivateKeyRepresentation = .ed25519Seed) throws -> Fixture {
        let memory = Memory()
        let app = try XabberOMEMO2Storage(owner: "app@example.test", persistence: memory)
        _ = try app.prepare(deviceID: 41, preKeyCount: 3)
        let crypto = XabberCrypto()
        let peer = try crypto.keys.generateIdentity(representation: peerRepresentation)
        let signed = try crypto.keys.generateAgreementKeyPair()
        let preKey = try crypto.keys.generateAgreementKeyPair()
        let signature = try peer.sign(signed.publicKey.rawRepresentation)
        let bundle = try OMEMO2Bundle(identityKey: peer.publicKey.rawRepresentation,
            signedPreKey: signed.publicKey.rawRepresentation, signedPreKeyID: 7,
            signature: signature.rawRepresentation, preKey: preKey.publicKey.rawRepresentation, preKeyID: 9)
        try app.initiateSession(jid: "peer@example.test", deviceID: 42, bundle: bundle)
        let context = try OMEMOSessionContext(scope: Data("isolated-public-receiver".utf8),
            localIdentity: peer.publicKey, peerIdentity: Ed25519PublicKey(rawRepresentation: app.identity().publicKey),
            localIdentityRepresentation: peer.representation)
        let localKeys = try OMEMOLocalPreKeys(signedPreKeyID: SignedPreKeyID(7), signedPreKey: signed,
            preKeyID: PreKeyID(9), preKey: preKey)
        return Fixture(app: app, memory: memory, crypto: crypto, peer: peer, preKeys: localKeys, context: context)
    }

    private func selectedBundle(_ bundle: OMEMO2LocalBundle) throws -> SelectedPeerBundle {
        let key = try XCTUnwrap(bundle.preKeys.first)
        return try SelectedPeerBundle(identityKey: Ed25519PublicKey(rawRepresentation: bundle.identityKey),
            signedPreKey: X25519PublicKey(rawRepresentation: bundle.signedPreKey),
            signedPreKeyID: SignedPreKeyID(bundle.signedPreKeyID), signature: Ed25519Signature(rawRepresentation: bundle.signature),
            preKey: X25519PublicKey(rawRepresentation: key.publicKey), preKeyID: PreKeyID(key.id))
    }

    private func exchange(_ wire: OMEMO2Ciphertext) throws -> OMEMOKeyExchange {
        try OMEMOKeyExchange(serializedData: wire.data)
    }

    private func ciphertext(_ candidate: OMEMOSendingCandidate) throws -> OMEMO2Ciphertext {
        let isKEX: Bool
        switch candidate.envelope { case .keyExchange: isKEX = true; case .message: isKEX = false }
        return try OMEMO2Ciphertext(data: candidate.envelope.serializedData(), keyExchange: isKEX)
    }

    private func material(_ value: OMEMOMessageMaterial) throws -> OMEMOPayloadKeyMaterial {
        guard case let .payload(material) = value else { throw OMEMO2StorageError.invalidState }
        return material
    }
}
