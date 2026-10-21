//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import RealmSwift
import XMPPFramework

enum OmemoManagerError: Error, Equatable {
    case bundleNotFound
    case preKeyNotFound
    case encryptionFailed
    case invalidEncryptedPayload
    case invalidDecryptedPayload
    case missingRecipientKey
    case noTrustedRecipientDevices
    case sessionCreationFailed
    case payloadAuthenticationFailed
}

extension OmemoManagerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .bundleNotFound: return L10n.text("omemo__localized_error_description__omemo_bundle_not_found", fallback: "OMEMO bundle not found")
        case .preKeyNotFound: return L10n.text("omemo__localized_error_description__omemo_pre_key_not_found", fallback: "OMEMO pre-key not found")
        case .encryptionFailed: return L10n.text("omemo__localized_error_description__omemo_encryption_failed", fallback: "OMEMO encryption failed")
        case .invalidEncryptedPayload: return L10n.text("omemo__localized_error_description__invalid_omemo_encrypted_payload", fallback: "Invalid OMEMO encrypted payload")
        case .invalidDecryptedPayload: return L10n.text("omemo__localized_error_description__invalid_omemo_decrypted_payload", fallback: "Invalid OMEMO decrypted payload")
        case .missingRecipientKey: return L10n.text("omemo__localized_error_description__omemo_recipient_key_not_found", fallback: "OMEMO recipient key not found")
        case .noTrustedRecipientDevices: return L10n.text("omemo__localized_error_description__no_trusted_omemo_recipient_devices", fallback: "No trusted OMEMO recipient devices")
        case .sessionCreationFailed: return L10n.text("omemo__localized_error_description__omemo_session_creation_failed", fallback: "OMEMO session creation failed")
        case .payloadAuthenticationFailed: return L10n.text("omemo__localized_error_description__omemo_payload_authentication_failed", fallback: "OMEMO payload authentication failed")
        }
    }
}

struct OmemoSendAvailabilityPolicy {
    enum Availability: Equatable {
        case canSend
        case canSendWithUntrustedContactDeviceWarning
        case blockedByOwnUntrustedDevices
        case blockedByNoTrustedContactDevices
        case blockedByPendingOptOut

        var canSend: Bool {
            switch self {
            case .canSend, .canSendWithUntrustedContactDeviceWarning:
                return true
            case .blockedByOwnUntrustedDevices, .blockedByNoTrustedContactDevices, .blockedByPendingOptOut:
                return false
            }
        }

        var requiresUntrustedContactDeviceWarning: Bool {
            return self == .canSendWithUntrustedContactDeviceWarning
        }
    }

    static func evaluate(
        conversationType: ClientSynchronizationManager.ConversationType,
        ownDeviceStates: [SignalDeviceStorageItem.TrustState],
        contactDeviceStates: [SignalDeviceStorageItem.TrustState]
    ) -> Availability {
        guard conversationType.isEncrypted else { return .canSend }

        if ownDeviceStates.contains(where: { $0 != .trusted }) {
            return .blockedByOwnUntrustedDevices
        }

        let trustedContactDeviceCount = contactDeviceStates.filter { $0 == .trusted }.count
        guard trustedContactDeviceCount > 0 else {
            return .blockedByNoTrustedContactDevices
        }

        if contactDeviceStates.contains(where: { $0 != .trusted }) {
            return .canSendWithUntrustedContactDeviceWarning
        }

        return .canSend
    }

    static func evaluate(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        realm: Realm
    ) -> Availability {
        if OMEMO2OptOutPolicy.projectedDecision(owner: owner, jid: jid, realm: realm) == .pending {
            return .blockedByPendingOptOut
        }
        guard conversationType.isEncrypted else { return .canSend }
        guard OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: owner)?.isKnown == true,
              OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: jid)?.isKnown == true else {
            return .blockedByNoTrustedContactDevices
        }
        let ownDeviceStates = realm
            .objects(SignalDeviceStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND isInDeviceList == true", owner, owner)
            .map { $0.state }
        let contactDeviceStates = realm
            .objects(SignalDeviceStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND isInDeviceList == true", owner, jid)
            .map { $0.state }

        return evaluate(
            conversationType: conversationType,
            ownDeviceStates: Array(ownDeviceStates),
            contactDeviceStates: Array(contactDeviceStates)
        )
    }
}

