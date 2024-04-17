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
import Curve25519Kit
import CryptoSwift


class TrustSharingManager: AbstractXMPPManager {
    let node = "urn:xmpp:trustsharing:0:items"
    
    override func namespaces() -> [String] {
        return [
            "urn:xmpp:trustsharing:0",
            "urn:xmpp:trustsharing:0:items+notify"
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    override func onStreamPrepared(_ stream: XMPPStream) {
        super.onStreamPrepared(stream)
    }
    
    func didReceivedTrustedSharingMessage(message: XMPPMessage) -> Bool {
        //TODO: implement handling archive messages
        if isArchivedMessage(message) {
            return false
        } else if isCarbonCopy(message) {
            return false
        } else if isCarbonForwarded(message) {
            return false
        }
        
        guard let notify = message.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns) ?? message.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns) else {
            return false
        }
        let uniqueMessageId = getUniqueMessageId(message, owner: self.owner)
        guard let messageContainer = notify.element(forName: "forwarded")?.element(forName: "message") else {
            return false
        }
        guard let jidRaw = messageContainer.attributeStringValue(forName: "from"),
              let jid = XMPPJID(string: jidRaw)?.bare else {
            return false
        }
        guard let share = messageContainer.element(forName: "share", xmlns: getPrimaryNamespace()),
              let jid = XMPPMessage(from: messageContainer).from,
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
            for item in trustedItemsList {
                let deviceOwner = item.attributeStringValue(forName: "owner")
                let trustsList = item.elements(forName: "trust")
                for trust in trustsList {
                    guard let trustKey = try String(bytes: (trust.stringValue?.base64decoded())!, encoding: .utf8),
                          let deviceId = Int(trustKey.components(separatedBy: "::")[0]) else {
                        fatalError()
                    }
                    akeManager.writeTrustedDevice(jid: deviceOwner ?? XMPPMessage(from: messageContainer).from!.bare, deviceId: deviceId)
                }
            }
            return true
        } catch {
            fatalError()
        }
    }
    
    func sendNotificationWithContactsDevices(opponentFullJid: XMPPJID, deviceId: Int, opponentDeviceId: Int) {
        let share = DDXMLElement(name: "share", xmlns: self.getPrimaryNamespace())
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

        let signatureXML = DDXMLElement(name: "signature", stringValue: signature.toBase64())
        signatureXML.addAttribute(withName: "xmlns", stringValue: self.getPrimaryNamespace())
        share.addChild(signatureXML)
        
        let message = XMPPMessage(messageType: .chat, to: opponentFullJid, elementID: UUID().uuidString, child: share)
        message.addAttribute(withName: "from", stringValue: AccountManager.shared.find(for: self.owner)!.xmppStream.myJID!.full)
        
        let iq = akeManager.getNotificationContainer(message: message, notificationTo: opponentFullJid)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
    }
    
    func publicOwnTrustedDevices(publisherDeviceId: String) {
        let share = DDXMLElement(name: "share", xmlns: self.getPrimaryNamespace())
        share.addAttribute(withName: "usage", stringValue: "urn:xmpp:omemo:2")
        do {
            let realm = try WRealm.safe()
            let predicate = NSPredicate(format: "owner == %@ AND jid == %@ AND state_ == %@", argumentArray: [self.owner, self.owner, "trusted"])
            let instances = realm.objects(SignalDeviceStorageItem.self).filter(predicate)
//            var jids: [String] = []
//            for instance in instances {
//                if !jids.contains(where: { $0 == instance.jid }) {
//                    jids.append(instance.jid)
//                }
//            }
//            for jid in jids {
            let trustedItems = DDXMLElement(name: "trusted-items")
            trustedItems.addAttribute(withName: "timestamp", stringValue: String(Date().timeIntervalSince1970))
            for instance in instances {
//                if instance.jid == jid {
                let trustedKey = String(instance.deviceId) + "::" + instance.fingerprint
                let trust = DDXMLElement(name: "trust", stringValue: trustedKey.toBase64())
                trust.addAttribute(withName: "timestamp", stringValue: String(instance.trustDate.timeIntervalSince1970))
                trustedItems.addChild(trust)
//                }
            }
            share.addChild(trustedItems)
//            }
        } catch {
            fatalError()
        }
        
        guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
              let privateKey = akeManager.keyPair?.privateKey.bytes else {
            fatalError()
        }
        let publicKey = akeManager.getUsersPublicKey(jid: self.owner, deviceId: Int(publisherDeviceId)!)
        let fingerprint = publicKey.toHexString()
        
        let identityXML = DDXMLElement(name: "identity", stringValue: fingerprint)
        identityXML.addAttribute(withName: "id", stringValue: String(publisherDeviceId))
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
        
//        let stringToSign = Array(SHA256.hash(data: (stringToHash.bytes)).makeIterator())
        let keyPair = Curve25519.load(fromPublicKey: akeManager.keyPair?.publicKey, andPrivateKey: akeManager.keyPair?.privateKey)
        let signature = Ed25519.sign(Data(stringToHash.bytes), with: keyPair)
        
//        let sharedKey = akeManager.calculateSharedKey(jid: opponentFullJid.bare, deviceId: opponentDeviceId)
//        let iv = [UInt8](repeating: 0, count: 16)
//        let aes = try! AES(key: sharedKey, blockMode: CBC(iv: iv))
//        let signature = try! aes.encrypt(Array(SHA256.hash(data: (stringToHash.bytes)).makeIterator()))

        let signatureXML = DDXMLElement(name: "signature", stringValue: signature!.base64EncodedString())
        signatureXML.addAttribute(withName: "xmlns", stringValue: self.getPrimaryNamespace())
        share.addChild(signatureXML)
        
        let item = DDXMLElement(name: "item")
        item.addChild(share)
        item.addAttribute(withName: "id", stringValue: publisherDeviceId)
        let publish = DDXMLElement(name: "publish")
        publish.addAttribute(withName: "node", stringValue: self.node)
        publish.addChild(item)
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        pubsub.addChild(publish)
        let iq = XMPPIQ(iqType: .set, child: pubsub)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            self.createNode(stream, node: .trustList)
            self.configureNode(stream, node: .trustList)
            stream.send(iq)
        })
    }
    
    internal final func createNode(_ xmppStream: XMPPStream, node: OmemoManager.NodeType) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let create = DDXMLElement(name: "create")
        create.addAttribute(withName: "node", stringValue: node.rawValue)
        pubsub.addChild(create)
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub))
        self.queryIds.insert(elementId)
    }
    
    internal final func configureNode(_ xmppStream: XMPPStream, node: OmemoManager.NodeType) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub#owner")
        let configure = DDXMLElement(name: "configure")
        configure.addAttribute(withName: "node", stringValue: node.rawValue)
        let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
        x.addAttribute(withName: "type", stringValue: "submit")
        let form: [[String: String]] = [
            [
                "var": "FORM_TYPE",
                "type": "hidden",
                "value": "http://jabber.org/protocol/pubsub#node_config"
            ],
            [
                "var": "pubsub#access_model",
                "value": "open"
            ],
            [
                "var": "pubsub#max_items",
                "value": node == .update ? "1" : "32"
            ]
        ]
        
        form.compactMap {
                dict -> DDXMLElement in
                let field = DDXMLElement(name: "field")
                
                if let varAttr = dict["var"] {
                    field.addAttribute(withName: "var", stringValue: varAttr)
                }
                if let typeAttr = dict["type"] {
                    field.addAttribute(withName: "type", stringValue: typeAttr)
                }
                if let value = dict["value"] {
                    let valueElement = DDXMLElement(name: "value", stringValue: value)
                    field.addChild(valueElement)
                }
                
                return field
            }.forEach { Field in
                x.addChild(Field)
            }
        configure.addChild(x)
        pubsub.addChild(configure)
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub))
        self.queryIds.insert(elementId)
        
    }
}
