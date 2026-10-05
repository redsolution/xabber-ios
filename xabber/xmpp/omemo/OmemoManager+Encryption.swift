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
//import SignalClient
import SignalProtocolObjC
import RealmSwift
import CryptoSwift
import XMPPFramework
import CryptoKit

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

        var canSend: Bool {
            switch self {
            case .canSend, .canSendWithUntrustedContactDeviceWarning:
                return true
            case .blockedByOwnUntrustedDevices, .blockedByNoTrustedContactDevices:
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

    private static let sessionQueue = DispatchQueue(label: "com.xabber.omemo.session.queue")

    /// The protected profile owns the device ID after migration. Missing or
    /// inaccessible state must not silently select a new device identity.
    internal func deviceIDForOMEMO2Preparation(
        legacyDeviceID: (() -> Int?)? = nil,
        freshDeviceID: () -> Int = { Int(arc4random_uniform(XabberAxolotlStorage.deviceIdLimit - 1) + 1) }
    ) throws -> Int {
        guard let storage = omemo2Storage, storage.owner == owner else {
            throw OMEMO2StorageError.stateUnavailable
        }
        do { return try storage.localBundle().deviceID }
        catch OMEMO2StorageError.stateUnavailable {
            let realm = try WRealm.safe()
            guard realm.objects(SignalIdentityStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND protocolProfile == %@", owner, owner, Self.xmlns).isEmpty else {
                throw OMEMO2StorageError.stateUnavailable
            }
        }
        let oldID: Int?
        if let legacyDeviceID { oldID = legacyDeviceID() }
        else { oldID = CredentialsManager.shared.getDeviceId(for: owner) }
        let deviceID = oldID ?? freshDeviceID()
        guard deviceID > 0, deviceID <= Int(Int32.max) else { throw OMEMO2StorageError.invalidDeviceID }
        return deviceID
    }

    @discardableResult
    internal func ensureOMEMO2Prepared() throws -> XabberOMEMO2Storage {
        guard let storage = omemo2Storage, storage.owner == owner else { throw OMEMO2StorageError.stateUnavailable }
        let bundle: OMEMO2LocalBundle
        do { bundle = try storage.localBundle() }
        catch OMEMO2StorageError.stateUnavailable {
            let realm = try WRealm.safe()
            guard realm.objects(SignalIdentityStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND protocolProfile == %@", owner, owner, Self.xmlns).isEmpty,
                localStore.hasLocalIdentityKeyPair(), localStore.localDeviceId() > 0 else {
                throw OMEMO2StorageError.stateUnavailable
            }
            bundle = try storage.prepare(deviceID: localStore.localDeviceId())
        }
        try localStore.bindExistingDevice(deviceID: bundle.deviceID)
        try bindLocalOMEMO2Metadata(bundle)
        return storage
    }

    /// A public projection can be rebuilt from the protected aggregate. It
    /// cannot create or replace secret identity/prekey material.
    private func bindLocalOMEMO2Metadata(_ bundle: OMEMO2LocalBundle) throws {
        let realm = try WRealm.safe()
        let primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: owner, deviceId: bundle.deviceID)
        let identity = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary) ?? SignalIdentityStorageItem()
        let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary) ?? SignalDeviceStorageItem()
        let fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey)
        let changed = identity.realm == nil || identity.protocolProfile != Self.xmlns ||
            identity.identityKey != bundle.identityKey.base64EncodedString() ||
            identity.signedPreKey != bundle.signedPreKey.base64EncodedString() ||
            identity.signedPreKeyId != Int(bundle.signedPreKeyID) || device.fingerprint != fingerprint
        guard changed else { return }
        try realm.write {
            if identity.realm == nil {
                identity.owner = owner; identity.jid = owner; identity.deviceId = bundle.deviceID; identity.primary = primary
            }
            identity.identityKey = bundle.identityKey.base64EncodedString()
            identity.signedPreKey = bundle.signedPreKey.base64EncodedString()
            identity.signedPreKeyId = Int(bundle.signedPreKeyID)
            identity.signedPreKeySignature = bundle.signature.base64EncodedString()
            identity.protocolProfile = Self.xmlns
            identity.isPublicated = false
            if device.realm == nil {
                device.owner = owner; device.jid = owner; device.deviceId = bundle.deviceID; device.primary = primary
            }
            device.fingerprint = fingerprint; device.state = .trusted; device.isPublicated = false
            realm.add(identity, update: .modified); realm.add(device, update: .modified)
        }
        shouldPublicate = true
    }

    func doubleUnratched(_ encrypted: String, jid: String, deviceId: Int, keyExchange: Bool) throws -> Data {
        let data = try Omemo2PayloadCodec.decodeBase64(encrypted)
        let ciphertext = try OMEMO2Ciphertext(data: data, keyExchange: keyExchange)
        return try ensureOMEMO2Prepared().decrypt(ciphertext, jid: jid, deviceID: deviceId)
    }

    func doubleRatchet(hmac: Data, jid: String, deviceId: Int) throws -> DDXMLElement {
        try OmemoManager.sessionQueue.sync {
            let requiresTrustedIdentity = hmac != Data(repeating: 0, count: 32)
            if requiresTrustedIdentity {
                let realm = try WRealm.safe()
                guard OMEMO2DeviceListStorageItem.contains(in: realm, owner: owner, jid: jid, deviceID: deviceId) else {
                    throw OmemoManagerError.noTrustedRecipientDevices
                }
            }
            let storage = try ensureOMEMO2Prepared()
            if try !storage.sessionExists(jid: jid, deviceID: deviceId) {
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
        guard let preKey = bundle.preKeys.randomElement() else { throw OmemoManagerError.preKeyNotFound }
        try storage.initiateSession(jid: jid, deviceID: deviceId, bundle: bundle.selectedBundle(preKeyID: preKey.id))
    }

    func encryptMessage(message: String, to jid: String) throws -> DDXMLElement? {
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
        let prepared = try Omemo2PayloadCodec.prepareOutgoingXML(message)
        let sealed = try Omemo2PayloadCodec.seal(prepared)
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
        return encrypted
    }

    /// Protocol acknowledgements target exactly the sender's device. They never
    /// contain user content and can also confirm an untrusted identity.
    internal func makeOMEMO2Control(jid: String, deviceID: Int) throws -> XMPPMessage {
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