extension OmemoManager {
    internal static func synchronizeOutgoingEncryptionMetadata(_ message: XMPPMessage) {
        // Conversation/history labels do not identify the provider used on the wire.
        // Only a direct, unambiguous locally prepared OMEMO element selects EME.
        let namespaces: Set<String> = [Self.xmlns, "urn:xmpp:omemo:1", "eu.siacs.conversations.axolotl"]
        let encrypted = (message.children?.compactMap { $0 as? DDXMLElement } ?? []).filter {
            $0.localName == "encrypted" && namespaces.contains($0.uri ?? "")
        }
        guard encrypted.count == 1, let namespace = encrypted.first?.uri else { return }

        SCEReceivePolicy.children(of: message, named: "encryption", xmlns: "urn:xmpp:eme:0")
            .forEach { $0.detach() }
        let metadata = DDXMLElement(name: "encryption", xmlns: "urn:xmpp:eme:0")
        metadata.addAttribute(withName: "namespace", stringValue: namespace)
        message.addChild(metadata)
    }

    internal static let sessionQueue = DispatchQueue(label: "com.xabber.omemo.session.queue")

    /// The protected profile owns the device ID after migration. Missing or
    /// inaccessible state must not silently select a new device identity.
    internal func deviceIDForOMEMO2Preparation(
        legacyDeviceID: (() -> Int?)? = nil,
        freshDeviceID: () -> Int = { Int(arc4random_uniform(UInt32(Int32.max)) + 1) }
    ) throws -> Int {
        guard let storage = omemo2Storage, storage.owner == owner else {
            throw OMEMO2StorageError.stateUnavailable
        }
        do { return try storage.localBundle().deviceID }
        catch OMEMO2StorageError.stateUnavailable {
            let realm = try WRealm.safe()
            guard realm.objects(SignalIdentityStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND cryptoBackend == %@", owner, owner, XabberOMEMO2Storage.backend).isEmpty else {
                throw OMEMO2StorageError.stateUnavailable
            }
        }
        let deviceID = freshDeviceID()
        guard deviceID > 0, deviceID <= Int(Int32.max) else { throw OMEMO2StorageError.invalidDeviceID }
        return deviceID
    }

    @discardableResult
    internal func ensureOMEMO2Prepared(attemptPublication: Bool = true) throws -> XabberOMEMO2Storage {
        let storage = try preparedOMEMO2Storage(forceMaintenance: false)
        if attemptPublication { retryOMEMO2BundlePublication() }
        return storage
    }

    /// Existing authentication, foreground and crypto boundaries share this
    /// operation. Failure leaves protected keys intact and is retried by later
    /// activity; publication failures also have a bounded owner-queue retry.
    internal func performOMEMO2KeyMaintenance(_ stream: XMPPStream? = nil, force: Bool = false) {
        guard isOwnOMEMOEnabled, isOmemoPrepared else { return }
        do {
            _ = try preparedOMEMO2Storage(forceMaintenance: force)
            omemo2PreKeyCleanup.retryEligibleCleanup()
            retryOMEMO2BundlePublication(on: stream)
        } catch {
            DDLogDebug("OMEMO2 key maintenance could not be committed")
            retryOMEMO2BundlePublication(on: stream)
        }
    }

