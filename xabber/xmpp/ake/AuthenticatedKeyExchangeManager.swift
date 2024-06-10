//
//  AuthenticatedKeyExchangeManager.swift
//  xabber
//
//  Created by MacIntel on 08.02.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import SignalProtocolObjC
import XMPPFramework
import Curve25519Kit
import CryptoKit
import CryptoSwift
import RealmSwift

class AuthenticatedKeyExchangeManager: AbstractXMPPManager{
    enum State{
        case none
        case sentRequest
        case receivedRequest
        case acceptedRequest
        case hashSentToOpponent
        case hashSentToInitiator
        case trusted
    }
    
    override func namespaces() -> [String] {
        return [
            "urn:xabber:trust"
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    private final func generateByteSequence() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes
        } else {
            DDLogDebug("AuthenticationKeyExchangeManager: \(#function)")
            fatalError()
        }
    }
    
    private final func generateCode() -> String {
        return String.randomString(length: 6, includeNumber: true)
//        return String(Int.random(in: 100000...999999))
    }
    
    internal final func calculateSharedKey(jid: String, deviceId: Int) -> [UInt8] {
        let keyPair = AccountManager.shared.find(for: owner)?.omemo.localStore.getIdentityKeyPair()
        let keyPairCurve25519 = Curve25519.load(fromPublicKey: keyPair!.publicKey, andPrivateKey: keyPair!.privateKey)
        let opponentPublicKey = getUsersPublicKey(jid: jid, deviceId: deviceId)
        
        let sharedKey = Array(Curve25519.generateSharedSecret(fromPublicKey: Data(opponentPublicKey), andKeyPair: keyPairCurve25519))
        return sharedKey
    }
    
