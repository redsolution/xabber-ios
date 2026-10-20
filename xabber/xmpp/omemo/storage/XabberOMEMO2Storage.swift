import Foundation
import XabberCryptoSwift
import CryptoKit
import RealmSwift

enum OMEMO2StorageError: Error {
    case stateUnavailable
    case invalidState
    case identityMismatch
    case invalidDeviceID
    case invalidKeyID
    case missingPreKey
    case missingSession
    case receiveOnlySession
    case persistenceFailed
    case authenticatedDuplicate
    case freshBundleRequired
    case pendingOptOut
}

struct OMEMO2PublicPreKey: Equatable {
    let id: UInt32
    let publicKey: Data
}

struct OMEMO2LocalBundle {
    let deviceID: Int
    let identityKey: Data
    let fingerprintPublicKey: Data
    let signedPreKey: Data
    let signedPreKeyID: UInt32
    let signature: Data
    let preKeys: [OMEMO2PublicPreKey]
}

struct OMEMO2PeerAddress: Hashable, Codable {
    let jid: String
    let deviceID: Int
}

struct OMEMO2SessionMetadata {
    let remoteIdentityKey: Data
    let ephemeralKey: Data
    let sendCounter: UInt32
    let receiveCounter: UInt32
    let receiveOnly: Bool
    let keyExchangePending: Bool
}

/// Each save replaces one protected account item atomically. Implementations
/// must throw on a failed write and must distinguish unavailable from absent.
protocol OMEMO2StatePersistence {
    func load(owner: String) throws -> Data?
    func save(_ data: Data, owner: String) throws
    func remove(owner: String) throws
    /// This marker can only deny fallback after missing native secrets; it
    /// never supplies crypto material or grants any trust/policy permission.
    func nativePreparationExists(owner: String) throws -> Bool
    /// Read-only domain policy migration. Old crypto state remains opaque and
    /// must never supply keys or sessions to the native backend.
    func retiredOptOutRecords(owner: String) throws -> [String: OMEMO2OptOutRecord]?
    func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)?
    func legacyDeviceID(owner: String) -> Int?
}

extension OMEMO2StatePersistence {
    func nativePreparationExists(owner: String) throws -> Bool { false }
    func retiredOptOutRecords(owner: String) throws -> [String: OMEMO2OptOutRecord]? { nil }
    // Retained only for existing injectable persistence adapters. The native
    // backend never asks for old private scalars or old session credentials.
    func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
    func legacyDeviceID(owner: String) -> Int? { nil }
}

private struct CredentialsOMEMO2StatePersistence: OMEMO2StatePersistence {
    func load(owner: String) throws -> Data? { try CredentialsManager.shared.getOMEMO2State(for: owner) }
    func save(_ data: Data, owner: String) throws { try CredentialsManager.shared.setOMEMO2State(data, for: owner) }
    func remove(owner: String) throws { try CredentialsManager.shared.removeOMEMO2State(for: owner) }
    func nativePreparationExists(owner: String) throws -> Bool {
        let realm = try WRealm.safe()
        return !realm.objects(SignalIdentityStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND cryptoBackend == %@", owner, owner, XabberOMEMO2Storage.backend).isEmpty
    }
    func retiredOptOutRecords(owner: String) throws -> [String: OMEMO2OptOutRecord]? {
        guard let data = try CredentialsManager.shared.getRetiredOMEMO2StateForPolicyMigration(for: owner) else { return nil }
        return try XabberOMEMO2Storage.decodeRetiredOptOutRecords(data, owner: owner)
    }
}

/// OMEMO2 secrets and sessions never enter legacy Signal credential/record keys.
/// Restoring a fresh session for each transaction makes authentication, payload
/// validation and storage failure leave the persisted ratchet unchanged.
final class XabberOMEMO2Storage {
    static let profile = "urn:xmpp:omemo:2"
    static let stateVersion = 2
    static let backend = "XabberCryptoSwift"
    static let identityRepresentation = IdentityPrivateKeyRepresentation.ed25519Seed
    static let signedPreKeyRotationInterval: TimeInterval = 7 * 24 * 60 * 60
    static let maximumSessionsPerPeer = 64
    static let maximumAuthenticatedReceiveFingerprints = 4096
    private static var ownerLocks: [String: NSRecursiveLock] = [:]
    private static let locksLock = NSLock()

    private struct PreKey: Codable {
        let id: UInt32
        let privateKey: Data
        var consumed: Bool
    }

    private struct StoredSession: Codable {
        let address: OMEMO2PeerAddress
        var ephemeralKey: Data
        var snapshot: Data
        var receiveOnly: Bool
        let createdAt: Date
        var seenIncomingRatchets: [Data]
        // Additive public metadata; existing snapshots decode without it.
        var outgoingPreKey: Data? = nil
    }

    private struct SessionReplacement: Codable {
        let address: OMEMO2PeerAddress
        let generation: UUID
        var allowedBundleDigests: [Data]?
    }

    private struct RetiredSignedPreKey: Codable {
        let id: UInt32
        let privateKey: Data
        let retiredAt: Date
    }

    /// Sync authenticates previews before normal history persistence. Keep the
    /// packet-opening material in the same protected transaction as its ratchet
    /// so a later MAM ingress can materialize that exact logical message.
    private struct PendingSyncReceive: Codable {
        let fingerprint: Data
        let address: OMEMO2PeerAddress
        let messageIdentityDigest: Data
        let keyAndMAC: Data
        let identity: Data
    }

    private struct State: Codable {
        var version: Int
        var profile: String
        let backend: String
        let identityRepresentation: String
        let owner: String
        let deviceID: Int
        let identityPrivateKey: Data
        let fingerprintPublicKey: Data
        var signedPreKeyPrivateKey: Data
        var signedPreKeyID: UInt32
        var signature: Data
        var signedPreKeyCreatedAt: Date
        var retiredSignedPreKeys: [RetiredSignedPreKey]
        var nextPreKeyID: UInt32
        var preKeys: [PreKey]
        var sessions: [String: StoredSession]
        var currentSessions: [String: String]
        var controlsNeeded: Set<OMEMO2PeerAddress>
        // Optional for additive decoding within the native protected aggregate.
        var authenticatedReceiveFingerprints: [Data]? = nil
        var pendingSyncReceives: [PendingSyncReceive]? = nil
        var sessionReplacements: [String: SessionReplacement]? = nil
        // Realm only mirrors these protected decisions.
        var optOutDecisions: [String: OMEMO2OptOutRecord]? = nil
    }