    private func preparedOMEMO2Storage(forceMaintenance: Bool) throws -> XabberOMEMO2Storage {
        omemo2MaintenanceLock.lock()
        defer { omemo2MaintenanceLock.unlock() }
        guard let storage = omemo2Storage, storage.owner == owner else { throw OMEMO2StorageError.stateUnavailable }
        storage.authenticatedReceiveDidCommit = { [weak self] in self?.omemo2PreKeyCleanup.authenticatedReceiveDidCommit() }
        // Fresh preparation follows the verified own-device list collision
        // check in onOwnDeviceListUpdated. Never regenerate at an encrypt call.
        var bundle = try storage.localBundle()
        let time = omemo2MaintenanceNow()
        let elapsed = omemo2LastMaintenanceAt.map { time.timeIntervalSince($0) }
        let checkDue = forceMaintenance || elapsed == nil || elapsed! < 0 || elapsed! >= Self.omemo2MaintenanceCheckInterval
        if checkDue {
            if try storage.maintainKeysIfDue() {
                bundle = try storage.localBundle()
            }
        }
        try localStore.bindExistingDevice(deviceID: bundle.deviceID)
        try bindLocalOMEMO2Metadata(bundle)
        do { try OMEMO2OptOutPolicy.mirror(storage, in: WRealm.safe()) }
        catch { DDLogDebug("OMEMO2 opt-out projection will be retried") }
        if checkDue { omemo2LastMaintenanceAt = time }
        return storage
    }

    /// A public projection can be rebuilt from the protected aggregate. It
    /// cannot create or replace secret identity/prekey material.
    internal func reconcileLocalOMEMO2Metadata() {
        omemo2MaintenanceLock.lock()
        defer { omemo2MaintenanceLock.unlock() }
        guard let storage = omemo2Storage, storage.owner == owner else { return }
        do {
            try bindLocalOMEMO2Metadata(storage.localBundle())
        } catch OMEMO2StorageError.stateUnavailable {
            // Fresh registration has not committed an identity yet.
        } catch {
            DDLogDebug("OMEMO2 own device projection will be retried")
        }
    }

