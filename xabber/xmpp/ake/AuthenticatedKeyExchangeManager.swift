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
import RxCocoa
import RxSwift

class AuthenticatedKeyExchangeManager: AbstractXMPPManager{
    static let showConfirmationViewNotification = NSNotification.Name("com.xabber.ios.ake.showConfirmationViewNotification")
    static let showSuccessViewNotification = NSNotification.Name("com.xabber.ios.ake.showSuccessViewNotification")
    static let showCodeInputViewNotification = NSNotification.Name("com.xabber.ios.ake.showCodeInputViewNotification")
    static let showCodeOutputViewNotification = NSNotification.Name("com.xabber.ios.ake.showCodeOutputViewNotification")
    
    enum State{
        case none
        case sentRequest
        case receivedRequest
        case acceptedRequest
        case hashSentToOpponent
        case hashSentToInitiator
        case trusted
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        subscribe()
    }
    
    deinit {
        unsubscribe()
    }
    
    override func namespaces() -> [String] {
        return [
            "urn:xabber:trust"
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    var bag: DisposeBag = DisposeBag()
    private var messageBag: BehaviorRelay<Array<XMPPMessage>> = BehaviorRelay(value: [])
    
    private final func generateByteSequence() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        
        guard status == errSecSuccess else {
            throw AuthenticatedKeyExchangeManagerError.secRandomCopyBytesFailed
        }
        
        return bytes
    }
    
    func subscribe() {
        bag = DisposeBag()
        messageBag.asObservable().debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance).subscribe { results in
            // creating a list of sids for new verification messages for further processing of each new or changed verification session (for displaying notifications and view controllers if necessary)
            let newVerificationMessagesSids = results.compactMap { result in
                let sid = self.processMessage(message: result)
                return sid
            }
            
            // invoke just unique sids
            var processedSessionsSid = Set(newVerificationMessagesSids)
            
            for sid in processedSessionsSid {
                do {
                    let realm = try WRealm.safe()
                    if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                        guard let timestamp = TimeInterval(instance.timestamp) else {
                            continue
                        }
                        
                        let jid = instance.jid
                        let sid = instance.sid
                        
                        var bodyNotification = ""
                        switch instance.state {
                        case .receivedRequest:
                            if jid == self.owner {
                                NotificationCenter.default.post(name: AuthenticatedKeyExchangeManager.showConfirmationViewNotification, object: self, userInfo: ["owner": self.owner, "sid": sid])
                            } else {
                                bodyNotification = "Verification request received"
                                self.showNotification(title: jid, owner: self.owner, body: bodyNotification, sid: sid, timestamp: timestamp)
                                
                                AccountManager.shared.find(for: self.owner)?.omemo.initChat(jid: jid)
                                self.makeSystemMessage(jid: jid, body: "Incoming verification request")
                                
                            }
                            
                        case .receivedRequestAccept:
                            bodyNotification = "Verification request accepted"
                            
                            if jid == self.owner {
                                NotificationCenter.default.post(name: AuthenticatedKeyExchangeManager.showCodeInputViewNotification, object: self, userInfo: ["owner": self.owner, "sid": sid])
                            } else {
                                self.showNotification(title: jid, owner: self.owner, body: bodyNotification, sid: sid, timestamp: timestamp)
                                self.makeSystemMessage(jid: jid, body: "Contact accepted the verification request")
                            }
                            
                        case .failed:
                            try realm.write {
                                realm.delete(instance)
                            }
                            bodyNotification = "Verification failed"
                            self.showNotification(title: jid, owner: self.owner, body: bodyNotification, sid: sid, timestamp: timestamp)
                            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "rejected_VerificationConfirmationViewController"), object: self, userInfo: ["sid": sid])
                            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "close_view"), object: self, userInfo: ["sid": sid])
                            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "AuthenticationCodeInputViewController"), object: self, userInfo: ["sid": sid])
                            
                            if jid != self.owner {
                                self.makeSystemMessage(jid: jid, body: "Verification failed")
                            }
                            
                        case .rejected:
                            try realm.write {
                                realm.delete(instance)
                            }
                            bodyNotification = "Verification rejected"
                            self.showNotification(title: jid, owner: self.owner, body: bodyNotification, sid: sid, timestamp: timestamp)
                            
                            if jid != self.owner {
                                self.makeSystemMessage(jid: jid, body: "Verification rejected")
                            }
                            
                        case .trusted:
                            if jid != self.owner {
                                self.makeSystemMessage(jid: jid, body: "Verification succeeded")
                            }
                            
                            let deviceId = instance.opponentDeviceId
                            
                            NotificationCenter.default.post(name: AuthenticatedKeyExchangeManager.showSuccessViewNotification,
                                                            object: self,
                                                            userInfo: [
                                                                "owner": self.owner,
                                                                "jid": jid,
                                                                "deviceId": String(deviceId)
                                                            ]
                            )
                            
                        default:
                            return
                        }
                    }
                } catch {
                    DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
                }
            }
            
            
        } onError: { _ in
            
        } onCompleted: {
            
        } onDisposed: {
            
        }.disposed(by: bag)
    }
    
    func unsubscribe() {
        bag = DisposeBag()
    }
    
    private final func generateCode() -> String {
//        return String.randomString(length: 6, includeNumber: true)
        return String(Int.random(in: 100000...999999))
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
    
    func getMessageChildsForVerififcationRequest(sid: String, ttl: Int, myDeviceId: Int, deviceId: String? = nil) -> DDXMLElement? {
        let authenticationKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticationKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        authenticationKeyExchange.addAttribute(withName: "timestamp", stringValue: String(Int(Date().timeIntervalSince1970.rounded())))
        
        let verificationStart = DDXMLElement(name: "verification-start")
        verificationStart.addAttribute(withName: "device-id", stringValue: String(myDeviceId))
        verificationStart.addAttribute(withName: "ttl", stringValue: String(ttl))
        if deviceId != nil {
            verificationStart.addAttribute(withName: "to-device-id", stringValue: deviceId!)
        }
        
        authenticationKeyExchange.addChild(verificationStart)
        
        return authenticationKeyExchange
    }
    
    func getMessageChildsForAcceptVerificationRequest(sid: String, myDeviceId: Int, encryptedByteSequence: String, iv: String) -> DDXMLElement {
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        authenticatedKeyExchange.addAttribute(withName: "timestamp", stringValue: String(Int(Date().timeIntervalSince1970.rounded())))
        
        let verificationAccept = DDXMLElement(name: "verification-accepted")
        verificationAccept.addAttribute(withName: "device-id", stringValue: String(myDeviceId))
        
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
        authenticatedKeyExchange.addAttribute(withName: "timestamp", stringValue: String(Int(Date().timeIntervalSince1970.rounded())))
        
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
        authenticatedKeyExchange.addAttribute(withName: "timestamp", stringValue: String(Int(Date().timeIntervalSince1970.rounded())))
        
        let verificationFailed = DDXMLElement(name: "verification-failed")
        verificationFailed.addAttribute(withName: "reason", stringValue: reason)
        
        authenticatedKeyExchange.addChild(verificationFailed)
        
        return authenticatedKeyExchange
    }
    
    func didReceivedVerificationMessage(message: XMPPMessage) -> Bool {
        guard let notify = message.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns) ?? message.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns),
              let messageContainer = notify.element(forName: "forwarded")?.element(forName: "message"),
              let authenticatedKeyExchange = messageContainer.element(forName: "authenticated-key-exchange", xmlns: getPrimaryNamespace()),
              XMPPMessage(from: messageContainer).from != nil,
              authenticatedKeyExchange.attributeStringValue(forName: "sid") != nil,
              authenticatedKeyExchange.attributeStringValue(forName: "timestamp") != nil else {
            return false
        }
        
        if XMPPMessage(from: messageContainer).from == AccountManager.shared.find(for: self.owner)?.xmppStream.myJID {
            return true
        }
        
        var value = messageBag.value
        value.append(message)
        messageBag.accept(value)
        
        return true
    }
    
    func processMessage(message: XMPPMessage) -> String? {
        guard let notify = message.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns),
              let messageContainer = notify.element(forName: "forwarded")?.element(forName: "message"),
              let authenticatedKeyExchange = messageContainer.element(forName: "authenticated-key-exchange", xmlns: getPrimaryNamespace()),
              let jid = XMPPMessage(from: messageContainer).from,
              let sid = authenticatedKeyExchange.attributeStringValue(forName: "sid") else {
            return nil
        }

        if let toDeviceId = authenticatedKeyExchange.element(forName: "verification-start")?.attributeStringValue(forName: "to-device-id") {
            guard isVerificationRequestAddressedToMyDevice(toDeviceId: toDeviceId) else {
                return nil
            }
        }
        
        switch true {
        case didVerificationStartReceived(authenticatedKeyExchange: authenticatedKeyExchange, jid: jid): break
        case didVerificationAcceptReceived(authenticatedKeyExchange: authenticatedKeyExchange, jid: jid): break
        case didHashFromInitiatorReceived(authenticatedKeyExchange: authenticatedKeyExchange, jid: jid): break
        case didHashFromRecipientReceived(authenticatedKeyExchange: authenticatedKeyExchange, jid: jid): break
        case didVerificationSuccessReceived(authenticatedKeyExchange: authenticatedKeyExchange, jid: jid): break
        case didVerificationRejectReceived(authenticatedKeyExchange: authenticatedKeyExchange, jid: jid): break
        case didVerificationFailureReceived(authenticatedKeyExchange: authenticatedKeyExchange, jid: jid): break
        default:
            return nil
        }
        
        return sid
    }
    
    func isVerificationRequestAddressedToMyDevice(toDeviceId: String) -> Bool {
        guard let myDeviceId = AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() else {
            DDLogDebug("AuthenticatedKeyExchange: \(#function).")
            return false
        }
        
        if String(myDeviceId) != toDeviceId {
            return false
        } else {
            return true
        }
    }
    
    func didVerificationStartReceived(authenticatedKeyExchange: DDXMLElement, jid: XMPPJID) -> Bool {
        guard let sid = authenticatedKeyExchange.attributeStringValue(forName: "sid"),
              let timestamp = authenticatedKeyExchange.attributeStringValue(forName: "timestamp"),
              let verificationStart = authenticatedKeyExchange.element(forName: "verification-start"),
              let opponentDeviceIdRaw = verificationStart.attributeStringValue(forName: "device-id"),
              let opponentDeviceID = Int(opponentDeviceIdRaw) else {
            return false
        }
        
        do {
            let realm = try WRealm.safe()
            if realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) != nil {
                return false
            }
            
            if let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid.bare, deviceId: opponentDeviceID)),
               deviceInstance.state == SignalDeviceStorageItem.TrustState.trusted {
                return false
            }
            
            let predicate = NSPredicate(format: "owner == %@ AND jid == %@", argumentArray: [self.owner, jid.bare])
            let oldInstances = realm.objects(VerificationSessionStorageItem.self).filter(predicate).sorted(byKeyPath: "timestamp", ascending: false)
            if !oldInstances.isEmpty {
                if oldInstances.first!.timestamp < timestamp {
                    try realm.write {
                        realm.delete(oldInstances)
                    }
                } else {
                    return false
                }
            }
            
            let ttlRaw = verificationStart.attributeStringValue(forName: "ttl")
            if ttlRaw == nil {
                return false
            }
            let ttl = TimeInterval(ttlRaw!)
            let secondsPassed = Date().timeIntervalSince1970 - TimeInterval(timestamp)!
            if secondsPassed >= ttl! {
                return false
            }
            
            guard let deviceIdRecipient = AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() else {
                return false
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
            instance.timestamp = timestamp
            instance.ttl = ttlRaw!
            
            try realm.write {
                realm.add(instance)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + (ttl! - secondsPassed)) {
                do {
                    try realm.write {
                        realm.delete(instance)
                    }
                    NotificationCenter.default.post(name: NSNotification.Name(rawValue: "close_view"), object: self, userInfo: ["sid": sid])
                } catch {
                    DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
                }
            }
            
            return true
            
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
            return false
        }
    }
    
    func didVerificationAcceptReceived(authenticatedKeyExchange: DDXMLElement, jid: XMPPJID) -> Bool {
        guard let sid = authenticatedKeyExchange.attributeStringValue(forName: "sid"),
              let timestamp = authenticatedKeyExchange.attributeStringValue(forName: "timestamp"),
              let verificationAccepted = authenticatedKeyExchange.element(forName: "verification-accepted"),
              let opponentDeviceIdRaw = verificationAccepted.attributeStringValue(forName: "device-id"),
              let opponentDeviceID = Int(opponentDeviceIdRaw) else {
            return false
        }
        
        var byteSequence: [UInt8]? = nil
        do {
            byteSequence = try self.generateByteSequence()
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        
        guard let byteSequence = byteSequence else {
            return false
        }
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                if instance.state != .sentRequest && instance.state != .receivedRequest {
                    return false
                }
        
                // if the accept verification message is from other device of user, that already accepted the request from contact
                let saltEncrypted = authenticatedKeyExchange.element(forName: "salt")?.element(forName: "ciphertext")?.stringValue
                let saltIv = authenticatedKeyExchange.element(forName: "salt")?.element(forName: "iv")?.stringValue
                if (saltEncrypted == nil && saltIv == nil) || instance.state != .sentRequest {
                    NotificationCenter.default.post(name: NSNotification.Name(rawValue: "rejected_VerificationConfirmationViewController"), object: self, userInfo: ["sid": sid])
                    try realm.write {
                        realm.delete(instance)
                    }
                    
                    return false
                }
                
                if instance.jid != jid.bare {
                    return false
                }
                
                try realm.write {
                    instance.fullJID = jid.full
                    instance.opponentDeviceId = opponentDeviceID
                    instance.byteSequence = byteSequence.toBase64()
                    instance.state = .receivedRequestAccept
                    instance.opponentByteSequenceEncrypted = saltEncrypted!
                    instance.opponentByteSequenceIv = saltIv!
                    instance.timestamp = timestamp
                }
                
                return true
                
            } else {
                return false
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
            return false
        }
    }
    
    func didHashFromInitiatorReceived(authenticatedKeyExchange: DDXMLElement, jid: XMPPJID) -> Bool {
        guard let sid = authenticatedKeyExchange.attributeStringValue(forName: "sid"),
              let hashEncrypted = authenticatedKeyExchange.element(forName: "hash"),
              let byteSequenceEncrypted = authenticatedKeyExchange.element(forName: "salt") else {
            return false
        }
        
        var deviceId: Int? = nil
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                guard instance.jid == jid.bare else {
                    return false
                }
                
                if instance.state == .receivedRequest {
                    try realm.write {
                        realm.delete(instance)
                    }
                    
                    return false
                }
                
                try realm.write {
                    instance.state = .hashSentToInitiator
                    instance.timestamp = String(Int(Date().timeIntervalSince1970.rounded()))
                }
                
                deviceId = instance.opponentDeviceId
                
            }
            
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
            return false
        }
        
        guard let fullJid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full,
              let deviceId = deviceId else {
            return false
        }
        
        if !checkHashFromInitiator(jid: jid.bare, sid: sid, deviceId: deviceId, hashEncrypted: hashEncrypted, byteSequenceEncrypted: byteSequenceEncrypted) {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "close_view"), object: self, userInfo: ["sid": sid])
            
            let child = self.getMessageChildsForErrorMessage(sid: sid, reason: "Hashes didn't match")
            
            let message = XMPPMessage(messageType: .chat, to: jid, elementID: UUID().uuidString, child: child)
            message.addAttribute(withName: "from", stringValue: fullJid)
            
            let iq = self.getNotificationContainer(message: message, notificationTo: jid)
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                stream.send(iq)
            })
            
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                    try realm.write {
                        instance.state = .failed
                        instance.timestamp = String(Date().timeIntervalSince1970)
                    }
                    
                }
            } catch {
                DDLogDebug("AuthenticatedKeyExchange: \(#function). \(error.localizedDescription)")
                return false
            }
            
            return true
        }
        
        guard let hash = self.calculateHashForInitiator(jid: jid.bare, sid: sid) else {
            return false
        }
        
        var hashCiphertext: [UInt8]? = nil
        var hashIv: [UInt8]? = nil
        
        do {
            (hashCiphertext, hashIv) = try self.encrypt(jid: jid.bare, sid: sid, deviceId: deviceId, data: hash)
            
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        
        guard let hashCiphertext = hashCiphertext,
              let hashIv = hashIv else {
            return false
        }
        
        let authenticatedKeyExchangeChild = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchangeChild.addAttribute(withName: "sid", stringValue: sid)
        authenticatedKeyExchangeChild.addAttribute(withName: "timestamp", stringValue: String(Int(Date().timeIntervalSince1970.rounded())))
        let hashChild = DDXMLElement(name: "hash")
        hashChild.addAttribute(withName: "algo", stringValue: "sha-256")
        hashChild.addChild(DDXMLElement(name: "ciphertext", stringValue: hashCiphertext.toBase64()))
        hashChild.addChild(DDXMLElement(name: "iv", stringValue: hashIv.toBase64()))
        authenticatedKeyExchangeChild.addChild(hashChild)
        
        let message = XMPPMessage(messageType: .chat, to: jid, elementID: UUID().uuidString, child: authenticatedKeyExchangeChild)
        message.addAttribute(withName: "from", stringValue: fullJid)
        
        let iq = self.getNotificationContainer(message: message, notificationTo: jid)
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
        
        return true
    }
    
    func didHashFromRecipientReceived(authenticatedKeyExchange: DDXMLElement, jid: XMPPJID) -> Bool {
        guard let sid = authenticatedKeyExchange.attributeStringValue(forName: "sid"),
              let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore,
              let hashEncrypted = authenticatedKeyExchange.element(forName: "hash") else {
            return false
        }
        
        let deviceIdRecipient = localStore.localDeviceId()
        
        var deviceId: Int? = nil
        var byteSequence: [UInt8]? = nil
        var opponentByteSequence: [UInt8]? = nil
        var code: String? = nil
        
        var omemoFingerprint = ""
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)),
               let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid.bare, deviceId: instance.opponentDeviceId)) {
                
                if instance.jid != jid.bare || instance.state != .hashSentToOpponent {
                    return false
                }
                
                try realm.write {
                    instance.state = .hashSentToInitiator
                    instance.timestamp = String(Int(Date().timeIntervalSince1970.rounded()))
                }
                
                omemoFingerprint = deviceInstance.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
                
                deviceId = instance.opponentDeviceId
                code = instance.code
                byteSequence = try instance.byteSequence.base64decoded()
                opponentByteSequence = try instance.opponentByteSequence.base64decoded()
                
                
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return false
        }
        
        guard let deviceId = deviceId,
              let byteSequence = byteSequence,
              let opponentByteSequence = opponentByteSequence,
              let code = code else {
            return false
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
            
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                if hash != myHash {
                    try realm.write {
                        instance.state = .failed
                        instance.timestamp = String(Date().timeIntervalSince1970)
                    }
                    
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        user.akeManager.sendErrorMessage(fullJID: jid, sid: sid, reason: "Hashes didn't match")
                    })
                    
                    return true
                    
                } else {
                    try realm.write {
                        instance.state = .trusted
                        instance.timestamp = String(Date().timeIntervalSince1970)
                    }
                    
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return false
        }
        
        self.writeTrustedDevice(jid: jid.bare, deviceId: deviceId)
        
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            user.akeManager.sendSuccessfulVerificationMessage(toJid: jid, sid: sid)
            
            if self.owner == jid.bare {
                user.trustSharingManager.sendListOfContactsDevices()
                user.trustSharingManager.publicOwnTrustedDevices(publisherDeviceId: String(deviceIdRecipient))
                user.trustSharingManager.getUserTrustedDevices(jid: jid.bare, deviceId: String(deviceId))
                
            } else {
                user.trustSharingManager.sendListOfContactsDevices()
                user.trustSharingManager.getUserTrustedDevices(jid: jid.bare, deviceId: String(deviceId))
                
            }
        }
        
        return true
    }
    
    func didVerificationSuccessReceived(authenticatedKeyExchange: DDXMLElement, jid: XMPPJID) -> Bool {
        guard authenticatedKeyExchange.element(forName: "verification-successful") != nil,
              let sid = authenticatedKeyExchange.attributeStringValue(forName: "sid"),
              let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
            return false
        }
        
        let deviceIdRecipient = localStore.localDeviceId()
        
        var deviceId: Int? = nil
        
        do {
            let realm = try WRealm.safe()
            
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                if instance.jid != jid.bare || instance.state != .hashSentToInitiator {
                    return false
                }
                
                try realm.write {
                    instance.state = .trusted
                }
                
                deviceId = instance.opponentDeviceId
                
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchange: \(#function). \(error.localizedDescription)")
            return false
        }
        
        guard let deviceId = deviceId else {
            return false
        }
        
        self.writeTrustedDevice(jid: jid.bare, deviceId: deviceId)
        
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            if self.owner == jid.bare {
                user.trustSharingManager.sendListOfContactsDevices()
                user.trustSharingManager.getUserTrustedDevices(jid: jid.bare, deviceId: String(deviceId))
                user.trustSharingManager.publicOwnTrustedDevices(publisherDeviceId: String(deviceIdRecipient))
            } else {
                user.trustSharingManager.sendListOfContactsDevices()
                user.trustSharingManager.getUserTrustedDevices(jid: jid.bare, deviceId: String(deviceId))
            }
        }
        
        return true
    }
    
    func didVerificationRejectReceived(authenticatedKeyExchange: DDXMLElement, jid: XMPPJID) -> Bool {
        guard authenticatedKeyExchange.element(forName: "verification-rejected") != nil,
              let sid = authenticatedKeyExchange.attributeStringValue(forName: "sid"),
              let timestamp = authenticatedKeyExchange.attributeStringValue(forName: "timestamp") else {
            return false
        }
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                if instance.jid != jid.bare && jid.bare != self.owner
                    || instance.state != .sentRequest && instance.state != .receivedRequest {
                    return false
                }
                
                if instance.state == .receivedRequest {
                    try realm.write {
                        realm.delete(instance)
                    }
                    
                    NotificationCenter.default.post(name: NSNotification.Name(rawValue: "rejected_VerificationConfirmationViewController"), object: self, userInfo: ["sid": sid])
                    return false
                    
                } else {
                    try realm.write {
                        instance.state = .rejected
                        instance.timestamp = timestamp
                    }
                }
                
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "rejected_VerificationConfirmationViewController"), object: self, userInfo: ["sid": sid])
                return true
                
            } else {
                return false
            }
            
        } catch {
            DDLogDebug("AuthenticatedKeyExchange: \(#function). \(error.localizedDescription)")
            return false
        }
    }
    
    func didVerificationFailureReceived(authenticatedKeyExchange: DDXMLElement, jid: XMPPJID) -> Bool {
        guard authenticatedKeyExchange.element(forName: "verification-failed") != nil,
              let sid = authenticatedKeyExchange.attributeStringValue(forName: "sid") else {
            return false
        }
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                if jid.bare != instance.jid {
                    return false
                }
                
                if instance.state == .receivedRequest {
                    try realm.write {
                        realm.delete(instance)
                    }
                    
                    NotificationCenter.default.post(name: NSNotification.Name(rawValue: "close_view"), object: self, userInfo: ["sid": sid])
                    return false
                    
                } else {
                    try realm.write {
                        instance.state = .failed
                    }
                }
                
                return true
                
            } else {
                return false
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchange: \(#function). \(error.localizedDescription)")
            return false
        }
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
        var ttl: Int
        if jid == self.owner {
            ttl = 300
        } else {
            ttl = 86400
        }
        
        guard let myDeviceId = AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() else {
            return
        }
        
        do {
            let realm = try WRealm.safe()
            
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
            instance.timestamp = String(Int(Date().timeIntervalSince1970.rounded()))
            instance.ttl = String(ttl)
            try realm.write {
                realm.add(instance)
            }
            
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return
        }
        
        if jid != self.owner {
            AccountManager.shared.find(for: self.owner)?.omemo.initChat(jid: jid)
            makeSystemMessage(jid: jid, body: "Outgoing verification request")
        }
        
        let fullJid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full
        let toJid = XMPPJID(string: jid)
        if fullJid == nil || toJid == nil {
            DDLogDebug("AuthenticatedKeyExchange: \(#function).")
            return
        }
        
        let childs = self.getMessageChildsForVerififcationRequest(sid: sid, ttl: ttl, myDeviceId: myDeviceId, deviceId: deviceId)
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: jid), elementID: UUID().uuidString, child: childs)
        message.addAttribute(withName: "from", stringValue: fullJid!)
        
        let iq = self.getNotificationContainer(message: message, notificationTo: toJid!)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
    }
    
    @objc
    static func checkVerificationSessionsTTL() {
        let users = AccountManager.shared.users.compactMap { user in
            return user.jid
        }
        
        do {
            let realm = try WRealm.safe()
            let instances = realm.objects(VerificationSessionStorageItem.self).filter("owner IN %@ AND state_ IN %@", users, [VerificationSessionStorageItem.VerififcationState.sentRequest.rawValue, VerificationSessionStorageItem.VerififcationState.receivedRequest.rawValue])
            
            instances.forEach { item in
                if TimeInterval(item.ttl) ?? 0 <= Date().timeIntervalSince1970 - (TimeInterval(item.timestamp) ?? 0) {
                    do {
                        let realm = try WRealm.safe()
                        
                        try realm.write {
                            realm.delete(item)
                        }
                    } catch {
                        DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func acceptVerificationRequest(jid: String, sid: String) -> String? {
        let code = self.generateCode()
        
        var deviceId: Int? = nil
        var fullJID: String? = nil
        
        var byteSequence: [UInt8]? = nil
        do {
            byteSequence = try self.generateByteSequence()
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        
        guard let byteSequence = byteSequence else {
            return nil
        }
        
        do {
            let realm = try WRealm.safe()
            
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                try realm.write {
                    instance.code = code
                    instance.state = .acceptedRequest
                    instance.byteSequence = byteSequence.toBase64()
                    instance.timestamp = String(Int(Date().timeIntervalSince1970.rounded()))
                }
                
                deviceId = instance.opponentDeviceId
                fullJID = instance.fullJID
                
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return nil
        }
        
        guard let deviceId = deviceId,
              let fullJID = fullJID,
              let myFullJid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full,
              let toJid = XMPPJID(string: fullJID)?.bareJID else {
            return nil
        }
        
        var saltCiphertext: [UInt8]? = nil
        var saltIv: [UInt8]? = nil
        
        do {
            (saltCiphertext, saltIv) = try self.encrypt(jid: jid, sid: sid, deviceId: deviceId, data: byteSequence)
            
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
            return nil
        }
        
        guard let saltCiphertext = saltCiphertext,
              let saltIv = saltIv,
              let myDeviceId = AccountManager.shared.find(for: self.owner)?.omemo.localStore.localDeviceId() else {
            return nil
        }
        
        let child = self.getMessageChildsForAcceptVerificationRequest(sid: sid, myDeviceId: myDeviceId, encryptedByteSequence: saltCiphertext.toBase64(), iv: saltIv.toBase64())
        
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
            
            makeSystemMessage(jid: jid, body: "You accepted the verification request")
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
        var deviceId: Int? = nil
        var byteSequence: [UInt8]? = nil
        var opponentByteSequence: [UInt8]? = nil
        var code: String? = nil
        var myTrustedKey: String? = nil
        
        do {
            let realm = try WRealm.safe()
            
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)),
               let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: instance.myDeviceId)) {
                
                try realm.write {
                    instance.state = .hashSentToOpponent
                    instance.timestamp = String(Int(Date().timeIntervalSince1970.rounded()))
                }
                
                deviceId = instance.opponentDeviceId
                byteSequence = try instance.byteSequence.base64decoded()
                opponentByteSequence = try instance.opponentByteSequence.base64decoded()
                code = instance.code
                
                let omemoFingerprint = deviceInstance.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
                myTrustedKey = String(deviceInstance.deviceId) + "::" + omemoFingerprint
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
            return
        }
        
        guard let deviceId = deviceId,
              let byteSequence = byteSequence,
              let opponentByteSequence = opponentByteSequence,
              let code = code,
              let myTrustedKey = myTrustedKey else {
            return
        }
        
        let stringToHash = myTrustedKey.bytes + code.bytes + opponentByteSequence
        let hash = Array(SHA256.hash(data: stringToHash).makeIterator())
        
        var hashCiphertext: [UInt8]? = nil
        var hashIv: [UInt8]? = nil
        var saltCiphertext: [UInt8]? = nil
        var saltIv: [UInt8]? = nil
        
        do {
            (hashCiphertext, hashIv) = try self.encrypt(jid: jid.bare, sid: sid, deviceId: deviceId, data: hash)
            (saltCiphertext, saltIv) = try self.encrypt(jid: jid.bare, sid: sid, deviceId: deviceId, data: byteSequence)
            
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        
        guard let hashCiphertext = hashCiphertext,
              let hashIv = hashIv,
              let saltCiphertext = saltCiphertext,
              let saltIv = saltIv else {
            return
        }
            
        let child = self.getMessageChildsToSendHashAndSaltToOpponent(sid: sid, encryptedHash: hashCiphertext.toBase64(), ivHash: hashIv.toBase64(), encryptedSalt: saltCiphertext.toBase64(), ivSalt: saltIv.toBase64())
        
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
        authenticatedKeyExchange.addAttribute(withName: "timestamp", stringValue: String(Int(Date().timeIntervalSince1970.rounded())))
        
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
    
    func processSecretCode(code: String, sid: String) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                try realm.write {
                    instance.code = code
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
            
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            var jid: String? = nil
            
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                    jid = instance.jid
                    let deviceId = instance.opponentDeviceId
                    let saltCiphertext = instance.opponentByteSequenceEncrypted
                    let saltIv = instance.opponentByteSequenceIv
                    
                    guard let jid = jid else {
                        return
                    }
                    
                    let salt = try user.akeManager.decrypt(
                        jid: jid,
                        sid: sid,
                        deviceId: deviceId,
                        ciphertext: try saltCiphertext.base64decoded(),
                        iv: try saltIv.base64decoded()
                    )
                    
                    try realm.write {
                        instance.opponentByteSequence = salt.toBase64()
                    }
                }
            } catch {
                DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
                return
            }
            
            guard let xmppJid = XMPPJID(string: jid ?? "") else {
                return
            }
            
            user.akeManager.sendHashToOpponent(jid: xmppJid, sid: sid)
        }
    }
    
    func checkHashFromInitiator(jid: String, sid: String, deviceId: Int, hashEncrypted: DDXMLElement, byteSequenceEncrypted: DDXMLElement) -> Bool {
        let hash = self.decryptElementFromXML(jid: jid, sid: sid, deviceId: deviceId, encryptedXML: hashEncrypted)
        guard let opponentByteSequence = self.decryptElementFromXML(jid: jid, sid: sid, deviceId: deviceId, encryptedXML: byteSequenceEncrypted) else {
            return false
        }
        
        var deviceId: String? = nil
        var code: String? = nil
        var byteSequence: [UInt8]? = nil
        var omemoFingerprint: String? = nil
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                try realm.write {
                    instance.opponentByteSequence = opponentByteSequence.toBase64()
                }
                
                deviceId = String(instance.opponentDeviceId)
                code = instance.code
                byteSequence = try instance.byteSequence.base64decoded()
                
                if let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: Int(deviceId ?? "") ?? -1)) {
                    omemoFingerprint = deviceInstance.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
            return true
        }
        
        guard let deviceId = deviceId,
              let code = code,
              let byteSequence = byteSequence,
              let omemoFingerprint = omemoFingerprint else {
            return false
        }
        
        let opponentTrustedKey = deviceId + "::" + omemoFingerprint
        
        let stringToHash = Data(opponentTrustedKey.bytes + code.bytes + byteSequence)
        let myHash = Array(SHA256.hash(data: stringToHash).makeIterator())
        
        if hash != myHash {
            return false
        }
        
        return true
    }
    
    func calculateHashForInitiator(jid: String, sid: String) -> [UInt8]? {
        var code: String? = nil
        var byteSequence: [UInt8]? = nil
        var opponentByteSequence: [UInt8]? = nil
        var omemoFingerprint: String? = nil
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                try realm.write {
                    instance.state = .hashSentToInitiator
                    instance.timestamp = String(Int(Date().timeIntervalSince1970.rounded()))
                }
                
                code = instance.code
                byteSequence = try instance.byteSequence.base64decoded()
                opponentByteSequence = try instance.opponentByteSequence.base64decoded()
                
                let myDeviceId = instance.myDeviceId
                
                if let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: myDeviceId)) {
                    omemoFingerprint = deviceInstance.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        
        guard let code = code,
              let byteSequence = byteSequence,
              let opponentByteSequence = opponentByteSequence,
              let omemoFingerprint = omemoFingerprint,
              let localDeviceId = AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() else {
            return nil
        }
        
        let trustedKey = (String(localDeviceId) + "::" + omemoFingerprint).bytes
        
        let stringToHash = trustedKey + Array(code.utf8) + byteSequence + opponentByteSequence
        let hash = Array(SHA256.hash(data: stringToHash).makeIterator())

        return hash
    }
    
    func encrypt(jid: String, sid: String, deviceId: Int, data: Array<UInt8>) throws -> (encrypted: [UInt8], iv: [UInt8]) {
        let sharedKey = calculateSharedKey(jid: jid, deviceId: deviceId)
        let encryptionKey = calculateEncryptionKey(jid: jid, sid: sid, sharedKey: sharedKey)
        var iv = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv)
        guard status == errSecSuccess else {
            throw AuthenticatedKeyExchangeManagerError.secRandomCopyBytesFailed
        }
        
        do {
            let aes = try AES(key: encryptionKey, blockMode: CBC(iv: iv))
            let encrypted = try aes.encrypt(data)
            
            return (encrypted: encrypted, iv: iv)
        } catch {
            throw error
        }
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
        
        do {
            let decryptedValue = try decrypt(jid: jid, sid: sid, deviceId: deviceId, ciphertext: ciphertext!, iv: iv!)
            
            return decryptedValue
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
            return nil
        }
    }
    
    func decrypt(jid: String, sid: String, deviceId: Int, ciphertext: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        let sharedKey = calculateSharedKey(jid: jid, deviceId: deviceId)
        let encryptionKey = calculateEncryptionKey(jid: jid, sid: sid, sharedKey: sharedKey)
        var decrypted: [UInt8] = []
        
        do {
            let aes = try AES(key: encryptionKey, blockMode: CBC(iv: iv))
            decrypted = try aes.decrypt(ciphertext)
        } catch {
            throw error
        }
        
        return decrypted
    }
    
    func rejectRequestToVerify(jid: String, sid: String) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                try realm.write {
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return
        }
        
        let timestamp = Int(Date().timeIntervalSince1970.rounded())
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
    
    func cancelVerificationSession(sid: String) {
        var jid = ""
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) {
                jid = instance.jid
                try realm.write {
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("VerificationViewController: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            user.akeManager.sendErrorMessage(fullJID: XMPPJID(string: jid)!, sid: sid, reason: "Сontact canceled verification session")
        }
    }
    
    func showNotification(title: String, owner: String, body: String, sid: String, timestamp: TimeInterval) {
        NotifyManager.shared.update(withVerificationMessage: body, owner: owner, displayName: title, sid: sid, timestamp: timestamp)
        NotifyManager.shared.showNotify(forType: .verification)
    }
    
    func makeSystemMessage(jid: String, body: String) {
        do {
            let realm = try WRealm.safe()
            
            let item = MessageStorageItem()
            item.messageId = UUID().uuidString
            item.owner = self.owner
            item.body = body
            item.opponent = jid
            item.outgoing = true
            item.isRead = true
            item.displayAs = .system
            item.conversationType = .omemo
            item.updatePrimary(system: true, auth: false)
            
            try realm.write {
                _ = item.save(commitTransaction: false)
            }
            
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: item.opponent,
                    owner: item.owner,
                    conversationType: item.conversationType
                )
            ) {
                try realm.write {
                    instance.lastMessage = item
                    // timestamp from message
                    instance.messageDate = Date()
                }
            }
            
        } catch {
            DDLogDebug("AuthenticatedKeyExchange: \(#function). \(error.localizedDescription)")
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
    
    static func prepare() {
        let timer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(self.checkVerificationSessionsTTL),
            userInfo: nil,
            repeats: true
        )
        RunLoop.current.add(timer, forMode: .default)
        
        do {
            let realm = try WRealm.safe()
            let jids = AccountManager.shared.users.compactMap { return $0.jid }
            for owner in jids {
                if let ownVerification = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@ AND state_ == %@", owner, owner, VerificationSessionStorageItem.VerififcationState.receivedRequest.rawValue).first {
                    
                    let sid = ownVerification.sid
                    
                    NotificationCenter.default.post(name: AuthenticatedKeyExchangeManager.showConfirmationViewNotification, object: self, userInfo: ["owner": owner, "sid": sid])
                }
            }
            
        } catch {
            DDLogDebug("AuthenticatedKeyExchange: \(#function). \(error.localizedDescription)")
        }
    }
}

enum AuthenticatedKeyExchangeManagerError: Error {
    case secRandomCopyBytesFailed
}