    /// The retired backend is decoded only through this domain-only view.
    /// Neither private representation nor snapshot/key fields are inspected.
    private struct RetiredPolicy: Decodable {
        let version: Int
        let profile: String
        let owner: String
        let optOutDecisions: [String: OMEMO2OptOutRecord]?
    }

    /// Invoked only after a successful receive transaction released the owner lock.
    private var receiveCommitCallback: (() -> Void)?
    var authenticatedReceiveDidCommit: (() -> Void)? {
        get { synchronized { receiveCommitCallback } }
        set { synchronized { receiveCommitCallback = newValue } }
    }

    let owner: String
    private let context: OMEMO2Context
    private let persistence: OMEMO2StatePersistence
    private let lock: NSRecursiveLock
    private let now: () -> Date

    init(owner: String, persistence: OMEMO2StatePersistence? = nil, now: @escaping () -> Date = Date.init) throws {
        self.owner = owner
        self.persistence = persistence ?? CredentialsOMEMO2StatePersistence()
        self.now = now
        context = try OMEMO2Context(error: ())
        Self.locksLock.lock()
        if let existing = Self.ownerLocks[owner] {
            lock = existing
        } else {
            let created = NSRecursiveLock()
            Self.ownerLocks[owner] = created
            lock = created
        }
        Self.locksLock.unlock()
    }

    @discardableResult
    func prepare(deviceID: Int, preKeyCount: Int = 100) throws -> OMEMO2LocalBundle {
        try synchronized {
            guard deviceID > 0, deviceID <= Int(Int32.max), (1...1000).contains(preKeyCount) else {
                throw OMEMO2StorageError.invalidDeviceID
            }
            if var state = try loadState() {
                guard state.deviceID == deviceID else { throw OMEMO2StorageError.invalidDeviceID }
                if try rotateSignedPreKeyIfDue(&state) { try save(state) }
                return try bundle(state)
            }
            // Private scalars and provider snapshots from the retired backend
            // are deliberately not imported. The separate protected item owns
            // a fresh explicitly typed Ed25519 seed from this point onward.
            let preservedDecisions = try retiredOptOutRecords()
            let identity = try context.generateIdentity(representation: Self.identityRepresentation)
            let signedPreKey = try context.generateKeyPair()
            let signature = try context.sign(signedPreKey.publicKey, identity: identity)
            var state = State(version: Self.stateVersion, profile: Self.profile,
                              backend: Self.backend, identityRepresentation: Self.identityRepresentation.rawValue, owner: owner,
                              deviceID: deviceID, identityPrivateKey: identity.privateKey,
                              fingerprintPublicKey: identity.fingerprintPublicKey,
                              signedPreKeyPrivateKey: signedPreKey.privateKey, signedPreKeyID: 1,
                              signature: signature, signedPreKeyCreatedAt: now(), retiredSignedPreKeys: [],
                              nextPreKeyID: 1, preKeys: [], sessions: [:],
                              currentSessions: [:], controlsNeeded: [])
            state.optOutDecisions = preservedDecisions
            try addPreKeys(to: &state, count: preKeyCount)
            let result = try bundle(state)
            try save(state)
            return result
        }
    }

    func localBundle() throws -> OMEMO2LocalBundle {
        try synchronized { try bundle(requireState()) }
    }

    /// Activity can maintain an already registered profile without creating a
    /// new identity or session. The rotation and expired grace-key removal are
    /// committed together; a failed save leaves the old aggregate authoritative.
    @discardableResult
    func maintainKeysIfDue() throws -> Bool {
        try synchronized {
            var state = try requireState()
            guard try rotateSignedPreKeyIfDue(&state) else { return false }
            try save(state)
            return true
        }
    }

    func identity() throws -> OMEMO2IdentityKeyPair {
        try synchronized { try context.identity(withPrivateKey: requireState().identityPrivateKey,
                                                representation: Self.identityRepresentation) }
    }

    @discardableResult
    func replenishPreKeys(minimumCount: Int = 100) throws -> OMEMO2LocalBundle {
        try synchronized {
            guard (1...1000).contains(minimumCount) else { throw OMEMO2StorageError.invalidKeyID }
            var state = try requireState()
            let needed = minimumCount - state.preKeys.filter { !$0.consumed }.count
            if needed > 0 {
                try addPreKeys(to: &state, count: needed)
                try save(state)
            }
            return try bundle(state)
        }
    }

    /// Always creates an outbound-capable session from a freshly selected peer
    /// bundle; already stored sessions remain available for delayed ciphertexts.
    func initiateSession(jid: String, deviceID: Int, bundle: OMEMO2Bundle, initialControlNeeded: Bool = false) throws {
        try synchronized {
            var state = try requireState()
            try requireOptOutAllowsSend(jid: jid, state: state)
            let address = try checkedAddress(jid: jid, deviceID: deviceID)
            if let replacement = state.sessionReplacements?[addressKey(address)],
               replacement.allowedBundleDigests?.contains(Self.bundleDigest(bundle)) != true {
                throw OMEMO2StorageError.freshBundleRequired
            }
            let identity = try context.identity(withPrivateKey: state.identityPrivateKey, representation: Self.identityRepresentation)
            let session = try context.initiateSession(withIdentity: identity, bundle: bundle, scope: sessionScope(address))
            let key = sessionKey(address, ephemeralKey: session.ephemeralKey)
            state.sessions[key] = StoredSession(address: address, ephemeralKey: session.ephemeralKey,
                                                snapshot: try session.serializedData(), receiveOnly: false,
                                                createdAt: now(), seenIncomingRatchets: [], outgoingPreKey: bundle.preKey)
            state.currentSessions[addressKey(address)] = key
            state.sessionReplacements?.removeValue(forKey: addressKey(address))
            if initialControlNeeded { state.controlsNeeded.insert(address) }
            pruneSessions(&state, address: address)
            try save(state)
        }
    }

