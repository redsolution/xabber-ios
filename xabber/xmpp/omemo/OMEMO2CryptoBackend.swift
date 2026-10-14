import Foundation
import XabberCryptoSwift

/// RFC7748 public-coordinate equality for host slot/diagnostic metadata only.
/// The backend authenticates the original envelope bytes without rewriting them.
enum OMEMO2PublicKeyRepresentation {
    static func canonicalX25519(_ key: Data) -> Data {
        guard key.count == 32 else { return key }
        var bytes = Array(key)
        bytes[31] &= 0x7f
        let prime = [UInt8(0xed)] + Array(repeating: UInt8(0xff), count: 30) + [0x7f]
        var atLeastPrime = true
        for index in stride(from: 31, through: 0, by: -1) {
            if bytes[index] != prime[index] {
                atLeastPrime = bytes[index] > prime[index]
                break
            }
        }
        if atLeastPrime {
            var borrow = 0
            for index in 0..<32 {
                let difference = Int(bytes[index]) - Int(prime[index]) - borrow
                bytes[index] = UInt8(truncatingIfNeeded: difference)
                borrow = difference < 0 ? 1 : 0
            }
        }
        return Data(bytes)
    }
}

/// App boundary for the transport-independent backend. The storage adapter owns
/// serialization and commits; these session objects are disposable candidates.
struct OMEMO2IdentityKeyPair {
    fileprivate let raw: IdentityKeyPair
    var privateKey: Data { raw.exportPrivateMaterial() }
    var publicKey: Data { raw.publicKey.rawRepresentation }
    var fingerprintPublicKey: Data { raw.agreementPublicKey.rawRepresentation }
    var representation: IdentityPrivateKeyRepresentation { raw.representation }
}

struct OMEMO2KeyPair {
    fileprivate let raw: AgreementKeyPair
    var privateKey: Data { raw.exportPrivateScalar() }
    var publicKey: Data { raw.publicKey.rawRepresentation }
}

struct OMEMO2Bundle: Codable {
    let identityKey: Data
    let signedPreKey: Data
    let signedPreKeyID: UInt32
    let signature: Data
    let preKey: Data
    let preKeyID: UInt32

    init(identityKey: Data, signedPreKey: Data, signedPreKeyID: UInt32,
         signature: Data, preKey: Data, preKeyID: UInt32) throws {
        self.identityKey = identityKey
        self.signedPreKey = signedPreKey
        self.signedPreKeyID = signedPreKeyID
        self.signature = signature
        self.preKey = preKey
        self.preKeyID = preKeyID
        _ = try selectedPeerBundle()
    }

    fileprivate func selectedPeerBundle() throws -> SelectedPeerBundle {
        try SelectedPeerBundle(identityKey: Ed25519PublicKey(rawRepresentation: identityKey),
            signedPreKey: X25519PublicKey(rawRepresentation: signedPreKey),
            signedPreKeyID: SignedPreKeyID(signedPreKeyID),
            signature: Ed25519Signature(rawRepresentation: signature),
            preKey: X25519PublicKey(rawRepresentation: preKey), preKeyID: PreKeyID(preKeyID))
    }
}

struct OMEMO2Ciphertext {
    let data: Data
    fileprivate let envelope: OMEMOEnvelope
    fileprivate let message: OMEMOMessage

    init(data: Data, keyExchange: Bool) throws {
        self.data = data
        envelope = try XabberCrypto().parseEnvelope(data, keyExchange: keyExchange)
        switch envelope {
        case .message(let authenticated): message = try authenticated.decodeMessage()
        case .keyExchange(let exchange): message = try exchange.message.decodeMessage()
        }
    }

    fileprivate init(_ envelope: OMEMOEnvelope) throws {
        self.envelope = envelope
        data = try envelope.serializedData()
        switch envelope {
        case .message(let authenticated): message = try authenticated.decodeMessage()
        case .keyExchange(let exchange): message = try exchange.message.decodeMessage()
        }
    }

    var isKeyExchange: Bool { if case .keyExchange = envelope { return true }; return false }
    var ephemeralKey: Data? { if case .keyExchange(let value) = envelope { return value.ephemeralKey }; return nil }
    var preKeyID: UInt32 { if case .keyExchange(let value) = envelope { return value.preKeyID }; return 0 }
    var signedPreKeyID: UInt32 { if case .keyExchange(let value) = envelope { return value.signedPreKeyID }; return 0 }
    var identityKey: Data? { if case .keyExchange(let value) = envelope { return value.identityKey }; return nil }
    var ratchetKey: Data { message.ratchetKey }
    var counter: UInt32 { message.counter }
}

