import CryptoKit
import Foundation
import XCTest
import XabberCryptoSwift
@testable import xabber

/// The app's disposable crypto adapter, using real native cryptography and only
/// synthetic keys. Storage/transport commits are covered by their own suites.
final class OMEMO2CryptoBackendBehaviorTests: XCTestCase {
    private let control = Data(repeating: 0, count: 32)
    private let material = Data(repeating: 0xA7, count: 48)

    private struct Fixture {
        let context: OMEMO2Context
        let senderIdentity: OMEMO2IdentityKeyPair
        let receiverIdentity: OMEMO2IdentityKeyPair
        let signed: OMEMO2KeyPair
        let preKey: OMEMO2KeyPair
        let bundle: OMEMO2Bundle
        let sender: OMEMO2Session
        let scope: Data
    }

    func testGeneratedIdentitiesPreserveRepresentationAndRoundTripSigningAndAgreementKeys() throws {
        let context = try OMEMO2Context(error: ())
        for representation in IdentityPrivateKeyRepresentation.allCases {
            let generated = try context.generateIdentity(representation: representation)
            let imported = try context.identity(withPrivateKey: generated.privateKey, representation: representation)

            XCTAssertEqual(generated.representation, representation)
            XCTAssertEqual(imported.privateKey, generated.privateKey)
            XCTAssertEqual(imported.publicKey, generated.publicKey)
            XCTAssertEqual(imported.fingerprintPublicKey, generated.fingerprintPublicKey)
            XCTAssertEqual(generated.privateKey.count, 32)
            XCTAssertEqual(generated.publicKey.count, 32)
            XCTAssertEqual(generated.fingerprintPublicKey,
                           try Omemo2IdentityRepresentation.curvePublicKey(from: generated.publicKey))
            for bytes in [Data(), Data("native identity 🔐".utf8)] {
                let signature = try context.sign(bytes, identity: imported)
                try OMEMO2Context.verifySignature(signature, data: bytes, identityKey: generated.publicKey)
                XCTAssertTrue(try Curve25519.Signing.PublicKey(rawRepresentation: generated.publicKey)
                    .isValidSignature(signature, for: bytes))
            }
        }
    }

    func testPrivateRepresentationIsExplicitAndDefaultsRemainScalarForTheAdapterAndSeedForIdentityHelpers() throws {
        let context = try OMEMO2Context(error: ())
        let privateKey = Data(repeating: 0x39, count: 32)
        let scalar = try context.identity(withPrivateKey: privateKey, representation: .xabberX25519Scalar)
        let seed = try context.identity(withPrivateKey: privateKey, representation: .ed25519Seed)

        XCTAssertEqual(try context.identity(withPrivateKey: privateKey).publicKey, scalar.publicKey)
        XCTAssertEqual(try context.generateIdentity().representation, .xabberX25519Scalar)
        XCTAssertNotEqual(scalar.publicKey, seed.publicKey)
        XCTAssertNotEqual(scalar.fingerprintPublicKey, seed.fingerprintPublicKey)
        XCTAssertEqual(scalar.privateKey, seed.privateKey)
        let bytes = Data("representation must accompany private bytes".utf8)
        XCTAssertTrue(Omemo2IdentityRepresentation.verify(
            try Omemo2IdentityRepresentation.sign(bytes, privateKey: privateKey),
            data: bytes, storedIdentity: seed.publicKey))
        XCTAssertTrue(Omemo2IdentityRepresentation.verify(
            try Omemo2IdentityRepresentation.sign(bytes, privateKey: privateKey, representation: .xabberX25519Scalar),
            data: bytes, storedIdentity: scalar.publicKey))
    }