    /// The ciphertext is returned only after the advanced ratchet was stored.
    func encrypt(_ data: Data, jid: String, deviceID: Int) throws -> OMEMO2Ciphertext {
        try synchronized {
            var state = try requireState()
            try requireOptOutAllowsSend(jid: jid, state: state)
            let address = try checkedAddress(jid: jid, deviceID: deviceID)
            guard let key = state.currentSessions[addressKey(address)], var stored = state.sessions[key] else {
                throw OMEMO2StorageError.missingSession
            }
            guard !stored.receiveOnly else { throw OMEMO2StorageError.receiveOnlySession }
            let session = try restoreSession(stored, state: state)
            let ciphertext = try session.encryptData(data)
            stored.snapshot = try session.serializedData()
            // Native initiation creates its EK with the first packet. Move the
            // prepared slot atomically to that authenticated exchange identity.
            stored.ephemeralKey = session.ephemeralKey
            let committedKey = sessionKey(address, ephemeralKey: stored.ephemeralKey)
            if committedKey != key { state.sessions.removeValue(forKey: key) }
            state.sessions[committedKey] = stored
            state.currentSessions[addressKey(address)] = committedKey
            state.controlsNeeded.remove(address)
            try save(state)
            return ciphertext
        }
    }

    /// `validating` authenticates the outer payload and SCE envelope before
    /// committing either ratchet state or OPK consumption. Only an active,
    /// outbound-capable KEX updates the current identity projection; delayed
    /// archived and receive-only sessions cannot change current device trust.
    /// `authenticatedIdentity` reports the exact successful candidate after
    /// saving and releasing the owner lock, before receive cleanup can prune it.
    func decrypt(_ ciphertext: OMEMO2Ciphertext, jid: String, deviceID: Int,
                 replayFingerprint: Data? = nil,
                 previouslyAuthenticated: () -> Bool = { false },
                 retainingSyncContent: Bool = false,
                 recoveringSyncContent: Bool = false,
                 materializationIdentity: () -> String? = { nil },
                 updatingIdentity: (Data) throws -> Void = { _ in },
                 recordingOptOut: () throws -> OMEMO2OptOutRequest? = { nil },
                 authenticatedIdentity: (Data) -> Void = { _ in },
                 validating: (Data) throws -> Void = { _ in }) throws -> Data {
        var authenticatedIdentityKey: Data?
        let plaintext = try synchronized {
            var state = try requireState()
            let address = try checkedAddress(jid: jid, deviceID: deviceID)
            if let replayFingerprint {
                guard replayFingerprint.count == 32 else { throw OMEMO2StorageError.invalidState }
                if state.authenticatedReceiveFingerprints?.contains(replayFingerprint) == true {
                    // Durable history and non-archive replay remain consumed.
                    // Recovery never advances/rewinds a ratchet or grants trust.
                    guard recoveringSyncContent, !previouslyAuthenticated(),
                          let pending = state.pendingSyncReceives?.first(where: {
                              $0.fingerprint == replayFingerprint && $0.address == address
                          }) else { throw OMEMO2StorageError.authenticatedDuplicate }
                    try validating(pending.keyAndMAC)
                    guard let messageID = materializationIdentity(),
                          Self.syncMaterializationIdentityDigest(messageID) == pending.messageIdentityDigest else {
                        throw OMEMO2StorageError.authenticatedDuplicate
                    }
                    authenticatedIdentityKey = pending.identity
                    return pending.keyAndMAC
                }
            }
            if ciphertext.isKeyExchange {
                guard let ephemeralKey = ciphertext.ephemeralKey else { throw OMEMO2StorageError.invalidState }
                let key = sessionKey(address, ephemeralKey: ephemeralKey)
                if var stored = state.sessions[key] {
                    let session = try restoreSession(stored, state: state)
                    let plaintext: Data
                    do { plaintext = try session.decryptCiphertext(ciphertext) }
                    catch {
                        if replayFingerprint != nil, previouslyAuthenticated() { throw OMEMO2StorageError.authenticatedDuplicate }
                        throw error
                    }
                    try validating(plaintext)
                    if !stored.receiveOnly, state.currentSessions[addressKey(address)] == key {
                        try updatingIdentity(session.remoteIdentityKey)
                    }
                    stored.snapshot = try session.serializedData()
                    observeIncoming(ciphertext, stored: &stored, state: &state)
                    state.sessions[key] = stored
                    if !stored.receiveOnly, state.currentSessions[addressKey(address)] == key {
                        state.controlsNeeded.insert(address)
                    }
                    try recordOptOut(recordingOptOut(), state: &state)
                    recordAuthenticatedReceive(replayFingerprint, address: address, plaintext: plaintext,
                        identity: session.remoteIdentityKey,
                        messageID: retainingSyncContent ? materializationIdentity() : nil, state: &state)
                    try save(state)
                    authenticatedIdentityKey = session.remoteIdentityKey
                    return plaintext
                }
                guard let preKeyIndex = state.preKeys.firstIndex(where: { $0.id == ciphertext.preKeyID }) else {
                    if replayFingerprint != nil, previouslyAuthenticated() { throw OMEMO2StorageError.authenticatedDuplicate }
                    throw OMEMO2StorageError.missingPreKey
                }
                if state.preKeys[preKeyIndex].consumed, replayFingerprint != nil, previouslyAuthenticated() {
                    throw OMEMO2StorageError.authenticatedDuplicate
                }
                let signedPreKeyPrivate: Data
                if ciphertext.signedPreKeyID == state.signedPreKeyID {
                    signedPreKeyPrivate = state.signedPreKeyPrivateKey
                } else if let old = state.retiredSignedPreKeys.first(where: {
                    $0.id == ciphertext.signedPreKeyID && now().timeIntervalSince($0.retiredAt) < Self.signedPreKeyRotationInterval
                }) {
                    signedPreKeyPrivate = old.privateKey
                } else { throw OMEMO2StorageError.missingPreKey }
                let preKeyRecord = state.preKeys[preKeyIndex]
                let identity = try context.identity(withPrivateKey: state.identityPrivateKey, representation: Self.identityRepresentation)
                let signedPreKey = try context.keyPair(withPrivateKey: signedPreKeyPrivate)
                let preKey = try context.keyPair(withPrivateKey: preKeyRecord.privateKey)
                var output: NSData?
                let session = try context.acceptKeyExchange(ciphertext, identity: identity,
                                                             signedPreKey: signedPreKey, signedPreKeyID: ciphertext.signedPreKeyID,
                                                             preKey: preKey, preKeyID: preKeyRecord.id, plaintext: &output,
                                                             scope: sessionScope(address), preKeyConsumed: preKeyRecord.consumed)
                guard let output else { throw OMEMO2StorageError.invalidState }
                let plaintext = output as Data
                try validating(plaintext)
                if !preKeyRecord.consumed { try updatingIdentity(session.remoteIdentityKey) }
                state.sessions[key] = StoredSession(address: address, ephemeralKey: ephemeralKey,
                                                    snapshot: try session.serializedData(), receiveOnly: preKeyRecord.consumed,
                                                    createdAt: now(), seenIncomingRatchets: [Self.canonicalEphemeralKey(ciphertext.ratchetKey)])
                state.preKeys[preKeyIndex].consumed = true
                if !preKeyRecord.consumed {
                    state.currentSessions[addressKey(address)] = key
                    state.controlsNeeded.insert(address)
                }
                pruneSessions(&state, address: address)
                try recordOptOut(recordingOptOut(), state: &state)
                recordAuthenticatedReceive(replayFingerprint, address: address, plaintext: plaintext,
                    identity: session.remoteIdentityKey,
                    messageID: retainingSyncContent ? materializationIdentity() : nil, state: &state)
                try save(state)
                authenticatedIdentityKey = session.remoteIdentityKey
                return plaintext
            }
            // Regular envelopes do not carry EK. Try authenticated snapshots
            // without committing any candidate until both layers validate.
            let current = state.currentSessions[addressKey(address)]
            let keys = state.sessions.keys.filter { state.sessions[$0]?.address == address }.sorted {
                if $0 == current { return true }
                if $1 == current { return false }
                return (state.sessions[$0]?.createdAt ?? .distantPast) > (state.sessions[$1]?.createdAt ?? .distantPast)
            }
            var lastError: Error = OMEMO2StorageError.missingSession
            for key in keys {
                guard var stored = state.sessions[key] else { continue }
                let session = try restoreSession(stored, state: state)
                let plaintext: Data
                do { plaintext = try session.decryptCiphertext(ciphertext) }
                catch { lastError = error; continue }
                try validating(plaintext)
                stored.snapshot = try session.serializedData()
                observeIncoming(ciphertext, stored: &stored, state: &state)
                state.sessions[key] = stored
                try recordOptOut(recordingOptOut(), state: &state)
                recordAuthenticatedReceive(replayFingerprint, address: address, plaintext: plaintext,
                    identity: session.remoteIdentityKey,
                    messageID: retainingSyncContent ? materializationIdentity() : nil, state: &state)
                try save(state)
                authenticatedIdentityKey = session.remoteIdentityKey
                return plaintext
            }
            if replayFingerprint != nil, previouslyAuthenticated() { throw OMEMO2StorageError.authenticatedDuplicate }
            throw lastError
        }
        if let authenticatedIdentityKey { authenticatedIdentity(authenticatedIdentityKey) }
        authenticatedReceiveDidCommit?()
        return plaintext
    }

