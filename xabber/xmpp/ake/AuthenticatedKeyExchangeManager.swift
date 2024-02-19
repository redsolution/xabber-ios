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

class AuthenticatedKeyExchangeManager: AbstractXMPPManager{
    override func namespaces() -> [String] {
        return [
            "urn:xabber:trust"
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    var vc: AuthenticationCodeInputViewController? = nil
    
    internal var localStore: XabberAxolotlStorage
    internal var keyPair: SignalIdentityKeyPair? = nil
    internal var publicKey: Data? = nil
    internal var privateKey: Data? = nil
    internal var deviceID: Int? = nil
    internal var sharedKey: Data? = nil
    internal var encryptionKey: Array<UInt8>? = nil
    internal var isWaitingForResponce: Bool
    internal var byteSequence: [UInt8]? = nil
    internal var code: String? = nil
    internal var isRequestAccepted: Bool = false
    
    internal var opponent: XMPPJID? = nil
    internal var opponentDeviceID: Int? = nil
    internal var opponentPublicKey: Data? = nil
    internal var opponentByteSequence: [UInt8]? = nil
    
    var message: XMPPMessage? = nil
    
    override init(withOwner owner: String) {
        self.localStore = XabberAxolotlStorage(withOwner: owner)
        self.isWaitingForResponce = false
        
        super.init(withOwner: owner)
        
        self.vc = AuthenticationCodeInputViewController(owner: self.owner)
        self.vc?.passcode.isUserInteractionEnabled = false
    }
    
    override func onStreamPrepared(_ stream: XMPPStream) {
        self.keyPair = self.localStore.getIdentityKeyPair()
        self.publicKey = self.keyPair!.publicKey
        self.privateKey = self.keyPair!.privateKey
        self.deviceID = self.localStore.localDeviceId()
        
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
    }
    
    func generateCode() {
        self.code = String.randomString(length: 6, includeNumber: true)
    }
    
//    @objc
//    internal func enterCodeFromOpponent(_ sender: UIButton) {
//        self.code = textFiled.text
////        textFiled.
//    }
    
    func calculateSharedKey() {
        let keyPair = Curve25519.load(fromPublicKey: self.publicKey, andPrivateKey: self.privateKey)
        self.sharedKey = Curve25519.generateSharedSecret(fromPublicKey: self.opponentPublicKey, andKeyPair: keyPair)
    }
    
    func calculateEncryptionKey() {
        guard self.sharedKey != nil, self.sharedKey?.count == 32 else {
            return
        }
        let stringToHash = self.sharedKey! + SHA256.hash(data: (self.code?.data(using: String.Encoding.utf8))!)
        self.encryptionKey = Array(SHA256.hash(data: stringToHash).makeIterator())
    }
    
    func getMessageChildsForVerififcationRequest() -> [DDXMLElement] {
        let authenticationKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticationKeyExchange.addAttribute(withName: "sid", stringValue: UUID().uuidString)
        
        let verificationStart = DDXMLElement(name: "verification-start")
        verificationStart.addAttribute(withName: "device-id", intValue: Int32(self.deviceID!))
        
        authenticationKeyExchange.addChild(verificationStart)
        
        return [authenticationKeyExchange]
    }
    
    func getMessageChildsForAcceptVerificationRequest(sid: String, encryptedByteSequence: String, iv: String) -> [DDXMLElement] {
        let authenticatedKeyExchange = DDXMLElement(name: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        authenticatedKeyExchange.addAttribute(withName: "sid", stringValue: sid)
        
        let verificationAccept = DDXMLElement(name: "verification-accepted")
        verificationAccept.addAttribute(withName: "device-id", intValue: Int32(self.deviceID!))
        
        let salt = DDXMLElement(name: "salt")
        salt.addChild(DDXMLElement(name: "ciphertext", objectValue: encryptedByteSequence))
        salt.addChild(DDXMLElement(name: "iv", objectValue: iv))
        
        authenticatedKeyExchange.addChild(verificationAccept)
        authenticatedKeyExchange.addChild(salt)
        
        return [authenticatedKeyExchange]
    }
    
    func sendVerificationMessage() {
        let childs = self.getMessageChildsForVerififcationRequest()
        guard (self.opponent != nil) else {
            DDLogDebug("Opponent JID is not specified")
            return
        }
        AccountManager.shared.find(for: self.owner)?.unsafeAction({
            (user, stream) in
            
            user.messages.sendSystemMessage(attachments: [], to: (self.opponent?.bare as String?)!, childs: childs, conversationType: .regular)
        })
    }
    
    func didReceivedVerificationMessage(_ message: XMPPMessage) -> Bool {
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
                self.acceptVerificationRequest(message: message)
                return true
            } else if authenticatedKeyExchange.element(forName: "verififaction-accepted") != nil {
                self.message = message
                isRequestAccepted = true
                self.vc?.passcode.isUserInteractionEnabled = true
                return true
            }
        }
        return true
    }
    
    func acceptVerificationRequest(message: XMPPMessage) {
        self.generateCode()
        let authenticatedKeyExchange = message.element(forName: "authenticated-key-exchange", xmlns: getPrimaryNamespace())
        let verificationStart = authenticatedKeyExchange?.element(forName: "verification-start")
        self.opponent = message.from
        guard let opponentDeviceID = verificationStart?.attributeIntegerValue(forName: "device-id") else {
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
        self.opponentPublicKey?.removeLast()
        
        self.calculateSharedKey()
        self.calculateEncryptionKey()
        
        let result = self.encrypt(data: self.byteSequence!)
        
        let childs = self.getMessageChildsForAcceptVerificationRequest(sid: (message.element(forName: "authenticated-key-exchange")?.attributeStringValue(forName: "sid"))!, encryptedByteSequence: result.encrypted.toBase64(), iv: result.iv.toBase64())
        
        AccountManager.shared.find(for: self.owner)?.unsafeAction { user, stream in
            user.messages.sendSystemMessage(attachments: [], to: self.opponent!.full, childs: childs, conversationType: .regular)
        }
    }
    
    func sendHashToOpponent() {
        let message = self.message
        
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
    
    func decrypt(ciphertext: [UInt8], iv: [UInt8]) -> [UInt8] {
        let aes = try! AES(key: self.encryptionKey!, blockMode: CBC(iv: iv))
        let decrypted = try! aes.decrypt(ciphertext)
        
        return decrypted
    }
}
