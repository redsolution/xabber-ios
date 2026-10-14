import Foundation
import XabberCryptoSwift

enum Omemo2IdentityRepresentationError: Error {
    case invalidIdentity
    case invalidPrivateKey
}

/// Exact Ed25519 wire identities remain distinct from the X25519 projection
/// used for fingerprints and identity agreement. A legacy 33-byte projection
/// is display metadata only; it cannot supply a local native identity.
enum Omemo2IdentityRepresentation {
    /// Only prepared native protected state may supply signing/agreement keys.
    /// Missing, corrupt or inaccessible state never selects a retired scalar.
    static func localIdentityPrivateKey(owner: String, storage: XabberOMEMO2Storage? = nil,
                                        legacyPrivateKey: (() -> Data?)? = nil) throws -> Data {
        let authoritativeStorage: XabberOMEMO2Storage
        if let storage {
            authoritativeStorage = storage
        } else if let active = AccountManager.shared.find(for: owner)?.omemo.omemo2Storage {
            authoritativeStorage = active
        } else {
            authoritativeStorage = try XabberOMEMO2Storage(owner: owner)
        }
        guard authoritativeStorage.owner == owner else {
            throw Omemo2IdentityRepresentationError.invalidIdentity
        }
        return try authoritativeStorage.identity().privateKey
    }

    static func curvePublicKey(from wireIdentity: Data) throws -> Data {
        try Ed25519PublicKey(rawRepresentation: wireIdentity).agreementKey().rawRepresentation
    }

    static func canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity identity: Data) throws -> Data {
        if identity.count == 33, identity.first == 5 {
            return Data(identity.dropFirst())
        }
        return try curvePublicKey(from: identity)
    }

    static func fingerprint(for identity: Data) throws -> String {
        let curve = try canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: identity)
        return stride(from: 0, to: curve.count, by: 4).map { offset in
            curve[offset..<(offset + 4)].map { String(format: "%02x", $0) }.joined()
        }.joined(separator: " ")
    }

    static func rawX25519(identityKey: Data) throws -> Data {
        try curvePublicKey(from: identityKey)
    }

    static func canonicalRawX25519(storedIdentityKey: Data) throws -> Data {
        try canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: storedIdentityKey)
    }

    static func sharedSecret(privateKey: Data, peerIdentity: Data,
                             representation: IdentityPrivateKeyRepresentation = .ed25519Seed) throws -> Data {
        guard privateKey.count == 32 else {
            throw Omemo2IdentityRepresentationError.invalidPrivateKey
        }
        let identity = try OMEMOKeyFactory().identity(privateMaterial: privateKey, representation: representation)
        let peer = try X25519PublicKey(rawRepresentation: canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: peerIdentity))
        return try identity.sharedSecret(with: peer)
    }

    static func sign(_ data: Data, privateKey: Data,
                     representation: IdentityPrivateKeyRepresentation = .ed25519Seed) throws -> Data {
        let identity = try OMEMOKeyFactory().identity(privateMaterial: privateKey, representation: representation)
        return try identity.sign(data).rawRepresentation
    }

    static func verify(_ signature: Data, data: Data, storedIdentity: Data) -> Bool {
        // A retired Curve-only identity cannot establish native Ed identity.
        // Invalid signatures never trigger a representation/verifier fallback.
        guard signature.count == 64, storedIdentity.count == 32 else { return false }
        do {
            return try Ed25519PublicKey(rawRepresentation: storedIdentity)
                .isValidSignature(Ed25519Signature(rawRepresentation: signature), for: data)
        } catch {
            return false
        }
    }
}