    func optOutDecision(jid: String) throws -> OMEMO2OptOutPolicy.Decision {
        try synchronized {
            let peer = try OMEMO2OptOutPolicy.bareJID(jid)
            if let state = try loadState() { return state.optOutDecisions?[peer]?.decision ?? .none }
            return try retiredOptOutRecords()[peer]?.decision ?? .none
        }
    }

    func optOutRecords() throws -> [OMEMO2OptOutRecord] {
        try synchronized {
            if let state = try loadState() { return Array((state.optOutDecisions ?? [:]).values) }
            return Array(try retiredOptOutRecords().values)
        }
    }

    func resolveOptOut(jid: String, decision: OMEMO2OptOutPolicy.Decision, at date: Date) throws {
        try synchronized {
            let peer = try OMEMO2OptOutPolicy.bareJID(jid)
            guard decision == .plaintext || decision == .omemo, date.timeIntervalSince1970.isFinite else {
                throw OMEMO2StorageError.invalidState
            }
            var state = try requireState()
            guard var record = state.optOutDecisions?[peer] else { throw OMEMO2StorageError.invalidState }
            record.decision = decision
            record.resolvedWatermark = [date, record.protectedRequestDate, record.resolvedWatermark].compactMap { $0 }.max()
            record.updatedAt = date
            state.optOutDecisions?[peer] = record
            try save(state)
        }
    }

    private func requireOptOutAllowsSend(jid: String, state: State) throws {
        let peer = try OMEMO2OptOutPolicy.bareJID(jid)
        if peer != owner, state.optOutDecisions?[peer]?.decision == .pending {
            throw OMEMO2StorageError.pendingOptOut
        }
    }

