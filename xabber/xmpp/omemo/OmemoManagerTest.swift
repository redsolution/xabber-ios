//
//  OmemoManagerTest.swift
//  xabber
//
//  Created by Игорь Болдин on 25.02.2022.
//  Copyright © 2022 Igor Boldin. All rights reserved.
//

import Foundation
import XMPPFramework
import RealmSwift
import SignalClient
import SignalCoreKit
import RxSwift
import CryptoSwift
import SwiftKeychainWrapper
import SwiftUI

open class OmemoManager: AbstractXMPPManager {
    override func namespaces() -> [String] {
        return [
            OmemoManager.xmlns
        ]
    }

    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }

    struct PreKeyItem {
        let key: PrivateKey
        let id: UInt32
    }
    
    static let xmlns: String = "urn:xmpp:omemo:2"
    static let signalPreKeysMaxVal: UInt32 = 16777215
    static let signedPreKeyRotationPeriod: TimeInterval = 604800
    
    public var deviceId: UInt32!
    
    internal var deviceName: String = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
    
    internal var isOmemoPrepared: Bool
    
    internal var localAddress: ProtocolAddress!
    internal var localStore: InMemorySignalProtocolStore!
    
//    internal var bundle: PreKeyBundle!
    
    internal var preKey: PreKeyRecord!
    internal var preKeys: [PreKeyRecord] = []
    
    
    static func generatePreKeys() throws -> [PreKeyRecord] {
        return try (0...100).compactMap {
            _ -> PreKeyRecord in
            
            let key = PrivateKey.generate()
            let keyId = UInt32.random(in: 0..<OmemoManager.signalPreKeysMaxVal - 1)
            
            return try PreKeyRecord(id: keyId, publicKey: key.publicKey, privateKey: key)
        }
    }
    
    override init(withOwner owner: String) {
        
        guard let storedDeviceId = CredentialsManager.shared.getDeviceId(for: owner) else {
            self.isOmemoPrepared = false
            super.init(withOwner: owner)
            return
        }
        self.isOmemoPrepared = true
        self.deviceId = UInt32(storedDeviceId)
        super.init(withOwner: owner)
        self.configureLocal(for: storedDeviceId)
    }
    
    public final func configureLocal(for deviceId: Int) {
        do {
            try self.loadKeys(for: deviceId)
        } catch {
            do {
                try initKeys(for: deviceId)
            } catch {
                self.isOmemoPrepared = false
            }
        }
    }
    
    private final func loadKeys(for deviceId: Int) throws {
        localStore = InMemorySignalProtocolStore()
        let signedPreKeyBytes = try CredentialsManager.shared.getKey(for: self.owner, type: .signedPreKey)
        let signedPreKeySignatureBytes = try CredentialsManager.shared.getKey(for: self.owner, type: .signedPreKeySignature)
        let identityKeyBytes = try CredentialsManager.shared.getKey(for: self.owner, type: .identityKey)
        
        let realm = try Realm()
        guard let preKeyPublicRecord = realm
            .objects(SignalPreKeysStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND deviceId == %@", self.owner, self.owner, deviceId)
            .toArray()
            .randomElement() else {
                throw OmemoManagerError.preKeyNotFound
            }
        
        guard let bundleRecord = realm.object(
            ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(
                owner: self.owner,
                jid: self.owner,
                deviceId: deviceId
            )
        ) else {
            throw OmemoManagerError.bundleNotFound
        }
        
        let preKeyPrivateBytes = try CredentialsManager.shared.getPreKey(for: self.owner, id: preKeyPublicRecord.pkId)
        self.preKey = try PreKeyRecord(
            id: UInt32(preKeyPublicRecord.pkId),
            publicKey: try PublicKey(preKeyPublicRecord.preKey),
            privateKey: try PrivateKey(preKeyPrivateBytes))
        
        let signedPreKey = try SignedPreKeyRecord(
            id: UInt32(bundleRecord.signedPreKeyId),
            timestamp: UInt64(bundleRecord.signedPreKeyTimestamp),
            privateKey: try PrivateKey(signedPreKeyBytes),
            signature: signedPreKeySignatureBytes
        )
        let identityKey = try IdentityKey(bytes: identityKeyBytes)
        try localStore.storePreKey(self.preKey, id: self.preKey.id, context: NullContext())
        try localStore.storeSignedPreKey(signedPreKey, id: signedPreKey.id, context: NullContext())
        
        let bundle = try PreKeyBundle(
            registrationId: UInt32(bundleRecord.registrationId),
            deviceId: UInt32(deviceId),
            prekeyId: preKey.id,
            prekey: preKey.publicKey,
            signedPrekeyId: signedPreKey.id,
            signedPrekey: signedPreKey.publicKey,
            signedPrekeySignature: signedPreKey.signature,
            identity: identityKey
        )
        try processPreKeyBundle(
            bundle,
            for: try ProtocolAddress(name: bundleRecord.name, deviceId: UInt32(deviceId)),
            sessionStore: localStore,
            identityStore: localStore,
            context: NullContext()
        )
    }
    
    private final func initKeys(for deviceId: Int) throws {
        localStore = InMemorySignalProtocolStore()
        let preKeys = try initPreKeys(for: deviceId)
        guard let preKey = preKeys.randomElement() else {
            throw OmemoManagerError.preKeyNotFound
        }
        self.preKeys = preKeys
        let identityKey = try localStore.identityKeyPair(context: NullContext()).identityKey
        let signedPreKey = PrivateKey.generate()
        let signedPreKeySignature = try localStore.identityKeyPair(context: NullContext()).privateKey.generateSignature(message: signedPreKey.publicKey.serialize())
        let signedPreKeyRecord = try SignedPreKeyRecord(id: UInt32.random(in: 0..<OmemoManager.signalPreKeysMaxVal - 1), timestamp: UInt64(Date().timeIntervalSince1970), privateKey: signedPreKey, signature: signedPreKeySignature)
        try localStore.storePreKey(preKey, id: preKey.id, context: NullContext())
        try localStore.storeSignedPreKey(signedPreKeyRecord, id: signedPreKeyRecord.id, context: NullContext())
        let bundle = try PreKeyBundle(
            registrationId: try localStore.localRegistrationId(context: NullContext()),
            deviceId: UInt32(deviceId),
            prekeyId: preKey.id,
            prekey: preKey.publicKey,
            signedPrekeyId: signedPreKeyRecord.id,
            signedPrekey: signedPreKeyRecord.publicKey,
            signedPrekeySignature: signedPreKeySignature,
            identity: identityKey
        )
        
        let localAddr = try ProtocolAddress(name: self.owner, deviceId: UInt32(deviceId))
        
        try processPreKeyBundle(
            bundle,
            for: localAddr,
            sessionStore: localStore,
            identityStore: localStore,
            context: NullContext()
        )
        
        let realm = try Realm()
        
        let identityInstance = SignalIdentityStorageItem()
        identityInstance.owner = self.owner
        identityInstance.jid = self.owner
        identityInstance.deviceId = deviceId
        identityInstance.primary = SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: self.owner, deviceId: deviceId)
        identityInstance.name = localAddr.name
        identityInstance.registrationId = Int(bundle.registrationId)
        identityInstance.signedPreKeyId = Int(signedPreKeyRecord.id)
        identityInstance.signedPreKeyTimestamp = Double(signedPreKeyRecord.timestamp)
        
        let preKeysCollection = preKeys.compactMap {
            privateKey -> SignalPreKeysStorageItem in
            let uuid = UUID().uuidString
            let instance = SignalPreKeysStorageItem()
            instance.deviceId = deviceId
            instance.owner = self.owner
            instance.jid = self.owner
            instance.pkId = Int(privateKey.id)
            instance.preKey = Data(privateKey.publicKey.serialize())
            instance.keyUUID = uuid
            instance.primary = SignalPreKeysStorageItem.genPrimary(keyUUID: uuid)
            
            CredentialsManager.shared.setPreKey(for: self.owner, id: Int(privateKey.id), value: Data(privateKey.privateKey.serialize()))
            return instance
        }
        
        let deviceInstance = SignalDeviceStorageItem()
        deviceInstance.name = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        deviceInstance.owner = self.owner
        deviceInstance.jid = self.owner
        deviceInstance.deviceId = deviceId
        deviceInstance.primary = SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: deviceId)
        deviceInstance.fingerprint = Data(identityKey.publicKey.serialize()).formattedFingerprint()
        
        try realm.write {
            realm.add(preKeysCollection)
            realm.add(identityInstance)
            realm.add(deviceInstance)
        }
        
        CredentialsManager.shared.setKey(for: self.owner, type: .identityKey, value: Data(identityKey.serialize()))
        CredentialsManager.shared.setKey(for: self.owner, type: .signedPreKey, value: Data(signedPreKey.serialize()))
        CredentialsManager.shared.setKey(for: self.owner, type: .signedPreKeySignature, value: Data(signedPreKeySignature))
        AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
            user.omemo.updateMyDevice(stream)
        })
    }
    
    fileprivate final func initPreKeys(for deviceId: Int) throws -> [PreKeyRecord] {
        return try (0..<100).compactMap {
            index throws -> PreKeyRecord in
            let id = UInt32.random(in: 0..<OmemoManager.signalPreKeysMaxVal - 1)
            let privateKey = PrivateKey.generate()
            return try PreKeyRecord(id: id, privateKey: privateKey)
        }
    }
    
    private func updateOwnDeviceRecord() throws {
        let realm = try Realm()
        let primary = SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: Int(self.deviceId))
        if realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary) == nil {
            let instance = SignalDeviceStorageItem()
            instance.primary = primary
            instance.owner = self.owner
            instance.jid = self.owner
            instance.deviceId = Int(self.deviceId)
            instance.name = self.deviceName
//            instance.fingerprint = self.bundle.identityKey.publicKey.fing
            
            try realm.write {
                realm.add(instance, update: .modified)
            }
        }
    }
    
    func setupRemoteStore(registrationId: UInt32, address: ProtocolAddress, preKeyId: UInt32, preKey: PublicKey, signedPreKeyId: UInt32, signedPreKey: PublicKey, signedPreKeySignature: [UInt8], identity: IdentityKey) throws {
        
        let remoteBundle = try PreKeyBundle(
            registrationId: registrationId,
            deviceId: address.deviceId,
            prekeyId: preKeyId,
            prekey: preKey,
            signedPrekeyId: signedPreKeyId,
            signedPrekey: signedPreKey,
            signedPrekeySignature: signedPreKeySignature,
            identity: identity
        )
        
        try processPreKeyBundle(
            remoteBundle,
            for: address,
            sessionStore: self.localStore,
            identityStore: self.localStore,
            context: NullContext()
        )
    }
        
    func testCrypt() {
        let message = "Test crypto message"
        
        
        let remote_address = try! ProtocolAddress(name: "+14151111112", deviceId: 1)
        let remote_store = InMemorySignalProtocolStore()
        
        let remote_pre_key = PrivateKey.generate()
        let remote_signed_pre_key = PrivateKey.generate()

        let remote_signed_pre_key_public = remote_signed_pre_key.publicKey.serialize()

        let remote_identity_key = try! remote_store.identityKeyPair(context: NullContext()).identityKey
        let remote_signed_pre_key_signature = try! remote_store.identityKeyPair(context: NullContext()).privateKey.generateSignature(message: remote_signed_pre_key_public)

        
        let remote_prekey_id: UInt32 = 4570
        let remote_signed_prekey_id: UInt32 = 3006

        let remote_bundle = try! PreKeyBundle(registrationId: remote_store.localRegistrationId(context: NullContext()),
                                           deviceId: remote_address.deviceId,
                                           prekeyId: remote_prekey_id,
                                           prekey: remote_pre_key.publicKey,
                                           signedPrekeyId: remote_signed_prekey_id,
                                           signedPrekey: remote_signed_pre_key.publicKey,
                                           signedPrekeySignature: remote_signed_pre_key_signature,
                                           identity: remote_identity_key)

        
        try! processPreKeyBundle(remote_bundle,
                                 for: remote_address,
                                 sessionStore: localStore,
                                 identityStore: localStore,
                                 context: NullContext())


        try! remote_store.storePreKey(PreKeyRecord(id: remote_prekey_id, privateKey: remote_pre_key),
                                   id: remote_prekey_id,
                                   context: NullContext())

        try! remote_store.storeSignedPreKey(
            SignedPreKeyRecord(
                id: remote_signed_prekey_id,
                timestamp: 604800,
                privateKey: remote_signed_pre_key,
                signature: remote_signed_pre_key_signature
            ),
            id: remote_signed_prekey_id,
            context: NullContext()
        )
        
        
        
        
        let ptext2_b = message.bytes
        
        let ptext_a: [UInt8] = message.bytes

        let ctext_a = try! signalEncrypt(message: ptext_a,
                                         for: remote_address,
                                         sessionStore: localStore,
                                         identityStore: localStore,
                                         context: NullContext())



        let ctext_b = try! PreKeySignalMessage(bytes: ctext_a.serialize())

        let ptext_b = try! signalDecryptPreKey(message: ctext_b,
                                               from: localAddress,
                                               sessionStore: remote_store,
                                               identityStore: remote_store,
                                               preKeyStore: remote_store,
                                               signedPreKeyStore: remote_store,
                                               context: NullContext())
        

        let out = String(data: Data(ptext2_b), encoding: .utf8)
        print("CRYPTO TEST MESSAGE", out!)
        print(112)
    }
 
    public final func prepareSecretChat(wit jid: String, success: (() -> Void)?, fail: (() -> Void)?) {
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.omemo.getContactDevices(stream, jid: jid)
            user.omemo.subscribeNode(stream, jid: jid, node: .device)
            user.omemo.subscribeNode(stream, jid: jid, node: .bundle)
        })
    }
    
    public final func initChat(jid: String) {
        do {
            let realm = try Realm()
            if realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: .omemo)) == nil {
                let initialMessageInstance = MessageStorageItem()

                initialMessageInstance.configureInitialMessage(
                    owner,
                    opponent: jid,
                    conversationType: .omemo,
                    text: "Encrypted chat created".localizeString(id: "encrypted_chat_created", arguments: []),
                    date: Date(),
                    isRead: true
                )

                initialMessageInstance.isDeleted = false

                let instance = LastChatsStorageItem()
                instance.owner = self.owner
                instance.jid = jid
                instance.conversationType = .omemo
                instance.messageDate = Date()
                instance.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: .omemo)
                
                try realm.write {
                    realm.add(instance, update: .modified)
                    if let messageInstance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: initialMessageInstance.primary) {
                        instance.lastMessage = messageInstance
                    } else {
                        instance.lastMessage = initialMessageInstance
                    }
                }
            }
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.omemo.subscribeNode(stream, jid: jid, node: .device)
                user.omemo.subscribeNode(stream, jid: jid, node: .bundle)
            })
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
    }
    