    private final func calculateEncryptionKey(jid: String, sid: String, sharedKey: [UInt8]) -> [UInt8] {
        var code: String = ""
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner,sid: sid))
            code = instance!.code
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        let stringToHash = sharedKey + Array(SHA256.hash(data: (code.bytes)).makeIterator())
        let encryptionKey = Array(SHA256.hash(data: stringToHash).makeIterator())
        return encryptionKey
    }
    
    func getUsersPublicKey(jid: String, deviceId: Int) -> [UInt8] {
        var publicKey: [UInt8] = []
        do {
            let realm = try WRealm.safe()
            let storedBundle = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: jid, deviceId: deviceId))
            publicKey = try storedBundle!.identityKey!.base64decoded()
            if publicKey.count == 33 {
                publicKey = Array(publicKey.dropFirst())
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        
        return publicKey
    }
    
    func getMessageChildsForVerififcationRequest(sid: String, deviceId: String? = nil) -> DDXMLElement {
        let authenticationKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticationKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        authenticationKeyExchange.addAttribute(withName: "timestamp", stringValue: String(Date().timeIntervalSince1970))
        
        guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
            fatalError()
        }
        let myDeviceId = localStore.localDeviceId()
        
        let verificationStart = DDXMLElement(name: "verification-start")
        verificationStart.addAttribute(withName: "device-id", stringValue: String(myDeviceId))
        if deviceId != nil {
            verificationStart.addAttribute(withName: "to-device-id", stringValue: deviceId!)
        }
        
        authenticationKeyExchange.addChild(verificationStart)
        
        return authenticationKeyExchange
    }
    
    func getMessageChildsForAcceptVerificationRequest(sid: String, encryptedByteSequence: String, iv: String) -> DDXMLElement {
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        authenticatedKeyExchange.addAttribute(withName: "timestamp", stringValue: String(Date().timeIntervalSince1970))
        
        guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
            fatalError()
        }
        let deviceId = localStore.localDeviceId()
        
        let verificationAccept = DDXMLElement(name: "verification-accepted")
        verificationAccept.addAttribute(withName: "device-id", stringValue: String(deviceId))
        
        let salt = DDXMLElement(name: "salt")
        salt.addChild(DDXMLElement(name: "ciphertext", stringValue: encryptedByteSequence))
        salt.addChild(DDXMLElement(name: "iv", stringValue: iv))
        
        authenticatedKeyExchange.addChild(verificationAccept)
        authenticatedKeyExchange.addChild(salt)
        
        return authenticatedKeyExchange
    }
    
    func getMessageChildsToSendHashAndSaltToOpponent(sid: String, encryptedHash: String, ivHash: String, encryptedSalt: String, ivSalt: String) -> DDXMLElement {
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        authenticatedKeyExchange.addAttribute(withName: "timestamp", stringValue: String(Date().timeIntervalSince1970))
        
        let hash = DDXMLElement(name: "hash")
        hash.addAttribute(withName: "algo", stringValue: "sha-256")
        hash.addChild(DDXMLElement(name: "ciphertext", stringValue: encryptedHash))
        hash.addChild(DDXMLElement(name: "iv", stringValue: ivHash))
        
        let salt = DDXMLElement(name: "salt")
        salt.addChild(DDXMLElement(name: "ciphertext", stringValue: encryptedSalt))
        salt.addChild(DDXMLElement(name: "iv", stringValue: ivSalt))
        
        authenticatedKeyExchange.addChild(hash)
        authenticatedKeyExchange.addChild(salt)
        
        return authenticatedKeyExchange
    }
    
    func getMessageChildsForErrorMessage(sid: String, reason: String) -> DDXMLElement {
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        authenticatedKeyExchange.addAttribute(withName: "timestamp", stringValue: String(Date().timeIntervalSince1970))
        
        let verificationFailed = DDXMLElement(name: "verification-failed")
        verificationFailed.addAttribute(withName: "reason", stringValue: reason)
        
        authenticatedKeyExchange.addChild(verificationFailed)
        
        return authenticatedKeyExchange
    }
    
    
    
    func didReceivedVerificationMessage(message: XMPPMessage) -> Bool {
        var bareMessage: XMPPMessage = message
        if isArchivedMessage(message) {
            bareMessage = getArchivedMessageContainer(message) ?? message
        } else if isCarbonCopy(message) {
            return true
        } else if isCarbonForwarded(message) {
            return true
        }
        
        guard let notify = bareMessage.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns) ?? bareMessage.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns) else {
            return false
        }
        let uniqueMessageId = getUniqueMessageId(bareMessage, owner: self.owner)
        guard let messageContainer = notify.element(forName: "forwarded")?.element(forName: "message") else {
            return false
        }
        
        guard let authenticatedKeyExchange = messageContainer.element(forName: "authenticated-key-exchange", xmlns: getPrimaryNamespace()),
              let jid = XMPPMessage(from: messageContainer).from,
              let sid = authenticatedKeyExchange.attributeStringValue(forName: "sid"),
              let timestamp = authenticatedKeyExchange.attributeStringValue(forName: "timestamp") else {
            return false
        }
        
        if XMPPMessage(from: messageContainer).from == AccountManager.shared.find(for: self.owner)?.xmppStream.myJID {
            return true
        }
        
        let dateString = bareMessage.element(forName: "time")?.attributeStringValue(forName: "stamp")
        var date: Date? = nil
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        date = dateFormatter.date(from: dateString ?? "")
        if date == nil {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            date = dateFormatter.date(from: dateString ?? "")
        }
        
        var toDeviceId: String? = nil
        do {
            let realm = try WRealm.safe()
            if realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: jid.bare, uniqueId: uniqueMessageId)) != nil {
                return true
            }
            let instance = NotificationStorageItem()
            instance.owner = self.owner
            instance.jid = jid.bare
            instance.uniqueId = uniqueMessageId
            instance.primary = NotificationStorageItem.genPrimary(owner: self.owner, jid: jid.bare, uniqueId: uniqueMessageId)
            instance.category = .trust
            instance.verificationSid = sid
            instance.associatedJid = jid.bare
            
            if date != nil {
                instance.date = date!
            }
            
            toDeviceId = authenticatedKeyExchange.element(forName: "verification-start")?.attributeStringValue(forName: "to-device-id")
            if toDeviceId != nil {
                guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
                    DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                    return true
                }
                let myDeviceId = localStore.localDeviceId()
                if String(myDeviceId) != toDeviceId {
                    return true
                }
            }
            
            if authenticatedKeyExchange.element(forName: "verification-accepted") != nil {
                instance.verificationState = .acceptedRequest
                instance.deviceId = authenticatedKeyExchange.element(forName: "verification-accepted")?.attributeStringValue(forName: "device-id")
            } else if authenticatedKeyExchange.element(forName: "verification-rejected") != nil {
                instance.verificationState = .rejected
            }
            
            try realm.write {
                realm.add(instance)
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchange: \(#function). \(error.localizedDescription)")
            return true
        }
        
        var title = ""
        guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
            DDLogDebug("AuthenticatedKeyExchange: \(#function).")
            return true
        }
        let deviceIdRecipient = localStore.localDeviceId()
        
        if authenticatedKeyExchange.element(forName: "verification-start") != nil {
            do {
                let realm = try WRealm.safe()
                if realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) != nil {
                    return false
                }
                guard let verificationStart = authenticatedKeyExchange.element(forName: "verification-start"),
                      let opponentDeviceIdRaw = verificationStart.attributeStringValue(forName: "device-id"),
                      let opponentDeviceID = Int(opponentDeviceIdRaw),
                      let timestamp = authenticatedKeyExchange.attributeStringValue(forName: "timestamp") else {
                    return false
                }
                
                let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid.bare, deviceId: opponentDeviceID))
                if deviceInstance?.state == .trusted {
                    return true
                }
                
                let predicate = NSPredicate(format: "owner == %@ AND myDeviceId == %@ AND jid == %@", argumentArray: [self.owner, deviceIdRecipient, jid.bare])
                let oldInstances = realm.objects(VerificationSessionStorageItem.self).filter(predicate).sorted(byKeyPath: "timestamp", ascending: false)
                if !oldInstances.isEmpty {
                    if oldInstances.first!.timestamp < timestamp {
                        try realm.write {
                            realm.delete(oldInstances)
                        }
                    } else {
                        return true
                    }
                }
                
                guard let notificationInstance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: jid.bare, uniqueId: uniqueMessageId)) else {
                    DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                    return true
                }
                
                let instance = VerificationSessionStorageItem()
                instance.owner = self.owner
                instance.myDeviceId = deviceIdRecipient
                instance.jid = jid.bare
                instance.fullJID = jid.full
                instance.sid = sid
                instance.opponentDeviceId = opponentDeviceID
                instance.state = .receivedRequest
                instance.primary = VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)
                instance.timestamp = String(timestamp)
                try realm.write {
                    realm.add(instance)
                    notificationInstance.verificationState = .receivedRequest
                }
            } catch {
                DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
                return true
            }
            title = "Verification request received"
            
            if jid.bare == self.owner && toDeviceId == nil {
                guard let presenter = (UIApplication.shared.delegate as? AppDelegate)?.splitController else {
                    return true
                }
                
                let vc = VerificationConfirmationViewController()
                
                DispatchQueue.main.async {
                    vc.configure(owner: self.owner, sid: sid)
                    showModal(vc, from: presenter)
                }
            }
        } else if authenticatedKeyExchange.element(forName: "verification-accepted") != nil {
            let byteSequence = self.generateByteSequence()
            
            do {
                let realm = try WRealm.safe()
                guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                    return true
                }
                if instance.state != .sentRequest {
                    NotificationCenter.default.post(name: NSNotification.Name(rawValue: "VerificationConfirmationViewController"), object: self, userInfo: ["sid": sid])
                    
                    try realm.write {
                        realm.delete(instance)
                    }
                    return true
                }
                
                guard let verificationAccepted = authenticatedKeyExchange.element(forName: "verification-accepted"),
                      let opponentDeviceIdRaw = verificationAccepted.attributeStringValue(forName: "device-id"),
                      let opponentDeviceID = Int(opponentDeviceIdRaw),
                      let saltEncrypted = authenticatedKeyExchange.element(forName: "salt")?.element(forName: "ciphertext")?.stringValue,
                      let saltIv = authenticatedKeyExchange.element(forName: "salt")?.element(forName: "iv")?.stringValue else {
                    return true
                }
                
                guard let notificationInstance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: jid.bare, uniqueId: uniqueMessageId)) else {
                    DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                    return true
                }
                
                try realm.write {
                    instance.jid = jid.bare
                    instance.fullJID = jid.full
                    instance.opponentDeviceId = opponentDeviceID
                    instance.byteSequence = byteSequence.toBase64()
                    instance.state = .receivedRequestAccept
                    instance.opponentByteSequenceEncrypted = saltEncrypted
                    instance.opponentByteSequenceIv = saltIv
                    instance.timestamp = String(timestamp)
                    notificationInstance.verificationState = .receivedRequestAccept
                }
            } catch {
                DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
                return true
            }
            
            title = "Verification request accepted"
        } else if authenticatedKeyExchange.element(forName: "hash") != nil && authenticatedKeyExchange.element(forName: "salt") != nil {
            guard let hashEncrypted = authenticatedKeyExchange.element(forName: "hash"),
                  let byteSequenceEncrypted = authenticatedKeyExchange.element(forName: "salt") else {
                return true
            }
            
            var deviceId: Int = 0
            
            do {
                let realm = try WRealm.safe()
                guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                    return true
                }
                
                deviceId = instance.opponentDeviceId
                
                guard let notificationInstance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: jid.bare, uniqueId: uniqueMessageId)) else {
                    DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                    return true
                }
                
                try realm.write {
                    instance.state = .hashSentToInitiator
                    instance.timestamp = String(Date().timeIntervalSince1970)
                    notificationInstance.verificationState = .hashSentToInitiator
                }
            } catch {
                DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
                return true
            }
            
            guard let fullJid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full else {
                return true
            }
            
            if !checkHashFromInitiator(jid: jid.bare, sid: sid, deviceId: deviceId, hashEncrypted: hashEncrypted, byteSequenceEncrypted: byteSequenceEncrypted) {
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "ShowCodeViewController"), object: self, userInfo: ["sid": sid])
                
                let child = self.getMessageChildsForErrorMessage(sid: sid, reason: "Hashes didn't match")
                
                let message = XMPPMessage(messageType: .chat, to: jid, elementID: UUID().uuidString, child: child)
                message.addAttribute(withName: "from", stringValue: fullJid)
                
                let iq = self.getNotificationContainer(message: message, notificationTo: jid)
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    stream.send(iq)
                })
                
                do {
                    let realm = try WRealm.safe()
                    guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)),
                          let notificationInstance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: jid.bare, uniqueId: uniqueMessageId)) else {
                        DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                        return true
                    }
                    try realm.write {
                        instance.state = .failed
                        notificationInstance.verificationState = .failed
                    }
                } catch {
                    DDLogDebug("AuthenticatedKeyExchange: \(#function). \(error.localizedDescription)")
                    return true
                }
                self.showNotification(title: jid.bare, owner: self.owner, body: "Verification failed", sid: sid, timestamp: Date().timeIntervalSince1970)
                return true
            }
            let hash = self.calculateHashForInitiator(jid: jid.bare, sid: sid)
            let encryptedHashResult = self.encrypt(jid: jid.bare, sid: sid, deviceId: deviceId, data: hash)
            let authenticatedKeyExchangeChild = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
            authenticatedKeyExchangeChild.addAttribute(withName: "sid", stringValue: sid)
            authenticatedKeyExchangeChild.addAttribute(withName: "timestamp", stringValue: String(Date().timeIntervalSince1970))
            let hashChild = DDXMLElement(name: "hash")
            hashChild.addAttribute(withName: "algo", stringValue: "sha-256")
            hashChild.addChild(DDXMLElement(name: "ciphertext", stringValue: encryptedHashResult.encrypted.toBase64()))
            hashChild.addChild(DDXMLElement(name: "iv", stringValue: encryptedHashResult.iv.toBase64()))
            authenticatedKeyExchangeChild.addChild(hashChild)
            
            let message = XMPPMessage(messageType: .chat, to: jid, elementID: UUID().uuidString, child: authenticatedKeyExchangeChild)
            message.addAttribute(withName: "from", stringValue: fullJid)
            
            let iq = self.getNotificationContainer(message: message, notificationTo: jid)
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                stream.send(iq)
            })
            
            return true
        } else if authenticatedKeyExchange.element(forName: "hash") != nil {
            guard let hashEncrypted = authenticatedKeyExchange.element(forName: "hash") else {
                return true
            }
            
            var deviceId: Int = 0
            var byteSequence: [UInt8] = []
            var opponentByteSequence: [UInt8] = []
            var code: String = ""
            
            var omemoFingerprint = ""
            
            do {
                let realm = try WRealm.safe()
                guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                    return true
                }
                
                guard let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid.bare, deviceId: instance.opponentDeviceId)) else {
                    return true
                }
                omemoFingerprint = deviceInstance.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
                
                guard let notificationInstance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: jid.bare, uniqueId: uniqueMessageId)) else {
                    DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                    return true
                }
                
                deviceId = instance.opponentDeviceId
                code = instance.code
                byteSequence = try instance.byteSequence.base64decoded()
                opponentByteSequence = try instance.opponentByteSequence.base64decoded()
                
                try realm.write {
                    instance.state = .hashSentToInitiator
                    instance.timestamp = String(Date().timeIntervalSince1970)
                    notificationInstance.verificationState = .hashSentToInitiator
                }
                
            } catch {
                DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
                return true
            }
            
            let hash = self.decryptElementFromXML(jid: jid.bare,
                                                  sid: sid,
                                                  deviceId: deviceId,
                                                  encryptedXML: hashEncrypted)
            
            let opponentTrustedKey = String(deviceId) + "::" + omemoFingerprint
            
            let stringToHash = opponentTrustedKey.bytes + code.bytes + opponentByteSequence + byteSequence
            let myHash = Array(SHA256.hash(data: stringToHash).makeIterator())
            
            do {
                let realm = try WRealm.safe()
                let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid))
                guard let notificationInstance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: jid.bare, uniqueId: uniqueMessageId)) else {
                    DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                    return true
                }
                if hash != myHash {
                    sendErrorMessage(fullJID: jid, sid: sid, reason: "Hashes didn't match")
                    self.showNotification(title: jid.bare, owner: self.owner, body: "Verification failed", sid: sid, timestamp: Date().timeIntervalSince1970)
                    
                    try realm.write {
                        instance?.state = .failed
                        notificationInstance.verificationState = .failed
                    }
                    return true
                }
                try realm.write {
                    instance?.state = .trusted
                    notificationInstance.verificationState = .trusted
                    
                }
            } catch {
                DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
                return true
            }
            
            self.sendSuccessfulVerificationMessage(toJid: jid, sid: sid)
            self.writeTrustedDevice(jid: jid.bare, deviceId: deviceId)
            
            guard let trustSharingManager = AccountManager.shared.find(for: self.owner)?.trustSharingManager else {
                DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                return true
            }
            if self.owner == jid.bare {
                trustSharingManager.sendNotificationWithContactsDevices(opponentFullJid: jid.bareJID, deviceId: deviceIdRecipient)
                trustSharingManager.publicOwnTrustedDevices(publisherDeviceId: String(deviceIdRecipient))
                trustSharingManager.getUserTrustedDevices(jid: jid.bareJID, deviceId: String(deviceId))
            } else {
                trustSharingManager.sendNotificationWithContactsDevices(opponentFullJid: XMPPJID(string: self.owner)!, deviceId: deviceIdRecipient)
                trustSharingManager.getUserTrustedDevices(jid: jid.bareJID, deviceId: String(deviceId))
            }
            
            title = "Verification completed successfully"
        } else if authenticatedKeyExchange.element(forName: "verification-successful") != nil {
            var deviceId: Int = 0
            do {
                let realm = try WRealm.safe()
                guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                    return true
                }
                guard let notificationInstance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: jid.bare, uniqueId: uniqueMessageId)) else {
                    DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                    return true
                }
                
                deviceId = instance.opponentDeviceId
                
                try realm.write {
                    instance.state = .trusted
                    notificationInstance.verificationState = .trusted
                }
            } catch {
                DDLogDebug("AuthenticatedKeyExchange: \(#function). \(error.localizedDescription)")
                return true
            }
            self.writeTrustedDevice(jid: jid.bare, deviceId: deviceId)
            
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "ShowCodeViewController"), object: self, userInfo: ["sid": sid])
            
            guard let trustSharingManager = AccountManager.shared.find(for: self.owner)?.trustSharingManager else {
                DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                return true
            }
            if self.owner == jid.bare {
                trustSharingManager.sendNotificationWithContactsDevices(opponentFullJid: jid.bareJID, deviceId: deviceIdRecipient)
                trustSharingManager.publicOwnTrustedDevices(publisherDeviceId: String(deviceIdRecipient))
            } else {
                trustSharingManager.sendNotificationWithContactsDevices(opponentFullJid: XMPPJID(string: self.owner)!, deviceId: deviceIdRecipient)
                trustSharingManager.getUserTrustedDevices(jid: jid.bareJID, deviceId: String(deviceId))
            }
            
            title = "Verification completed successfully"
        } else if authenticatedKeyExchange.element(forName: "verification-rejected") != nil {
            do {
                let realm = try WRealm.safe()
                guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                    return true
                }
                guard let notificationInstance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: jid.bare, uniqueId: uniqueMessageId)) else {
                    DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                    return true
                }
                
                if instance.state != .sentRequest {
                    return true
                }
                
                try realm.write {
                    instance.state = .rejected
                    notificationInstance.verificationState = .rejected
                }
            } catch {
                DDLogDebug("AuthenticatedKeyExchange: \(#function). \(error.localizedDescription)")
                return true
            }
            title = "Verification rejected"
        } else if authenticatedKeyExchange.element(forName: "verification-failed") != nil {
            do {
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "VerificationConfirmationViewController"), object: self, userInfo: ["sid": sid])
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "ShowCodeViewController"), object: self, userInfo: ["sid": sid])
                
                let realm = try WRealm.safe()
                guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                    return true
                }
                if instance.state == .receivedRequest {
                    try realm.write {
                        realm.delete(instance)
                    }
                    return true
                }
                
                guard let notificationInstance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: jid.bare, uniqueId: uniqueMessageId)) else {
                    DDLogDebug("AuthenticatedKeyExchange: \(#function).")
                    return true
                }
                try realm.write {
                    notificationInstance.verificationState = .failed
                    instance.state = .failed
                }
            } catch {
                DDLogDebug("AuthenticatedKeyExchange: \(#function). \(error.localizedDescription)")
                return true
            }
            title = "Verification failed"
        }
        self.showNotification(title: jid.bare, owner: self.owner, body: title, sid: sid, timestamp: Date().timeIntervalSince1970)
        return true
    }
    
    func writeTrustedDevice(jid: String, deviceId: Int) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: deviceId)) {
                try realm.write {
                    instance.trustDate = Date()
                    instance.state = .trusted
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func sendVerificationRequest(jid: String, deviceId: String? = nil) {
        let sid = UUID().uuidString
        do {
            let realm = try WRealm.safe()
            
            guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
                DDLogDebug("AuthenticatedKeyExchangeManager: \(#function).")
                return
            }
            let myDeviceId = localStore.localDeviceId()
            
            let predicate = NSPredicate(format: "owner == %@ AND myDeviceId == %@ AND jid == %@", argumentArray: [self.owner, myDeviceId, jid])
            let oldInstances = realm.objects(VerificationSessionStorageItem.self).filter(predicate)
            if !oldInstances.isEmpty {
                try realm.write {
                    realm.delete(oldInstances)
                }
            }
            
            let instance = VerificationSessionStorageItem()
            instance.owner = self.owner
            instance.myDeviceId = myDeviceId
            instance.jid = jid
            instance.sid = sid
            instance.state = .sentRequest
            instance.primary = VerificationSessionStorageItem.genPrimary(owner: instance.owner, sid: instance.sid)
            instance.timestamp = String(Date().timeIntervalSince1970)
            try realm.write {
                realm.add(instance)
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return
        }
        
        guard let fullJid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full,
        let toJid = XMPPJID(string: jid) else {
            return
        }
        
        let childs = self.getMessageChildsForVerififcationRequest(sid: sid, deviceId: deviceId)
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: jid), elementID: UUID().uuidString, child: childs)
        message.addAttribute(withName: "from", stringValue: fullJid)
        
        let iq = self.getNotificationContainer(message: message, notificationTo: toJid)

        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
    }
    
    func acceptVerificationRequest(jid: String, sid: String) -> String? {
        let code = self.generateCode()
        
        var deviceId: Int = 0
        var fullJID: String = ""
        let byteSequence = self.generateByteSequence()
        
        do {
            let realm = try WRealm.safe()
            
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                DDLogDebug("AuthenticatedKeyExchangeManager: \(#function).")
                return nil
            }
            deviceId = instance.opponentDeviceId
            fullJID = instance.fullJID
            
            try realm.write {
                instance.code = code
                instance.state = .acceptedRequest
                instance.byteSequence = byteSequence.toBase64()
                instance.timestamp = String(Date().timeIntervalSince1970)
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return nil
        }
        
        let result = self.encrypt(jid: jid, sid: sid, deviceId: deviceId, data: byteSequence)
        
        let child = self.getMessageChildsForAcceptVerificationRequest(sid: sid, encryptedByteSequence: result.encrypted.toBase64(), iv: result.iv.toBase64())
        
        guard let myFullJid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full,
        let toJid = XMPPJID(string: fullJID) else {
            return nil
        }
        
        let message = XMPPMessage(messageType: .chat, to: toJid, elementID: UUID().uuidString, child: child)
        message.addAttribute(withName: "from", stringValue: myFullJid)
        
        let iq = self.getNotificationContainer(message: message, notificationTo: toJid)
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
        
        if toJid.bare != self.owner {
            guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore,
            let timestamp = message.element(forName: "authenticated-key-exchange")?.attributeStringValue(forName: "timestamp") else {
                DDLogDebug("AuthenticatedKeyExchangeManager: \(#function).")
                return nil
            }
            let deviceId = localStore.localDeviceId()
            
            let verificationAccepted = DDXMLElement(name: "verification-accepted")
            verificationAccepted.addAttribute(withName: "device-id", stringValue: String(deviceId))
            
            let akeXML = DDXMLElement(name: "authenticated-key-exchange", xmlns: "urn:xabber:trust")
            akeXML.addAttribute(withName: "sid", stringValue: sid)
            akeXML.addAttribute(withName: "timestamp", stringValue: timestamp)
            akeXML.addChild(verificationAccepted)
            
            let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: fullJID), elementID: UUID().uuidString, child: akeXML)
            message.addAttribute(withName: "from", stringValue: myFullJid)
            
            let iqToMyDevices = self.getNotificationContainer(message: message, notificationTo: XMPPJID(string: self.owner)!)
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                stream.send(iqToMyDevices)
            })
        }
        
        return code
    }
    
    func getNotificationContainer(message: XMPPMessage, notificationTo: XMPPJID) -> XMPPIQ {
        let forwarded = DDXMLElement(name: "forwarded", xmlns: "urn:xmpp:forward:0")
        forwarded.addChild(message.copy() as! DDXMLElement)
        
        let notification = DDXMLElement(name: "notification")
        notification.addChild(forwarded)
        
        let address = DDXMLElement(name: "address")
        address.addAttribute(withName: "type", stringValue: "to")
        address.addAttribute(withName: "jid", stringValue: notificationTo.full)
        let addresses = DDXMLElement(name: "addresses", xmlns: "http://jabber.org/protocol/address")
        addresses.addChild(address)
        
        let notify = DDXMLElement(name: "notify", xmlns: "urn:xabber:xen:0")
        notify.addChild(notification)
        notify.addChild(addresses)
        
        let iq = XMPPIQ(iqType: .set, to: notificationTo.bareJID, child: notify)
        
        return iq
    }
    
    func sendHashToOpponent(jid: XMPPJID, sid: String) {
        var deviceId: Int = 0
        var byteSequence: [UInt8] = []
        var opponentByteSequence: [UInt8] = []
        var code: String = ""
        
        var myTrustedKey = ""
        
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                DDLogDebug("AuthenticatedKeyExchange \(#function).")
                return
            }
            deviceId = instance.opponentDeviceId
            byteSequence = try instance.byteSequence.base64decoded()
            opponentByteSequence = try instance.opponentByteSequence.base64decoded()
            code = instance.code
            try realm.write {
                instance.state = .hashSentToOpponent
                instance.timestamp = String(Date().timeIntervalSince1970)
            }
            
            guard let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: instance.myDeviceId)) else {
                DDLogDebug("AuthenticatedKeyExchange \(#function).")
                return
            }
            let omemoFingerprint = deviceInstance.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
            myTrustedKey = String(deviceInstance.deviceId) + "::" + omemoFingerprint
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
            return
        }
        
        let stringToHash = myTrustedKey.bytes + code.bytes + opponentByteSequence
        let hash = Array(SHA256.hash(data: stringToHash).makeIterator())
        
        let resultHash = self.encrypt(jid: jid.bare, sid: sid, deviceId: deviceId, data: hash)
        let resultSalt = self.encrypt(jid: jid.bare, sid: sid, deviceId: deviceId, data: byteSequence)
        
        let child = self.getMessageChildsToSendHashAndSaltToOpponent(sid: sid, encryptedHash: resultHash.encrypted.toBase64(), ivHash: resultHash.iv.toBase64(), encryptedSalt: resultSalt.encrypted.toBase64(), ivSalt: resultSalt.iv.toBase64())
        child.addChild(DDXMLElement(name: "my-trusted-key", stringValue: myTrustedKey))
        child.addChild(DDXMLElement(name: "code", stringValue: code))
        child.addChild(DDXMLElement(name: "opponent-byte-sequence", stringValue: opponentByteSequence.toBase64()))
        
        guard let myFullJid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full else {
            DDLogDebug("AuthenticatedKeyExchange \(#function).")
            return
        }
        
        let messageToSend = XMPPMessage(messageType: .chat, to: jid, elementID: UUID().uuidString, child: child)
        messageToSend.addAttribute(withName: "from", stringValue: myFullJid)
        
        let iq = self.getNotificationContainer(message: messageToSend, notificationTo: jid)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
    }
    
    func sendSuccessfulVerificationMessage(toJid: XMPPJID, sid: String) {
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        authenticatedKeyExchange.addAttribute(withName: "timestamp", stringValue: String(Date().timeIntervalSince1970))
        
        let verificationSuccessful = DDXMLElement(name: "verification-successful")
        
        authenticatedKeyExchange.addChild(verificationSuccessful)
        
        guard let myFullJid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full else {
            DDLogDebug("AuthenticatedKeyExchange \(#function).")
            return
        }
        
        let message = XMPPMessage(messageType: .chat, to: toJid, elementID: UUID().uuidString, child: authenticatedKeyExchange)
        message.addAttribute(withName: "from", stringValue: myFullJid)
        
        let iq = self.getNotificationContainer(message: message, notificationTo: toJid)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
    }
    
    func sendErrorMessage(fullJID: XMPPJID, sid: String, reason: String) {
        let child = getMessageChildsForErrorMessage(sid: sid, reason: reason)
        
        guard let myFullJid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full else {
            DDLogDebug("AuthenticatedKeyExchange \(#function).")
            return
        }
        
        let message = XMPPMessage(messageType: .chat, to: fullJID, elementID: UUID().uuidString, child: child)
        message.addAttribute(withName: "from", stringValue: myFullJid)
        
        let iq = self.getNotificationContainer(message: message, notificationTo: fullJID)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
    }
    
    func checkHashFromInitiator(jid: String, sid: String, deviceId: Int, hashEncrypted: DDXMLElement, byteSequenceEncrypted: DDXMLElement) -> Bool {
        let hash = self.decryptElementFromXML(jid: jid, sid: sid, deviceId: deviceId, encryptedXML: hashEncrypted)
        guard let opponentByteSequence = self.decryptElementFromXML(jid: jid, sid: sid, deviceId: deviceId, encryptedXML: byteSequenceEncrypted) else {
            DDLogDebug("AuthenticatedKeyExchange \(#function).")
            return false
        }
        
        var deviceId: String = ""
        var code: String = ""
        var byteSequence: [UInt8] = []
        
        var omemoFingerprint = ""
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid))
            try realm.write {
                instance?.opponentByteSequence = opponentByteSequence.toBase64()
            }
            
            deviceId = String(instance!.opponentDeviceId)
            code = instance!.code
            byteSequence = try instance!.byteSequence.base64decoded()
            
            let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: Int(deviceId)!))
            omemoFingerprint = deviceInstance!.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
            return true
        }
        
        let opponentTrustedKey = deviceId + "::" + omemoFingerprint
        
        let stringToHash = Data(opponentTrustedKey.bytes + code.bytes + byteSequence)
        let myHash = Array(SHA256.hash(data: stringToHash).makeIterator())
        
        if hash != myHash {
            return false
        }
        
        return true
    }
    
    func calculateHashForInitiator(jid: String, sid: String) -> [UInt8] {
        var code: String = ""
        var byteSequence: [UInt8] = []
        var opponentByteSequence: [UInt8] = []
        
        var omemoFingerprint = ""
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid))
            
            code = instance!.code
            byteSequence = try instance!.byteSequence.base64decoded()
            opponentByteSequence = try instance!.opponentByteSequence.base64decoded()
            
            try realm.write {
                instance?.state = .hashSentToInitiator
                instance?.timestamp = String(Date().timeIntervalSince1970)
            }
            
            let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: instance!.myDeviceId))
            omemoFingerprint = deviceInstance!.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        
        guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function).")
            fatalError()
        }
        
        let keyPair = localStore.getIdentityKeyPair()
        let deviceID = localStore.localDeviceId()
        
        let trustedKey = (String(deviceID) + "::" + omemoFingerprint).bytes
        
        let stringToHash = trustedKey + Array(code.utf8) + byteSequence + opponentByteSequence
        let hash = Array(SHA256.hash(data: stringToHash).makeIterator())

        return hash
    }
    
    func encrypt(jid: String, sid: String, deviceId: Int, data: Array<UInt8>) -> (encrypted: [UInt8], iv: [UInt8]) {
        let sharedKey = calculateSharedKey(jid: jid, deviceId: deviceId)
        let encryptionKey = calculateEncryptionKey(jid: jid, sid: sid, sharedKey: sharedKey)
        var iv = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv)
        guard status == errSecSuccess else {
            DDLogDebug("AuthenticationKeyExchangeManager: \(#function)")
            fatalError()
        }
        
        let aes = try! AES(key: encryptionKey, blockMode: CBC(iv: iv))
        let encrypted = try! aes.encrypt(data)
        
        return (encrypted: encrypted, iv: iv)
    }
    
    func decryptElementFromXML(jid: String, sid: String, deviceId: Int, encryptedXML: DDXMLElement) -> [UInt8]? {
        let ciphertext: [UInt8]?
        let iv: [UInt8]?
        
        do {
            ciphertext = try encryptedXML.element(forName: "ciphertext")?.stringValue?.base64decoded()
            iv = try encryptedXML.element(forName: "iv")?.stringValue?.base64decoded()
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
            return nil
        }
        let decryptedValue = decrypt(jid: jid, sid: sid, deviceId: deviceId, ciphertext: ciphertext!, iv: iv!)
        
        return decryptedValue
    }
    
    func decrypt(jid: String, sid: String, deviceId: Int, ciphertext: [UInt8], iv: [UInt8]) -> [UInt8] {
        let sharedKey = calculateSharedKey(jid: jid, deviceId: deviceId)
        let encryptionKey = calculateEncryptionKey(jid: jid, sid: sid, sharedKey: sharedKey)
        var decrypted: [UInt8] = []
        
        do {
            let aes = try AES(key: encryptionKey, blockMode: CBC(iv: iv))
            decrypted = try aes.decrypt(ciphertext)
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
            fatalError()
        }
        
        return decrypted
    }
    
    func rejectRequestToVerify(jid: String, sid: String) {
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                return
            }
            try realm.write {
                realm.delete(instance)
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return
        }
        
        let timestamp = Date().timeIntervalSince1970.rounded()
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        authenticatedKeyExchange.addAttribute(withName: "timestamp", stringValue: String(timestamp))
        let verificationRejected = DDXMLElement(name: "verification-rejected")
        authenticatedKeyExchange.addChild(verificationRejected)
        
        guard let myFullJid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full,
              let jid = XMPPJID(string: jid) else {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function).")
            return
        }
        
        let message = XMPPMessage(messageType: .chat, to: jid, elementID: UUID().uuidString, child: authenticatedKeyExchange)
        message.addAttribute(withName: "from", stringValue: myFullJid)
        
        let iq = self.getNotificationContainer(message: message, notificationTo: jid)
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
        
        if jid.bare != self.owner {
            let verificationRejected = DDXMLElement(name: "verification-rejected")
            
            let akeXML = DDXMLElement(name: "authenticated-key-exchange", xmlns: "urn:xabber:trust")
            akeXML.addAttribute(withName: "sid", stringValue: sid)
            akeXML.addAttribute(withName: "timestamp", stringValue: String(timestamp))
            akeXML.addChild(verificationRejected)
            
            let message = XMPPMessage(messageType: .chat, to: jid, elementID: UUID().uuidString, child: akeXML)
            message.addAttribute(withName: "from", stringValue: myFullJid)
            
            let iqToMyDevices = self.getNotificationContainer(message: message, notificationTo: XMPPJID(string: self.owner)!)
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                stream.send(iqToMyDevices)
            })
        }
    }
    
    func showNotification(title: String, owner: String, body: String, sid: String, timestamp: TimeInterval) {
        NotifyManager.shared.update(withVerificationMessage: body, owner: owner, displayName: title, sid: sid, timestamp: timestamp)
        NotifyManager.shared.showNotify(forType: .verification)
    }
    
    func showFailedRejectedSuccessfulAlert(state: VerificationSessionStorageItem.VerififcationState, jid: String, sid: String) {
        DispatchQueue.main.async {
            var alert = UIAlertController()
            switch state {
            case .failed:
                let action = UIAlertAction(title: "Okay", style: .cancel)
                alert = UIAlertController(title: "", message: "Verification session with \(jid) failed.\nSID: \(sid)", preferredStyle: UIAlertController.Style.alert)
                alert.addAction(action)
            case .rejected:
                let action = UIAlertAction(title: "Okay", style: .cancel)
                alert = UIAlertController(title: "", message: "Verification session with \(jid) rejected.\nSID: \(sid)", preferredStyle: UIAlertController.Style.alert)
                alert.addAction(action)
            case .trusted:
                let action = UIAlertAction(title: "Okay", style: .cancel)
                alert = UIAlertController(title: "", message: "Verification session with \(jid) successful, the device is now trusted.\nSID: \(sid)", preferredStyle: UIAlertController.Style.alert)
                alert.addAction(action)
            default:
                DDLogDebug("AuthenticatedKeyExchangeManager: \(#function).")
                return
            }
            getAppTabBar()?.viewControllers?.first?.present(alert, animated: true)
        }
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(VerificationSessionStorageItem.self)
                .filter("owner == %@", owner)
            if commitTransaction {
                try realm.write {
                    realm.delete(collection)
                }
            } else {
                realm.delete(collection)
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
    }
}
