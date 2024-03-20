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

// TODO: пуш при входящем запросе или ответе на запрос, если пользователь находится вне приложения, локальное уведомление, если пользователь находится в приложении
// TODO: отображение окна с вводом кода при нажатии на ячейку в списке чатов
// TODO: удаление ячейки с запросом при принятии или отклонении запроса
// TODO: обновление списка чатов при неверном вводе кода (ячейка с сессией должна пропасть)
// TODO: контроллер ввода кода и отображения кода переместить

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
    
    internal var keyPair: SignalIdentityKeyPair? = nil
    internal var deviceID: Int? = nil
    internal var trustedKey: [UInt8]? = nil
    
    override func onStreamPrepared(_ stream: XMPPStream) {
        guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
            return
        }
        self.keyPair = localStore.getIdentityKeyPair()
        self.deviceID = localStore.localDeviceId()
        
        guard self.keyPair != nil,
              self.deviceID != nil else {
            return
        }
        
        let publicKey = Array(self.keyPair!.publicKey.dropFirst())
        let fingerprint = publicKey.toHexString()
        
        self.trustedKey = (String(self.deviceID!) + "::" + fingerprint).bytes
    }
    
    func generateByteSequence() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes
        } else {
            DDLogDebug("AuthenticationKeyExchangeManager: \(#function)")
            fatalError()
        }
    }
    
    func generateCode() -> String {
        return String.randomString(length: 6, includeNumber: true)
    }
    
    func calculateSharedKey(jid: String, deviceId: Int) -> [UInt8] {
        let keyPair = Curve25519.load(fromPublicKey: self.keyPair?.publicKey, andPrivateKey: self.keyPair?.privateKey)
        let opponentPublicKey = getUsersPublicKey(jid: jid, deviceId: deviceId)
        
        let sharedKey = Array(Curve25519.generateSharedSecret(fromPublicKey: Data(opponentPublicKey), andKeyPair: keyPair))
        return sharedKey
    }
    
    func calculateEncryptionKey(jid: String, sid: String, sharedKey: [UInt8]) -> [UInt8] {
        var code: String = ""
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid, sid: sid))
            code = instance!.code
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        let stringToHash = sharedKey + Array(SHA256.hash(data: (code.bytes)).makeIterator())
        let encryptionKey = Array(SHA256.hash(data: stringToHash).makeIterator())
        return encryptionKey
    }
    
    // TODO: use this method
    func sendMessage(message: XMPPMessage) {
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(message)
        })
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
    
    func getMessageChildsForVerififcationRequest(sid: String) -> DDXMLElement {
        let authenticationKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticationKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        
        let verificationStart = DDXMLElement(name: "verification-start")
        verificationStart.addAttribute(withName: "device-id", stringValue: String(self.deviceID!))
        
        authenticationKeyExchange.addChild(verificationStart)
        
        return authenticationKeyExchange
    }
    
    func getMessageChildsForAcceptVerificationRequest(sid: String, encryptedByteSequence: String, iv: String) -> DDXMLElement {
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        
        let verificationAccept = DDXMLElement(name: "verification-accepted")
        verificationAccept.addAttribute(withName: "device-id", stringValue: String(self.deviceID!))
        
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
        
        let verificationFailed = DDXMLElement(name: "verification-failed")
        verificationFailed.addAttribute(withName: "reason", stringValue: reason)
        
        authenticatedKeyExchange.addChild(verificationFailed)
        
        return authenticatedKeyExchange
    }
    
    func didReceivedVerificationMessage(_ message: XMPPMessage) -> Bool {
        // TODO: implement archive
        if isArchivedMessage(message) {
            return false
        } else if isCarbonCopy(message) {
            return false
        } else if isCarbonForwarded(message) {
            return false
        } else  {
            guard let authenticatedKeyExchange = message.element(forName: "authenticated-key-exchange", xmlns: getPrimaryNamespace()),
                  let jid = message.from,
                  let sid = authenticatedKeyExchange.attributeStringValue(forName: "sid") else {
                return false
            }
            
            if authenticatedKeyExchange.element(forName: "verification-start") != nil {
                do {
                    let realm = try WRealm.safe()
                    if realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid.bare, sid: sid)) != nil {
                        return true
                    }
                    guard let verificationStart = authenticatedKeyExchange.element(forName: "verification-start"),
                          let opponentDeviceID = Int((verificationStart.attributeStringValue(forName: "device-id"))!) else {
                        DDLogDebug("Opponent device ID is not specified")
                        return true
                    }
                    
                    let predicate = NSPredicate(format: "owner == %@ AND myDeviceId == %@ AND opponentDeviceId == %@", argumentArray: [self.owner, self.deviceID!, opponentDeviceID])
                    let oldInstances = realm.objects(VerificationSessionStorageItem.self).filter(predicate)
                    if !oldInstances.isEmpty {
                        try realm.write {
                            realm.delete(oldInstances)
                        }
                    }
                    
                    let instance = VerificationSessionStorageItem()
                    instance.owner = self.owner
                    instance.myDeviceId = self.deviceID!
                    instance.jid = jid.bare
                    instance.fullJID = jid.full
                    instance.sid = sid
                    instance.opponentDeviceId = opponentDeviceID
                    instance.state = .receivedRequest
                    instance.primary = VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid.bare, sid: sid)
                    try realm.write {
                        realm.add(instance)
                    }
                } catch {
                    DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
                    fatalError()
                }
                