    private func bindLocalOMEMO2Metadata(_ bundle: OMEMO2LocalBundle) throws {
        let realm = try WRealm.safe()
        let primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: owner, deviceId: bundle.deviceID)
        let identity = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary) ?? SignalIdentityStorageItem()
        let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary) ?? SignalDeviceStorageItem()
        let fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey)
        let changed = identity.realm == nil || identity.protocolProfile != Self.xmlns ||
            identity.cryptoBackend != XabberOMEMO2Storage.backend ||
            identity.identityKey != bundle.identityKey.base64EncodedString() ||
            identity.signedPreKey != bundle.signedPreKey.base64EncodedString() ||
            identity.signedPreKeyId != Int(bundle.signedPreKeyID) || device.fingerprint != fingerprint
        let currentUID = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.deviceUuid
        let currentDevice: DeviceStorageItem? = currentUID.flatMap { uid in
            guard !uid.isEmpty else { return nil }
            return realm.object(ofType: DeviceStorageItem.self,
                                forPrimaryKey: DeviceStorageItem.genPrimary(uid: uid, owner: owner))
        }
        let bindingChanged = currentDevice.map { $0.omemoDeviceId != bundle.deviceID } ?? false
        guard changed || bindingChanged else { return }
        try realm.write {
            if bindingChanged { currentDevice?.omemoDeviceId = bundle.deviceID }
            // Repairing a local session association is independent of key
            // publication and cannot manufacture PEP device-list membership.
            guard changed else { return }
            if identity.realm == nil {
                identity.owner = owner; identity.jid = owner; identity.deviceId = bundle.deviceID; identity.primary = primary
            }
            identity.identityKey = bundle.identityKey.base64EncodedString()
            identity.signedPreKey = bundle.signedPreKey.base64EncodedString()
            identity.signedPreKeyId = Int(bundle.signedPreKeyID)
            identity.signedPreKeySignature = bundle.signature.base64EncodedString()
            identity.protocolProfile = Self.xmlns
            identity.cryptoBackend = XabberOMEMO2Storage.backend
            identity.isPublicated = false
            if device.realm == nil {
                device.owner = owner; device.jid = owner; device.deviceId = bundle.deviceID; device.primary = primary
            }
            device.fingerprint = fingerprint; device.state = .trusted; device.isPublicated = false
            realm.add(identity, update: .modified); realm.add(device, update: .modified)
        }
        if changed { shouldPublicate = true }
    }

    func doubleUnratched(_ encrypted: String, jid: String, deviceId: Int, keyExchange: Bool) throws -> Data {
        let data = try Omemo2PayloadCodec.decodeBase64(encrypted)
        let ciphertext = try OMEMO2Ciphertext(data: data, keyExchange: keyExchange)
        return try ensureOMEMO2Prepared().decrypt(ciphertext, jid: jid, deviceID: deviceId)
    }

    func doubleRatchet(hmac: Data, jid: String, deviceId: Int) throws -> DDXMLElement {
        try OmemoManager.sessionQueue.sync {
            try OMEMO2OptOutPolicy.requireAllowedMessage(owner: owner, jid: jid, storage: omemo2Storage)
            let requiresTrustedIdentity = hmac != Data(repeating: 0, count: 32)
            if requiresTrustedIdentity {
                let realm = try WRealm.safe()
                guard OMEMO2DeviceListStorageItem.contains(in: realm, owner: owner, jid: jid, deviceID: deviceId) else {
                    throw OmemoManagerError.noTrustedRecipientDevices
                }
            }
            let storage = try ensureOMEMO2Prepared()
            let generation = try storage.sessionReplacementGeneration(jid: jid, deviceID: deviceId)
            if try storage.sessionReplacementNeedsFreshBundle(jid: jid, deviceID: deviceId) {
                requestFreshOMEMO2Bundle(jid: jid, deviceID: deviceId, generation: generation, isRecovery: false)
                throw OMEMO2StorageError.freshBundleRequired
            }
            let exists = try storage.sessionExists(jid: jid, deviceID: deviceId)
            if generation != nil || !exists {
                try createSession(jid: jid, deviceId: deviceId, storage: storage, requiresTrustedIdentity: requiresTrustedIdentity)
            }
            if requiresTrustedIdentity {
                let realm = try WRealm.safe()
                guard let device = realm.object(ofType: SignalDeviceStorageItem.self,
                    forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceId)),
                      device.state == .trusted else { throw OmemoManagerError.noTrustedRecipientDevices }
                if let metadata = try storage.sessionMetadata(jid: jid, deviceID: deviceId),
                   device.fingerprint != (try Omemo2IdentityRepresentation.fingerprint(for: metadata.remoteIdentityKey)) {
                    try storage.deleteSessions(jid: jid, deviceID: deviceId)
                    try createSession(jid: jid, deviceId: deviceId, storage: storage, requiresTrustedIdentity: true)
                }
                guard let metadata = try storage.sessionMetadata(jid: jid, deviceID: deviceId),
                      device.fingerprint == (try Omemo2IdentityRepresentation.fingerprint(for: metadata.remoteIdentityKey)) else {
                    throw OmemoManagerError.noTrustedRecipientDevices
                }
            }
            let ciphertext = try storage.encrypt(hmac, jid: jid, deviceID: deviceId)
            let key = DDXMLElement(name: "key", xmlns: Self.xmlns)
            key.addAttribute(withName: "rid", integerValue: deviceId)
            if ciphertext.isKeyExchange { key.addAttribute(withName: "kex", stringValue: "true") }
            key.stringValue = ciphertext.data.base64EncodedString()
            return key
        }
    }

    private func createSession(jid: String, deviceId: Int, storage: XabberOMEMO2Storage, requiresTrustedIdentity: Bool) throws {
        let realm = try WRealm.safe()
        guard let identity = realm.object(ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: owner, jid: jid, deviceId: deviceId)) else {
            throw OmemoManagerError.bundleNotFound
        }
        let preKeys = realm.objects(SignalPreKeysStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND deviceId == %@", owner, jid, deviceId).toArray()
        let bundle = try OMEMO2BundleCodec.storedBundle(identity, preKeys: preKeys)
        if requiresTrustedIdentity {
            guard let device = realm.object(ofType: SignalDeviceStorageItem.self,
                forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceId)),
                  device.state == .trusted,
                  device.fingerprint == (try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey)) else {
                throw OmemoManagerError.noTrustedRecipientDevices
            }
        }
        guard let preKey = try storage.availableOutgoingPreKeys(bundle: bundle, jid: jid, deviceID: deviceId).randomElement() else {
            if let generation = try storage.sessionReplacementGeneration(jid: jid, deviceID: deviceId) {
                requestFreshOMEMO2Bundle(jid: jid, deviceID: deviceId, generation: generation, isRecovery: false)
            }
            throw OmemoManagerError.preKeyNotFound
        }
        do {
            try storage.initiateSession(jid: jid, deviceID: deviceId, bundle: bundle.selectedBundle(preKeyID: preKey.id))
        } catch OMEMO2StorageError.freshBundleRequired {
            requestFreshOMEMO2Bundle(jid: jid, deviceID: deviceId,
                                   generation: try storage.sessionReplacementGeneration(jid: jid, deviceID: deviceId), isRecovery: false)
            throw OMEMO2StorageError.freshBundleRequired
        }
    }

    struct PreparedEncryptedMessage {
        let element: DDXMLElement
        let time: Omemo2PayloadCodec.AuthoredTime
    }

    func encryptMessage(message: String, to jid: String) throws -> DDXMLElement? {
        try encryptPreparedMessage(message: message, to: jid).element
    }

    internal func encryptPreparedMessage(message: String, to jid: String) throws -> PreparedEncryptedMessage {
        try OMEMO2OptOutPolicy.requireAllowedMessage(owner: owner, jid: jid, storage: omemo2Storage)
        let storage = try ensureOMEMO2Prepared()
        let localID = try storage.localBundle().deviceID
        let realm = try WRealm.safe()
        guard OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: owner)?.isKnown == true,
              OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: jid)?.isKnown == true else {
            requestMissingDeviceLists(jid: jid)
            throw OmemoManagerError.noTrustedRecipientDevices
        }
        let recipients = realm.objects(SignalDeviceStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND isInDeviceList == true AND state_ == %@", owner, jid, SignalDeviceStorageItem.TrustState.trusted.rawValue)
            .toArray().filter { !(jid == owner && $0.deviceId == localID) }
        guard !recipients.isEmpty else { throw OmemoManagerError.noTrustedRecipientDevices }
        let prepared = try Omemo2PayloadCodec.prepareOutgoingPayload(message)
        let sealed = try Omemo2PayloadCodec.seal(prepared.xml)
        let encrypted = DDXMLElement(name: "encrypted", xmlns: Self.xmlns)
        let header = DDXMLElement(name: "header", xmlns: Self.xmlns)
        header.addAttribute(withName: "sid", integerValue: localID)
        let remote = DDXMLElement(name: "keys", xmlns: Self.xmlns)
        remote.addAttribute(withName: "jid", stringValue: jid)
        for recipient in recipients { remote.addChild(try doubleRatchet(hmac: sealed.keyAndMAC, jid: jid, deviceId: recipient.deviceId)) }
        header.addChild(remote)
        if jid != owner {
            let ownDevices = realm.objects(SignalDeviceStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND isInDeviceList == true AND state_ == %@ AND deviceId != %@", owner, owner,
                        SignalDeviceStorageItem.TrustState.trusted.rawValue, localID).toArray()
            if !ownDevices.isEmpty {
                let own = DDXMLElement(name: "keys", xmlns: Self.xmlns)
                own.addAttribute(withName: "jid", stringValue: owner)
                for device in ownDevices { own.addChild(try doubleRatchet(hmac: sealed.keyAndMAC, jid: owner, deviceId: device.deviceId)) }
                header.addChild(own)
            }
        }
        encrypted.addChild(header)
        let payload = DDXMLElement(name: "payload", xmlns: Self.xmlns)
        payload.stringValue = sealed.ciphertext.base64EncodedString()
        encrypted.addChild(payload)
        return PreparedEncryptedMessage(element: encrypted, time: prepared.time)
    }

    /// Protocol acknowledgements target exactly the sender's device. They never
    /// contain user content and can also confirm an untrusted identity.
    internal func makeOMEMO2Control(jid: String, deviceID: Int) throws -> XMPPMessage {
        try OMEMO2OptOutPolicy.requireAllowedMessage(owner: owner, jid: jid, storage: omemo2Storage)
        let storage = try ensureOMEMO2Prepared()
        guard let metadata = try storage.sessionMetadata(jid: jid, deviceID: deviceID), !metadata.receiveOnly else {
            throw OMEMO2StorageError.receiveOnlySession
        }
        let message = XMPPMessage(type: "chat", to: XMPPJID(string: jid), elementID: UUID().uuidString)
        let encrypted = DDXMLElement(name: "encrypted", xmlns: Self.xmlns)
        let header = DDXMLElement(name: "header", xmlns: Self.xmlns)
        header.addAttribute(withName: "sid", integerValue: try storage.localBundle().deviceID)
        let keys = DDXMLElement(name: "keys", xmlns: Self.xmlns)
        keys.addAttribute(withName: "jid", stringValue: jid)
        keys.addChild(try doubleRatchet(hmac: Data(repeating: 0, count: 32), jid: jid, deviceId: deviceID))
        header.addChild(keys); encrypted.addChild(header); message.addChild(encrypted)
        message.addChild(DDXMLElement(name: "store", xmlns: "urn:xmpp:hints"))
        Self.synchronizeOutgoingEncryptionMetadata(message)
        return message
    }

    internal func flushOMEMO2Controls() {
        guard let storage = omemo2Storage, let pending = try? storage.pendingControlAddresses(), !pending.isEmpty else { return }
        let send: () -> Void = {
            for address in pending {
                do {
                    let control = try self.makeOMEMO2Control(jid: address.jid, deviceID: address.deviceID)
                    self.omemo2ControlSender?(control)
                } catch { DDLogDebug("OMEMO2 control could not be prepared") }
            }
        }
        if omemo2ControlSender != nil { send(); return }
        AccountManager.shared.find(for: owner)?.action { _, stream in
            guard stream.isAuthenticated else { return }
            for address in pending {
                do { stream.send(try self.makeOMEMO2Control(jid: address.jid, deviceID: address.deviceID)) }
                catch { DDLogDebug("OMEMO2 control could not be prepared") }
            }
        }
    }
}

