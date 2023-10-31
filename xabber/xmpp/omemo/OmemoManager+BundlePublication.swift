//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//
import Foundation
import XMPPFramework
import SignalProtocolObjC
import RealmSwift
import Network

extension OmemoManager {
    
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
                "value": "32"
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
    
    internal final func sendOwnDeviceBundle(_ xmppStream: XMPPStream, createNode: Bool) throws {
        self.shouldPublicate = false
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let realm = try WRealm.safe()
        let publish = DDXMLElement(name: "publish")
        publish.addAttribute(withName: "node", stringValue: "\(getPrimaryNamespace()):bundles")
        let item = DDXMLElement(name: "item")
        guard let bundleRecord = realm.object(
            ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(
                owner: self.owner,
                jid: self.owner,
                deviceId: Int(self.localStore.localDeviceId())
            )
        ) else {
            return
        }
        
        item.addAttribute(withName: "id", integerValue: Int(self.localStore.localDeviceId()))
        let bundle = DDXMLElement(name: "bundle", xmlns: getPrimaryNamespace())
        let spk = DDXMLElement(name: "spk", stringValue: bundleRecord.signedPreKey)
        spk.addAttribute(withName: "id", integerValue: bundleRecord.signedPreKeyId)
        bundle.addChild(spk)
        let spks = DDXMLElement(name: "spks", stringValue: bundleRecord.signedPreKeySignature)
        bundle.addChild(spks)
        
        let ik = DDXMLElement(name: "ik", stringValue: bundleRecord.identityKey)
        bundle.addChild(ik)
        
        if let sign = SignatureManager.shared.bundleSignatureElement {
            if let secCert = SignatureManager.shared.certificate {
                let certData = SecCertificateCopyData(secCert) as CFData
                
                if let cert = SecCertificateCreateWithData(nil, certData) {
                    var cfName: CFString?
                    SecCertificateCopyCommonName(cert, &cfName)
                    if let cn = cfName as String?, cn == self.owner {
                        bundle.addChild(sign)
                    }
                }
            }
        } else {
            if bundleRecord.isPublicated {
                return
            }
        }
        
        let prekeys = DDXMLElement(name: "prekeys")
        
        realm
            .objects(SignalPreKeysStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND deviceId == %@", self.owner, self.owner, self.localStore.localDeviceId())
            .toArray()
            .forEach {
                pk in
                let item = DDXMLElement(name: "pk", stringValue: pk.preKey)
                item.addAttribute(withName: "id", integerValue: pk.pkId)
                prekeys.addChild(item)
            }
        
        bundle.addChild(prekeys)
        
        if (bundle.children?.isEmpty ?? false) {
            return
        }
        item.addChild(bundle)
        publish.addChild(item)
        pubsub.addChild(publish)
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub))
        try realm.write {
            if bundleRecord.isInvalidated {
                return
            }
            bundleRecord.isPublicated = true
        }
        self.queryIds.insert(elementId)
    }
    
    internal final func sendOwnDevice(_ xmppStream: XMPPStream, createNode: Bool) throws {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let realm = try WRealm.safe()
        
        let isOmemoEnabled = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.isEncryptionEnabled ?? false
        let publish = DDXMLElement(name: "publish")
        publish.addAttribute(withName: "node", stringValue: "\(getPrimaryNamespace()):devices")
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "id", stringValue: "current")
        let devices = DDXMLElement(name: "devices", xmlns: getPrimaryNamespace())
        
        realm
            .objects(SignalDeviceStorageItem.self)
            .filter("owner == %@ AND jid == %@", owner, owner)
            .compactMap {
                deviceItem -> DDXMLElement? in
                if !isOmemoEnabled {
                    if deviceItem.deviceId == Int(self.localStore.localDeviceId()) {
                        return nil
                    }
                }
                let deviceElement = DDXMLElement(name: "device")
                deviceElement.addAttribute(withName: "id", integerValue: deviceItem.deviceId)
                if let name = deviceItem.name {
                    deviceElement.addAttribute(withName: "label", stringValue: name)
                }
                return deviceElement
            }.forEach { devices.addChild($0) }
        
        item.addChild(devices)
        publish.addChild(item)
        pubsub.addChild(publish)
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub))
        self.queryIds.insert(elementId)
    }
    
    public final func updateMyDevice(_ stream: XMPPStream) {
        self.shouldPublicate = true
        if !(AccountManager.shared.find(for: self.owner)?.devices.isAvailable ?? true) {
            self.getOwnDevices(stream)
        } else {
            try? self.publicateOwnDevice(stream, createNode: true)
        }
//        if (AccountManager.shared.find(for: self.owner)?.isNewAccount ?? false) {
//            try? self.publicateOwnDevice(stream, createNode: true)
//        } else {
//            if !(AccountManager.shared.find(for: self.owner)?.devices.isAvailable ?? true) {
//                self.getOwnDevices(stream)
//            } else {
//                try? self.publicateOwnDevice(stream, createNode: false)
//            }
//        }
    }
    
    public final func publicateOwnDevice(_ xmppStream: XMPPStream, createNode: Bool) throws {
        if createNode {
            self.createNode(xmppStream, node: .device)
            self.createNode(xmppStream, node: .bundle)
            self.configureNode(xmppStream, node: .device)
            self.configureNode(xmppStream, node: .bundle)
        }
        try self.sendOwnDeviceBundle(xmppStream, createNode: createNode)
        if !(AccountManager.shared.find(for: self.owner)?.devices.isAvailable ?? true) {
            try self.sendOwnDevice(xmppStream, createNode: createNode)
        }
    }
    
    public final func getOwnDevices(_ xmppStream: XMPPStream) {
        self.getContactDevices(xmppStream, jid: self.owner)
    }
}