//                self.acceptVerificationRequest(jid: jid, sid: sid)
                
                return true
            } else if authenticatedKeyExchange.element(forName: "verification-accepted") != nil {
                let byteSequence = self.generateByteSequence()
                
                do {
                    let realm = try WRealm.safe()
                    guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid.bare, sid: sid)) else {
                        return true
                    }
                    if instance.state != .sentRequest {
                        return true
                    }
                    
                    guard let verificationAccepted = authenticatedKeyExchange.element(forName: "verification-accepted"),
                          let opponentDeviceID = Int((verificationAccepted.attributeStringValue(forName: "device-id"))!),
                          let sid = authenticatedKeyExchange.attributeStringValue(forName: "sid"),
                          let saltEncrypted = authenticatedKeyExchange.element(forName: "salt")?.element(forName: "ciphertext")?.stringValue,
                          let saltIv = authenticatedKeyExchange.element(forName: "salt")?.element(forName: "iv")?.stringValue else {
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
                    }
                } catch {
                    DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
                    fatalError()
                }
                
                return true
            } else if authenticatedKeyExchange.element(forName: "hash") != nil && authenticatedKeyExchange.element(forName: "salt") != nil {
                guard let hashEncrypted = authenticatedKeyExchange.element(forName: "hash"),
                      let byteSequenceEncrypted = authenticatedKeyExchange.element(forName: "salt") else {
                    return false
                }
                
                var deviceId: Int = 0
                
                do {
                    let realm = try WRealm.safe()
                    guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid.bare, sid: sid)) else {
                        return true
                    }
                    if instance.state != .acceptedRequest {
                        return true
                    }
                    
                    deviceId = instance.opponentDeviceId
                    
                    try realm.write {
                        instance.state = .hashSentToInitiator
                    }
                } catch {
                    DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
                }
                
                if !checkHashFromInitiator(jid: jid.bare, sid: sid, deviceId: deviceId, hashEncrypted: hashEncrypted, byteSequenceEncrypted: byteSequenceEncrypted) {
                    let child = self.getMessageChildsForErrorMessage(sid: sid, reason: "Hashes didn't match")
                    let message = XMPPMessage(messageType: .chat, to: jid, elementID: UUID().uuidString, child: child)
                    self.sendMessage(message: message)
                    return true
                }
                let hash = self.calculateHashForInitiator(jid: jid.bare, sid: sid)
                let encryptedHashResult = self.encrypt(jid: jid.bare, sid: sid, deviceId: deviceId, data: hash)
                
                let authenticatedKeyExchangeChild = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
                authenticatedKeyExchangeChild.addAttribute(withName: "sid", stringValue: sid)
                
                let hashChild = DDXMLElement(name: "hash")
                hashChild.addAttribute(withName: "algo", stringValue: "sha-256")
                hashChild.addChild(DDXMLElement(name: "ciphertext", stringValue: encryptedHashResult.encrypted.toBase64()))
                hashChild.addChild(DDXMLElement(name: "iv", stringValue: encryptedHashResult.iv.toBase64()))
                
                authenticatedKeyExchangeChild.addChild(hashChild)
                
                let message = XMPPMessage(messageType: .chat, to: jid, elementID: UUID().uuidString, child: authenticatedKeyExchangeChild)
                self.sendMessage(message: message)
                
                return true
            } else if authenticatedKeyExchange.element(forName: "hash") != nil {
                guard let hashEncrypted = authenticatedKeyExchange.element(forName: "hash") else {
                    return false
                }
                
                var deviceId: Int = 0
//                var publicKey: [UInt8] = []
//                var fingerprint: String = ""
                var byteSequence: [UInt8] = []
                var opponentByteSequence: [UInt8] = []
                var code: String = ""
                
                do {
                    let realm = try WRealm.safe()
                    let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid.bare, sid: sid))
                    if instance?.state != .hashSentToOpponent {
                        return true
                    }
                    deviceId = instance!.opponentDeviceId
                    code = instance!.code
                    byteSequence = try instance!.byteSequence.base64decoded()
                    opponentByteSequence = try instance!.opponentByteSequence.base64decoded()
                    
                    try realm.write {
                        instance?.state = .hashSentToInitiator
                    }
                    
