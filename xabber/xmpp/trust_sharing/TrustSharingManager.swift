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
    
    static let receivedTrustedDevicesAfterVerification = NSNotification.Name("com.xabber.ios.ake.receivedTrustedDevicesAfterVerification")
    
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
    
    func didReceivedListOfContactsDevices(message: XMPPMessage) -> Bool {
        guard let notify = message.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns) ?? message.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns),
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
        
        guard let content = messageContainer.element(forName: "content"),
              let jid = messageContainer.element(forName: "from")?.attributeStringValue(forName: "jid"),
              let share = content.element(forName: "share", xmlns: getPrimaryNamespace()) ?? content.element(forName: "update", xmlns: getPrimaryNamespace()),
              let signature = try! share.element(forName: "signature")?.stringValue?.base64decoded(),
              let identity = share.element(forName: "identity"),
              let deviceIdRaw = identity.attributeStringValue(forName: "id"),
              let deviceId = Int(deviceIdRaw) else {
            return false
        }
        
        if deviceId == omemoManager.localStore.localDeviceId() {
            return true
        }
        
        // a delay of 2 sec is set so that the device has time to change its status to trusted if the list was requested after successful verification
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
            do {
                let realm = try WRealm.safe()
                guard let instance = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@ AND deviceId == %@", self.owner, jid, deviceId).first else {
                    return
                }
                if instance.state != SignalDeviceStorageItem.TrustState.trusted {
                    return
                }
            } catch {
                DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            }
            
            let itemsList = share.elements(forName: "items").sorted(by: { $0.attributeStringValue(forName: "timestamp") ?? "" > $1.attributeStringValue(forName: "timestamp") ?? "" })
            
            if !self.checkItemSignature(jid: jid, deviceId: deviceId, signature: Data(signature), itemsList: itemsList) {
                return
            }
            
            _ = self.handleTrustItems(publisherDeviceId: deviceId, itemsList: itemsList)
            
        }
        
        return true
    }
    
    func didReceivedTrustedSharingEvent(message: XMPPMessage) -> Bool {
        guard let jid = message.from,
              let event = message.element(forName: "event"),
              let pubsubItems = event.element(forName: "items"),
              pubsubItems.attributeStringValue(forName: "node") == self.node,
              let pubsubItem = pubsubItems.element(forName: "item"),
              let publisherDeviceIdRaw = pubsubItem.attributeStringValue(forName: "id"),
              let publisherDeviceId = Int(publisherDeviceIdRaw),
              let share = pubsubItem.element(forName: "share"),
              let trustedItemsList = share.element(forName: "items") ?? share.element(forName: "trusted-items"),
              let timestamp = trustedItemsList.attributeStringValue(forName: "timestamp") else {
            return false
        }
        
        var signature: [UInt8] = []
        do {
            signature = try share.element(forName: "signature")?.stringValue?.base64decoded() ?? []

        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return true
        }
        
        guard let deviceId = AccountManager.shared.find(for: self.owner)?.omemo.localStore.localDeviceId() else {
            DDLogDebug("TrustSharingManager: \(#function).")
            return true
        }
        if String(deviceId) == publisherDeviceIdRaw {
            return true
        }
        
        var isPublicationNeeded = false
        let predicateForSessions = NSPredicate(format: "owner == %@ AND jid == %@ AND deviceId == %@", argumentArray: [self.owner, jid.bare, publisherDeviceId])
        
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.objects(SignalDeviceStorageItem.self).filter(predicateForSessions).first else {
                return true
            }
            if instance.state != SignalDeviceStorageItem.TrustState.trusted {
                self.getUserTrustedDevices(jid: jid.bareJID)
                
                return true
            }
            
            if instance.lastTrustedItemsUpdateTimestamp == timestamp {
                return true
            } else {
                try realm.write {
                    instance.lastTrustedItemsUpdateTimestamp = timestamp
                }
            }
            
            if !self.checkItemSignature(jid: jid.bare, deviceId: publisherDeviceId, signature: Data(signature), itemsList: [trustedItemsList]) {
                return true
            }
            
            isPublicationNeeded = self.handleTrustItems(jid: jid.bare, publisherDeviceId: publisherDeviceId, itemsList: [trustedItemsList])
            
            do {
                let realm = try WRealm.safe()
                let instance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND opponentDeviceId == %@", self.owner, publisherDeviceId).first
                if instance != nil && instance?.state == .trusted {
//                    NotificationCenter.default.post(name: NSNotification.Name(rawValue: "show_success"),
//                                                    object: self,
//                                                    userInfo: [
//                                                        "owner": self.owner,
//                                                        "jid": jid!.bare,
//                                                        "deviceId": publisherDeviceIdRaw!
//                                                    ]
//                    )

                }
            } catch {
                DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            }
            
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return true
        }
        
        if isPublicationNeeded {
            guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
                DDLogDebug("TrustSharingManager: \(#function).")
                return true
            }
            self.publicOwnTrustedDevices(publisherDeviceId: String(localStore.localDeviceId()))
        }
        
        return true
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        guard let jid = iq.from,
              let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              let items = pubsub.element(forName: "items") ?? pubsub.element(forName: "trusted-items") else {
            return false
        }
        
        let itemList = items.elements(forName: "item")
        if itemList.isEmpty {
            return false
        }
        
        var isPublicationNeeded = false
        for item in itemList {
            guard let publisherDeviceIdRaw = item.attributeStringValue(forName: "id"),
                  let publisherDeviceId = Int(publisherDeviceIdRaw),
                  let share = item.element(forName: "share"),
                  let timestamp = share.element(forName: "items")?.attributeStringValue(forName: "timestamp") ?? share.element(forName: "trusted-items")?.attributeStringValue(forName: "timestamp"),
                  let signature = try! share.element(forName: "signature")?.stringValue?.base64decoded() else {
                return false
            }
            
            let trustedItemsList = share.element(forName: "items") ?? share.element(forName: "trusted-items")
            if trustedItemsList == nil {
                return true
            }
            
            let predicateForDevices = NSPredicate(format: "owner == %@ AND jid == %@ AND deviceId == %@", argumentArray: [self.owner, jid.bare, publisherDeviceId])
            do {
                let realm = try WRealm.safe()
                if let instance = realm.objects(SignalDeviceStorageItem.self).filter(predicateForDevices).first {
                    if instance.state != SignalDeviceStorageItem.TrustState.trusted || instance.lastTrustedItemsUpdateTimestamp == timestamp {
                        continue
                    }
                    try realm.write {
                        instance.lastTrustedItemsUpdateTimestamp = timestamp
                    }
                }
            } catch {
                DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
                return true
            }
            
            if !self.checkItemSignature(jid: jid.bare, deviceId: publisherDeviceId, signature: Data(signature), itemsList: [trustedItemsList!]) {
                continue
            }
            
            isPublicationNeeded = self.handleTrustItems(jid: jid.bare, publisherDeviceId: publisherDeviceId, itemsList: [trustedItemsList!])
            
            do {
                let realm = try WRealm.safe()
                let instance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND opponentDeviceId == %@", self.owner, publisherDeviceId).first
                if instance != nil && instance?.state == .trusted {
//                    NotificationCenter.default.post(name: NSNotification.Name(rawValue: "show_success"),
//                                                    object: self,
//                                                    userInfo: [
//                                                        "owner": self.owner,
//                                                        "jid": jid.bare,
//                                                        "deviceId": publisherDeviceIdRaw
//                                                    ]
//                    )

                }
            } catch {
                DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        if isPublicationNeeded {
            guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
                DDLogDebug("TrustSharingManager: \(#function).")
                return true
            }
            self.publicOwnTrustedDevices(publisherDeviceId: String(localStore.localDeviceId()))
        } else if !isPublicationNeeded && self.owner == jid.bare {
            do {
                let realm = try WRealm.safe()
                let instance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, jid.bare).first
                if instance != nil {
                    try realm.write {
                        realm.delete(instance!)
                    }
                }
            } catch {
                DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            }
        }
        return true
    }
    
    func checkItemSignature(jid: String, deviceId: Int, signature: Data, itemsList: [DDXMLElement]) -> Bool {
        var stringToVerifySignature = ""
        
        for item in itemsList {
            guard let timestamp = item.attribute(forName: "timestamp")?.stringValue else {
                DDLogDebug("TrustSharingManager: \(#function).")
                return false
            }
            stringToVerifySignature += timestamp
            
            let trustItems = item.elements(forName: SignalDeviceStorageItem.TrustState.trusted.rawValue)
            let distrustedItems = item.elements(forName: SignalDeviceStorageItem.TrustState.distrusted.rawValue)
            let revokedItems = item.elements(forName: SignalDeviceStorageItem.TrustState.revoked.rawValue)
            
            let devicesList = (trustItems + distrustedItems + revokedItems).sorted(by: { $0.attributeStringValue(forName: "timestamp") ?? "" > $1.attributeStringValue(forName: "timestamp") ?? "" })
            
            for trust in devicesList {
                guard let timestamp = trust.attributeStringValue(forName: "timestamp"),
                      let trustKey = trust.stringValue else {
                    DDLogDebug("TrustSharingManager: \(#function).")
                    return true
                }
                stringToVerifySignature += "<" + timestamp + "/" + trustKey
            }
        }
        
        var pubKey: [UInt8]? = nil
        do {
            let realm = try WRealm.safe()
            if let storedBundle = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: jid, deviceId: deviceId)) {
                pubKey = try storedBundle.identityKey?.base64decoded()
                
                if pubKey == nil {
                    return false
                }
                
                if pubKey!.count == 33 {
                    pubKey = Array(pubKey!.dropFirst())
                }
            } else {
                return false
            }
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
        }
        
        guard let pubKey = pubKey else {
            return false
        }
        
        if !Ed25519.verifySignature(signature, publicKey: Data(pubKey), data: Data(stringToVerifySignature.bytes)) {
            return false
        }
        
        return true
    }
    
    func handleTrustItems(jid: String? = nil, publisherDeviceId: Int, itemsList: [DDXMLElement]) -> Bool {
        var isShouldPublish = false
        
        for item in itemsList {
            let jid = jid ?? item.attributeStringValue(forName: "owner")
            if jid == nil {
                return false
            }
            
            let trustItems = item.elements(forName: SignalDeviceStorageItem.TrustState.trusted.rawValue)
            let distrustedItems = item.elements(forName: SignalDeviceStorageItem.TrustState.distrusted.rawValue)
            let revokedItems = item.elements(forName: SignalDeviceStorageItem.TrustState.revoked.rawValue)
            
            let devicesList = trustItems + distrustedItems + revokedItems
            
            for itemDevice in devicesList {
                do {
                    let trustKey = try String(bytes: (itemDevice.stringValue?.base64decoded())!, encoding: .utf8)
                    if trustKey?.components(separatedBy: "::") == nil {
                        return false
                    }
                    let deviceId = Int((trustKey?.components(separatedBy: "::")[0])!)
                    if deviceId == nil {
                        return false
                    }
                    
                    let realm = try WRealm.safe()
                    let instance = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@ AND deviceId == %@", self.owner, jid!, deviceId!).first
                    
                    let state = SignalDeviceStorageItem.TrustState(rawValue: itemDevice.name ?? "")
                    if state == nil {
                        continue
                    }
                    
                    if instance == nil {
                        if state == SignalDeviceStorageItem.TrustState.revoked {
                            let instance = SignalDeviceStorageItem()
                            instance.owner = self.owner
                            instance.jid = jid!
                            instance.primary = SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid!, deviceId: deviceId!)
                            instance.deviceId = deviceId!
                            instance.state = .revoked
                            instance.freshlyUpdated = true
                            
                            try realm.write {
                                realm.add(instance)
                            }
                        }
                        
                        continue
                    }
                    
                    if instance!.state != state {
                        try realm.write {
                            instance!.state = state!
                            if state == .trusted {
                                instance?.trustDate = Date()
                                instance!.trustedByDeviceId = String(publisherDeviceId)
                            }
                        }
                        
                        // if the device has trusted own device then it should publish a new list of trusted devices
                        if self.owner == jid {
                            isShouldPublish = true
                        }
                        
                    }
                    
                } catch {
                    DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
                }
            }
        }
        
        return isShouldPublish
    }
    
    func sendUpdateOfContactsDevices(jid: String, updatedDevicesIds: [Int]) {
        let update = DDXMLElement(name: "update", xmlns: self.getPrimaryNamespace())
        update.addAttribute(withName: "usage", stringValue: "urn:xmpp:omemo:2")
        
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "owner", stringValue: jid)
        let itemsTimestamp = String(Int(Date().timeIntervalSince1970.rounded()))
        items.addAttribute(withName: "timestamp", stringValue: itemsTimestamp)
        
        var stringToHash = ""
        stringToHash += itemsTimestamp
        
        let localDeviceId = AccountManager.shared.find(for: self.owner)?.omemo.localStore.localDeviceId()
        if localDeviceId == nil {
            return
        }
        
        var omemoFingerprint = ""
        
        do {
            let realm = try WRealm.safe()
            for device in updatedDevicesIds {
                let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: device))
                if instance == nil {
                    return
                }
                
                let trustedKey = String(instance!.deviceId) + "::" + instance!.fingerprint
                let deviceItem = DDXMLElement(name: instance!.state_, stringValue: trustedKey.toBase64())
                let trustTimestamp = String(Int(instance!.trustDate.timeIntervalSince1970.rounded()))
                deviceItem.addAttribute(withName: "timestamp", stringValue: trustTimestamp)
                items.addChild(deviceItem)
            }
            
            let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: localDeviceId!))
            if deviceInstance == nil {
                return
            }
            
            omemoFingerprint = deviceInstance!.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
        }
        
        update.addChild(items)
        
        let trustItems = items.elements(forName: SignalDeviceStorageItem.TrustState.trusted.rawValue)
        let distrustedItems = items.elements(forName: SignalDeviceStorageItem.TrustState.distrusted.rawValue)
        let revokedItems = items.elements(forName: SignalDeviceStorageItem.TrustState.revoked.rawValue)
        
        let devicesList = (trustItems + distrustedItems + revokedItems).sorted(by: { $0.attributeStringValue(forName: "timestamp") ?? "" > $1.attributeStringValue(forName: "timestamp") ?? "" })
        
        for item in devicesList {
            guard let timestamp = item.attributeStringValue(forName: "timestamp"),
                  let trustKey = item.stringValue else {
                DDLogDebug("TrustSharingManager: \(#function).")
                return
            }
            stringToHash += "<" + timestamp + "/" + trustKey
        }
        
        let keyPair = AccountManager.shared.find(for: self.owner)?.omemo.localStore.getIdentityKeyPair()
        if keyPair == nil {
            return
        }
