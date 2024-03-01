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
// TODO: Data = [UInt]
class AuthenticatedKeyExchangeManager: AbstractXMPPManager{
    enum State{
        case none
        case accepted
    }
    
    override func namespaces() -> [String] {
        return [
            "urn:xabber:trust"
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    internal var delegate: AuthenticatedKeyExchangeManagerDelegate?
    internal var state: State = .none
    internal var sid: String? = nil
    internal var messageId: String? = nil
    
    internal var localStore: XabberAxolotlStorage
    internal var keyPair: SignalIdentityKeyPair? = nil
    
    // TODO: only keypair
    internal var publicKey: Data? = nil
    internal var privateKey: Data? = nil
    
    internal var deviceID: Int? = nil
    internal var sharedKey: Data? = nil
    internal var encryptionKey: [UInt8]? = nil
    internal var trustedKey: [UInt8]? = nil
    
    // TODO: enum with states
    internal var isWaitingForResponce: Bool
    internal var isRequestAccepted: Bool = false
    
    internal var byteSequence: [UInt8]? = nil
    internal var code: String? = nil
    
    // TODO: WRealm with information abount sid, owner, opponent, opponentsDeviceID, trustedKey
    internal var opponent: XMPPJID? = nil
    internal var opponentDeviceID: Int? = nil
    internal var opponentPublicKey: Data? = nil
    internal var opponentByteSequence: [UInt8]? = nil
    
    var message: XMPPMessage? = nil
    
    override init(withOwner owner: String) {
        // TODO: do not initialize, account.omemo.something with keys
        self.localStore = XabberAxolotlStorage(withOwner: owner)
        
        self.isWaitingForResponce = false
        
        super.init(withOwner: owner)
    }
    
    override func onStreamPrepared(_ stream: XMPPStream) {
        self.keyPair = self.localStore.getIdentityKeyPair()
        self.publicKey = self.keyPair!.publicKey
        self.privateKey = self.keyPair!.privateKey
        self.deviceID = self.localStore.localDeviceId()
        let stringToHash = String(self.deviceID!).data(using: String.Encoding.utf8)! + self.publicKey!
        self.trustedKey = Array(SHA256.hash(data: stringToHash).makeIterator())
        print("my trustedKey: \(self.trustedKey!)")
        
        self.generateByteSequence()
    }
    
    func setOponent(jid: String) {
        self.opponent = XMPPJID(string: jid)
    }
    
    func generateByteSequence() {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            self.byteSequence = bytes
        } else {
            DDLogDebug("AuthenticationKeyExchangeManager: \(#function)")
        }
        print("byteSequence: \(self.byteSequence!)")
    }
    
    func generateCode() {
        self.code = String.randomString(length: 6, includeNumber: true)
        print("code: \(self.code!)")
    }
    
    func calculateSharedKey() {
        let keyPair = Curve25519.load(fromPublicKey: self.keyPair?.publicKey, andPrivateKey: self.keyPair?.privateKey)
        self.sharedKey = Curve25519.generateSharedSecret(fromPublicKey: self.opponentPublicKey?.dropFirst(), andKeyPair: keyPair)
        print("sharedKey: \(self.sharedKey!)")
    }
    
    func calculateEncryptionKey() {
        guard self.sharedKey != nil, self.sharedKey?.count == 32 else {
            return
        }
        let stringToHash = self.sharedKey! + SHA256.hash(data: (self.code?.data(using: String.Encoding.utf8))!)
        self.encryptionKey = Array(SHA256.hash(data: stringToHash).makeIterator())
        print("encryptionKey: \(self.encryptionKey!)")
    }
    
    func sendMessage(message: XMPPMessage) {
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(message)
        })
    }
    
    func getMessageChildsForVerififcationRequest() -> DDXMLElement {
        let authenticationKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticationKeyExchange.addAttribute(withName: "sid", stringValue: UUID().uuidString)
        
        let verificationStart = DDXMLElement(name: "verification-start")
        
        // TODO: in attribute string
        verificationStart.addAttribute(withName: "device-id", intValue: Int32(self.deviceID!))
        
        authenticationKeyExchange.addChild(verificationStart)
        
        return authenticationKeyExchange
    }
    
    func getMessageChildsForAcceptVerificationRequest(sid: String, encryptedByteSequence: String, iv: String) -> DDXMLElement {
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        
        let verificationAccept = DDXMLElement(name: "verification-accepted")
        verificationAccept.addAttribute(withName: "device-id", intValue: Int32(self.deviceID!))
        
        let salt = DDXMLElement(name: "salt")
        salt.addChild(DDXMLElement(name: "ciphertext", objectValue: encryptedByteSequence))
        salt.addChild(DDXMLElement(name: "iv", objectValue: iv))
        
        // TODO: copy()
        authenticatedKeyExchange.addChild(verificationAccept)
        authenticatedKeyExchange.addChild(salt)
        
        return authenticatedKeyExchange
    }
    
    func getMessageChildsToSendHashAndSaltToOpponent(sid: String, encryptedHash: String, ivHash: String, encryptedSalt: String, ivSalt: String) -> DDXMLElement {
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        
        let hash = DDXMLElement(name: "hash")
        hash.addAttribute(withName: "algo", stringValue: "sha-256")
        hash.addChild(DDXMLElement(name: "ciphertext", objectValue: encryptedHash))
        hash.addChild(DDXMLElement(name: "iv", objectValue: ivHash))
        
        let salt = DDXMLElement(name: "salt")
        salt.addChild(DDXMLElement(name: "ciphertext", objectValue: encryptedSalt))
        salt.addChild(DDXMLElement(name: "iv", objectValue: ivSalt))
        
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
            guard let authenticatedKeyExchange = message.element(forName: "authenticated-key-exchange", xmlns: getPrimaryNamespace()) else {
                return false
            }
            
            if authenticatedKeyExchange.element(forName: "verification-start") != nil {
                self.state = .accepted
                
                let authenticatedKeyExchange = message.element(forName: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
                let verificationStart = authenticatedKeyExchange?.element(forName: "verification-start")
                self.opponent = message.from
                guard let opponentDeviceID = verificationStart?.attributeIntegerValue(forName: "device-id") else {
                    DDLogDebug("Opponent device ID is not specified")
                    return true
                }
                self.messageId = message.elementID
                self.opponentDeviceID = opponentDeviceID
                self.sid = message.element(forName: "authenticated-key-exchange")?.attributeStringValue(forName: "sid")
                
                return true
            } else if authenticatedKeyExchange.element(forName: "verification-accepted") != nil {
                self.message = message
                isRequestAccepted = true
                self.sid = authenticatedKeyExchange.attributeStringValue(forName: "sid")
                
                DispatchQueue.main.async {
                    self.delegate?.verificationRequestAccepted()
                }
                
                return true
            } else if authenticatedKeyExchange.element(forName: "hash") != nil && authenticatedKeyExchange.element(forName: "salt") != nil {
                if !checkHashFromInitiator(message: message) {
                    let child = self.getMessageChildsForErrorMessage(sid: self.sid!, reason: "Hashes didn't match")
                    let message = XMPPMessage(messageType: .chat, to: self.opponent, elementID: message.elementID, child: child)
                    self.sendMessage(message: message)
                    return true
                }
                let hash = self.calculateHashForInitiator()
                let encryptedHashResult = self.encrypt(data: hash)
                
                let authenticatedKeyExchangeChild = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
                authenticatedKeyExchangeChild.addAttribute(withName: "sid", stringValue: self.sid!)
                
                let hashChild = DDXMLElement(name: "hash")
                hashChild.addAttribute(withName: "algo", stringValue: "sha-256")
                hashChild.addChild(DDXMLElement(name: "ciphertext", stringValue: encryptedHashResult.encrypted.toBase64()))
                hashChild.addChild(DDXMLElement(name: "iv", stringValue: encryptedHashResult.iv.toBase64()))
                
                authenticatedKeyExchangeChild.addChild(hashChild)
                
                let message = XMPPMessage(messageType: .chat, to: self.opponent, elementID: message.elementID, child: authenticatedKeyExchangeChild)
                self.sendMessage(message: message)
                
                return true
            } else if authenticatedKeyExchange.element(forName: "hash") != nil {
                let hashEncrypted = authenticatedKeyExchange.element(forName: "hash")!
                
                let hash = self.decryptElementFromXML(encryptedXML: hashEncrypted)
                
                let stringForTrustedKey = String(self.opponentDeviceID!).data(using: String.Encoding.utf8)! + self.opponentPublicKey!
                let opponentTrustedKey = Array(SHA256.hash(data: stringForTrustedKey).makeIterator())
                
                let stringToHash = opponentTrustedKey + Array(self.code!.utf8) + self.opponentByteSequence! + self.byteSequence!
                let myHash = Array(SHA256.hash(data: stringToHash).makeIterator())
                
                if hash != myHash {
                    sendErrorMessage(sid: self.sid!, reason: "Hashes didn't match", messageId: message.elementID!)
                    
                    return true
                }
                
                return true
            }
        }
        return true
    }
    
    func sendVerificationMessage() {
        let childs = self.getMessageChildsForVerififcationRequest()
        guard (self.opponent != nil) else {
            DDLogDebug("Opponent JID is not specified")
            return
        }
        
        let message = XMPPMessage(messageType: .chat, to: self.opponent, elementID: UUID().uuidString, child: childs)

        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(message)
        })
    }
    
    // TODO: make different ids for messaged of one verification session
    func acceptVerificationRequest() {
        self.generateCode()
        
        let realm = try! WRealm.safe()
        
        guard let storedBundle = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: self.opponent!.bare, deviceId: self.opponentDeviceID!)) else {
            DDLogDebug("Can't find any IdentityKeys")
            return
        }
                
        self.opponentPublicKey = Data(base64Encoded: storedBundle.identityKey!)
        
        self.calculateSharedKey()
        self.calculateEncryptionKey()
        
        let result = self.encrypt(data: self.byteSequence!)
        
        let child = self.getMessageChildsForAcceptVerificationRequest(sid: self.sid!, encryptedByteSequence: result.encrypted.toBase64(), iv: result.iv.toBase64())
        
        let message = XMPPMessage(messageType: .chat, to: self.opponent, elementID: self.messageId, child: child)

        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(message)
        })
        
        DispatchQueue.main.async {
            self.delegate?.verificationRequestReceived(code: self.code!)
        }
    }
    
    func sendHashToOpponent() {
        let message = self.message
        
        let authenticatedKeyExchange = message!.element(forName: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        let verificationAccepted = authenticatedKeyExchange?.element(forName: "verification-accepted")
        self.opponent = XMPPJID(string: (message!.from?.full.components(separatedBy: "_")[0])!)
        guard let opponentDeviceID = verificationAccepted?.attributeIntegerValue(forName: "device-id") else {
            DDLogDebug("Opponent device ID is not specified")
            return
        }
        
        self.opponentDeviceID = opponentDeviceID
        
        let realm = try! WRealm.safe()
        
        guard let storedBundle = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: self.opponent!.bare, deviceId: self.opponentDeviceID!)) else {
            DDLogDebug("Can't find any IdentityKeys")
            return
        }
        self.opponentPublicKey = Data(base64Encoded: storedBundle.identityKey!)
        
        if self.sharedKey == nil {
            self.calculateSharedKey()
        }
        
        self.calculateEncryptionKey()
        
        let salt = message!.element(forName: "authenticated-key-exchange", xmlns: getPrimaryNamespace())?.element(forName: "salt")
        
        let ciphertext: [UInt8]?
        let iv: [UInt8]?
        
        do {
            ciphertext = try salt?.element(forName: "ciphertext")?.stringValue?.base64decoded()
            iv = try salt?.element(forName: "iv")?.stringValue?.base64decoded()
        } catch {
            DDLogDebug("Can't serialize data")
            return
        }
        self.opponentByteSequence = self.decrypt(ciphertext: ciphertext!, iv: iv!)
        
        let stringToHash = self.trustedKey! + Array(self.code!.utf8) + self.opponentByteSequence!
        let hash = Array(SHA256.hash(data: stringToHash).makeIterator())
        
        print("hash to opponent: \(hash)")
        
        let resultHash = self.encrypt(data: hash)
        let resultSalt = self.encrypt(data: self.byteSequence!)
        
        let child = self.getMessageChildsToSendHashAndSaltToOpponent(sid: (message!.element(forName: "authenticated-key-exchange")?.attributeStringValue(forName: "sid"))!, encryptedHash: resultHash.encrypted.toBase64(), ivHash: resultHash.iv.toBase64(), encryptedSalt: resultSalt.encrypted.toBase64(), ivSalt: resultSalt.iv.toBase64())
        
        let messageToSend = XMPPMessage(messageType: .chat, to: self.opponent, elementID: message?.elementID, child: child)
        messageToSend.addAttribute(withName: "from", stringValue: self.owner)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(messageToSend)
        })
    }
    
    func sendErrorMessage(sid: String, reason: String, messageId: String) {
        let child = getMessageChildsForErrorMessage(sid: sid, reason: reason)
        
        let message = XMPPMessage(messageType: .chat, to: self.opponent, elementID: messageId, child: child)
        message.addAttribute(withName: "from", stringValue: self.owner)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(message)
        })
    }
    
    func checkHashFromInitiator(message: XMPPMessage) -> Bool {
        let authenticatedKeyExchange = message.element(forName: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        let hashEncrypted = authenticatedKeyExchange?.element(forName: "hash")
        
        let hashCiphertext: [UInt8]?
        let hashIv: [UInt8]?
        
        do {
            hashCiphertext = try hashEncrypted?.element(forName: "ciphertext")?.stringValue?.base64decoded()
            hashIv = try hashEncrypted?.element(forName: "iv")?.stringValue?.base64decoded()
            
        } catch {
            DDLogDebug("Can't serialize data")
            return false
        }
        let hash = decrypt(ciphertext: hashCiphertext!, iv: hashIv!)
        print("decrypted hash from opponent: \(hash)")
        let byteSequenceEncrypted = authenticatedKeyExchange?.element(forName: "salt")
        
        let byteSequenceCiphertext: [UInt8]?
        let byteSequenceIv: [UInt8]?
        
        do {
            byteSequenceCiphertext = try byteSequenceEncrypted?.element(forName: "ciphertext")?.stringValue?.base64decoded()
            byteSequenceIv = try byteSequenceEncrypted?.element(forName: "iv")?.stringValue?.base64decoded()
        } catch {
            DDLogDebug("Can't serialize data")
            return false
        }
        self.opponentByteSequence = decrypt(ciphertext: byteSequenceCiphertext!, iv: byteSequenceIv!)
        
        var stringToHash = String(self.opponentDeviceID!).data(using: String.Encoding.utf8)! + self.opponentPublicKey!
        let opponentTrustedKey = Array(SHA256.hash(data: stringToHash).makeIterator())
        print("opponent trustedKey: \(opponentTrustedKey)")
        
        stringToHash = Data(opponentTrustedKey + Array(self.code!.utf8) + self.byteSequence!)
        let myHash = Array(SHA256.hash(data: stringToHash).makeIterator())
        print("hash from initiator calculated on my side: \(myHash)")
        
        if hash != myHash {
            let sid = authenticatedKeyExchange?.attributeStringValue(forName: "sid")
            let messageId = message.attributeStringValue(forName: "id")
            sendErrorMessage(sid: sid!, reason: "Hashes didn't match", messageId: messageId!)
            
            return false
        }
        
        return true
    }
    
    func calculateHashForInitiator() -> [UInt8] {
        let stringToHash = self.trustedKey! + Array(self.code!.utf8) + self.byteSequence! + self.opponentByteSequence!
        let hash = Array(SHA256.hash(data: stringToHash).makeIterator())

        return hash
    }
    
    func encrypt(data: Array<UInt8>) -> (encrypted: [UInt8], iv: [UInt8]) {
        var iv = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv)
        guard status == errSecSuccess else {
            DDLogDebug("AuthenticationKeyExchangeManager: \(#function)")
            fatalError()
        }
        
        let aes = try! AES(key: self.encryptionKey!, blockMode: CBC(iv: iv))
        let encrypted = try! aes.encrypt(data)
        
        return (encrypted: encrypted, iv: iv)
    }
    
    func decryptElementFromXML(encryptedXML: DDXMLElement) -> [UInt8]? {
        let ciphertext: [UInt8]?
        let iv: [UInt8]?
        
        do {
            ciphertext = try encryptedXML.element(forName: "ciphertext")?.stringValue?.base64decoded()
            iv = try encryptedXML.element(forName: "iv")?.stringValue?.base64decoded()
            
        } catch {
            DDLogDebug("Can't serialize data")
            return nil
        }
        let decryptedValue = decrypt(ciphertext: ciphertext!, iv: iv!)
        
        return decryptedValue
    }
    
    func decrypt(ciphertext: [UInt8], iv: [UInt8]) -> [UInt8] {
        let aes = try! AES(key: self.encryptionKey!, blockMode: CBC(iv: iv))
        let decrypted = try! aes.decrypt(ciphertext)
        
        return decrypted
    }
}