    /// Called only after crypto, SCE and existing identity checks succeeded.
    /// This changes the same local aggregate as the ratchet, before one save.
    private func recordOptOut(_ request: OMEMO2OptOutRequest?, state: inout State) throws {
        guard let request else { return }
        let peer = try OMEMO2OptOutPolicy.bareJID(request.jid)
        guard peer != owner, peer == request.jid, request.fingerprint.count == 32,
              request.protectedDate?.timeIntervalSince1970.isFinite != false else {
            throw OMEMO2StorageError.invalidState
        }
        let old = state.optOutDecisions?[peer]
        if old?.requestFingerprint == request.fingerprint { return }
        if let watermark = old?.resolvedWatermark {
            if let date = request.protectedDate, date <= watermark { return }
            if request.protectedDate == nil, request.historical { return }
        }
        if old?.decision == .pending, let previous = old?.protectedRequestDate,
           let date = request.protectedDate, date <= previous { return }
        var decisions = state.optOutDecisions ?? [:]
        decisions[peer] = OMEMO2OptOutRecord(jid: peer, decision: .pending,
            requestFingerprint: request.fingerprint, protectedRequestDate: request.protectedDate,
            reason: request.reason, resolvedWatermark: old?.resolvedWatermark, updatedAt: now())
        state.optOutDecisions = decisions
    }

    func sessionExists(jid: String, deviceID: Int) throws -> Bool {
        try sessionMetadata(jid: jid, deviceID: deviceID) != nil
    }

    func sessionMetadata(jid: String, deviceID: Int, ephemeralKey: Data? = nil) throws -> OMEMO2SessionMetadata? {
        try synchronized {
            let state = try requireState()
            let address = try checkedAddress(jid: jid, deviceID: deviceID)
            let key = ephemeralKey.map { sessionKey(address, ephemeralKey: $0) } ?? state.currentSessions[addressKey(address)]
            guard let key, let stored = state.sessions[key] else { return nil }
            let session = try restoreSession(stored, state: state)
            return OMEMO2SessionMetadata(remoteIdentityKey: session.remoteIdentityKey, ephemeralKey: session.ephemeralKey,
                                         sendCounter: session.sendCounter, receiveCounter: session.receiveCounter,
                                         receiveOnly: stored.receiveOnly, keyExchangePending: session.isKeyExchangePending)
        }
    }

    /// Explicit user action invalidates outgoing capability in one protected
    /// transaction. Delayed authenticated ciphertext can still use old snapshots.
    func replaceOutgoingSessions() throws {
        try synchronized {
            var state = try requireState()
            let addresses = Set(state.sessions.values.map(\.address))
                .union((state.sessionReplacements ?? [:]).values.map(\.address))
            guard !addresses.isEmpty else { return }
            let generation = UUID()
            var replacements = state.sessionReplacements ?? [:]
            for address in addresses {
                replacements[addressKey(address)] = SessionReplacement(address: address, generation: generation, allowedBundleDigests: nil)
            }
            for key in Array(state.sessions.keys) { state.sessions[key]?.receiveOnly = true }
            state.currentSessions.removeAll()
            state.controlsNeeded.removeAll()
            state.sessionReplacements = replacements
            try save(state)
        }
    }

    func sessionReplacementGeneration(jid: String, deviceID: Int) throws -> UUID? {
        try synchronized {
            let state = try requireState()
            let address = try checkedAddress(jid: jid, deviceID: deviceID)
            return state.sessionReplacements?[addressKey(address)]?.generation
        }
    }

    func sessionReplacementNeedsFreshBundle(jid: String, deviceID: Int) throws -> Bool {
        try synchronized {
            let state = try requireState()
            let address = try checkedAddress(jid: jid, deviceID: deviceID)
            return state.sessionReplacements?[addressKey(address)].map { $0.allowedBundleDigests == nil } ?? false
        }
    }

    /// A matching network fetch can authorize only the reset generation that
    /// requested it. Cached/headline XML cannot create this protected evidence.
    @discardableResult
    func authorizeSessionReplacement(jid: String, deviceID: Int, generation: UUID, bundle: OMEMO2PublishedBundle) throws -> Bool {
        try synchronized {
            var state = try requireState()
            let address = try checkedAddress(jid: jid, deviceID: deviceID)
            let key = addressKey(address)
            guard var replacement = state.sessionReplacements?[key], replacement.generation == generation else { return false }
            guard bundle.deviceID == address.deviceID else { throw OMEMO2StorageError.invalidDeviceID }
            replacement.allowedBundleDigests = try bundle.preKeys.map { Self.bundleDigest(try bundle.selectedBundle(preKeyID: $0.id)) }
            state.sessionReplacements?[key] = replacement
            try save(state)
            return true
        }
    }

    /// Absence of a current outgoing pointer is not absence of a session:
    /// archived and receive-only snapshots also prohibit automatic recovery.
    func canRecoverMissingSession(jid: String, deviceID: Int) throws -> Bool {
        try synchronized {
            let state = try requireState()
            let address = try checkedAddress(jid: jid, deviceID: deviceID)
            return state.sessionReplacements?[addressKey(address)] == nil && !state.sessions.values.contains { $0.address == address }
        }
    }

    private static func bundleDigest(_ bundle: OMEMO2Bundle) -> Data {
        var material = bundle.identityKey + bundle.signedPreKey + bundle.signature + bundle.preKey
        for id in [bundle.signedPreKeyID, bundle.preKeyID] {
            var bigEndian = id.bigEndian
            withUnsafeBytes(of: &bigEndian) { material.append(contentsOf: $0) }
        }
        return Data(SHA256.hash(data: material))
    }