//                    let storedBundle = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: jid.bare, deviceId: deviceId))
//                    publicKey = try Array(storedBundle!.identityKey!.base64decoded().dropFirst())
                    
//                    let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid.bare, deviceId: deviceId))
//                    fingerprint = device!.fingerprint
                    
                } catch {
                    DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
                    fatalError()
                }
                
                let publicKey = self.getUsersPublicKey(jid: jid.bare, deviceId: deviceId)
                let fingerprint = publicKey.toHexString()
                
                let hash = self.decryptElementFromXML(jid: jid.bare,
                                                      sid: sid,
                                                      deviceId: deviceId,
                                                      encryptedXML: hashEncrypted)
                
//                let stringForTrustedKey = String(deviceId).data(using: String.Encoding.utf8)! + publicKey
//                let stringForTrustedKey = String(deviceId) + fingerprint
//                
//                let opponentTrustedKey = Array(SHA256.hash(data: (stringForTrustedKey).bytes).makeIterator())
                
                let opponentTrustedKey = String(deviceId) + "::" + fingerprint
                
                let stringToHash = opponentTrustedKey.bytes + Array(code.utf8) + opponentByteSequence + byteSequence
                let myHash = Array(SHA256.hash(data: stringToHash).makeIterator())
                
                if hash != myHash {
                    do {
                        let realm = try WRealm.safe()
                        let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid.bare, sid: sid))
                        try realm.write {
                            realm.delete(instance!)
                        }
                    } catch {
                        DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
                        fatalError()
                    }
                    sendErrorMessage(fullJID: jid, sid: sid, reason: "Hashes didn't match")
                    
                    return true
                }
                
                self.writeTrustedDevice(jid: jid.bare, deviceId: deviceId)
                self.sendSuccessfulVerificationMessage(fullJID: jid, sid: sid)
                
                return true
            } else if authenticatedKeyExchange.element(forName: "verification-successful") != nil {
                var deviceId: Int = 0
                do {
                    let realm = try WRealm.safe()
                    let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid.bare, sid: sid))
                    if instance?.state != .hashSentToInitiator {
                        return true
                    }
                    deviceId = instance!.opponentDeviceId
                } catch {
                    fatalError()
                }
                self.writeTrustedDevice(jid: jid.bare, deviceId: deviceId)
            } else if authenticatedKeyExchange.element(forName: "verification-rejected") != nil {
                do {
                    let realm = try WRealm.safe()
                    guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid.bare, sid: sid)) else {
                        return true
                    }
                    try realm.write {
                        realm.delete(instance)
                    }
                } catch {
                    fatalError()
                }
            }
        }
        return true
    }
    
    func writeTrustedDevice(jid: String, deviceId: Int) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: deviceId)) {
                try realm.write {
                    instance.state = .trusted
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    // TODO: use this function when messages received, add all elements
    func processReceivedData(jid: String, sid: String, message: XMPPMessage) {
        guard let authenticatedKeyExchange = message.element(forName: "authenticated-key-exchange") else {
            fatalError()
        }
        
        var deviceId: Int = 0
        var salt: String = ""
        
        if let verificationAccepted = authenticatedKeyExchange.element(forName: "verification-accepted") {
            deviceId = Int(verificationAccepted.attributeStringValue(forName: "device-id")!)!
        }
        
        if let saltXML = authenticatedKeyExchange.element(forName: "salt") {
            salt = (self.decryptElementFromXML(jid: jid, sid: sid, deviceId: deviceId, encryptedXML: saltXML)?.toBase64())!
        }
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid, sid: sid))
            try realm.write {
                if salt != "" {
                    instance?.opponentByteSequence = salt
                }
                if deviceId != 0 {
                    instance?.opponentDeviceId = deviceId
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func sendVerificationRequest(jid: String) {
        let sid = UUID().uuidString
        do {
            let realm = try WRealm.safe()
            
            let predicate = NSPredicate(format: "owner == %@ AND myDeviceId == %@ AND jid == %@ AND state_ == %@", argumentArray: [self.owner, self.deviceID!, jid, VerificationSessionStorageItem.VerififcationState.sentRequest.rawValue])
            let oldInstances = realm.objects(VerificationSessionStorageItem.self).filter(predicate)
            if !oldInstances.isEmpty {
                try realm.write {
                    realm.delete(oldInstances)
                }
            }
            
            let instance = VerificationSessionStorageItem()
            instance.owner = self.owner
            instance.myDeviceId = self.deviceID!
            instance.jid = jid
            instance.sid = sid
            instance.state = .sentRequest
            instance.primary = VerificationSessionStorageItem.genPrimary(owner: instance.owner, jid: jid, sid: instance.sid)
            try realm.write {
                realm.add(instance)
            }
        } catch {
            
        }
                        
        let childs = self.getMessageChildsForVerififcationRequest(sid: sid)
        
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: jid), elementID: UUID().uuidString, child: childs)

        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(message)
        })
        
