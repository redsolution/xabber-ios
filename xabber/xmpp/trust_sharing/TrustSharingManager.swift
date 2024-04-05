//
//  TrustSharingManager.swift
//  xabber
//
//  Created by Admin on 03.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import XMPPFramework
import CryptoKit
import CryptoSwift


class TrustSharingManager: AbstractXMPPManager {
    override func namespaces() -> [String] {
        return [
            "urn:xmpp:trustsharing:0"
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    override func onStreamPrepared(_ stream: XMPPStream) {
        
    }
    
    func didReceivedTrustedSharingMessage(_ message: XMPPMessage) -> Bool {
        if isArchivedMessage(message) {
            return false
        } else if isCarbonCopy(message) {
            return false
        } else if isCarbonForwarded(message) {
            return false
        } else  {
            guard let share = message.element(forName: "share", xmlns: getPrimaryNamespace()),
                  let jid = message.from,
                  let signature = try! share.element(forName: "signature")?.stringValue?.base64decoded(),
                  let identity = share.element(forName: "identity"),
                  let fingerprint = identity.stringValue,
                  let deviceId = Int(identity.attributeStringValue(forName: "id")!),
                  let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
                return false
            }
            
            let predicate = NSPredicate(format: "owner == %@ AND fullJID == %@ AND opponentDeviceId == %@", argumentArray: [self.owner, jid.full, deviceId])
            do {
                let realm = try WRealm.safe()
                guard let instance = realm.objects(VerificationSessionStorageItem.self).filter(predicate).first else {
                    fatalError()
                }
                if instance.state != VerificationSessionStorageItem.VerififcationState.trusted {
                    return true
                }
            } catch {
                fatalError()
            }
            
            var stringToVerifySignature = ""
            let trustedItemsList = share.elements(forName: "trusted-items").sorted(by: { $0.attributeStringValue(forName: "timestamp")! > $1.attributeStringValue(forName: "timestamp")! })
            
            for item in trustedItemsList {
                stringToVerifySignature += item.attribute(forName: "timestamp")!.stringValue!
                let trustsList = item.elements(forName: "trust").sorted(by: { $0.attributeStringValue(forName: "timestamp")! > $1.attributeStringValue(forName: "timestamp")! })
                for trust in trustsList {
                    stringToVerifySignature += "<" + trust.attributeStringValue(forName: "timestamp")! + "/" + trust.stringValue!
                }
                stringToVerifySignature += "<"
            }
            
            let opponentPublicKey = akeManager.getUsersPublicKey(jid: jid.bare, deviceId: deviceId)
            
            let sharedKey = akeManager.calculateSharedKey(jid: jid.bare, deviceId: deviceId)
            let iv = [UInt8](repeating: 0, count: 16)
            let aes = try! AES(key: sharedKey, blockMode: CBC(iv: iv))
            let mySignature = try! aes.encrypt(Array(SHA256.hash(data: (stringToVerifySignature.bytes)).makeIterator()))
            if mySignature != signature {
                do {
                    let realm = try WRealm.safe()
                    guard let instance = realm.objects(VerificationSessionStorageItem.self).filter(predicate).first else {
                        fatalError()
                    }
                    akeManager.sendErrorMessage(fullJID: jid, sid: instance.sid, reason: "Error when exchanging trusted devices")
                    akeManager.showNotification(title: jid.bare, owner: self.owner, body: "Verification failed", sid: instance.sid, timestamp: Date().timeIntervalSince1970)
                    try realm.write {
                        instance.state = .failed
                    }
                } catch {
                    fatalError()
                }
                return true
            }
            
            do {
                let realm = try WRealm.safe()
                
                for item in trustedItemsList {
                    let deviceOwner = item.attributeStringValue(forName: "owner")
                    let trustsList = item.elements(forName: "trust")
                    for trust in trustsList {
                        guard let trustKey = try String(bytes: (trust.stringValue?.base64decoded())!, encoding: .utf8),
                              let deviceId = Int(trustKey.components(separatedBy: "::")[0]) else {
                            fatalError()
                        }
                        let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: deviceOwner!, deviceId: deviceId))
//                        }
                        try realm.write {
                            instance!.state = SignalDeviceStorageItem.TrustState.trusted
                        }
                    }
                }
            } catch {
                fatalError()
            }
            
            akeManager.writeTrustedDevice(jid: jid.bare, deviceId: deviceId)
            return true
        }
    }
    
    func sendMessageWithContactsDevices(opponentFullJid: XMPPJID, deviceId: Int, opponentDeviceId: Int) {
        let share = DDXMLElement(name: "share", xmlns: "urn:xmpp:trustsharing:0")
        share.addAttribute(withName: "usage", stringValue: "urn:xmpp:omemo:2")
        
        do {
            let realm = try WRealm.safe()
            let predicate = NSPredicate(format: "owner == %@ AND jid != %@ AND state_ == %@", argumentArray: [self.owner, self.owner, "trusted"])
            let instances = realm.objects(SignalDeviceStorageItem.self).filter(predicate)
            var jids: [String] = []
            for instance in instances {
                if !jids.contains(where: { $0 == instance.jid }) {
                    jids.append(instance.jid)
                }
            }
            for jid in jids {
                let trustedItems = DDXMLElement(name: "trusted-items")
                trustedItems.addAttribute(withName: "owner", stringValue: jid)
                trustedItems.addAttribute(withName: "timestamp", stringValue: String(Date().timeIntervalSince1970))
                for instance in instances {
                    if instance.jid == jid {
                        let trustedKey = String(instance.deviceId) + "::" + instance.fingerprint
                        let trust = DDXMLElement(name: "trust", stringValue: trustedKey.toBase64())
                        trust.addAttribute(withName: "timestamp", stringValue: String(instance.trustDate.timeIntervalSince1970))
                        trustedItems.addChild(trust)
                    }
                }
                share.addChild(trustedItems)
            }
        } catch {
            fatalError()
        }
        
        guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
              let privateKey = akeManager.keyPair?.privateKey.bytes else {
            fatalError()
        }
        let publicKey = akeManager.getUsersPublicKey(jid: self.owner, deviceId: deviceId)
        let fingerprint = publicKey.toHexString()
        
        let identityXML = DDXMLElement(name: "identity", stringValue: fingerprint)
        identityXML.addAttribute(withName: "id", stringValue: String(deviceId))
        share.addChild(identityXML)
        
        var stringToHash = ""
        let trustedItemsList = share.elements(forName: "trusted-items").sorted(by: { $0.attributeStringValue(forName: "timestamp")! > $1.attributeStringValue(forName: "timestamp")! })
        
        for item in trustedItemsList {
            stringToHash += item.attribute(forName: "timestamp")!.stringValue!
            let trustsList = item.elements(forName: "trust").sorted(by: { $0.attributeStringValue(forName: "timestamp")! > $1.attributeStringValue(forName: "timestamp")! })
            for trust in trustsList {
                stringToHash += "<" + trust.attributeStringValue(forName: "timestamp")! + "/" + trust.stringValue!
            }
            stringToHash += "<"
        }
        
        
        let sharedKey = akeManager.calculateSharedKey(jid: opponentFullJid.bare, deviceId: opponentDeviceId)
        let iv = [UInt8](repeating: 0, count: 16)
        let aes = try! AES(key: sharedKey, blockMode: CBC(iv: iv))
        let signature = try! aes.encrypt(Array(SHA256.hash(data: (stringToHash.bytes)).makeIterator()))
        
//        let privateKeyCurve = try! CryptoKit.Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
//        let signature = try! privateKeyCurve.signature(for: stringToHash.bytes)
//        privateKey.signature()
        let signatureXML = DDXMLElement(name: "signature", stringValue: signature.toBase64())
        signatureXML.addAttribute(withName: "xmlns", stringValue: "urn:xmpp:trustsharing:0")
        share.addChild(signatureXML)
        
        let message = XMPPMessage(messageType: .chat, to: opponentFullJid, elementID: UUID().uuidString)
        message.addChild(share)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(message)
        })
    }
}