//    static func generateIdentityKeyPair() -> IdentityKeyPair {
//        return IdentityKeyPair.generate()
//    }
//
//    static func generateRegistrationId() -> UInt32 {
//        return UInt32.random(in: 0...0x3FFF)
//    }
//
//    static func generateSignedPreKey(identityKeyPair: IdentityKeyPair, signedPreKeyId: UInt32) throws -> SignedPreKeyRecord {
////        let privateKey = identityKeyPair.privateKey//PrivateKey.generate()
//        let signature = identityKeyPair
//            .privateKey
//            .generateSignature(message: identityKeyPair.publicKey.serialize())
//        return try SignedPreKeyRecord(
//            id: signedPreKeyId, timestamp: UInt64(CACurrentMediaTime().truncatingRemainder(dividingBy: 1)),
//            privateKey: identityKeyPair.privateKey,
//            signature: signature)
//    }
//
//
//    static func generatePreKeys(start: UInt32, count: UInt32) throws -> [PreKeyRecord] {
//        return (start..<(start + count))
//            .compactMap {
//                index in
//                let preKeyId = ((start + index) % (OmemoManager.signalPreKeysMaxVal - 1))
//                let privateKey = PrivateKey.generate()
//                return try? PreKeyRecord(id: UInt32(preKeyId), publicKey: privateKey.publicKey, privateKey: privateKey)
//            }
//    }
//
//    static func generateKeys() throws -> Registration {
//        let identityKeyPair = OmemoManager.generateIdentityKeyPair()
//        let registrationId = OmemoManager.generateRegistrationId()
//        let signedPreKey = try OmemoManager.generateSignedPreKey(
//            identityKeyPair: identityKeyPair,
//            signedPreKeyId: UInt32.random(in: 1...OmemoManager.signalPreKeysMaxVal - 1)
//        )
//        let preKeys = try OmemoManager.generatePreKeys(
//            start: UInt32.random(in: 100...OmemoManager.signalPreKeysMaxVal - 101),
//            count: 100
//        )
//        return Registration(
//            identityKeyPair: identityKeyPair,
//            registrationId: registrationId,
//            preKeys: preKeys,
//            signedPreKeyRecord: signedPreKey
//        )
//    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case onContactDeviceListReceive(iq): return true
        case onContactDeviceListErrorReceive(iq): return true
        case onContactBundleReceive(iq): return true
        case onContactBundleErrorReceive(iq): return true
        default: return false
        }
    }
}

