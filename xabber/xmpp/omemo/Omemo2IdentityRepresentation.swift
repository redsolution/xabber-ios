import Foundation
import Curve25519Kit
import RealmSwift
import SignalProtocolC
import SignalProtocolObjC

enum Omemo2IdentityRepresentationError: Error {
    case invalidIdentity
    case invalidPrivateKey
    case cryptoFailure(Int32)
}

/// Keeps the transport identity (Ed25519) distinct from the Curve25519 key
/// used for fingerprints and identity ECDH. A stored 33-byte key explicitly
/// selects the old Signal representation; a 32-byte key selects OMEMO2.
enum Omemo2IdentityRepresentation {
    /// A prepared OMEMO2 aggregate owns the local identity. Legacy credentials
    /// are a transition source only when that aggregate is absent; malformed or
    /// inaccessible new state must never silently select an older identity.
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
        do {
            return try authoritativeStorage.identity().privateKey
        } catch OMEMO2StorageError.stateUnavailable {
            let realm = try WRealm.safe()
            guard realm.objects(SignalIdentityStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND protocolProfile == %@", owner, owner, XabberOMEMO2Storage.profile)
                .isEmpty else { throw OMEMO2StorageError.stateUnavailable }
            let legacy: Data?
            if let legacyPrivateKey { legacy = legacyPrivateKey() }
            else { legacy = CredentialsManager.shared.getIdentityKeyPrivateKey(for: owner) }
            guard let legacy, legacy.count == 32 else {
                throw Omemo2IdentityRepresentationError.invalidPrivateKey
            }
            return legacy
        }
    }

    static func curvePublicKey(from wireIdentity: Data) throws -> Data {
        guard wireIdentity.count == 32 else {
            throw Omemo2IdentityRepresentationError.invalidIdentity
        }
        return try withContext { context in
            var point: OpaquePointer?
            defer { if let point { signal_type_unref(point) } }
            try wireIdentity.withUnsafeBytes { bytes in
                try requireSuccess(omemo_identity_key_decode(&point, bytes.bindMemory(to: UInt8.self).baseAddress, context))
            }
            var rawCurve = [UInt8](repeating: 0, count: 32)
            try rawCurve.withUnsafeMutableBufferPointer {
                try requireSuccess(omemo_public_key_encode($0.baseAddress, point))
            }
            return Data(rawCurve)
        }
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

    // These aliases express the bundle codec's two distinct inputs.
    static func rawX25519(identityKey: Data) throws -> Data {
        try curvePublicKey(from: identityKey)
    }

    static func canonicalRawX25519(storedIdentityKey: Data) throws -> Data {
        try canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: storedIdentityKey)
    }

    static func sharedSecret(privateKey: Data, peerIdentity: Data) throws -> Data {
        guard privateKey.count == 32 else {
            throw Omemo2IdentityRepresentationError.invalidPrivateKey
        }
        let rawCurve = try canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: peerIdentity)
        return try withContext { context in
            var publicPoint: OpaquePointer?
            var privatePoint: OpaquePointer?
            defer {
                if let publicPoint { signal_type_unref(publicPoint) }
                if let privatePoint { signal_type_unref(privatePoint) }
            }
            try rawCurve.withUnsafeBytes {
                try requireSuccess(omemo_public_key_decode(&publicPoint, $0.bindMemory(to: UInt8.self).baseAddress, context))
            }
            try privateKey.withUnsafeBytes {
                try requireSuccess(curve_decode_private_point(&privatePoint, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, context))
            }
            var shared = [UInt8](repeating: 0, count: 32)
            try shared.withUnsafeMutableBufferPointer {
                try requireSuccess(omemo_calculate_agreement($0.baseAddress, publicPoint, privatePoint))
            }
            return Data(shared)
        }
    }

    static func sign(_ data: Data, privateKey: Data) throws -> Data {
        let context = try OMEMO2Context(error: ())
        let identity = try context.identity(withPrivateKey: privateKey)
        return try context.sign(data, identity: identity)
    }

    static func verify(_ signature: Data, data: Data, storedIdentity: Data) -> Bool {
        guard signature.count == 64 else { return false }
        if storedIdentity.count == 32 {
            // A standard signature failure cannot select a legacy verifier.
            do {
                try OMEMO2Context.verifySignature(signature, data: data, identityKey: storedIdentity)
                return true
            } catch {
                return false
            }
        }
        guard storedIdentity.count == 33, storedIdentity.first == 5 else { return false }
        return Ed25519.verifySignature(signature, publicKey: Data(storedIdentity.dropFirst()), data: data)
    }

    private static func withContext<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        try requireSuccess(signal_context_create(&pointer, nil))
        guard let context = pointer else {
            throw Omemo2IdentityRepresentationError.invalidIdentity
        }
        defer { signal_context_destroy(context) }
        return try operation(context)
    }

    private static func requireSuccess(_ result: Int32) throws {
        guard result == 0 else { throw Omemo2IdentityRepresentationError.cryptoFailure(result) }
    }
}