    /// One protected read and at most one provider restore per old snapshot.
    /// Candidate selection never advances an archived ratchet to inspect its KEX.
    func availableOutgoingPreKeys(bundle: OMEMO2PublishedBundle, jid: String, deviceID: Int) throws -> [OMEMO2PublicPreKey] {
        try synchronized {
            let state = try requireState()
            let address = try checkedAddress(jid: jid, deviceID: deviceID)
            guard bundle.deviceID == deviceID else { throw OMEMO2StorageError.invalidDeviceID }
            let peerIdentity = try Omemo2IdentityRepresentation.rawX25519(identityKey: bundle.identityKey)
            var usedPublicKeys = Set<Data>()
            var migratedUsedIDs = Set<UInt32>()
            for stored in state.sessions.values where stored.address == address {
                if let known = stored.outgoingPreKey {
                    usedPublicKeys.insert(known)
                } else {
                    // Old aggregates lack public OPK metadata. Alice's remote
                    // OPK ID survives ACK/restore; Bob returns zero. Match the
                    // actual peer identity using its existing canonical curve
                    // representation.
                    do {
                        let session = try restoreSession(stored, state: state)
                        if session.remotePreKeyID > 0,
                           try Omemo2IdentityRepresentation.rawX25519(identityKey: session.remoteIdentityKey) == peerIdentity {
                            migratedUsedIDs.insert(session.remotePreKeyID)
                        }
                    } catch {
                        // An explicit reset must be able to replace a broken
                        // archived provider snapshot. The blob remains stored;
                        // initiation still enforces the correlated fresh-bundle
                        // digest. Aggregate/current failures remain fatal.
                        guard stored.receiveOnly,
                              state.sessionReplacements?[addressKey(address)]?.allowedBundleDigests != nil else { throw error }
                    }
                }
            }
            return bundle.preKeys.filter { !usedPublicKeys.contains($0.publicKey) && !migratedUsedIDs.contains($0.id) }
        }
    }

    /// Identity changes still revoke outgoing capability. During an explicit
    /// replacement, retained old snapshots stay receive-only for delayed history.
    func deleteSessions(jid: String, deviceID: Int? = nil) throws {
        try synchronized {
            var state = try requireState()
            let addresses = Set(state.sessions.values.filter {
                $0.address.jid == jid && (deviceID == nil || $0.address.deviceID == deviceID)
            }.map(\.address))
            let preserved = Set(addresses.filter { state.sessionReplacements?[addressKey($0)] != nil })
            state.sessions = state.sessions.filter { !addresses.contains($0.value.address) || preserved.contains($0.value.address) }
            for key in Array(state.sessions.keys) where preserved.contains(state.sessions[key]!.address) {
                state.sessions[key]?.receiveOnly = true
            }
            for address in addresses { state.currentSessions.removeValue(forKey: addressKey(address)) }
            state.controlsNeeded.subtract(addresses)
            try save(state)
        }
    }

    func pendingControlAddresses() throws -> [OMEMO2PeerAddress] {
        try synchronized { Array(try requireState().controlsNeeded) }
    }

    func markControlNeeded(jid: String, deviceID: Int, needed: Bool) throws {
        try synchronized {
            var state = try requireState()
            let address = try checkedAddress(jid: jid, deviceID: deviceID)
            if needed { state.controlsNeeded.insert(address) }
            else { state.controlsNeeded.remove(address) }
            try save(state)
        }
    }

    func removeAllState() throws { try synchronized { try persistence.remove(owner: owner) } }

    func consumedPreKeyIDs() throws -> Set<UInt32> {
        try synchronized { Set(try requireState().preKeys.filter(\.consumed).map(\.id)) }
    }

    /// A caller supplies eligibility, but storage still enforces consumed-only
    /// deletion. Known-EK snapshots and pending empty replies remain untouched.
    func removeConsumedPreKeys(ids: Set<UInt32>) throws {
        try synchronized {
            var state = try requireState()
            let oldCount = state.preKeys.count
            state.preKeys.removeAll { $0.consumed && ids.contains($0.id) }
            guard state.preKeys.count != oldCount else { return }
            try save(state)
        }
    }

    /// Invoke only after archive catch-up completed. Session snapshots keep
    /// delayed packets with an already known EK decryptable without OPK reuse.
    func finishCatchUp() throws {
        try synchronized {
            var state = try requireState()
            guard state.preKeys.contains(where: \.consumed) else { return }
            state.preKeys.removeAll(where: \.consumed)
            try save(state)
        }
    }

    private func rotateSignedPreKeyIfDue(_ state: inout State) throws -> Bool {
        let time = now()
        let oldCount = state.retiredSignedPreKeys.count
        state.retiredSignedPreKeys.removeAll { time.timeIntervalSince($0.retiredAt) >= Self.signedPreKeyRotationInterval }
        guard time.timeIntervalSince(state.signedPreKeyCreatedAt) >= Self.signedPreKeyRotationInterval else {
            return oldCount != state.retiredSignedPreKeys.count
        }
        guard state.signedPreKeyID < UInt32(Int32.max) else { throw OMEMO2StorageError.invalidKeyID }
        let identity = try context.identity(withPrivateKey: state.identityPrivateKey, representation: Self.identityRepresentation)
        let new = try context.generateKeyPair()
        state.retiredSignedPreKeys.append(RetiredSignedPreKey(id: state.signedPreKeyID,
                                                            privateKey: state.signedPreKeyPrivateKey, retiredAt: time))
        state.signedPreKeyPrivateKey = new.privateKey
        state.signedPreKeyID += 1
        state.signature = try context.sign(new.publicKey, identity: identity)
        state.signedPreKeyCreatedAt = time
        return true
    }

    private func recordAuthenticatedReceive(_ fingerprint: Data?, address: OMEMO2PeerAddress, plaintext: Data,
                                            identity: Data, messageID: String?, state: inout State) {
        guard let fingerprint else { return }
        var fingerprints = state.authenticatedReceiveFingerprints ?? []
        fingerprints.append(fingerprint)
        if fingerprints.count > Self.maximumAuthenticatedReceiveFingerprints {
            fingerprints.removeFirst(fingerprints.count - Self.maximumAuthenticatedReceiveFingerprints)
        }
        state.authenticatedReceiveFingerprints = fingerprints
        let retained = Set(fingerprints)
        var pending = (state.pendingSyncReceives ?? []).filter { retained.contains($0.fingerprint) }
        if let messageID, !messageID.isEmpty, plaintext.count == 48 {
            pending.append(PendingSyncReceive(fingerprint: fingerprint,
                address: address, messageIdentityDigest: Self.syncMaterializationIdentityDigest(messageID),
                keyAndMAC: plaintext, identity: identity))
        }
        state.pendingSyncReceives = pending
    }