//        let item = MessageReferenceStorageItem()
//        item.kind = .systemMessage
//        item.owner = self.owner
//        item.jid = jid
//        item.primary = UUID().uuidString
//        let body = "Verification request from \(self.owner)"
//        AccountManager.shared.find(for: self.owner)?.messages.sendSystemMessage(
//            body,
//            attachments: [item],
//            to: jid,
//            conversationType: .regular
//        )
    }
    
    func acceptVerificationRequest(jid: String, sid: String) -> String {
        let code = self.generateCode()
        
        var deviceId: Int = 0
        var fullJID: String = ""
        let byteSequence = self.generateByteSequence()
        
        do {
            let realm = try WRealm.safe()
            
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid, sid: sid))
            deviceId = instance!.opponentDeviceId
            fullJID = instance!.fullJID
            
            guard let storedBundle = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: jid, deviceId: deviceId)) else {
                DDLogDebug("Can't find any IdentityKeys")
                fatalError()
            }
            
            try realm.write {
                instance?.code = code
                instance?.state = .acceptedRequest
                instance?.byteSequence = byteSequence.toBase64()
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
        
        let result = self.encrypt(jid: jid, sid: sid, deviceId: deviceId, data: byteSequence)
        
        let child = self.getMessageChildsForAcceptVerificationRequest(sid: sid, encryptedByteSequence: result.encrypted.toBase64(), iv: result.iv.toBase64())
        
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: fullJID), elementID: UUID().uuidString, child: child)
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(message)
        })
        
        return code
        