final class OMEMO2Context {
    fileprivate let crypto = XabberCrypto()
    fileprivate static let testScope = Data("xabber-omemo2-unbound-test-session".utf8)

    init(error: Void) throws {}

    func generateIdentity(representation: IdentityPrivateKeyRepresentation = .xabberX25519Scalar) throws -> OMEMO2IdentityKeyPair {
        OMEMO2IdentityKeyPair(raw: try crypto.keys.generateIdentity(representation: representation))
    }

    func identity(withPrivateKey privateKey: Data,
                  representation: IdentityPrivateKeyRepresentation = .xabberX25519Scalar) throws -> OMEMO2IdentityKeyPair {
        OMEMO2IdentityKeyPair(raw: try crypto.keys.identity(privateMaterial: privateKey, representation: representation))
    }

    func generateKeyPair() throws -> OMEMO2KeyPair {
        OMEMO2KeyPair(raw: try crypto.keys.generateAgreementKeyPair())
    }

    func keyPair(withPrivateKey privateKey: Data) throws -> OMEMO2KeyPair {
        OMEMO2KeyPair(raw: try crypto.keys.agreementKeyPair(privateScalar: privateKey))
    }

    func sign(_ data: Data, identity: OMEMO2IdentityKeyPair) throws -> Data {
        try identity.raw.sign(data).rawRepresentation
    }

    static func verifySignature(_ signature: Data, data: Data, identityKey: Data) throws {
        guard try Ed25519PublicKey(rawRepresentation: identityKey)
            .isValidSignature(Ed25519Signature(rawRepresentation: signature), for: data) else {
            throw OMEMOKeyError.invalidSignature
        }
    }

    func initiateSession(withIdentity identity: OMEMO2IdentityKeyPair, bundle: OMEMO2Bundle,
                         scope: Data = OMEMO2Context.testScope) throws -> OMEMO2Session {
        _ = try bundle.selectedPeerBundle()
        let binding = try OMEMOSessionContext(scope: scope, localIdentity: identity.raw.publicKey,
            peerIdentity: Ed25519PublicKey(rawRepresentation: bundle.identityKey),
            localIdentityRepresentation: identity.representation)
        // The native facade creates the first envelope together with its state.
        // Store an explicit preparation until the actual material is available,
        // avoiding a discarded control packet and an artificial counter advance.
        return OMEMO2Session(crypto: crypto, context: binding, preparation: (identity, bundle),
                             provisionalEphemeral: try generateKeyPair().publicKey)
    }

    func acceptKeyExchange(_ ciphertext: OMEMO2Ciphertext, identity: OMEMO2IdentityKeyPair,
                           signedPreKey: OMEMO2KeyPair, signedPreKeyID: UInt32,
                           preKey: OMEMO2KeyPair, preKeyID: UInt32, plaintext: inout NSData?,
                           scope: Data = OMEMO2Context.testScope, preKeyConsumed: Bool = false) throws -> OMEMO2Session {
        guard case .keyExchange(let exchange) = ciphertext.envelope else { throw OMEMOCryptoError.invalidEnvelope }
        let binding = try OMEMOSessionContext(scope: scope, localIdentity: identity.raw.publicKey,
            peerIdentity: Ed25519PublicKey(rawRepresentation: exchange.identityKey),
            localIdentityRepresentation: identity.representation)
        let localKeys = try OMEMOLocalPreKeys(signedPreKeyID: SignedPreKeyID(signedPreKeyID),
            signedPreKey: signedPreKey.raw, preKeyID: PreKeyID(preKeyID), preKey: preKey.raw,
            availability: preKeyConsumed ? .retainedConsumed : .available)
        let candidate = try crypto.accept(exchange, identity: identity.raw, preKeys: localKeys,
                                          context: binding, allowRetainedPreKey: preKeyConsumed)
        let session = OMEMO2Session(crypto: crypto, session: candidate.candidateSession)
        session.observeAuthenticatedReceive(ciphertext)
        plaintext = OMEMO2Session.bytes(candidate.material) as NSData
        return session
    }