    private func observeIncoming(_ ciphertext: OMEMO2Ciphertext, stored: inout StoredSession, state: inout State) {
        let ratchetKey = Self.canonicalEphemeralKey(ciphertext.ratchetKey)
        guard !stored.seenIncomingRatchets.contains(ratchetKey) else { return }
        stored.seenIncomingRatchets.append(ratchetKey)
        if stored.seenIncomingRatchets.count > OMEMO2Session.maximumReceivedRatchets {
            stored.seenIncomingRatchets.removeFirst(stored.seenIncomingRatchets.count - OMEMO2Session.maximumReceivedRatchets)
        }
        if ciphertext.counter >= 53, !stored.receiveOnly,
           state.currentSessions[addressKey(stored.address)] == sessionKey(stored.address, ephemeralKey: stored.ephemeralKey) {
            state.controlsNeeded.insert(stored.address)
        }
    }

    private func pruneSessions(_ state: inout State, address: OMEMO2PeerAddress) {
        let current = state.currentSessions[addressKey(address)]
        let obsolete = state.sessions.keys.filter { state.sessions[$0]?.address == address && $0 != current }.sorted {
            (state.sessions[$0]?.createdAt ?? .distantPast) < (state.sessions[$1]?.createdAt ?? .distantPast)
        }
        let count = state.sessions.values.filter { $0.address == address }.count
        if count > Self.maximumSessionsPerPeer {
            for key in obsolete.prefix(count - Self.maximumSessionsPerPeer) { state.sessions.removeValue(forKey: key) }
        }
    }

    private func bundle(_ state: State) throws -> OMEMO2LocalBundle {
        let identity = try context.identity(withPrivateKey: state.identityPrivateKey, representation: Self.identityRepresentation)
        let signedPreKey = try context.keyPair(withPrivateKey: state.signedPreKeyPrivateKey)
        let preKeys = try state.preKeys.filter { !$0.consumed }.map {
            OMEMO2PublicPreKey(id: $0.id, publicKey: try context.keyPair(withPrivateKey: $0.privateKey).publicKey)
        }
        return OMEMO2LocalBundle(deviceID: state.deviceID, identityKey: identity.publicKey,
                                 fingerprintPublicKey: identity.fingerprintPublicKey, signedPreKey: signedPreKey.publicKey,
                                 signedPreKeyID: state.signedPreKeyID, signature: state.signature, preKeys: preKeys)
    }

    private func addPreKeys(to state: inout State, count: Int) throws {
        for _ in 0..<count {
            guard state.nextPreKeyID > 0, state.nextPreKeyID <= UInt32(Int32.max) else {
                throw OMEMO2StorageError.invalidKeyID
            }
            let key = try context.generateKeyPair()
            state.preKeys.append(PreKey(id: state.nextPreKeyID, privateKey: key.privateKey, consumed: false))
            state.nextPreKeyID += 1
        }
    }

    private func requireState() throws -> State {
        guard let state = try loadState() else { throw OMEMO2StorageError.stateUnavailable }
        return state
    }

    private func retiredOptOutRecords() throws -> [String: OMEMO2OptOutRecord] {
        guard try !persistence.nativePreparationExists(owner: owner) else { throw OMEMO2StorageError.stateUnavailable }
        let records = try persistence.retiredOptOutRecords(owner: owner) ?? [:]
        guard Self.validOptOutRecords(records, owner: owner) else { throw OMEMO2StorageError.invalidState }
        return records
    }

    static func decodeRetiredOptOutRecords(_ data: Data, owner: String) throws -> [String: OMEMO2OptOutRecord] {
        let policy: RetiredPolicy
        do { policy = try PropertyListDecoder().decode(RetiredPolicy.self, from: data) }
        catch { throw OMEMO2StorageError.invalidState }
        let records = policy.optOutDecisions ?? [:]
        guard policy.version == 1, policy.profile == Self.profile, policy.owner == owner,
              validOptOutRecords(records, owner: owner) else { throw OMEMO2StorageError.invalidState }
        return records
    }

    private static func validOptOutRecords(_ records: [String: OMEMO2OptOutRecord], owner: String) -> Bool {
        records.allSatisfy { key, value in
            key == value.jid && key != owner && (try? OMEMO2OptOutPolicy.bareJID(key)) == key
                && value.decision != .none && value.requestFingerprint.count == 32
                && value.protectedRequestDate?.timeIntervalSince1970.isFinite != false
                && value.resolvedWatermark?.timeIntervalSince1970.isFinite != false
                && value.updatedAt.timeIntervalSince1970.isFinite
                && (value.decision == .pending || value.resolvedWatermark != nil)
        }
    }