//        let privateKey = keyPair.privateKey.bytes
        
//        let publicKey = AccountManager.shared.find(for: self.owner)?.akeManager.getUsersPublicKey(jid: self.owner, deviceId: localDeviceId)
        
        let identityXML = DDXMLElement(name: "identity", stringValue: omemoFingerprint)
        identityXML.addAttribute(withName: "id", stringValue: String(localDeviceId!))
        update.addChild(identityXML)
        
        let ecKeyPair = Curve25519.load(fromPublicKey: keyPair!.publicKey, andPrivateKey: keyPair!.privateKey)
        guard let signature = Ed25519.sign(Data(stringToHash.bytes), with: ecKeyPair) else {
            DDLogDebug("TrustSharingManager: \(#function).")
            return
        }

        let signatureXML = DDXMLElement(name: "signature", stringValue: signature.base64EncodedString())
        signatureXML.addAttribute(withName: "xmlns", stringValue: self.getPrimaryNamespace())
        update.addChild(signatureXML)
        
        let omemoEnvelope = AccountManager.shared.find(for: self.owner)?.omemo.prepareStanzaContent(message: "", date: Date(), jid: self.owner, additionalContent: [update], ignoreTimeSignature: true)
        if omemoEnvelope == nil {
            return
        }
        
        var omemoEncrypted: DDXMLElement? = nil
        do {
            omemoEncrypted = try AccountManager.shared.find(for: self.owner)?.omemo.encryptMessage(message: omemoEnvelope!, to: self.owner)
            
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return
        }
        
        if omemoEncrypted == nil {
            return
        }
        
        let omemoMessage = XMPPMessage(messageType: .chat, to: XMPPJID(string: self.owner), elementID: UUID().uuidString)
        omemoMessage.addChild(omemoEncrypted!.copy() as! DDXMLElement)
        omemoMessage.addBody("Message was encrypted by OMEMO".localizeString(id: "message_omemo_encryption", arguments: []))
        let encryptionElement = DDXMLElement(name: "encryption", xmlns: "urn:xmpp:eme:0")
        encryptionElement.addAttribute(withName: "namespace", stringValue: "urn:xmpp:omemo:2")
        omemoMessage.addChild(encryptionElement)
        omemoMessage.addOriginId(UUID().uuidString)
        omemoMessage.addAttribute(withName: "from", stringValue: self.owner)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            let iq = user.akeManager.getNotificationContainer(message: XMPPMessage(from: omemoMessage), notificationTo: XMPPJID(string: self.owner)!)
            stream.send(iq)
        })
        
    }
    
    func sendListOfContactsDevices() {
        let share = DDXMLElement(name: "share", xmlns: self.getPrimaryNamespace())
        share.addAttribute(withName: "usage", stringValue: "urn:xmpp:omemo:2")
        
//        guard let localStore = AccountManager.shared.find(for: self.owner)?.omemo.localStore else {
//            return
//        }
        let localDeviceId = AccountManager.shared.find(for: self.owner)?.omemo.localStore.localDeviceId()
        if localDeviceId == nil {
            return
        }
        
        var omemoFingerprint = ""
        
        do {
            let realm = try WRealm.safe()
            
            // Search for all devices that need to be sent
            let instances = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid != %@ AND state_ IN %@", self.owner, self.owner, [SignalDeviceStorageItem.TrustState.trusted.rawValue, SignalDeviceStorageItem.TrustState.distrusted.rawValue, SignalDeviceStorageItem.TrustState.revoked.rawValue])
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
                let items = DDXMLElement(name: "items")
                items.addAttribute(withName: "owner", stringValue: jid)
                items.addAttribute(withName: "timestamp", stringValue: String(Int(Date().timeIntervalSince1970.rounded())))
                for instance in instances {
                    if instance.jid == jid {
                        let trustedKey = String(instance.deviceId) + "::" + instance.fingerprint
                        let deviceItem = DDXMLElement(name: instance.state_, stringValue: trustedKey.toBase64())
                        deviceItem.addAttribute(withName: "timestamp", stringValue: String(Int(instance.trustDate.timeIntervalSince1970.rounded())))
                        items.addChild(deviceItem)
                    }
                }
                share.addChild(items)
            }
            
            guard let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: localDeviceId!)) else {
                DDLogDebug("TrustSharingManager: \(#function).")
                return
            }
            
            omemoFingerprint = deviceInstance.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return
        }
        