struct OMEMO2FreshBundleRequest {
    let id: String
    let address: OMEMO2PeerAddress
    let replacementGeneration: UUID?
    let isRecovery: Bool
    let startedAt: Date
}

extension OmemoManager {
    /// Global manual replacement leaves identities, trust decisions and stored
    /// history intact. A failed protected write leaves outgoing sessions usable.
    internal func replaceOMEMO2Sessions() throws {
        try Self.sessionQueue.sync {
            guard let storage = omemo2Storage, storage.owner == owner else { throw OMEMO2StorageError.stateUnavailable }
            try storage.replaceOutgoingSessions()
            for request in omemo2FreshBundleRequests.values { queryIds.remove(request.id) }
            omemo2FreshBundleRequests.removeAll()
            omemo2MissingSessionCandidates.removeAll()
        }
    }

    /// Called only after strict non-KEX parsing and a storage missing-session
    /// outcome. The second protected-state check also rejects receive-only and
    /// manually replaced snapshots; decryption errors never reset them.
    internal func recoverMissingOMEMO2Session(jid: String, deviceID: Int) {
        Self.sessionQueue.sync {
            do {
                guard isOwnOMEMOEnabled, let storage = omemo2Storage,
                      try storage.canRecoverMissingSession(jid: jid, deviceID: deviceID) else { return }
                let time = omemo2MaintenanceNow()
                discardExpiredMissingOMEMO2Candidates(at: time)
                let address = OMEMO2PeerAddress(jid: jid, deviceID: deviceID)
                let localID = try storage.localBundle().deviceID
                guard !(jid == owner && deviceID == localID) else { return }
                let realm = try WRealm.safe()
                if OMEMO2DeviceListStorageItem.contains(in: realm, owner: owner, jid: jid, deviceID: deviceID) {
                    omemo2MissingSessionCandidates.removeValue(forKey: address)
                    requestFreshOMEMO2Bundle(jid: jid, deviceID: deviceID, generation: nil, isRecovery: true)
                } else {
                    // The existing unknown-SID refresh precedes this missing
                    // outcome. Wait for its accepted list, including when the
                    // old cached list was known but did not contain this SID.
                    if omemo2MissingSessionCandidates[address] == nil { omemo2MissingSessionCandidates[address] = time }
                    if omemo2MissingSessionCandidates.count > 256,
                       let oldest = omemo2MissingSessionCandidates.min(by: { $0.value < $1.value })?.key {
                        omemo2MissingSessionCandidates.removeValue(forKey: oldest)
                    }
                }
            } catch { DDLogDebug("OMEMO2 missing-session recovery could not be requested") }
        }
    }