    private static func syncMaterializationIdentityDigest(_ identifier: String) -> Data {
        let bytes = Data(identifier.utf8)
        var framed = Data("Xabber OMEMO2 sync materialization identity v1".utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(bytes)
        return Data(SHA256.hash(data: framed))
    }

    private static func validPendingSyncReceives(_ pending: [PendingSyncReceive], fingerprints: Set<Data>) -> Bool {
        guard pending.count <= maximumAuthenticatedReceiveFingerprints,
              Set(pending.map(\.fingerprint)).count == pending.count else { return false }
        return pending.allSatisfy {
            $0.fingerprint.count == 32 && fingerprints.contains($0.fingerprint)
                && $0.messageIdentityDigest.count == 32 && $0.keyAndMAC.count == 48
                && $0.address.deviceID > 0 && $0.address.deviceID <= Int(Int32.max)
                && (try? OMEMO2OptOutPolicy.bareJID($0.address.jid)) == $0.address.jid
                && (try? Omemo2IdentityRepresentation.rawX25519(identityKey: $0.identity)) != nil
        }
    }

    private func loadState() throws -> State? {
        guard let data = try persistence.load(owner: owner) else { return nil }
        let state: State
        do { state = try PropertyListDecoder().decode(State.self, from: data) }
        catch { throw OMEMO2StorageError.invalidState }
        guard state.version == Self.stateVersion, state.profile == Self.profile, state.owner == owner,
              state.backend == Self.backend, state.identityRepresentation == Self.identityRepresentation.rawValue,
              state.deviceID > 0, state.deviceID <= Int(Int32.max), state.identityPrivateKey.count == 32,
              state.fingerprintPublicKey.count == 32, state.signedPreKeyPrivateKey.count == 32,
              state.signedPreKeyID > 0, state.signedPreKeyID <= UInt32(Int32.max), state.signature.count == 64,
              state.signedPreKeyCreatedAt.timeIntervalSince1970.isFinite,
              state.nextPreKeyID > (state.preKeys.map(\.id).max() ?? 0), state.nextPreKeyID <= UInt32(Int32.max) + 1,
              Set(state.preKeys.map(\.id)).count == state.preKeys.count,
              state.preKeys.allSatisfy({ $0.id > 0 && $0.id <= UInt32(Int32.max) && $0.privateKey.count == 32 }),
              state.retiredSignedPreKeys.allSatisfy({
                  $0.id > 0 && $0.id < state.signedPreKeyID && $0.privateKey.count == 32
                      && $0.retiredAt.timeIntervalSince1970.isFinite
              }),
              state.sessions.allSatisfy({ key, value in
                  value.createdAt.timeIntervalSince1970.isFinite
                      && value.ephemeralKey.count == 32 && value.seenIncomingRatchets.count <= OMEMO2Session.maximumReceivedRatchets
                      && value.seenIncomingRatchets.allSatisfy { $0.count == 32 }
                      && (value.outgoingPreKey == nil || value.outgoingPreKey?.count == 32)
                      && value.address.deviceID > 0 && value.address.deviceID <= Int(Int32.max)
                      && !value.address.jid.isEmpty && sessionKey(value.address, ephemeralKey: value.ephemeralKey) == key
              }),
              state.controlsNeeded.allSatisfy({ address in
                  !address.jid.isEmpty && address.deviceID > 0 && address.deviceID <= Int(Int32.max)
              }),
              (state.authenticatedReceiveFingerprints ?? []).count <= Self.maximumAuthenticatedReceiveFingerprints,
              (state.authenticatedReceiveFingerprints ?? []).allSatisfy({ $0.count == 32 }),
              Set(state.authenticatedReceiveFingerprints ?? []).count == (state.authenticatedReceiveFingerprints ?? []).count,
              Self.validPendingSyncReceives(state.pendingSyncReceives ?? [],
                  fingerprints: Set(state.authenticatedReceiveFingerprints ?? [])),
              (state.sessionReplacements ?? [:]).allSatisfy({ key, value in
                  key == addressKey(value.address) && !value.address.jid.isEmpty
                      && value.address.deviceID > 0 && value.address.deviceID <= Int(Int32.max)
                      && (value.allowedBundleDigests == nil || (!(value.allowedBundleDigests ?? []).isEmpty
                          && (value.allowedBundleDigests ?? []).count <= OMEMO2BundleCodec.maximumPreKeyCount
                          && (value.allowedBundleDigests ?? []).allSatisfy { $0.count == 32 }))
              }),
              Self.validOptOutRecords(state.optOutDecisions ?? [:], owner: owner),
              state.currentSessions.allSatisfy({ address, session in
                  state.sessions[session].map { addressKey($0.address) == address && !$0.receiveOnly } ?? false
              }) else {
            throw OMEMO2StorageError.invalidState
        }
        let identity = try context.identity(withPrivateKey: state.identityPrivateKey, representation: Self.identityRepresentation)
        guard identity.fingerprintPublicKey == state.fingerprintPublicKey else { throw OMEMO2StorageError.identityMismatch }
        let signedPreKey = try context.keyPair(withPrivateKey: state.signedPreKeyPrivateKey)
        try OMEMO2Context.verifySignature(state.signature, data: signedPreKey.publicKey, identityKey: identity.publicKey)
        return state
    }

    private func save(_ state: State) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try persistence.save(try encoder.encode(state), owner: owner)
    }

    private func checkedAddress(jid: String, deviceID: Int) throws -> OMEMO2PeerAddress {
        guard !jid.isEmpty, deviceID > 0, deviceID <= Int(Int32.max) else { throw OMEMO2StorageError.invalidDeviceID }
        return OMEMO2PeerAddress(jid: jid, deviceID: deviceID)
    }

    private func restoreSession(_ stored: StoredSession, state: State) throws -> OMEMO2Session {
        let identity = try context.identity(withPrivateKey: state.identityPrivateKey,
                                            representation: Self.identityRepresentation)
        let session = try context.restoreSession(with: stored.snapshot, scope: sessionScope(stored.address),
                                                 localIdentity: identity.publicKey)
        guard session.ephemeralKey == stored.ephemeralKey else { throw OMEMO2StorageError.invalidState }
        return session
    }

    private func sessionScope(_ address: OMEMO2PeerAddress) -> Data {
        // The crypto snapshot is bound to one exact protected owner/peer slot.
        // Length framing also prevents delimiter-bearing JIDs from aliasing.
        let framed = Data("\(Self.profile):\(owner.utf8.count):\(owner):\(addressKey(address))".utf8)
        // Legal long JIDs may exceed the native facade's 1024-byte scope bound.
        // A fixed digest preserves this exact tuple's binding at any JID length.
        return Data(SHA256.hash(data: framed))
    }

    private func addressKey(_ address: OMEMO2PeerAddress) -> String {
        // Length framing avoids JID/device delimiter collisions.
        "\(address.jid.utf8.count):\(address.jid):\(address.deviceID)"
    }

    private func sessionKey(_ address: OMEMO2PeerAddress, ephemeralKey: Data) -> String {
        addressKey(address) + ":" + Self.canonicalEphemeralKey(ephemeralKey).base64EncodedString()
    }

    /// RFC7748 §5: bit255 is ignored and u is reduced modulo 2^255-19.
    /// Only slot equality uses this projection. The received KEX and native
    /// snapshot retain their exact wire bytes for crypto/header validation.
    static func canonicalEphemeralKey(_ key: Data) -> Data {
        OMEMO2PublicKeyRepresentation.canonicalX25519(key)
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