extension OmemoManager {
    
    public enum NodeType: String {
        case device = "urn:xmpp:omemo:2:devices"
        case bundle = "urn:xmpp:omemo:2:bundles"
    }
    
    public final func subscribeNode(_ xmppStream: XMPPStream, jid: String, node: NodeType) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let subscribe = DDXMLElement(name: "subscribe", xmlns: "http://jabber.org/protocol/pubsub")
        subscribe.addAttribute(withName: "node", stringValue: node.rawValue)
        subscribe.addAttribute(withName: "jid", stringValue: self.owner)
        pubsub.addChild(subscribe)
        let elementId = xmppStream.generateUUID
        let iq = XMPPIQ(iqType: .set, to: XMPPJID(string: jid), elementID: elementId, child: pubsub)
        xmppStream.send(iq)
        self.queryIds.append(elementId)
    }
    
    public final func updateMyDevice(_ stream: XMPPStream) {
        self.getOwnDevices(stream)
    }
    
    public final func publicateOwnDevice(_ xmppStream: XMPPStream, createNode: Bool) throws {
        self.sendOwnDevice(xmppStream, createNode: createNode)
        try self.sendOwnDeviceBundle(xmppStream, createNode: createNode)
    }
    
    private final func sendOwnDeviceBundle(_ xmppStream: XMPPStream, createNode: Bool) throws {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let realm = try Realm()
        let isOmemoEnabled = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.isEncryptionEnabled ?? false
        if !isOmemoEnabled {
            return
        }
        if createNode {
            let publishOptions = DDXMLElement(name: "publish-options")
            let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
            x.addAttribute(withName: "type", stringValue: "submit")
            let form: [[String: String]] = [
                [
                    "var": "FORM_TYPE",
                    "type": "hidden",
                    "value": "http://jabber.org/protocol/pubsub#publish-options"
                ],
                [
                    "var": "pubsub#max_items",
                    "value": "max"
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
            publishOptions.addChild(x)
            pubsub.addChild(publishOptions)
        }
        guard deviceId != nil else { throw OmemoManagerError.bundleNotFound }
        let publish = DDXMLElement(name: "publish")
        publish.addAttribute(withName: "node", stringValue: "\(getPrimaryNamespace()):bundles")
        let item = DDXMLElement(name: "item")
        guard let bundleRecord = realm.object(
            ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(
                owner: self.owner,
                jid: self.owner,
                deviceId: Int(deviceId)
            )
        ) else {
            throw OmemoManagerError.bundleNotFound
        }
        item.addAttribute(withName: "id", integerValue: Int(self.deviceId))
        let bundle = DDXMLElement(name: "bundle", xmlns: getPrimaryNamespace())
        let spk = DDXMLElement(name: "spk", stringValue: bundleRecord.signedPreKey.base64EncodedString())
        spk.addAttribute(withName: "id", integerValue: bundleRecord.signedPreKeyId)
        bundle.addChild(spk)
        let spks = DDXMLElement(name: "spks", stringValue: bundleRecord.signedPreKeySignature.base64EncodedString())
        bundle.addChild(spks)
        let ik = DDXMLElement(name: "ik", stringValue: bundleRecord.identityKey.base64EncodedString())
        bundle.addChild(ik)
        let prekeys = DDXMLElement(name: "prekeys")
        self.preKeys.compactMap {
            prekey -> DDXMLElement in
            let pk = DDXMLElement(name: "pk")
            pk.stringValue = prekey.publicKey.serialize().toBase64()
            pk.addAttribute(withName: "id", intValue: Int32(prekey.id))
            return pk
        }.forEach {
            prekeys.addChild($0)
        }
        
        bundle.addChild(prekeys)
        item.addChild(bundle)
        publish.addChild(item)
        pubsub.addChild(publish)
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub))
        self.queryIds.insert(elementId)
    }
    
    private final func sendOwnDevice(_ xmppStream: XMPPStream, createNode: Bool) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        if createNode {
            let publishOptions = DDXMLElement(name: "publish-options")
            let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
            x.addAttribute(withName: "type", stringValue: "submit")
            let form: [[String: String]] = [
                [
                    "var": "FORM_TYPE",
                    "type": "hidden",
                    "value": "http://jabber.org/protocol/pubsub#publish-options"
                ],
                [
                    "var": "pubsub#access_model",
                    "value": "open"
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
            publishOptions.addChild(x)
            pubsub.addChild(publishOptions)
        }
        do {
            let realm = try Realm()
            
            let isOmemoEnabled = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.isEncryptionEnabled ?? false
            let publish = DDXMLElement(name: "publish")
            publish.addAttribute(withName: "node", stringValue: "\(getPrimaryNamespace()):devices")
            let item = DDXMLElement(name: "item")
            item.addAttribute(withName: "id", stringValue: "current")
            let devices = DDXMLElement(name: "devices", xmlns: getPrimaryNamespace())
            
            let devicesCollection = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", owner, owner).compactMap {
                deviceItem -> DDXMLElement? in
                if !isOmemoEnabled {
                    if deviceItem.deviceId == Int(self.deviceId) {
                        return nil
                    }
                }
                let deviceElement = DDXMLElement(name: "device")
                deviceElement.addAttribute(withName: "id", integerValue: deviceItem.deviceId)
                if let name = deviceItem.name {
                    deviceElement.addAttribute(withName: "label", stringValue: name)
                }
                return deviceElement
            }
            
            devicesCollection.forEach { devices.addChild($0) }
            item.addChild(devices)
            publish.addChild(item)
            pubsub.addChild(publish)
            let elementId = xmppStream.generateUUID
            xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub))
            self.queryIds.insert(elementId)
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func getOwnDevices(_ xmppStream: XMPPStream) {
        self.getContactDevices(xmppStream, jid: self.owner)
    }
    
    public func getContactDevices(_ xmppStream: XMPPStream, jid: String) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: "\(getPrimaryNamespace()):devices")
        pubsub.addChild(items)
        let elementId = xmppStream.generateUUID
        let iq = XMPPIQ(iqType: .get, to: jid == owner ? nil : XMPPJID(string: jid), elementID: elementId, child: pubsub)
        xmppStream.send(iq)
        print(iq.prettyXMLString!)
        self.queryIds.append(elementId)
    }
    
    public func getContactBundles(_ xmppStream: XMPPStream, jid: String, deviceId: String) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: "\(getPrimaryNamespace()):bundles")
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "id", stringValue: deviceId)
        items.addChild(item)
        pubsub.addChild(items)
        let elementId = xmppStream.generateUUID
        let iq = XMPPIQ(iqType: .get, to: jid == owner ? nil : XMPPJID(string: jid), elementID: elementId, child: pubsub)
        xmppStream.send(iq)
        print(iq.prettyXMLString!)
        self.queryIds.append(elementId)
    }
    
    private func onContactDeviceListErrorReceive(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .error,
              let jid = iq.from?.bare,
              let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              let items = pubsub.element(forName: "items"),
              items.attributeStringValue(forName: "node") == "\(getPrimaryNamespace()):devices",
              let error = iq.element(forName: "error"),
              error.attributeStringValue(forName: "code") == "404" else {
                  return false
              }
        if jid == owner {
//            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
//                try? session.omemo?.publicateOwnDevice(stream, createNode: true)
//            } fail: {
                AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
                    try? user.omemo.publicateOwnDevice(stream, createNode: true)
                })
