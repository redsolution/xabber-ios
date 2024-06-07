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
        let bareMessage: XMPPMessage
        if isArchivedMessage(message) {
            bareMessage = getArchivedMessageContainer(message)!
        } else if isCarbonCopy(message) {
            return false
        } else if isCarbonForwarded(message) {
            return false
        } else {
            bareMessage = message
        }
        
        guard let notify = bareMessage.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns) ?? bareMessage.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns),
              let encryptedMessage = notify.element(forName: "forwarded")?.element(forName: "message"),
              let omemoManager = AccountManager.shared.find(for: self.owner)?.omemo else {
            return false
        }
        
        let messageContainer: DDXMLElement
        do {
            guard let messageContainerr = try omemoManager.decryptMessage(XMPPMessage(from: encryptedMessage)) else {
                return false
            }
            messageContainer = messageContainerr
        } catch {
            return false
        }
//        let uniqueMessageId = getUniqueMessageId(bareMessage, owner: self.owner)
//        guard let messageContainer = notify.element(forName: "forwarded")?.element(forName: "message") else {
//            return false
//        }
        guard let content = messageContainer.element(forName: "content"),
              let jid = messageContainer.element(forName: "from")?.attributeStringValue(forName: "jid"),
              let share = content.element(forName: "share", xmlns: getPrimaryNamespace()),
              let signature = try! share.element(forName: "signature")?.stringValue?.base64decoded(),
              let identity = share.element(forName: "identity"),
              let fingerprint = identity.stringValue,
              let deviceId = Int(identity.attributeStringValue(forName: "id")!),
              let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
            return false
        }
        
        if deviceId == omemoManager.localStore.localDeviceId() {
            return true
        }
        
        let predicate = NSPredicate(format: "owner == %@ AND jid == %@ AND deviceId == %@", argumentArray: [self.owner, jid, deviceId])
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.objects(SignalDeviceStorageItem.self).filter(predicate).first else {
                return true
            }
            if instance.state != SignalDeviceStorageItem.TrustState.trusted {
                return true
            }
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
        }
        
        var stringToVerifySignature = ""
        let trustedItemsList = share.elements(forName: "trusted-items").sorted(by: { $0.attributeStringValue(forName: "timestamp")! > $1.attributeStringValue(forName: "timestamp")! })
        if trustedItemsList.isEmpty {
            return true
        }
        
        for item in trustedItemsList {
            stringToVerifySignature += item.attribute(forName: "timestamp")!.stringValue!
            let trustsList = item.elements(forName: "trust").sorted(by: { $0.attributeStringValue(forName: "timestamp")! > $1.attributeStringValue(forName: "timestamp")! })
            for trust in trustsList {
                stringToVerifySignature += "<" + trust.attributeStringValue(forName: "timestamp")! + "/" + trust.stringValue!
            }
        }
        
        let userPublicKey = akeManager.getUsersPublicKey(jid: jid, deviceId: deviceId)
        if !Ed25519.verifySignature(Data(signature), publicKey: Data(userPublicKey), data: Data(stringToVerifySignature.bytes)) {
            do {
                let realm = try WRealm.safe()
                guard let instance = realm.objects(VerificationSessionStorageItem.self).filter(predicate).first else {
                    DDLogDebug("TrustSharingManager: \(#function).")
                    return true
                }
            } catch {
                DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
                return true
            }
            return true
        }
        
        do {
            for item in trustedItemsList {
                let deviceOwner = item.attributeStringValue(forName: "owner")
                let trustsList = item.elements(forName: "trust")
                for trust in trustsList {
                    guard let trustKey = try String(bytes: (trust.stringValue?.base64decoded())!, encoding: .utf8),
                          let itemDeviceId = Int(trustKey.components(separatedBy: "::")[0]) else {
                        DDLogDebug("TrustSharingManager: \(#function).")
                        return true
                    }
                    
                    let predicate = NSPredicate(format: "owner == %@ AND jid == %@ AND deviceId == %@", argumentArray: [self.owner, deviceOwner!, itemDeviceId])
                    let realm = try WRealm.safe()
                    guard let instance = realm.objects(SignalDeviceStorageItem.self).filter(predicate).first else {
                        return true
                    }
                    if instance.state != SignalDeviceStorageItem.TrustState.trusted {
                        akeManager.writeTrustedDevice(jid: deviceOwner ?? XMPPMessage(from: messageContainer).from!.bare, deviceId: itemDeviceId)
                        try realm.write {
                            instance.trustedByDeviceId = String(deviceId)
                        }
                        self.getUserTrustedDevices(jid: XMPPJID(string: deviceOwner!)!, deviceId: String(itemDeviceId))
                    }
                }
            }
            
            return true
        } catch {
            fatalError()
        }
    }
    
    func didReceivedTrustedSharingEvent(message: XMPPMessage) -> Bool {
        guard let jid = message.from,
              let event = message.element(forName: "event"),
              let items = event.element(forName: "items"),
              items.attributeStringValue(forName: "node") == self.node,
              let item = items.element(forName: "item"),
              let publisherDeviceId = item.attributeStringValue(forName: "id"),
              let share = item.element(forName: "share"),
              let timestamp = share.element(forName: "trusted-items")?.attributeStringValue(forName: "timestamp") else {
            return false
        }
        
        guard let deviceId = AccountManager.shared.find(for: self.owner)?.omemo.localStore.localDeviceId() else {
            fatalError()
        }
        if String(deviceId) == publisherDeviceId {
            return true
        }
        
        let predicateForSessions = NSPredicate(format: "owner == %@ AND jid == %@ AND deviceId == %@", argumentArray: [self.owner, jid.bare, Int(publisherDeviceId)!])
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.objects(SignalDeviceStorageItem.self).filter(predicateForSessions).first else {
                return true
            }
            if instance.state != SignalDeviceStorageItem.TrustState.trusted {
                return true
            }
            
            if instance.lastTrustedItemsUpdateTimestamp == timestamp {
                return true
            }
        } catch {
            fatalError()
        }
        
        let itemsToGet = DDXMLElement(name: "items")
        itemsToGet.addAttribute(withName: "node", stringValue: self.node)
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        pubsub.addChild(itemsToGet)
        let iq = XMPPIQ(iqType: .get, to: jid, child: pubsub)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
        
        return true
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        guard let jid = iq.from,
              let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              let items = pubsub.element(forName: "items") else {
            return false
        }
        let itemList = items.elements(forName: "item")
        if itemList.isEmpty {
            return false
        }
        var isPublicationNeeded = false
        for item in itemList {
            guard let publisherDeviceId = item.attributeStringValue(forName: "id"),
                  let share = item.element(forName: "share"),
                  let timestamp = share.element(forName: "trusted-items")?.attributeStringValue(forName: "timestamp"),
                  let signature = try! share.element(forName: "signature")?.stringValue?.base64decoded(),
                  let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
                return false
            }
            
            let predicateForDevices = NSPredicate(format: "owner == %@ AND jid == %@ AND deviceId == %@", argumentArray: [self.owner, jid.bare, Int(publisherDeviceId)!])
            do {
                let realm = try WRealm.safe()
                guard let instance = realm.objects(SignalDeviceStorageItem.self).filter(predicateForDevices).first else {
                    continue
                }
                if instance.state != SignalDeviceStorageItem.TrustState.trusted {
                    continue
                }
                try realm.write {
                    instance.lastTrustedItemsUpdateTimestamp = timestamp
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
//                stringToVerifySignature += "<"
            }
            
            let userPublicKey = akeManager.getUsersPublicKey(jid: jid.bare, deviceId: Int(publisherDeviceId)!)
            if !Ed25519.verifySignature(Data(signature), publicKey: Data(userPublicKey), data: Data(stringToVerifySignature.bytes)) {
                continue
            }
            
            do {
                let realm = try WRealm.safe()
                for item in trustedItemsList {
                    let trustsList = item.elements(forName: "trust")
                    for trust in trustsList {
                        guard let trustKey = try String(bytes: (trust.stringValue?.base64decoded())!, encoding: .utf8),
                              let deviceId = Int(trustKey.components(separatedBy: "::")[0]) else {
                            fatalError()
                        }
                        let predicateForDevices = NSPredicate(format: "owner == %@ AND jid == %@ AND deviceId == %@", argumentArray: [self.owner, jid.bare, deviceId])
                        do {
                            guard let instance = realm.objects(SignalDeviceStorageItem.self).filter(predicateForDevices).first else {
                                continue
                            }
                            if instance.state != SignalDeviceStorageItem.TrustState.trusted {
                                akeManager.writeTrustedDevice(jid: jid.bare, deviceId: deviceId)
                                try realm.write {
                                    instance.trustedByDeviceId = publisherDeviceId
                                }
                                
                                // if the device has trusted its device then it should publish a new list of trusted devices of the device
                                if self.owner == jid.bare {
                                    isPublicationNeeded = true
                                }
                                
//                                let item = DDXMLElement(name: "item")
//                                item.addAttribute(withName: "id", stringValue: String(deviceId))
//                                let itemsToGet = DDXMLElement(name: "items")
//                                itemsToGet.addAttribute(withName: "node", stringValue: self.node)
//                                itemsToGet.addChild(item)
//                                let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
//                                pubsub.addChild(itemsToGet)
//                                let iq = XMPPIQ(iqType: .get, to: jid, child: pubsub)
//                                
//                                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
//                                    stream.send(iq)
//                                })
                            }
                        } catch {
                            fatalError()
                        }
                    }
                }
                continue
            } catch {
                fatalError()
            }
        }
        if isPublicationNeeded {
            guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
                fatalError()
            }
            self.publicOwnTrustedDevices(publisherDeviceId: String(localStore.localDeviceId()))
        }
        return true
    }
    
    func sendNotificationWithContactsDevices(opponentFullJid: XMPPJID, deviceId: Int) {
        let share = DDXMLElement(name: "share", xmlns: self.getPrimaryNamespace())
        share.addAttribute(withName: "usage", stringValue: "urn:xmpp:omemo:2")
        
        var omemoFingerprint = ""
        
        do {
            let realm = try WRealm.safe()
            let predicate = NSPredicate(format: "owner == %@ AND jid != %@ AND state_ == %@", argumentArray: [self.owner, self.owner, "trusted"])
            let instances = realm.objects(SignalDeviceStorageItem.self).filter(predicate)
            if instances.isEmpty {
                return
            }
            var jids: [String] = []
            for instance in instances {
                if !jids.contains(where: { $0 == instance.jid }) {
                    jids.append(instance.jid)
                }
            }
            for jid in jids {
                let trustedItems = DDXMLElement(name: "trusted-items")
                trustedItems.addAttribute(withName: "owner", stringValue: jid)
                trustedItems.addAttribute(withName: "timestamp", stringValue: String(Date().timeIntervalSince1970.rounded()))
                for instance in instances {
                    if instance.jid == jid {
                        let trustedKey = String(instance.deviceId) + "::" + instance.fingerprint
                        let trust = DDXMLElement(name: "trust", stringValue: trustedKey.toBase64())
                        trust.addAttribute(withName: "timestamp", stringValue: String(instance.trustDate.timeIntervalSince1970.rounded()))
                        trustedItems.addChild(trust)
                    }
                }
                share.addChild(trustedItems)
            }
            
            let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: deviceId))
            omemoFingerprint = deviceInstance!.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
        } catch {
            fatalError()
        }
        
        guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
              let omemoManager = AccountManager.shared.find(for: self.owner)?.omemo,
              let privateKey = akeManager.keyPair?.privateKey.bytes else {
            fatalError()
        }
        let publicKey = akeManager.getUsersPublicKey(jid: self.owner, deviceId: deviceId)
        let fingerprint = publicKey.toHexString()
        
        let identityXML = DDXMLElement(name: "identity", stringValue: omemoFingerprint)
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
        }
        
        let keyPair = Curve25519.load(fromPublicKey: akeManager.keyPair?.publicKey, andPrivateKey: akeManager.keyPair?.privateKey)
        let signature = Ed25519.sign(Data(stringToHash.bytes), with: keyPair)

        let signatureXML = DDXMLElement(name: "signature", stringValue: signature!.base64EncodedString())
        signatureXML.addAttribute(withName: "xmlns", stringValue: self.getPrimaryNamespace())
        share.addChild(signatureXML)
        
        let message = XMPPMessage(messageType: .chat, to: opponentFullJid, elementID: UUID().uuidString, child: share)
        message.addAttribute(withName: "from", stringValue: AccountManager.shared.find(for: self.owner)!.xmppStream.myJID!.full)
        
        let omemoEnvelope = omemoManager.prepareStanzaContent(message: "", date: Date(), jid: opponentFullJid.bare, additionalContent: [message], ignoreTimeSignature: true)
        let omemoEncrypted = try! omemoManager.encryptMessage(message: omemoEnvelope!, to: opponentFullJid.bare)
        let omemoMessage = XMPPMessage(messageType: .chat, to: opponentFullJid, elementID: UUID().uuidString, child: omemoEncrypted)
        omemoMessage.addBody("Message was encrypted by OMEMO".localizeString(id: "message_omemo_encryption", arguments: []))
        let encryptionElement = DDXMLElement(name: "encryption", xmlns: "urn:xmpp:eme:0")
        encryptionElement.addAttribute(withName: "namespace", stringValue: "urn:xmpp:omemo:2")
        omemoMessage.addChild(encryptionElement)
        omemoMessage.addOriginId(UUID().uuidString)
        omemoMessage.addAttribute(withName: "from", stringValue: self.owner)
        
        let iq = akeManager.getNotificationContainer(message: XMPPMessage(from: omemoMessage), notificationTo: opponentFullJid)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
    }
    
    func publicOwnTrustedDevices(publisherDeviceId: String) {
        let share = DDXMLElement(name: "share", xmlns: self.getPrimaryNamespace())
        share.addAttribute(withName: "usage", stringValue: "urn:xmpp:omemo:2")
        
        var omemoFingerprint = ""
        
        do {
            let realm = try WRealm.safe()
            let predicate = NSPredicate(format: "owner == %@ AND jid == %@ AND state_ == %@", argumentArray: [self.owner, self.owner, "trusted"])
            let instances = realm.objects(SignalDeviceStorageItem.self).filter(predicate)
            let trustedItems = DDXMLElement(name: "trusted-items")
            trustedItems.addAttribute(withName: "timestamp", stringValue: String(Date().timeIntervalSince1970.rounded()))
            for instance in instances {
                let trustedKey = String(instance.deviceId) + "::" + instance.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
                let trust = DDXMLElement(name: "trust", stringValue: trustedKey.toBase64())
                trust.addAttribute(withName: "timestamp", stringValue: String(instance.trustDate.timeIntervalSince1970.rounded()))
                trustedItems.addChild(trust)
            }
            share.addChild(trustedItems)
            
            let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: Int(publisherDeviceId)!))
            omemoFingerprint = deviceInstance!.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
        } catch {
            fatalError()
        }
        
        guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
            fatalError()
        }
        
        let keyPair = localStore.getIdentityKeyPair()
        let publicKey = keyPair.publicKey.dropFirst()
        
        let fingerprint = publicKey.toHexString()
        
        let identityXML = DDXMLElement(name: "identity", stringValue: omemoFingerprint)
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
        }
        
        let keyPairCurve25519 = Curve25519.load(fromPublicKey: keyPair.publicKey, andPrivateKey: keyPair.privateKey)
        let signature = Ed25519.sign(Data(stringToHash.bytes), with: keyPairCurve25519)

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
            stream.send(iq)
        })
    }
    
    func getUserTrustedDevices(jid: XMPPJID, deviceId: String? = nil) {
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: self.node)
        
        if deviceId != nil {
            let item = DDXMLElement(name: "item")
            item.addAttribute(withName: "id", stringValue: deviceId!)
            items.addChild(item)
        }
        
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        pubsub.addChild(items)
        
        let iq = XMPPIQ(iqType: .get, to: jid, child: pubsub)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            stream.send(iq)
        })
    }
}