    func restoreSession(with data: Data, scope: Data? = nil, localIdentity: Data? = nil) throws -> OMEMO2Session {
        try OMEMO2Session.restore(data, crypto: crypto, expectedScope: scope, expectedLocalIdentity: localIdentity)
    }
}

/// A local wrapper keeps the native snapshot opaque and records its exact host
/// binding/revision separately. Its JSON always lives inside protected storage.
final class OMEMO2Session {
    // A cached message key may outlive native retired-chain tombstones. Keep
    // diagnostic identities for the entire native successful-receive horizon.
    static let maximumReceivedRatchets = Int(OMEMOSessionLimits.default.maximumSkippedKeyAge) + 1

    private struct Stored: Codable {
        let version: Int
        let scope: Data
        let localIdentity: Data
        let peerIdentity: Data
        let representation: IdentityPrivateKeyRepresentation
        let revision: UInt64?
        let snapshot: Data?
        let preparationPrivateKey: Data?
        let preparationBundle: OMEMO2Bundle?
        let ephemeralKey: Data
        let sendCounter: UInt32
        let receiveCounter: UInt32
        let receivedRatchets: [Data]
    }

    private let crypto: XabberCrypto
    private let context: OMEMOSessionContext
    private var nativeSession: OMEMOSession?
    private var preparation: (OMEMO2IdentityKeyPair, OMEMO2Bundle)?
    private var provisionalEphemeral: Data?
    private(set) var sendCounter: UInt32 = 0
    private(set) var receiveCounter: UInt32 = 0
    private var receivedRatchets: [Data] = []

    fileprivate init(crypto: XabberCrypto, context: OMEMOSessionContext,
                     preparation: (OMEMO2IdentityKeyPair, OMEMO2Bundle), provisionalEphemeral: Data) {
        self.crypto = crypto
        self.context = context
        self.preparation = preparation
        self.provisionalEphemeral = provisionalEphemeral
    }

    fileprivate init(crypto: XabberCrypto, session: OMEMOSession) {
        self.crypto = crypto
        context = session.context
        nativeSession = session
    }

    var ephemeralKey: Data { nativeSession?.exchange.ephemeralKey.rawRepresentation ?? provisionalEphemeral! }
    var remoteIdentityKey: Data { context.peerIdentity.rawRepresentation }
    var remotePreKeyID: UInt32 {
        if let nativeSession {
            return nativeSession.role == .initiator ? nativeSession.exchange.preKeyID.rawValue : 0
        }
        return preparation!.1.preKeyID
    }
    var isKeyExchangePending: Bool { nativeSession?.pendingKeyExchange ?? true }

    func encryptData(_ data: Data) throws -> OMEMO2Ciphertext {
        let material: OMEMOMessageMaterial
        if data == Data(repeating: 0, count: 32) { material = .control }
        else { material = .payload(try OMEMOPayloadKeyMaterial(serializedData: data)) }
        let candidate: OMEMOSendingCandidate
        if let nativeSession {
            candidate = try crypto.encrypt(material, from: nativeSession)
        } else if let (identity, bundle) = preparation {
            candidate = try crypto.initiate(identity: identity.raw, peerBundle: bundle.selectedPeerBundle(),
                                            material: material, context: context)
        } else { throw OMEMOCryptoError.missingSession }
        let ciphertext = try OMEMO2Ciphertext(candidate.envelope)
        guard ciphertext.counter < UInt32.max else { throw OMEMOCryptoError.counterOverflow }
        nativeSession = candidate.candidateSession
        preparation = nil
        provisionalEphemeral = nil
        sendCounter = ciphertext.counter + 1
        return ciphertext
    }

    func decryptCiphertext(_ ciphertext: OMEMO2Ciphertext) throws -> Data {
        guard let nativeSession else { throw OMEMOCryptoError.missingSession }
        let candidate = try crypto.decrypt(ciphertext.envelope, from: nativeSession)
        self.nativeSession = candidate.candidateSession
        observeAuthenticatedReceive(ciphertext)
        return Self.bytes(candidate.material)
    }

