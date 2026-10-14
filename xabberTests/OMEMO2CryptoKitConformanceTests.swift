//
//  OMEMO2CryptoKitConformanceTests.swift
//  xabberTests
//
//  Independent checks for the linked XabberCryptoSwift backend.
//

import CryptoKit
import XCTest
import XabberCryptoSwift
@testable import xabber

final class OMEMO2CryptoKitConformanceTests: XCTestCase {
    private let aliceScalar = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
    private let bobScalar = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"

    func testImportedX25519PublicKeysMatchRFC7748AndCryptoKit() throws {
        // RFC7748 §6.1 uses scalars whose decoding requires clamping.
        let alicePrivate = try data(hex: aliceScalar)
        let bobPrivate = try data(hex: bobScalar)
        let aliceExpected = try data(hex: "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        let bobExpected = try data(hex: "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let context = try OMEMO2Context(error: ())

        let alice = try context.keyPair(withPrivateKey: alicePrivate)
        let bob = try context.keyPair(withPrivateKey: bobPrivate)
        let independentAlice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: alicePrivate)
        let independentBob = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bobPrivate)

        XCTAssertEqual(alice.publicKey, aliceExpected)
        XCTAssertEqual(bob.publicKey, bobExpected)
        XCTAssertEqual(alice.publicKey, independentAlice.publicKey.rawRepresentation)
        XCTAssertEqual(bob.publicKey, independentBob.publicKey.rawRepresentation)
        let identity = try context.identity(withPrivateKey: alicePrivate)
        XCTAssertEqual(identity.fingerprintPublicKey, aliceExpected)
        XCTAssertEqual(identity.publicKey.count, 32)
    }

    func testCheckedX25519SharedSecretMatchesRFC7748AndCryptoKit() throws {
        let alicePrivate = try data(hex: aliceScalar)
        let bobPrivate = try data(hex: bobScalar)
        let alicePublic = try data(hex: "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        let bobPublic = try data(hex: "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let expected = try data(hex: "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
        let independentPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: alicePrivate)
        let independentPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bobPublic)

        let independentSecret = try independentPrivate.sharedSecretFromKeyAgreement(with: independentPublic)
            .withUnsafeBytes { Data($0) }
        let aliceSecret = try checkedAgreement(privateKey: alicePrivate, publicKey: bobPublic)
        let bobSecret = try checkedAgreement(privateKey: bobPrivate, publicKey: alicePublic)

        XCTAssertEqual(independentSecret, expected)
        XCTAssertEqual(aliceSecret, expected)
        XCTAssertEqual(bobSecret, expected)
        XCTAssertEqual(aliceSecret, independentSecret)
    }

    func testNativeXEdDSASignaturesVerifyWithCryptoKitEd25519() throws {
        let context = try OMEMO2Context(error: ())
        let identities = [
            try context.identity(withPrivateKey: data(hex: aliceScalar)),
            try context.identity(withPrivateKey: data(hex: bobScalar))
        ]
        let messages = [Data(), Data(repeating: 0xA5, count: 32), Data("OMEMO XEdDSA conformance".utf8)]

        for identity in identities {
            let independentVerifier = try Curve25519.Signing.PublicKey(rawRepresentation: identity.publicKey)
            for message in messages {
                let signature = try context.sign(message, identity: identity)

                XCTAssertEqual(signature.count, 64)
                XCTAssertTrue(independentVerifier.isValidSignature(signature, for: message))
                XCTAssertNoThrow(try OMEMO2Context.verifySignature(signature, data: message, identityKey: identity.publicKey))
                var damaged = signature
                damaged[0] ^= 1
                XCTAssertFalse(independentVerifier.isValidSignature(damaged, for: message))
                XCTAssertThrowsError(try OMEMO2Context.verifySignature(damaged, data: message, identityKey: identity.publicKey))
            }
        }
    }

    func testCryptoKitEd25519SignedPreKeyWithSignBitOneIsAcceptedByWrapper() throws {
        // This fixed Ed25519 seed yields a public key with Edwards x sign 1.
        // It exercises a peer which uses Ed25519 internally, unlike native XEdDSA.
        let independentIdentity = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((0..<32).map(UInt8.init)))
        let identityKey = independentIdentity.publicKey.rawRepresentation
        let context = try OMEMO2Context(error: ())
        let signedPreKey = try context.generateKeyPair()
        let preKey = try context.generateKeyPair()
        let signature = try independentIdentity.signature(for: signedPreKey.publicKey)

        XCTAssertEqual(try XCTUnwrap(identityKey.last) & 0x80, 0x80)
        let bundle = try OMEMO2Bundle(
            identityKey: identityKey,
            signedPreKey: signedPreKey.publicKey,
            signedPreKeyID: 7,
            signature: signature,
            preKey: preKey.publicKey,
            preKeyID: 9
        )

        XCTAssertEqual(bundle.identityKey, identityKey)
        XCTAssertEqual(bundle.signature, signature)
        XCTAssertNoThrow(try OMEMO2Context.verifySignature(signature, data: signedPreKey.publicKey, identityKey: identityKey))
        var damagedPreKey = signedPreKey.publicKey
        damagedPreKey[0] ^= 1
        XCTAssertThrowsError(try OMEMO2Context.verifySignature(signature, data: damagedPreKey, identityKey: identityKey))
    }

    func testKeyExchangeCarriesTheEd25519IdentityUsedByCryptoKitVerifier() throws {
        let context = try OMEMO2Context(error: ())
        let alice = try context.identity(withPrivateKey: data(hex: aliceScalar))
        let bob = try context.identity(withPrivateKey: data(hex: bobScalar))
        let signedPreKey = try context.generateKeyPair()
        let preKey = try context.generateKeyPair()
        let bobSignature = try context.sign(signedPreKey.publicKey, identity: bob)
        let bundle = try OMEMO2Bundle(
            identityKey: bob.publicKey,
            signedPreKey: signedPreKey.publicKey,
            signedPreKeyID: 7,
            signature: bobSignature,
            preKey: preKey.publicKey,
            preKeyID: 9
        )
        let session = try context.initiateSession(withIdentity: alice, bundle: bundle)
        let proof = try context.sign(signedPreKey.publicKey, identity: alice)

        let encrypted = try session.encryptData(Data(repeating: 0x42, count: 48))
        let parsed = try OMEMO2Ciphertext(data: encrypted.data, keyExchange: true)
        let wireIdentity = try XCTUnwrap(parsed.identityKey)
        let independentVerifier = try Curve25519.Signing.PublicKey(rawRepresentation: wireIdentity)

        XCTAssertTrue(parsed.isKeyExchange)
        XCTAssertEqual(wireIdentity, alice.publicKey)
        XCTAssertEqual(wireIdentity.count, 32)
        XCTAssertNotEqual(wireIdentity, alice.fingerprintPublicKey)
        XCTAssertEqual(parsed.ratchetKey.count, 32)
        XCTAssertEqual(try XCTUnwrap(parsed.ephemeralKey).count, 32)
        XCTAssertTrue(independentVerifier.isValidSignature(proof, for: signedPreKey.publicKey))
    }

    private func checkedAgreement(privateKey: Data, publicKey: Data) throws -> Data {
        let key = try OMEMOKeyFactory().agreementKeyPair(privateScalar: privateKey)
        return try key.sharedSecret(with: X25519PublicKey(rawRepresentation: publicKey))
    }

    private func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else { throw NSError(domain: "OMEMO2CryptoKitConformanceTests.hex", code: 1) }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { throw NSError(domain: "OMEMO2CryptoKitConformanceTests.hex", code: 2) }
            bytes.append(byte)
            index = end
        }
        return Data(bytes)
    }
}