//        DispatchQueue.main.async {
//            self.delegate?.showOutputViewController(code: code)
//        }
        
        
    }
    
    func sendHashToOpponent(fullJID: XMPPJID, sid: String) {
        var deviceId: Int = 0
        var byteSequence: [UInt8] = []
        var opponentByteSequence: [UInt8] = []
        var code: String = ""
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: fullJID.bare, sid: sid))
            deviceId = instance!.opponentDeviceId
            byteSequence = try instance!.byteSequence.base64decoded()
            opponentByteSequence = try instance!.opponentByteSequence.base64decoded()
            code = instance!.code
            try realm.write {
                instance?.state = .hashSentToOpponent
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        
        let stringToHash = self.trustedKey! + Array(code.utf8) + opponentByteSequence
        let hash = Array(SHA256.hash(data: stringToHash).makeIterator())
        
        let resultHash = self.encrypt(jid: fullJID.bare, sid: sid, deviceId: deviceId, data: hash)
        let resultSalt = self.encrypt(jid: fullJID.bare, sid: sid, deviceId: deviceId, data: byteSequence)
        
        let child = self.getMessageChildsToSendHashAndSaltToOpponent(sid: sid, encryptedHash: resultHash.encrypted.toBase64(), ivHash: resultHash.iv.toBase64(), encryptedSalt: resultSalt.encrypted.toBase64(), ivSalt: resultSalt.iv.toBase64())
        
        let messageToSend = XMPPMessage(messageType: .chat, to: fullJID, elementID: UUID().uuidString, child: child)
        messageToSend.addAttribute(withName: "from", stringValue: self.owner)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(messageToSend)
        })
    }
    
    func sendSuccessfulVerificationMessage(fullJID: XMPPJID, sid: String) {
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        
        let verificationSuccessful = DDXMLElement(name: "verification-successful")
        
        authenticatedKeyExchange.addChild(verificationSuccessful)
        
        let message = XMPPMessage(messageType: .chat, to: fullJID, elementID: UUID().uuidString, child: authenticatedKeyExchange)
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(message)
        })
    }
    
    func sendErrorMessage(fullJID: XMPPJID, sid: String, reason: String) {
        let child = getMessageChildsForErrorMessage(sid: sid, reason: reason)
        
        let message = XMPPMessage(messageType: .chat, to: fullJID, elementID: UUID().uuidString, child: child)
        message.addAttribute(withName: "from", stringValue: self.owner)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(message)
        })
    }
    
    func checkHashFromInitiator(jid: String, sid: String, deviceId: Int, hashEncrypted: DDXMLElement, byteSequenceEncrypted: DDXMLElement) -> Bool {
        let hash = self.decryptElementFromXML(jid: jid, sid: sid, deviceId: deviceId, encryptedXML: hashEncrypted)
        let opponentByteSequence = self.decryptElementFromXML(jid: jid, sid: sid, deviceId: deviceId, encryptedXML: byteSequenceEncrypted)
        
        var deviceId: String = ""
        var code: String = ""
        var byteSequence: [UInt8] = []
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid, sid: sid))
            try realm.write {
                instance?.opponentByteSequence = opponentByteSequence!.toBase64()
            }
            
            deviceId = String(instance!.opponentDeviceId)
            code = instance!.code
            byteSequence = try instance!.byteSequence.base64decoded()
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        
        let publicKey = self.getUsersPublicKey(jid: jid, deviceId: Int(deviceId)!)
        let fingerprint = publicKey.toHexString()
        
        let opponentTrustedKey = deviceId + "::" + fingerprint
        
        let stringToHash = Data(opponentTrustedKey.bytes + Array(code.utf8) + byteSequence)
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
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid, sid: sid))
            
            code = instance!.code
            byteSequence = try instance!.byteSequence.base64decoded()
            opponentByteSequence = try instance!.opponentByteSequence.base64decoded()
            
            try realm.write {
                instance?.state = .hashSentToInitiator
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchange \(#function). \(error.localizedDescription)")
        }
        let stringToHash = self.trustedKey! + Array(code.utf8) + byteSequence + opponentByteSequence
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
        var fullJID: String
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: jid, sid: sid)) else {
                return
            }
            fullJID = instance.fullJID
            try realm.write {
                realm.delete(instance)
            }
        } catch {
            fatalError()
        }
        
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        
        let verificationSuccessful = DDXMLElement(name: "verification-rejected")
        
        authenticatedKeyExchange.addChild(verificationSuccessful)
        
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: fullJID), elementID: UUID().uuidString, child: authenticatedKeyExchange)
        
        self.sendMessage(message: message)
    }
}