    fileprivate func observeAuthenticatedReceive(_ ciphertext: OMEMO2Ciphertext) {
        let ratchetKey = OMEMO2PublicKeyRepresentation.canonicalX25519(ciphertext.ratchetKey)
        if !receivedRatchets.contains(ratchetKey) {
            receivedRatchets.append(ratchetKey)
            if receivedRatchets.count > Self.maximumReceivedRatchets {
                receivedRatchets.removeFirst(receivedRatchets.count - Self.maximumReceivedRatchets)
            }
            // A successful new peer DH creates a fresh local sending chain.
            sendCounter = 0
            receiveCounter = ciphertext.counter == UInt32.max ? UInt32.max : ciphertext.counter + 1
        } else if receivedRatchets.last == ratchetKey {
            receiveCounter = max(receiveCounter, ciphertext.counter == UInt32.max ? UInt32.max : ciphertext.counter + 1)
        }
    }

    fileprivate static func bytes(_ material: OMEMOMessageMaterial) -> Data {
        switch material {
        case .payload(let key): return key.serializedData()
        case .control: return Data(repeating: 0, count: 32)
        }
    }

    func serializedData() throws -> Data {
        let stored = Stored(version: 1, scope: context.scope,
            localIdentity: context.localIdentity.rawRepresentation, peerIdentity: remoteIdentityKey,
            representation: context.localIdentityRepresentation, revision: nativeSession?.revision,
            snapshot: try nativeSession.map { try crypto.snapshot($0).exportSecretData() },
            preparationPrivateKey: preparation?.0.privateKey, preparationBundle: preparation?.1,
            ephemeralKey: ephemeralKey, sendCounter: sendCounter, receiveCounter: receiveCounter,
            receivedRatchets: receivedRatchets)
        return try JSONEncoder().encode(stored)
    }

    fileprivate static func restore(_ data: Data, crypto: XabberCrypto,
                                     expectedScope: Data?, expectedLocalIdentity: Data?) throws -> OMEMO2Session {
        guard data.count <= 1_048_576 else { throw OMEMOCryptoError.invalidState }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard stored.version == 1, stored.ephemeralKey.count == 32,
              stored.receivedRatchets.count <= maximumReceivedRatchets,
              stored.receivedRatchets.allSatisfy({ $0.count == 32 }),
              Set(stored.receivedRatchets).count == stored.receivedRatchets.count,
              expectedScope.map({ $0 == stored.scope }) ?? true,
              expectedLocalIdentity.map({ $0 == stored.localIdentity }) ?? true else {
            throw OMEMOCryptoError.bindingMismatch
        }
        let context = try OMEMOSessionContext(scope: stored.scope,
            localIdentity: Ed25519PublicKey(rawRepresentation: stored.localIdentity),
            peerIdentity: Ed25519PublicKey(rawRepresentation: stored.peerIdentity),
            localIdentityRepresentation: stored.representation)
        let result: OMEMO2Session
        if let snapshot = stored.snapshot, let revision = stored.revision {
            guard stored.preparationPrivateKey == nil, stored.preparationBundle == nil else { throw OMEMOCryptoError.invalidState }
            let session = try crypto.restore(OMEMOSnapshot(secretData: snapshot), context: context, expectedRevision: revision)
            guard session.exchange.ephemeralKey.rawRepresentation == stored.ephemeralKey else { throw OMEMOCryptoError.bindingMismatch }
            result = OMEMO2Session(crypto: crypto, session: session)
        } else {
            guard stored.snapshot == nil, stored.revision == nil,
                  let privateKey = stored.preparationPrivateKey, let bundle = stored.preparationBundle,
                  stored.sendCounter == 0, stored.receiveCounter == 0, stored.receivedRatchets.isEmpty else {
                throw OMEMOCryptoError.invalidState
            }
            let identity = try crypto.keys.identity(privateMaterial: privateKey, representation: stored.representation)
            guard identity.publicKey == context.localIdentity, bundle.identityKey == stored.peerIdentity else {
                throw OMEMOCryptoError.bindingMismatch
            }
            _ = try bundle.selectedPeerBundle()
            result = OMEMO2Session(crypto: crypto, context: context,
                preparation: (OMEMO2IdentityKeyPair(raw: identity), bundle), provisionalEphemeral: stored.ephemeralKey)
        }
        result.sendCounter = stored.sendCounter
        result.receiveCounter = stored.receiveCounter
        result.receivedRatchets = stored.receivedRatchets
        return result
    }
}