    private func discardExpiredMissingOMEMO2Candidates(at date: Date) {
        omemo2MissingSessionCandidates = omemo2MissingSessionCandidates.filter {
            (0..<Self.omemo2PublicationIQTimeout).contains(date.timeIntervalSince($0.value))
        }
    }

    /// A verified PEP list/IQ can resume a strictly parsed missing-session
    /// receive without a second packet. New device announcements alone have no
    /// candidate and never eagerly build a session.
    internal func resumeMissingOMEMO2Sessions(afterDeviceList jid: String) {
        Self.sessionQueue.sync {
            discardExpiredMissingOMEMO2Candidates(at: omemo2MaintenanceNow())
            let candidates = omemo2MissingSessionCandidates.keys.filter { $0.jid == jid }
            for address in candidates {
                omemo2MissingSessionCandidates.removeValue(forKey: address)
                do {
                    guard isOwnOMEMOEnabled, let storage = omemo2Storage,
                          try storage.canRecoverMissingSession(jid: address.jid, deviceID: address.deviceID) else { continue }
                    let realm = try WRealm.safe()
                    guard OMEMO2DeviceListStorageItem.contains(in: realm, owner: owner, jid: address.jid, deviceID: address.deviceID) else { continue }
                    requestFreshOMEMO2Bundle(jid: address.jid, deviceID: address.deviceID, generation: nil, isRecovery: true)
                } catch { DDLogDebug("OMEMO2 missing-session list reconciliation could not be completed") }
            }
        }
    }