//        guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
//            DDLogDebug("TrustSharingManager: \(#function).")
//            return
//        }
        
        let keyPair = AccountManager.shared.find(for: owner)?.omemo.localStore.getIdentityKeyPair()
//        let privateKey = keyPair?.privateKey.bytes
        
//        guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
//              let omemoManager = AccountManager.shared.find(for: self.owner)?.omemo else {
//            DDLogDebug("TrustSharingManager: \(#function).")
//            return
//        }
        
        let publicKey = AccountManager.shared.find(for: self.owner)?.akeManager.getUsersPublicKey(jid: self.owner, deviceId: localDeviceId!)
        let fingerprint = publicKey?.toHexString()
        
        let identityXML = DDXMLElement(name: "identity", stringValue: omemoFingerprint)
        identityXML.addAttribute(withName: "id", stringValue: String(localDeviceId!))
        share.addChild(identityXML)
        
        var stringToHash = ""
        let trustedItemsList = share.elements(forName: "items").sorted(by: { $0.attributeStringValue(forName: "timestamp") ?? "" > $1.attributeStringValue(forName: "timestamp") ?? "" })
        
        for item in trustedItemsList {
            guard let timestamp = item.attribute(forName: "timestamp")?.stringValue else {
                DDLogDebug("TrustSharingManager: \(#function).")
                return
            }
            
            stringToHash += timestamp
            
            let trustItems = item.elements(forName: SignalDeviceStorageItem.TrustState.trusted.rawValue)
            let distrustedItems = item.elements(forName: SignalDeviceStorageItem.TrustState.distrusted.rawValue)
            let revokedItems = item.elements(forName: SignalDeviceStorageItem.TrustState.revoked.rawValue)
            
            let devicesList = (trustItems + distrustedItems + revokedItems).sorted(by: { $0.attributeStringValue(forName: "timestamp") ?? "" > $1.attributeStringValue(forName: "timestamp") ?? "" })
            
//            let devicesList = item.elements(forName: SignalDeviceStorageItem.TrustState.trusted.rawValue).sorted(by: { $0.attributeStringValue(forName: "timestamp") ?? "" > $1.attributeStringValue(forName: "timestamp") ?? "" })
            
            for item in devicesList {
                guard let timestamp = item.attributeStringValue(forName: "timestamp"),
                      let trustKey = item.stringValue else {
                    DDLogDebug("TrustSharingManager: \(#function).")
                    return
                }
                stringToHash += "<" + timestamp + "/" + trustKey
            }
        }
        
        let ecKeyPair = Curve25519.load(fromPublicKey: keyPair?.publicKey, andPrivateKey: keyPair?.privateKey)
        guard let signature = Ed25519.sign(Data(stringToHash.bytes), with: ecKeyPair),
              let myFullJid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full else {
            DDLogDebug("TrustSharingManager: \(#function).")
            return
        }

        let signatureXML = DDXMLElement(name: "signature", stringValue: signature.base64EncodedString())
        signatureXML.addAttribute(withName: "xmlns", stringValue: self.getPrimaryNamespace())
        share.addChild(signatureXML)
        
        guard let omemoEnvelope = AccountManager.shared.find(for: self.owner)?.omemo.prepareStanzaContent(message: "", date: Date(), jid: self.owner, additionalContent: [share], ignoreTimeSignature: true) else {
            DDLogDebug("TrustSharingManager: \(#function).")
            return
        }
        
        var omemoEncrypted: DDXMLElement? = nil
        do {
            omemoEncrypted = try AccountManager.shared.find(for: self.owner)?.omemo.encryptMessage(message: omemoEnvelope, to: self.owner)
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return
        }
        
        if omemoEncrypted == nil {
            return
        }
        
        let omemoMessage = XMPPMessage(messageType: .chat, to: XMPPJID(string: self.owner), elementID: UUID().uuidString, child: omemoEncrypted)
        omemoMessage.addBody("Message was encrypted by OMEMO".localizeString(id: "message_omemo_encryption", arguments: []))
        let encryptionElement = DDXMLElement(name: "encryption", xmlns: "urn:xmpp:eme:0")
        encryptionElement.addAttribute(withName: "namespace", stringValue: "urn:xmpp:omemo:2")
        omemoMessage.addChild(encryptionElement)
        omemoMessage.addOriginId(UUID().uuidString)
        omemoMessage.addAttribute(withName: "from", stringValue: self.owner)
        