//            }
        } else {
            do {
                let realm = try Realm()
                if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner)) {
                    try realm.write {
                        instance.isSupportOmemo = false
                    }
                }
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        return true
    }
    
    private func onContactDeviceListReceive(_ iq: XMPPIQ) -> Bool {
        guard let jid = iq.from?.bare,
              let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              let items = pubsub.element(forName: "items"),
              items.attributeStringValue(forName: "node") == "\(getPrimaryNamespace()):devices",
              let item = items.element(forName: "item"),
//              item.attributeStringValue(forName: "id") == "current",
              let devices = item.element(forName: "devices", xmlns: getPrimaryNamespace())?.elements(forName: "device") else {
                  return false
              }
        if jid == self.owner {
//            XMPPUIActionManager.shared.open(owner: self.owner)
//            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
//                try? session.omemo?.publicateOwnDevice(stream, createNode: false)
//            } fail: {
                AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
                    try? user.omemo.publicateOwnDevice(stream, createNode: false)
                })
//            }
        }
        devices.forEach {
            device in
            let id = device.attributeIntegerValue(forName: "id")
            let label = device.attributeStringValue(forName: "label")
            let primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: id)
            do {
                let realm = try Realm()
                if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary) {
                    try realm.write {
                        instance.name = label
                    }
                } else {
                    let instance = SignalDeviceStorageItem()
                    instance.owner = self.owner
                    instance.jid = jid
                    instance.primary = primary
                    instance.deviceId = Int(id)
                    instance.name = label
                    instance.state = .unknown
                    try realm.write {
                        realm.add(instance, update: .modified)
                    }
                }
            } catch {
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
        }
        AccountManager
            .shared
            .find(for: self.owner)?
            .unsafeAction({ user, stream in
                devices
                    .compactMap { return $0.attributeStringValue(forName: "id") }
                    .forEach {
                        id in
                        user.omemo.getContactBundles(
                            stream,
                            jid: jid,
                            deviceId: id
                        )
                    }
                
            })
        
        
        
        return true
    }
    
    /*<iq xmlns="jabber:client" lang="ru" to="igor.boldin@redsolution.com/xabber-ios-3F02F22F" from="andrew.nenakhov@redsolution.com" type="result" id="91037A2C-6B83-482B-95B1-5097863B27DD">
     <pubsub xmlns="http://jabber.org/protocol/pubsub">
       <items node="urn:xmpp:omemo:1:bundles">
         <item id="1364917854">
           <bundle xmlns="urn:xmpp:omemo:1">
             <spk id="1">BVdAi9fv4ziu3ysZs6axEw9cMhznZv8/oGxcHO3QRJE2</spk>
             <spks>CUROQwqBC8gmRJfqz5R28P+bj/RJaGyJIbAJJ/oWeBOvCEPP7DY+AmGaCEyscVQCiaL9BwoPyRrpmWbWw4njAA==</spks>
             <ik>BYE+pWj1STfb9waS3P/cdWesWp0abplMyOdTU70aj2VN</ik>
             <prekeys>
               <pk id="1">BUekWGI8i31EXQbiAgfUp8B55BnjWS7exYrLwT1vHP1Q</pk>
                ...
               <pk id="99">BX6rrIEVTzV6DnKMv1oRWH1s/rXjPSWqHWObEZ173yxy</pk>
               <pk id="100">BaYGC9npc5M+MkE0cy140YqLUpF5aajW21S4+C4UABY2</pk>
             </prekeys>
           </bundle>
         </item>
       </items>
     </pubsub>
   </iq>*/
    
    private final func onContactBundleErrorReceive(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .error,
              let from = iq.from?.bare,
              let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              let items = pubsub.element(forName: "items"),
              items.attributeStringValue(forName: "node") == "\(getPrimaryNamespace()):bundles",
              let error = iq.element(forName: "error"),
              error.attributeStringValue(forName: "code") == "404" else {
                  return false
              }

        return true
    }
    