    /// Every request is tied to an owner, exact peer/device and reset generation.
    /// A normal cached bundle or PEP headline is never sufficient to lift a reset.
    private func requestFreshOMEMO2Bundle(jid: String, deviceID: Int, generation: UUID?, isRecovery: Bool) {
        let address = OMEMO2PeerAddress(jid: jid, deviceID: deviceID)
        let time = omemo2MaintenanceNow()
        if let existing = omemo2FreshBundleRequests[address],
           existing.replacementGeneration == generation, existing.isRecovery == isRecovery,
           (0..<Self.omemo2PublicationIQTimeout).contains(time.timeIntervalSince(existing.startedAt)) { return }
        if let previous = omemo2FreshBundleRequests[address] { queryIds.remove(previous.id) }
        let id = UUID().uuidString
        omemo2FreshBundleRequests[address] = OMEMO2FreshBundleRequest(
            id: id, address: address, replacementGeneration: generation, isRecovery: isRecovery, startedAt: time)
        queryIds.append(id)
        if let requester = omemo2FreshBundleRequester {
            requester(jid, deviceID, id)
        } else {
            AccountManager.shared.find(for: owner)?.action { [weak self] _, stream in
                guard let self, stream.isAuthenticated, self.freshOMEMO2BundleRequestIsActive(id) else { return }
                self.getContactBundle(stream, jid: jid, deviceId: deviceID, force: true, requestID: id)
            }
        }
    }