//        let iq = akeManager.getNotificationContainer(message: XMPPMessage(from: omemoMessage), notificationTo: XMPPJID(string: self.owner)!)
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            let iq = user.akeManager.getNotificationContainer(message: XMPPMessage(from: omemoMessage), notificationTo: XMPPJID(string: self.owner)!)
            stream.send(iq)
        })
    }
    
    func publicOwnTrustedDevices(publisherDeviceId: String) {
        let share = DDXMLElement(name: "share", xmlns: self.getPrimaryNamespace())
        share.addAttribute(withName: "usage", stringValue: "urn:xmpp:omemo:2")
        
        var omemoFingerprint = ""
        
        do {
            let realm = try WRealm.safe()
            let predicate = NSPredicate(format: "owner == %@ AND jid == %@ AND state_ == %@", argumentArray: [self.owner, self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue])
            let instances = realm.objects(SignalDeviceStorageItem.self).filter(predicate)
            let trustedItems = DDXMLElement(name: "items")
            trustedItems.addAttribute(withName: "timestamp", stringValue: String(Int(Date().timeIntervalSince1970.rounded())))
            for instance in instances {
                let trustedKey = String(instance.deviceId) + "::" + instance.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
                let trust = DDXMLElement(name: "trust", stringValue: trustedKey.toBase64())
                trust.addAttribute(withName: "timestamp", stringValue: String(Int(instance.trustDate.timeIntervalSince1970.rounded())))
                trustedItems.addChild(trust)
            }
            share.addChild(trustedItems)
            
            guard let publisherdeviceIdInt = Int(publisherDeviceId) else {
                DDLogDebug("TrustSharingManager: \(#function).")
                return
            }
            
            guard let deviceInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: publisherdeviceIdInt)) else {
                DDLogDebug("TrustSharingManager: \(#function).")
                return
            }
            omemoFingerprint = deviceInstance.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return
        }
        
        guard let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
            DDLogDebug("TrustSharingManager: \(#function).")
            return
        }
        
        let keyPair = localStore.getIdentityKeyPair()
        let publicKey = keyPair.publicKey.dropFirst()
        
        let identityXML = DDXMLElement(name: "identity", stringValue: omemoFingerprint)
        identityXML.addAttribute(withName: "id", stringValue: String(publisherDeviceId))
        share.addChild(identityXML)
        
        var stringToHash = ""
        let trustedItemsList = share.elements(forName: "items").sorted(by: { $0.attributeStringValue(forName: "timestamp") ?? "" > $1.attributeStringValue(forName: "timestamp") ?? "" })
        
        for item in trustedItemsList {
            guard let timestamp = item.attribute(forName: "timestamp")?.stringValue else {
                DDLogDebug("TrustSharingManager: \(#function).")
                return
            }
            stringToHash += timestamp
            let trustsList = item.elements(forName: "trust").sorted(by: { $0.attributeStringValue(forName: "timestamp") ?? "" > $1.attributeStringValue(forName: "timestamp") ?? "" })
            for trust in trustsList {
                guard let timestamp = trust.attributeStringValue(forName: "timestamp"),
                      let trustKey = trust.stringValue else {
                    DDLogDebug("TrustSharingManager: \(#function).")
                    return
                }
                stringToHash += "<" + timestamp + "/" + trustKey
            }
        }
        
        let keyPairCurve25519 = Curve25519.load(fromPublicKey: keyPair.publicKey, andPrivateKey: keyPair.privateKey)
        guard let signature = Ed25519.sign(Data(stringToHash.bytes), with: keyPairCurve25519) else {
            DDLogDebug("TrustSharingManager: \(#function).")
            return
        }

        let signatureXML = DDXMLElement(name: "signature", stringValue: signature.base64EncodedString())
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
    
    static func remove(for owner: String, commitTransaction: Bool) {
//        do {
//            let realm = try WRealm.safe()
//            let collection = realm.objects(VerificationSessionStorageItem.self)
//                .filter("owner == %@", owner)
//            if commitTransaction {
//                try realm.write {
//                    realm.delete(collection)
//                }
//            } else {
//                realm.delete(collection)
//            }
//        } catch {
//            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
//        }
    }
}