    func testGeneratedAgreementKeysRoundTripAndMatchCryptoKit() throws {
        let context = try OMEMO2Context(error: ())
        let generated = try context.generateKeyPair()
        let imported = try context.keyPair(withPrivateKey: generated.privateKey)

        XCTAssertEqual(generated.privateKey.count, 32)
        XCTAssertEqual(imported.privateKey, generated.privateKey)
        XCTAssertEqual(imported.publicKey, generated.publicKey)
        XCTAssertEqual(generated.publicKey,
                       try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: generated.privateKey).publicKey.rawRepresentation)
    }

    func testIdentityAndAgreementImportsRejectMalformedPrivateMaterial() throws {
        let context = try OMEMO2Context(error: ())
        for length in [0, 1, 31, 33, 64] {
            let bytes = Data(repeating: 1, count: length)
            XCTAssertThrowsError(try context.keyPair(withPrivateKey: bytes))
            for representation in IdentityPrivateKeyRepresentation.allCases {
                XCTAssertThrowsError(try context.identity(withPrivateKey: bytes, representation: representation))
                XCTAssertThrowsError(try Omemo2IdentityRepresentation.sign(material, privateKey: bytes,
                    representation: representation))
                XCTAssertThrowsError(try Omemo2IdentityRepresentation.sharedSecret(privateKey: bytes,
                    peerIdentity: Data(repeating: 1, count: 32), representation: representation))
            }
        }
    }

    func testSignatureVerificationRejectsChangedMessageIdentitySignatureAndMalformedLengths() throws {
        let context = try OMEMO2Context(error: ())
        for representation in IdentityPrivateKeyRepresentation.allCases {
            let identity = try context.generateIdentity(representation: representation)
            let other = try context.generateIdentity(representation: representation)
            let signature = try context.sign(material, identity: identity)
            var damaged = signature
            damaged[0] ^= 1

            for (candidate, bytes, publicKey) in [(damaged, material, identity.publicKey),
                (signature, material + Data([1]), identity.publicKey), (signature, material, other.publicKey)] {
                XCTAssertThrowsError(try OMEMO2Context.verifySignature(candidate, data: bytes, identityKey: publicKey))
                XCTAssertFalse(Omemo2IdentityRepresentation.verify(candidate, data: bytes, storedIdentity: publicKey))
            }
            for length in [0, 63, 65] {
                XCTAssertThrowsError(try OMEMO2Context.verifySignature(Data(repeating: 0, count: length),
                    data: material, identityKey: identity.publicKey))
            }
            for length in [0, 31, 33] {
                XCTAssertThrowsError(try OMEMO2Context.verifySignature(signature,
                    data: material, identityKey: Data(repeating: 0, count: length)))
            }
        }
    }

    func testIdentityHelpersDeriveTheSameBilateralSecretForEverySeedAndScalarCombination() throws {
        let context = try OMEMO2Context(error: ())
        for aliceRepresentation in IdentityPrivateKeyRepresentation.allCases {
            for bobRepresentation in IdentityPrivateKeyRepresentation.allCases {
                let alice = try context.generateIdentity(representation: aliceRepresentation)
                let bob = try context.generateIdentity(representation: bobRepresentation)
                let aliceSecret = try Omemo2IdentityRepresentation.sharedSecret(privateKey: alice.privateKey,
                    peerIdentity: bob.publicKey, representation: aliceRepresentation)
                let bobSecret = try Omemo2IdentityRepresentation.sharedSecret(privateKey: bob.privateKey,
                    peerIdentity: alice.publicKey, representation: bobRepresentation)

                XCTAssertEqual(aliceSecret, bobSecret)
                XCTAssertEqual(aliceSecret.count, 32)
                XCTAssertNotEqual(aliceSecret, Data(repeating: 0, count: 32))
                if aliceRepresentation == .ed25519Seed {
                    XCTAssertEqual(try Omemo2IdentityRepresentation.sharedSecret(privateKey: alice.privateKey,
                        peerIdentity: bob.publicKey), aliceSecret)
                }
            }
        }
    }

    func testBundleRejectsMalformedLengthsOutOfRangeIdentifiersAndInvalidSignature() throws {
        let f = try fixture()
        let fields = ["identityKey", "signedPreKey", "preKey", "signature"]
        for field in fields {
            let validLength = field == "signature" ? 64 : 32
            for length in [0, validLength - 1, validLength + 1] {
                XCTAssertThrowsError(try bundle(f, replacing: field, with: Data(repeating: 0, count: length)))
            }
        }
        for id in [UInt32(0), UInt32(Int32.max) + 1, UInt32.max] {
            XCTAssertThrowsError(try bundle(f, signedID: id))
            XCTAssertThrowsError(try bundle(f, preKeyID: id))
        }
        XCTAssertNoThrow(try bundle(f, signedID: UInt32(Int32.max), preKeyID: UInt32(Int32.max)))
        var signature = f.bundle.signature
        signature[0] ^= 1
        XCTAssertThrowsError(try bundle(f, replacing: "signature", with: signature))
        XCTAssertThrowsError(try bundle(f, replacing: "identityKey", with: f.senderIdentity.publicKey))
        XCTAssertThrowsError(try bundle(f, replacing: "signedPreKey", with: f.preKey.publicKey))
    }

    func testBundleRejectsLowOrderAgreementKeysEvenWhenTheSignedPreKeySignatureIsValid() throws {
        let f = try fixture()
        for key in [Data(repeating: 0, count: 32), Data([1]) + Data(repeating: 0, count: 31)] {
            XCTAssertThrowsError(try bundle(f, replacing: "preKey", with: key))
            XCTAssertThrowsError(try OMEMO2Bundle(identityKey: f.receiverIdentity.publicKey,
                signedPreKey: key, signedPreKeyID: 7,
                signature: f.context.sign(key, identity: f.receiverIdentity), preKey: f.preKey.publicKey, preKeyID: 9))
        }
    }

    func testDecodedBundleIsRevalidatedBeforePreparingASession() throws {
        let f = try fixture()
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.bundle)) as? [String: Any])
        encoded["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        let bypassed = try JSONDecoder().decode(OMEMO2Bundle.self, from: JSONSerialization.data(withJSONObject: encoded))

        XCTAssertThrowsError(try f.context.initiateSession(withIdentity: f.senderIdentity, bundle: bypassed))
    }

    func testSessionPreparationRejectsEmptyAndOversizedHostScopes() throws {
        let f = try fixture()
        for scope in [Data(), Data(repeating: 1, count: 1025)] {
            XCTAssertThrowsError(try f.context.initiateSession(withIdentity: f.senderIdentity, bundle: f.bundle, scope: scope))
        }
        XCTAssertNoThrow(try f.context.initiateSession(withIdentity: f.senderIdentity, bundle: f.bundle,
            scope: Data(repeating: 1, count: 1024)))
    }

    func testPreparationMetadataAndRestartDoNotSpendAFirstSendCounter() throws {
        for representation in IdentityPrivateKeyRepresentation.allCases {
            let f = try fixture(representation: representation)
            let provisional = f.sender.ephemeralKey
            let stored = try f.sender.serializedData()
            let restored = try f.context.restoreSession(with: stored, scope: f.scope, localIdentity: f.senderIdentity.publicKey)

            XCTAssertTrue(restored.isKeyExchangePending)
            XCTAssertEqual(restored.remoteIdentityKey, f.receiverIdentity.publicKey)
            XCTAssertEqual(restored.remotePreKeyID, 9)
            XCTAssertEqual(restored.ephemeralKey, provisional)
            XCTAssertEqual(restored.sendCounter, 0)
            XCTAssertEqual(restored.receiveCounter, 0)
            XCTAssertEqual(try canonicalJSON(restored.serializedData()), try canonicalJSON(stored))
            let first = try restored.encryptData(material)
            let accepted = try accept(first, fixture: f)
            XCTAssertEqual(accepted.plaintext, material)
            XCTAssertTrue(first.isKeyExchange)
            XCTAssertEqual(first.counter, 0)
            XCTAssertEqual(restored.sendCounter, 1)
            XCTAssertEqual(first.ephemeralKey, restored.ephemeralKey)
            XCTAssertEqual(first.identityKey, f.senderIdentity.publicKey)
        }
    }

    func testPreparationCannotDecryptAnEnvelopeAndRemainsReusableAfterFailure() throws {
        let f = try fixture()
        let incoming = try fixture().sender.encryptData(control)
        let before = try canonicalJSON(f.sender.serializedData())

        XCTAssertThrowsError(try f.sender.decryptCiphertext(incoming)) {
            XCTAssertEqual($0 as? OMEMOCryptoError, .missingSession)
        }
        XCTAssertEqual(try canonicalJSON(f.sender.serializedData()), before)
        XCTAssertEqual(try f.sender.encryptData(material).counter, 0)
    }

    func testOnlyExactZero32ControlOrPayload48CanAdvancePreparationAndExistingSessions() throws {
        let f = try fixture()
        let invalid = [Data(), Data(repeating: 0, count: 31), Data(repeating: 1, count: 32),
                       Data(repeating: 0, count: 33), Data(repeating: 1, count: 47), Data(repeating: 1, count: 49)]
        for bytes in invalid {
            let before = try canonicalJSON(f.sender.serializedData())
            XCTAssertThrowsError(try f.sender.encryptData(bytes))
            XCTAssertEqual(try canonicalJSON(f.sender.serializedData()), before)
        }
        let first = try f.sender.encryptData(control)
        let receiver = try accept(first, fixture: f).session
        for bytes in invalid {
            let before = try canonicalJSON(f.sender.serializedData())
            XCTAssertThrowsError(try f.sender.encryptData(bytes))
            XCTAssertEqual(try canonicalJSON(f.sender.serializedData()), before)
        }
        let payload = Data(repeating: 0, count: 48)
        XCTAssertEqual(try receiver.decryptCiphertext(f.sender.encryptData(payload)), payload)
        XCTAssertEqual(try receiver.decryptCiphertext(f.sender.encryptData(control)), control)
    }

    func testCiphertextExposesActualKEXAndRatchetMetadataAndPreservesTheInputBytes() throws {
        let f = try fixture()
        let first = try f.sender.encryptData(material)
        let parsed = try OMEMO2Ciphertext(data: first.data, keyExchange: true)
        let receiver = try accept(first, fixture: f).session

        XCTAssertEqual(parsed.data, first.data)
        XCTAssertTrue(parsed.isKeyExchange)
        XCTAssertEqual(parsed.identityKey, f.senderIdentity.publicKey)
        XCTAssertEqual(parsed.ephemeralKey, f.sender.ephemeralKey)
        XCTAssertEqual(parsed.preKeyID, 9)
        XCTAssertEqual(parsed.signedPreKeyID, 7)
        XCTAssertEqual(parsed.counter, 0)
        XCTAssertEqual(parsed.ratchetKey.count, 32)
        XCTAssertNotEqual(parsed.ratchetKey, parsed.ephemeralKey)
        let reply = try receiver.encryptData(control)
        XCTAssertFalse(reply.isKeyExchange)
        XCTAssertNil(reply.identityKey)
        XCTAssertNil(reply.ephemeralKey)
        XCTAssertEqual(reply.preKeyID, 0)
        XCTAssertEqual(reply.signedPreKeyID, 0)
        XCTAssertEqual(reply.counter, 0)
        XCTAssertEqual(receiver.remotePreKeyID, 0)
    }

    func testCiphertextParserRejectsWrongKindTruncationDuplicateFieldsAndMissingCiphertext() throws {
        let f = try fixture()
        let kex = try f.sender.encryptData(control)
        let receiver = try accept(kex, fixture: f).session
        let reply = try receiver.encryptData(control)

        XCTAssertThrowsError(try OMEMO2Ciphertext(data: kex.data, keyExchange: false))
        XCTAssertThrowsError(try OMEMO2Ciphertext(data: reply.data, keyExchange: true))
        for packet in [kex, reply] {
            for bad in [Data(), Data(packet.data.dropLast()), packet.data + Data([0x0A, 0])] {
                XCTAssertThrowsError(try OMEMO2Ciphertext(data: bad, keyExchange: packet.isKeyExchange))
            }
        }
        // A CONCAT-only header is legal for derivation but not as a transmitted
        // authenticated key envelope, even with a syntactically valid MAC.
        let header = try OMEMOMessage(counter: 0, previousCounter: 0, ratchetKey: f.signed.publicKey, ciphertext: nil)
        let inner = try header.serializedData()
        let framed = Data([0x0A, 16]) + Data(repeating: 0, count: 16) + Data([0x12, UInt8(inner.count)]) + inner
        XCTAssertThrowsError(try OMEMO2Ciphertext(data: framed, keyExchange: false))
    }

    func testUnrecognizedOuterFieldsArePreservedWithoutChangingAuthenticatedPacketSemantics() throws {
        let f = try fixture()
        let first = try f.sender.encryptData(material)
        // Unknown field 15 is outside the authenticated inner message.
        let encoded = first.data + Data([0x78, 0x01])
        let parsed = try OMEMO2Ciphertext(data: encoded, keyExchange: true)

        XCTAssertEqual(parsed.data, encoded)
        XCTAssertEqual(parsed.counter, first.counter)
        XCTAssertEqual(parsed.ratchetKey, first.ratchetKey)
        XCTAssertEqual(try accept(parsed, fixture: f).plaintext, material)
    }

    func testAcceptRejectsRegularEnvelopesAndMismatchedPreKeyInputsWithoutPublishingPlaintext() throws {
        let f = try fixture()
        let first = try f.sender.encryptData(material)
        let receiver = try accept(first, fixture: f).session
        let regular = try receiver.encryptData(control)
        let sentinel = Data("unchanged caller output".utf8) as NSData
        var plaintext: NSData? = sentinel

        XCTAssertThrowsError(try f.context.acceptKeyExchange(regular, identity: f.receiverIdentity,
            signedPreKey: f.signed, signedPreKeyID: 7, preKey: f.preKey, preKeyID: 9, plaintext: &plaintext)) {
            XCTAssertEqual($0 as? OMEMOCryptoError, .invalidEnvelope)
        }
        for (signedID, preKeyID) in [(UInt32(8), UInt32(9)), (UInt32(7), UInt32(10)), (UInt32(0), UInt32(9))] {
            XCTAssertThrowsError(try f.context.acceptKeyExchange(first, identity: f.receiverIdentity,
                signedPreKey: f.signed, signedPreKeyID: signedID, preKey: f.preKey, preKeyID: preKeyID, plaintext: &plaintext))
            XCTAssertEqual(plaintext, sentinel)
        }
        let wrong = try f.context.generateKeyPair()
        for (signed, preKey) in [(wrong, f.preKey), (f.signed, wrong)] {
            XCTAssertThrowsError(try f.context.acceptKeyExchange(first, identity: f.receiverIdentity,
                signedPreKey: signed, signedPreKeyID: 7, preKey: preKey, preKeyID: 9, plaintext: &plaintext))
            XCTAssertEqual(plaintext, sentinel)
        }
        XCTAssertThrowsError(try f.context.acceptKeyExchange(first, identity: f.senderIdentity,
            signedPreKey: f.signed, signedPreKeyID: 7, preKey: f.preKey, preKeyID: 9, plaintext: &plaintext))
        XCTAssertEqual(plaintext, sentinel)
        XCTAssertEqual(try accept(first, fixture: f).plaintext, material)
    }

    func testAcceptCanExplicitlyRecoverWithRetainedConsumedPreKey() throws {
        let f = try fixture()
        let first = try f.sender.encryptData(material)
        var plaintext: NSData?
        let receiver = try f.context.acceptKeyExchange(first, identity: f.receiverIdentity,
            signedPreKey: f.signed, signedPreKeyID: 7, preKey: f.preKey, preKeyID: 9,
            plaintext: &plaintext, scope: f.scope, preKeyConsumed: true)

        XCTAssertEqual(plaintext as Data?, material)
        XCTAssertEqual(receiver.receiveCounter, 1)
        XCTAssertEqual(receiver.remoteIdentityKey, f.senderIdentity.publicKey)
        XCTAssertFalse(receiver.isKeyExchangePending)
    }

    func testFailedInitialAuthenticationLeavesCallerOutputUntouchedAndAuthenticPacketCanRetry() throws {
        let f = try fixture()
        let valid = try f.sender.encryptData(material)
        let damaged = try modifying(valid) { message in
            var mac = message.mac
            mac[0] ^= 1
            return try OMEMOAuthenticatedMessage(mac: mac, message: message.message)
        }
        let sentinel = Data([0xF1]) as NSData
        var plaintext: NSData? = sentinel

        XCTAssertThrowsError(try f.context.acceptKeyExchange(damaged, identity: f.receiverIdentity,
            signedPreKey: f.signed, signedPreKeyID: 7, preKey: f.preKey, preKeyID: 9, plaintext: &plaintext))
        XCTAssertEqual(plaintext, sentinel)
        XCTAssertEqual(try accept(valid, fixture: f).plaintext, material)
    }

    func testRepeatedKEXKeepsOneExchangeAndSupportsDelayedMessagesWithoutRegressingCounters() throws {
        let f = try fixture()
        let first = try f.sender.encryptData(control)
        let receiver = try accept(first, fixture: f).session
        let delayed = try f.sender.encryptData(Data(repeating: 0x11, count: 48))
        let later = try f.sender.encryptData(Data(repeating: 0x22, count: 48))

        XCTAssertTrue(f.sender.isKeyExchangePending)
        XCTAssertTrue(delayed.isKeyExchange)
        XCTAssertTrue(later.isKeyExchange)
        XCTAssertEqual(later.ephemeralKey, first.ephemeralKey)
        XCTAssertEqual(delayed.counter, 1)
        XCTAssertEqual(later.counter, 2)
        XCTAssertEqual(try receiver.decryptCiphertext(later), Data(repeating: 0x22, count: 48))
        XCTAssertEqual(receiver.receiveCounter, 3)
        let restored = try f.context.restoreSession(with: receiver.serializedData(), scope: f.scope,
            localIdentity: f.receiverIdentity.publicKey)
        XCTAssertEqual(try restored.decryptCiphertext(delayed), Data(repeating: 0x11, count: 48))
        XCTAssertEqual(restored.receiveCounter, 3)
        XCTAssertThrowsError(try restored.decryptCiphertext(delayed))
    }

    func testRepeatedKEXAcceptsEquivalentEphemeralEncodingAndRejectsItsReplayWithoutAdvancingState() throws {
        let f = try fixture()
        let first = try f.sender.encryptData(control)
        let receiver = try accept(first, fixture: f).session
        let valid = try f.sender.encryptData(material)
        let alias = try modifyingExchange(valid) { exchange in
            var ephemeral = exchange.ephemeralKey
            ephemeral[31] ^= 0x80
            return try OMEMOKeyExchange(preKeyID: exchange.preKeyID, signedPreKeyID: exchange.signedPreKeyID,
                identityKey: exchange.identityKey, ephemeralKey: ephemeral, message: exchange.message)
        }

        XCTAssertEqual(try receiver.decryptCiphertext(alias), material)
        XCTAssertEqual(receiver.ephemeralKey, first.ephemeralKey)
        let before = try canonicalJSON(receiver.serializedData())
        XCTAssertThrowsError(try receiver.decryptCiphertext(valid))
        XCTAssertEqual(try canonicalJSON(receiver.serializedData()), before)
    }

    func testRepeatedKEXWithConflictingIdentityOrPreKeyHeaderIsRejectedAndTheOriginalRemainsUsable() throws {
        let f = try fixture()
        let receiver = try accept(f.sender.encryptData(control), fixture: f).session
        let valid = try f.sender.encryptData(material)
        let before = try canonicalJSON(receiver.serializedData())
        for field in ["identity", "signed", "preKey"] {
            let conflicting = try modifyingExchange(valid) { exchange in
                try OMEMOKeyExchange(preKeyID: field == "preKey" ? 10 : exchange.preKeyID,
                    signedPreKeyID: field == "signed" ? 8 : exchange.signedPreKeyID,
                    identityKey: field == "identity" ? f.receiverIdentity.publicKey : exchange.identityKey,
                    ephemeralKey: exchange.ephemeralKey, message: exchange.message)
            }
            XCTAssertThrowsError(try receiver.decryptCiphertext(conflicting)) {
                XCTAssertEqual($0 as? OMEMOCryptoError, .conflictingHeader)
            }
            XCTAssertEqual(try canonicalJSON(receiver.serializedData()), before)
        }
        XCTAssertEqual(try receiver.decryptCiphertext(valid), material)
    }

    func testAuthenticatedInnerHeaderCiphertextAndMACTamperingDoNotMutateAReusableSession() throws {
        let f = try fixture()
        let receiver = try accept(f.sender.encryptData(control), fixture: f).session
        let valid = try f.sender.encryptData(material)
        let before = try canonicalJSON(receiver.serializedData())
        for field in ["ratchet", "counter", "previous", "ciphertext", "mac", "unknown"] {
            let changed = try modifying(valid) { authenticated in
                let original = try authenticated.decodeMessage()
                var ciphertext = try XCTUnwrap(original.ciphertext)
                if field == "ciphertext" { ciphertext[0] ^= 1 }
                var mac = authenticated.mac
                if field == "mac" { mac[0] ^= 1 }
                let header = try OMEMOMessage(counter: field == "counter" ? original.counter + 1 : original.counter,
                    previousCounter: field == "previous" ? original.previousCounter + 1 : original.previousCounter,
                    ratchetKey: field == "ratchet" ? f.preKey.publicKey : original.ratchetKey,
                    ciphertext: ciphertext)
                let bytes = field == "unknown" ? authenticated.message + Data([0x78, 1]) : try header.serializedData()
                return try OMEMOAuthenticatedMessage(mac: mac, message: bytes)
            }
            XCTAssertThrowsError(try receiver.decryptCiphertext(changed), field)
            XCTAssertEqual(try canonicalJSON(receiver.serializedData()), before, field)
        }
        XCTAssertEqual(try receiver.decryptCiphertext(valid), material)
    }

    func testOnlyAuthenticatedReplyConfirmsPendingKEXAndSubsequentSendsUseRegularEnvelopes() throws {
        let f = try fixture()
        let receiver = try accept(f.sender.encryptData(material), fixture: f).session
        let reply = try receiver.encryptData(control)
        let changed = try modifying(reply) { message in
            var mac = message.mac
            mac[0] ^= 1
            return try OMEMOAuthenticatedMessage(mac: mac, message: message.message)
        }
        let before = try canonicalJSON(f.sender.serializedData())

        XCTAssertThrowsError(try f.sender.decryptCiphertext(changed))
        XCTAssertTrue(f.sender.isKeyExchangePending)
        XCTAssertEqual(try canonicalJSON(f.sender.serializedData()), before)
        XCTAssertEqual(try f.sender.decryptCiphertext(reply), control)
        XCTAssertFalse(f.sender.isKeyExchangePending)
        XCTAssertEqual(f.sender.sendCounter, 0)
        XCTAssertEqual(f.sender.receiveCounter, 1)
        let sent = try f.sender.encryptData(material)
        XCTAssertFalse(sent.isKeyExchange)
        XCTAssertEqual(sent.counter, 0)
        XCTAssertEqual(try receiver.decryptCiphertext(sent), material)
    }

    func testPendingInitiatorRejectsSimultaneousKEXWithoutLosingItsOriginalExchange() throws {
        let f = try fixture()
        let receiver = try accept(f.sender.encryptData(control), fixture: f).session
        let targetBundle = try OMEMO2Bundle(identityKey: f.senderIdentity.publicKey,
            signedPreKey: f.signed.publicKey, signedPreKeyID: 7,
            signature: f.context.sign(f.signed.publicKey, identity: f.senderIdentity),
            preKey: f.preKey.publicKey, preKeyID: 9)
        let otherInitiation = try f.context.initiateSession(withIdentity: f.receiverIdentity, bundle: targetBundle)
        let simultaneous = try otherInitiation.encryptData(material)
        let before = try canonicalJSON(f.sender.serializedData())

        XCTAssertThrowsError(try f.sender.decryptCiphertext(simultaneous)) {
            XCTAssertEqual($0 as? OMEMOCryptoError, .simultaneousInitiation)
        }
        XCTAssertEqual(try canonicalJSON(f.sender.serializedData()), before)
        XCTAssertTrue(f.sender.isKeyExchangePending)
        XCTAssertEqual(try f.sender.decryptCiphertext(receiver.encryptData(control)), control)
        XCTAssertFalse(f.sender.isKeyExchangePending)
    }

    func testEstablishedResponderRejectsFreshKEXWithoutResettingItsCurrentSession() throws {
        let f = try fixture()
        let receiver = try accept(f.sender.encryptData(control), fixture: f).session
        let original = try f.sender.encryptData(material)
        let fresh = try f.context.initiateSession(withIdentity: f.senderIdentity, bundle: f.bundle)
        let replacement = try fresh.encryptData(control)
        let before = try canonicalJSON(receiver.serializedData())

        XCTAssertThrowsError(try receiver.decryptCiphertext(replacement)) {
            XCTAssertEqual($0 as? OMEMOCryptoError, .replacementRequired)
        }
        XCTAssertEqual(try canonicalJSON(receiver.serializedData()), before)
        XCTAssertEqual(try receiver.decryptCiphertext(original), material)
    }

    func testRatchetMetadataRemainsBoundedAfterItsReceiveHorizonAndExpiredDelayedPacketsCannotAdvanceState() throws {
        let f = try fixture()
        let receiver = try accept(f.sender.encryptData(control), fixture: f).session
        let delayed = try f.sender.encryptData(material)
        _ = try receiver.decryptCiphertext(f.sender.encryptData(control))
        _ = try f.sender.decryptCiphertext(receiver.encryptData(control))

        // Retain one skipped key, then pass its native successful-receive age
        // and the wrapper's entire diagnostic horizon with genuine DH changes.
        for _ in 0..<OMEMO2Session.maximumReceivedRatchets {
            _ = try receiver.decryptCiphertext(f.sender.encryptData(control))
            _ = try f.sender.decryptCiphertext(receiver.encryptData(control))
        }
        let stored = try receiver.serializedData()
        let ratchets = try XCTUnwrap(jsonObject(stored)["receivedRatchets"] as? [String])
        XCTAssertEqual(ratchets.count, OMEMO2Session.maximumReceivedRatchets)
        XCTAssertEqual(Set(ratchets).count, ratchets.count)
        let restored = try f.context.restoreSession(with: stored, scope: f.scope,
            localIdentity: f.receiverIdentity.publicKey)
        XCTAssertEqual(restored.sendCounter, receiver.sendCounter)
        XCTAssertEqual(restored.receiveCounter, receiver.receiveCounter)
        let before = try canonicalJSON(restored.serializedData())

        XCTAssertThrowsError(try restored.decryptCiphertext(delayed))
        XCTAssertEqual(try canonicalJSON(restored.serializedData()), before)
        XCTAssertEqual(try restored.decryptCiphertext(f.sender.encryptData(material)), material)
    }

    func testNativeSnapshotsRestorePendingAndEstablishedSessionsForBothPrivateRepresentations() throws {
        for representation in IdentityPrivateKeyRepresentation.allCases {
            let f = try fixture(representation: representation)
            let first = try f.sender.encryptData(control)
            let receiver = try accept(first, fixture: f).session
            let pending = try f.context.restoreSession(with: f.sender.serializedData(), scope: f.scope,
                localIdentity: f.senderIdentity.publicKey)
            XCTAssertTrue(pending.isKeyExchangePending)
            let repeated = try pending.encryptData(material)
            XCTAssertEqual(repeated.ephemeralKey, first.ephemeralKey)
            XCTAssertEqual(repeated.counter, 1)
            XCTAssertEqual(try receiver.decryptCiphertext(repeated), material)
            XCTAssertEqual(try pending.decryptCiphertext(receiver.encryptData(control)), control)
            let established = try f.context.restoreSession(with: pending.serializedData(), scope: f.scope,
                localIdentity: f.senderIdentity.publicKey)
            let receiverRestart = try f.context.restoreSession(with: receiver.serializedData(), scope: f.scope,
                localIdentity: f.receiverIdentity.publicKey)

            XCTAssertFalse(established.isKeyExchangePending)
            let sent = try established.encryptData(material)
            XCTAssertFalse(sent.isKeyExchange)
            XCTAssertEqual(try receiverRestart.decryptCiphertext(sent), material)
            XCTAssertEqual(try established.decryptCiphertext(receiverRestart.encryptData(material)), material)
        }
    }

    func testRestorationRejectsWrongAuthoritativeScopeAndLocalIdentityForPreparedAndNativeState() throws {
        let f = try fixture()
        let preparation = try f.sender.serializedData()
        _ = try f.sender.encryptData(control)
        for bytes in [preparation, try f.sender.serializedData()] {
            XCTAssertThrowsError(try f.context.restoreSession(with: bytes, scope: f.scope + Data([1])))
            XCTAssertThrowsError(try f.context.restoreSession(with: bytes, localIdentity: f.receiverIdentity.publicKey))
            XCTAssertNoThrow(try f.context.restoreSession(with: bytes, scope: f.scope, localIdentity: f.senderIdentity.publicKey))
        }
    }

    func testNativeSnapshotCannotBeRelabeledWithAnotherIdentityRepresentationRevisionOrEphemeralKey() throws {
        let f = try fixture()
        _ = try f.sender.encryptData(control)
        let original = try f.sender.serializedData()
        let mutations: [(String, Any)] = [
            ("scope", Data("different host slot".utf8).base64EncodedString()),
            ("localIdentity", f.receiverIdentity.publicKey.base64EncodedString()),
            ("peerIdentity", f.senderIdentity.publicKey.base64EncodedString()),
            ("representation", IdentityPrivateKeyRepresentation.xabberX25519Scalar.rawValue),
            ("revision", 2), ("ephemeralKey", f.preKey.publicKey.base64EncodedString())
        ]
        for (key, value) in mutations {
            let altered = try changingJSON(original) { $0[key] = value }
            XCTAssertThrowsError(try f.context.restoreSession(with: altered), key)
        }
        XCTAssertNoThrow(try f.context.restoreSession(with: original))
    }

    func testNativeSnapshotCorruptionTruncationAndUnsupportedVersionFailClosed() throws {
        let f = try fixture()
        _ = try f.sender.encryptData(control)
        let stored = try f.sender.serializedData()
        let json = try jsonObject(stored)
        let snapshot = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(json["snapshot"] as? String)))
        var corrupted = snapshot
        corrupted[corrupted.count - 1] ^= 1
        var futureVersion = snapshot
        // Public snapshot framing identifies its own schema independently of
        // the app wrapper. A future schema must never invoke a fallback reader.
        futureVersion[8] = 0xFF
        futureVersion[9] = 0xFF
        for damaged in [Data(), Data(snapshot.prefix(20)), Data(snapshot.dropLast()), corrupted, futureVersion] {
            let altered = try changingJSON(stored) { $0["snapshot"] = damaged.base64EncodedString() }
            XCTAssertThrowsError(try f.context.restoreSession(with: altered))
        }
        XCTAssertNoThrow(try f.context.restoreSession(with: stored))
    }

    func testRestorationRejectsUnknownWrapperVersionOversizedInputAndMalformedJSON() throws {
        let f = try fixture()
        let original = try f.sender.serializedData()
        for version in [0, 2, -1] {
            XCTAssertThrowsError(try f.context.restoreSession(with: changingJSON(original) { $0["version"] = version }))
        }
        for bytes in [Data(), Data("{}".utf8), Data("[1,2,3]".utf8), Data(repeating: 0x20, count: 1_048_577)] {
            XCTAssertThrowsError(try f.context.restoreSession(with: bytes))
        }
    }

    func testRestorationRejectsInvalidPreparationShapeAndForeignPrivateOrBundleMaterial() throws {
        let f = try fixture()
        let original = try f.sender.serializedData()
        let alterations: [(inout [String: Any]) throws -> Void] = [
            { $0.removeValue(forKey: "preparationPrivateKey") },
            { $0.removeValue(forKey: "preparationBundle") },
            { $0["snapshot"] = Data([1]).base64EncodedString() },
            { $0["revision"] = 1 },
            { $0["sendCounter"] = 1 },
            { $0["receiveCounter"] = 1 },
            { $0["receivedRatchets"] = [f.preKey.publicKey.base64EncodedString()] },
            { $0["preparationPrivateKey"] = f.receiverIdentity.privateKey.base64EncodedString() },
            { $0["preparationPrivateKey"] = Data(repeating: 1, count: 31).base64EncodedString() },
            { $0["peerIdentity"] = f.senderIdentity.publicKey.base64EncodedString() },
            { $0["representation"] = IdentityPrivateKeyRepresentation.xabberX25519Scalar.rawValue },
            { object in
                var bundle = try XCTUnwrap(object["preparationBundle"] as? [String: Any])
                bundle["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
                object["preparationBundle"] = bundle
            }
        ]
        for (index, change) in alterations.enumerated() {
            XCTAssertThrowsError(try f.context.restoreSession(with: changingJSON(original, change)), "mutation \(index)")
        }
        XCTAssertNoThrow(try f.context.restoreSession(with: original))
    }

    func testRestorationRejectsPartialNativeSnapshotOrMixedNativeAndPreparationState() throws {
        let f = try fixture()
        let preparation = try jsonObject(f.sender.serializedData())
        _ = try f.sender.encryptData(control)
        let original = try f.sender.serializedData()
        for key in ["snapshot", "revision"] {
            XCTAssertThrowsError(try f.context.restoreSession(with: changingJSON(original) { $0.removeValue(forKey: key) }))
        }
        for key in ["preparationPrivateKey", "preparationBundle"] {
            XCTAssertThrowsError(try f.context.restoreSession(with: changingJSON(original) { $0[key] = preparation[key] }))
        }
    }

    func testRestorationRejectsMalformedDuplicateOrOversizedReceivedRatchetMetadata() throws {
        let f = try fixture()
        let receiver = try accept(f.sender.encryptData(control), fixture: f).session
        let original = try receiver.serializedData()
        let ratchet = f.signed.publicKey.base64EncodedString()
        for entries in [[Data(repeating: 0, count: 31).base64EncodedString()], [ratchet, ratchet],
                        Array(repeating: ratchet, count: OMEMO2Session.maximumReceivedRatchets + 1)] {
            XCTAssertThrowsError(try f.context.restoreSession(with: changingJSON(original) { $0["receivedRatchets"] = entries }))
        }
        for length in [0, 31, 33] {
            XCTAssertThrowsError(try f.context.restoreSession(with: changingJSON(original) {
                $0["ephemeralKey"] = Data(repeating: 0, count: length).base64EncodedString()
            }))
        }
        XCTAssertNoThrow(try f.context.restoreSession(with: original))
    }

    private func fixture(representation: IdentityPrivateKeyRepresentation = .ed25519Seed) throws -> Fixture {
        let context = try OMEMO2Context(error: ())
        let sender = try context.identity(withPrivateKey: Data(repeating: 0x11, count: 32), representation: representation)
        let receiver = try context.identity(withPrivateKey: Data(repeating: 0x22, count: 32), representation: representation)
        let signed = try context.keyPair(withPrivateKey: Data(repeating: 0x33, count: 32))
        let preKey = try context.keyPair(withPrivateKey: Data(repeating: 0x44, count: 32))
        let bundle = try OMEMO2Bundle(identityKey: receiver.publicKey, signedPreKey: signed.publicKey, signedPreKeyID: 7,
            signature: context.sign(signed.publicKey, identity: receiver), preKey: preKey.publicKey, preKeyID: 9)
        let scope = Data("isolated-native-adapter-behavior".utf8)
        return Fixture(context: context, senderIdentity: sender, receiverIdentity: receiver, signed: signed, preKey: preKey,
            bundle: bundle, sender: try context.initiateSession(withIdentity: sender, bundle: bundle, scope: scope), scope: scope)
    }

    private func accept(_ ciphertext: OMEMO2Ciphertext, fixture f: Fixture) throws -> (session: OMEMO2Session, plaintext: Data) {
        var plaintext: NSData?
        let session = try f.context.acceptKeyExchange(ciphertext, identity: f.receiverIdentity,
            signedPreKey: f.signed, signedPreKeyID: 7, preKey: f.preKey, preKeyID: 9,
            plaintext: &plaintext, scope: f.scope)
        return (session, try XCTUnwrap(plaintext) as Data)
    }

    private func bundle(_ f: Fixture, replacing field: String = "", with value: Data = Data(),
                        signedID: UInt32 = 7, preKeyID: UInt32 = 9) throws -> OMEMO2Bundle {
        try OMEMO2Bundle(identityKey: field == "identityKey" ? value : f.bundle.identityKey,
            signedPreKey: field == "signedPreKey" ? value : f.bundle.signedPreKey, signedPreKeyID: signedID,
            signature: field == "signature" ? value : f.bundle.signature,
            preKey: field == "preKey" ? value : f.bundle.preKey, preKeyID: preKeyID)
    }

    private func modifyingExchange(_ ciphertext: OMEMO2Ciphertext,
                                   _ change: (OMEMOKeyExchange) throws -> OMEMOKeyExchange) throws -> OMEMO2Ciphertext {
        guard case .keyExchange(let exchange) = try OMEMOEnvelope(data: ciphertext.data, keyExchange: true) else {
            throw OMEMOCryptoError.invalidEnvelope
        }
        return try OMEMO2Ciphertext(data: change(exchange).serializedData(), keyExchange: true)
    }

    private func modifying(_ ciphertext: OMEMO2Ciphertext,
                           _ change: (OMEMOAuthenticatedMessage) throws -> OMEMOAuthenticatedMessage) throws -> OMEMO2Ciphertext {
        let envelope = try OMEMOEnvelope(data: ciphertext.data, keyExchange: ciphertext.isKeyExchange)
        let altered: OMEMOEnvelope
        switch envelope {
        case .message(let message): altered = .message(try change(message))
        case .keyExchange(let exchange):
            altered = .keyExchange(try OMEMOKeyExchange(preKeyID: exchange.preKeyID,
                signedPreKeyID: exchange.signedPreKeyID, identityKey: exchange.identityKey,
                ephemeralKey: exchange.ephemeralKey, message: change(exchange.message)))
        }
        return try OMEMO2Ciphertext(data: altered.serializedData(), keyExchange: ciphertext.isKeyExchange)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func changingJSON(_ data: Data, _ change: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try jsonObject(data)
        try change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject(data), options: [.sortedKeys])
    }
}