    private func freshOMEMO2BundleRequestIsActive(_ id: String) -> Bool {
        Self.sessionQueue.sync { omemo2FreshBundleRequests.values.contains { $0.id == id } }
    }

    /// Matching IQs are handled synchronously before the general cache receiver.
    /// Bundle signature/QNames, exact sender/device and protected generation are
    /// checked before a freshly fetched bundle can permit an outgoing session.
    internal func handleOMEMO2FreshBundleResponse(_ iq: XMPPIQ) -> Bool {
        var flushRecovery = false
        let handled = Self.sessionQueue.sync { () -> Bool in
            guard let id = iq.elementID,
                  let request = omemo2FreshBundleRequests.values.first(where: { $0.id == id }),
                  iq.from?.bare == request.address.jid || (iq.from == nil && request.address.jid == owner),
                  iq.iqType == .result || iq.iqType == .error else { return false }
            defer {
                omemo2FreshBundleRequests.removeValue(forKey: request.address)
                queryIds.remove(id)
            }
            guard iq.iqType == .result,
                  (0..<Self.omemo2PublicationIQTimeout).contains(omemo2MaintenanceNow().timeIntervalSince(request.startedAt)) else { return true }
            do {
                guard let pubsub = SCEReceivePolicy.children(of: iq, named: "pubsub", xmlns: "http://jabber.org/protocol/pubsub").omemo2Single,
                      let items = SCEReceivePolicy.children(of: pubsub, named: "items", xmlns: "http://jabber.org/protocol/pubsub").omemo2Single,
                      items.attributeStringValue(forName: "node") == Self.xmlns + ":bundles",
                      let item = SCEReceivePolicy.children(of: items, named: "item", xmlns: "http://jabber.org/protocol/pubsub").omemo2Single,
                      let storage = omemo2Storage else { return true }
                let bundle = try OMEMO2BundleCodec.decode(item: item)
                guard bundle.deviceID == request.address.deviceID else { return true }
                if let generation = request.replacementGeneration {
                    guard try storage.sessionReplacementGeneration(jid: request.address.jid, deviceID: request.address.deviceID) == generation else { return true }
                    _ = try onContactBundleReceive(items: items, jid: request.address.jid)
                    _ = try storage.authorizeSessionReplacement(jid: request.address.jid, deviceID: request.address.deviceID, generation: generation, bundle: bundle)
                } else if request.isRecovery {
                    guard isOwnOMEMOEnabled,
                          try storage.canRecoverMissingSession(jid: request.address.jid, deviceID: request.address.deviceID) else { return true }
                    let realm = try WRealm.safe()
                    guard OMEMO2DeviceListStorageItem.contains(in: realm, owner: owner, jid: request.address.jid, deviceID: request.address.deviceID) else { return true }
                    _ = try onContactBundleReceive(items: items, jid: request.address.jid)
                    guard let key = try storage.availableOutgoingPreKeys(bundle: bundle, jid: request.address.jid, deviceID: request.address.deviceID).randomElement() else { return true }
                    try storage.initiateSession(jid: request.address.jid, deviceID: request.address.deviceID,
                                                bundle: bundle.selectedBundle(preKeyID: key.id), initialControlNeeded: true)
                    flushRecovery = true
                }
            } catch { DDLogDebug("OMEMO2 fresh bundle could not authorize a session") }
            return true
        }
        if flushRecovery { flushOMEMO2Controls() }
        return handled
    }
}

private extension Array {
    var omemo2Single: Element? { count == 1 ? first : nil }
}