//    <message xmlns="jabber:client" to="igor.boldin@xmppdev01.xabber.com/xabber-ios-3F02F22F" from="igor.boldin@xmppdev01.xabber.com" type="headline">
//      <event xmlns="http://jabber.org/protocol/pubsub#event">
//        <items node="urn:xmpp:omemo:2:bundles">
//          <item id="14239832">
//            <bundle xmlns="urn:xmpp:omemo:2">
//              <spk id="0">BdZZaeTFZ50wF8vreTJ00PhqKoSCmgauWmMLCJJhdfFj</spk>
//              <spks>Mc54fu1Tl8mj9zdZjDhsrZJ/6A/xSzGnUkDNskk05V9p6F0zROl/IG0JN3OZVLph+tdCkcwH+5hXOv1JVc4mgw==</spks>
//              <ik>BT6W7KFpJT3zkkgVvUcgruMN62Oiv+ernZ/nLr4N91YH</ik>
//              <prekeys>
    
    
    public final func onContactBundleReceive(_ iq: XMPPIQ) -> Bool {
        print(iq.prettyXMLString!)
        guard let from = iq.from?.bare,
              let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              let items = pubsub.element(forName: "items"),
              items.attributeStringValue(forName: "node") == "\(getPrimaryNamespace()):bundles" else {
                  return false
              }
//        if let item = items.element(forName: "item") {
//            let id = item.attributeIntegerValue(forName: "id")
//            do {
//                let realm = try Realm()
//                if let instance = realm.object(ofType: SignalBundleStorageItem.self, forPrimaryKey: SignalBundleStorageItem.genPrimary(owner: self.owner, jid: from, deviceId: id)) {
//                    try realm.write {
//                        instance.bundle = items
//                    }
//                } else {
//                    let instance = SignalBundleStorageItem()
//                    instance.owner = self.owner
//                    instance.jid = from
//                    instance.deviceId = id
//                    instance.primary = SignalBundleStorageItem.genPrimary(owner: self.owner, jid: from, deviceId: id)
//                    instance.bundle = items
//                    try realm.write {
//                        realm.add(instance)
//                    }
//                }
//
//            } catch {
//                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
//            }
//        }
        
        do {
            return try self.onContactBundleReceive(items: items, jid: from)
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }
    
    
    public final func onContactDeviceReceiveHeadline(_ message: XMPPMessage) -> Bool {
        print(message.prettyXMLString!)
        guard let from = message.from?.bare,
              let event = message.element(forName: "event", xmlns: "http://jabber.org/protocol/pubsub#event"),
              let items = event.element(forName: "items"),
              items.attributeStringValue(forName: "node") == "\(getPrimaryNamespace()):bundles" else {
                  return false
              }
        do {
            return try self.onContactBundleReceive(items: items, jid: from)
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            return false
        }
//        if let item = items.element(forName: "item") {
//            let id = item.attributeIntegerValue(forName: "id")
//            do {
//                let realm = try Realm()
//                if let instance = realm.object(ofType: SignalBundleStorageItem.self, forPrimaryKey: SignalBundleStorageItem.genPrimary(owner: self.owner, jid: from, deviceId: id)) {
//                    try realm.write {
//                        instance.bundle = items
//                    }
//                } else {
//                    let instance = SignalBundleStorageItem()
//                    instance.owner = self.owner
//                    instance.jid = from
//                    instance.deviceId = id
//                    instance.primary = SignalBundleStorageItem.genPrimary(owner: self.owner, jid: from, deviceId: id)
//                    instance.bundle = items
//                    try realm.write {
//                        realm.add(instance)
//                    }
//                }
//
//            } catch {
//                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
//            }
//        }
//        return self.onContactBundleReceive(items: items, jid: from)
    }
    
    private final func onContactBundleReceive(items: DDXMLElement, jid: String) throws -> Bool {
        guard items.attributeStringValue(forName: "node") == "\(getPrimaryNamespace()):bundles",
              let item = items.element(forName: "item"),
              let bundle = item.element(forName: "bundle", xmlns: getPrimaryNamespace()) else {
                  return false
              }
                
        let id = item.attributeIntegerValue(forName: "id")
        guard let spkId = bundle.element(forName: "spk")?.attributeIntValue(forName: "id"),
              let spk_b64 = bundle.element(forName: "spk")?.stringValue,
              let spks_b64 = bundle.element(forName: "spks")?.stringValue,
              let ik_b64 = bundle.element(forName: "ik")?.stringValue,
              let preKeys = bundle.element(forName: "prekeys")?.elements(forName: "pk") else {
                  return false
              }
        
        let registrationId = bundle.element(forName: "registration")?.stringValueAsInt() ?? Int32(id)
        
        
        let realm = try Realm()
        
        let name = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: id))?.name ?? "\(id)"
        
        guard let spk = Data(base64Encoded: spk_b64),
              let spks = Data(base64Encoded: spks_b64),
              let ik = Data(base64Encoded: ik_b64) else {
                  return false
              }
        
        try preKeys.forEach {
            pkElement in
            
            let pk_id = pkElement.attributeIntegerValue(forName: "id")
            
            guard let pk_b64 = pkElement.stringValue,
                let pk = Data(base64Encoded: pk_b64) else {
                return
            }
            
            try self.setupRemoteStore(
                registrationId: UInt32(registrationId),
                address: ProtocolAddress(name: name, deviceId: UInt32(id)),
                preKeyId: UInt32(pk_id),
                preKey: try PublicKey(pk),
                signedPreKeyId: UInt32(spkId),
                signedPreKey: try PublicKey(spk),
                signedPreKeySignature: pk.bytes,
                identity: try IdentityKey(publicKey: try PublicKey(ik))
            )
        }
        
        print("RECEIVE DEVICE FROM", owner, jid, id) //14239832
        
        do {
            let realm = try Realm()
            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: jid, deviceId: id)) {
                if let fingerprintBytes = Data(base64Encoded: ik) {
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.fingerprint = fingerprintBytes.hexEncodedString()
                    }
                }
            }
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    func modifyOmemoStanza(message: XMPPMessage) -> XMPPMessage {
        guard message.element(forName: "encrypted", xmlns: getPrimaryNamespace()) != nil else {
            return message
        }
        do {
            let body = try self.decryptMessage(message)
            message.remove(forName: "body")
            message.addBody(body ?? "Failed to decrypt")
            
            print(123)
        } catch {
//            fatalError(error.localizedDescription)
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
        return message
    }
    
    func didReceiveOmemomMessage(_ message: XMPPMessage, fromCCC: Bool = false) -> Bool {
        
        
        if isArchivedMessage(message) {
            do {
                guard let bareMessage = getArchivedMessageContainer(message),
                      bareMessage.element(forName: "encrypted", xmlns: getPrimaryNamespace()) != nil else {
                          return false
                      }
                let body = try self.decryptMessage(bareMessage)
                
                message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.remove(forName: "body")
                message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message")?.addChild(DDXMLElement(name: "body", stringValue: body ?? "Failed to decrypt"))
                AccountManager.shared.find(for: self.owner)?.messages.receiveArchived(message)
            } catch {
//                fatalError(error.localizedDescription)
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
        } else {
            guard message.element(forName: "encrypted", xmlns: getPrimaryNamespace()) != nil else {
                return false
            }
            do {
                let body = try self.decryptMessage(message)
                message.remove(forName: "body")
                message.addBody(body ?? "Failed to decrypt")
                AccountManager.shared.find(for: self.owner)?.messages.receiveRuntime(message)
                print(123)
            } catch {
//                fatalError(error.localizedDescription)
                DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
            }
        }
        
        
        return true
    }
    
    func decryptMessage(_ message: XMPPMessage) throws -> String?  {
        guard let from = message.from?.bare,
              let encryptedElement = message.element(forName: "encrypted", xmlns: getPrimaryNamespace()),
              let headerElement = encryptedElement.element(forName: "header") else {
                  print(1)
                  return nil
              }
        let sid = headerElement.attributeIntValue(forName: "sid")
        print(encryptedElement.prettyXMLString!)
        let keyElement = headerElement
            .elements(forName: "keys")
            .filter({ $0.attributeStringValue(forName: "jid") == self.owner })
            .first?
            .elements(forName: "key")
            .first

        print(keyElement)

        guard let keyElementValue = keyElement?.stringValue else {
            print(2)
            return nil
        }

        guard let keyElementData = Data(base64Encoded: keyElementValue) else {
            print(3)
            return nil
        }
//
//        print(self.contacts.filter({ $0.jid == from }).first?.devices.filter({ $0.id == UInt32(sid) }))
//
//
//
//        self.contacts.filter({ $0.jid == from }).first?.devices.filter({ $0.id == UInt32(sid) }).first?.remotes.forEach {
//            remote in
//            do {
//                let session = try Session(local: self.local!, remote: remote)
//                let decrypted = try session.decrypt_d(message: keyElementValue)
//                print(decrypted)
//            } catch {
//                print(error.localizedDescription)
//            }
//        }
//
//        guard let remote = self.contacts.filter({ $0.jid == from }).first?.devices.filter({ $0.id == UInt32(sid) }).first?.remotes.first else {
//            print(4)
//            return nil
//        }
//
//        print(remote)
//
//        let session = try Session(local: self.local!, remoteAddress: remote.protoclAddress)
//        let session = try Session(local: self.local!, remoteAddress: remote.protoclAddress)

//        let ses = try session.store.loadSession(for: remote.protoclAddress, context: NullContext())
//        print(ses?.hasCurrentState)
//
//        print(try session.store.isTrustedIdentity(remote.identityKeyPairPublicKey, for: remote.protoclAddress, direction: .receiving, context: NullContext()))
//        let session = try Session(local: self.local!, remoteAddress: ProtocolAddress(name: from, deviceId: UInt32(sid)))
        let decrypted = Array(keyElementData)

        let key = decrypted
//        let key = Array(decrypted.prefix(32))
//        let tag = Array(decrypted.suffix(16))

        guard let iv_raw = headerElement.element(forName: "iv")?.stringValue,
              let iv = Data(base64Encoded: iv_raw) else {
                  print(5)
                  return nil
              }

        guard let encryptedPayload = encryptedElement.element(forName: "payload")?.stringValue,
              let encryptedData = Data(base64Encoded: encryptedPayload) else {
                  print(6)
                  return nil
              }

        let gcm = GCM(iv: Array(iv), mode: .combined)
        let aes = try AES(key: Array(key), blockMode: gcm, padding: .noPadding)
        let body = try aes.decrypt(Array(encryptedData))
        print(body)
//        let encrypted = try aes.decr
//        let tag = gcm.authenticationTag


        return String(bytes: body, encoding: .utf8)
    }


    func encryptMessage(message: String, to jid: String) throws -> DDXMLElement? {
        
        var key = Data(count: 32)
 
        key.withUnsafeMutableBytes { (bytes) -> Void in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        
        var salt = Array<UInt8>(repeating: 0, count: 32)
        
        let hkdf = try HKDF(
            password: key.bytes,
            salt: salt,
            info: Array("OMEMO Payload".data(using: .utf8)!),
            keyLength: key.bytes.count,
            variant: .sha256
        ).calculate()
        
        let encryptionKey: Array<UInt8> = Array(hkdf.prefix(32))
        let authKey: Array<UInt8> = Array(hkdf.suffix(from: 32).prefix(32))
        let iv: Array<UInt8> = Array(hkdf.suffix(16))
        
//        var iv = Data(count: 16)
//        iv.withUnsafeMutableBytes { (bytes) -> Void in
//            _ = SecRandomCopyBytes(kSecRandomDefault, 16, bytes.baseAddress!)
//        }

        

        var combinedKey = key

//        var enryptedBody = Data()
        let gcm = GCM(iv: iv, mode: .combined)
        let aes = try AES(key: encryptionKey, blockMode: gcm, padding: .noPadding)
        let encrypted = try aes.encrypt(message.bytes)
        let tag = gcm.authenticationTag
        let hmac = try HMAC(key: authKey, variant: .sha256).authenticate(encrypted).prefix(16)
        
        let encryptedElement = DDXMLElement(name: "encrypted", xmlns: getPrimaryNamespace())
        let payload = DDXMLElement(name: "payload", stringValue: Data(encrypted).base64EncodedString())
        encryptedElement.addChild(payload)

//        combinedKey.append(contentsOf: Array(tag!))


        let header = DDXMLElement(name: "header")
        header.addAttribute(withName: "sid", integerValue: Int(self.deviceId))
        let remoteKeysElement = DDXMLElement(name: "keys")
        remoteKeysElement.addAttribute(withName: "jid", stringValue: jid)

//        header.addChild(DDXMLElement(name: "iv", stringValue: iv.base64EncodedString()))

        let realm = try Realm()
               
        
        let ddd = realm.objects(SignalDeviceStorageItem.self).toArray()
        print(ddd)
        
        realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, jid).toArray().forEach {
            device in
//            device.primary
            let key = DDXMLElement(name: "key")
            key.addAttribute(withName: "rid", integerValue: device.deviceId)
            key.addAttribute(withName: "kex", boolValue: true)
            key.stringValue = combinedKey.base64EncodedString()//try encryptedKey?.serialize().toBase64()

            remoteKeysElement.addChild(key)
        }
        
//        try self.contacts.first(where: { $0.jid == jid })?.devices.forEach {
//            item in
//            let remote = item.remotes.first!
//            let session = try Session(local: self.local!, remote: remote)
//            let encryptedKey = try session.encrypt(bytes: Array(combinedKey))
//            let key = DDXMLElement(name: "key")
//            key.addAttribute(withName: "rid", integerValue: Int(item.id))
//            key.addAttribute(withName: "kex", boolValue: true)
//            key.stringValue = encryptedKey//try encryptedKey?.serialize().toBase64()
//
//            remoteKeysElement.addChild(key)
//        }

        header.addChild(remoteKeysElement)

        let localKeysElement = DDXMLElement(name: "keys")
        localKeysElement.addAttribute(withName: "jid", stringValue: self.owner)
//        self.local
//        try self.ownEntity.devices.forEach {
//            item in
//            let remote = item.remotes.first!
//            let session = try Session(local: self.local!, remote: remote)
//            let encryptedKey = try session.encrypt(bytes: Array(combinedKey))
//            let key = DDXMLElement(name: "key")
//            key.addAttribute(withName: "rid", integerValue: Int(item.id))
//            key.addAttribute(withName: "kex", boolValue: true)
//            key.stringValue = encryptedKey?.signalMessage.serialize().toBase64()
//            localKeysElement.addChild(key)
//        }
        header.addChild(localKeysElement)
        encryptedElement.addChild(header)

        return encryptedElement
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        func transaction(_ block: () -> Void) throws {
            let realm = try Realm()
            
            if commitTransaction {
                try realm.write {
                    block()
                }
            } else {
                block()
            }
        }
        do {
            let realm = try Realm()
            let identityCollection = realm.objects(SignalIdentityStorageItem.self).filter("owner == %@",  owner)
            let devicesCollection = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@",  owner)
            let preKeysCollection = realm.objects(SignalPreKeysStorageItem.self).filter("owner == %@",  owner)
            try transaction {
                realm.delete(identityCollection)
                realm.delete(devicesCollection)
                realm.delete(preKeysCollection)
            }
        } catch {
            DDLogDebug("OmemoManager: \(#function). \(error.localizedDescription)")
        }
     }
         
}
