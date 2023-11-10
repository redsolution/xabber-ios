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
import RealmSwift
import Security
import OpenSSL
import CryptoSwift

class X509XMPPManager: AbstractXMPPManager {
    override func namespaces() -> [String] {
        return [
            SignatureManager.xmlns,
            [SignatureManager.xmlns, "notify"].joined(separator: "+")
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        SignatureManager.xmlns
    }
    
    public func publicateCertificate(_ xmppStream: XMPPStream, remove: Bool) {
        
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")

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

        let publish = DDXMLElement(name: "publish")
        publish.addAttribute(withName: "node", stringValue: getPrimaryNamespace())
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "id", stringValue: "current")

        if !remove {
            if let crt = SignatureManager.shared.certificate {
                let x509cert = DDXMLElement(name: "x509-cert")
                
                let derData = SecCertificateCopyData(crt) as Data

                do {
                    let realm = try WRealm.safe()
                    if realm.object(ofType: X509StorageItem.self, forPrimaryKey: X509StorageItem.genRpimary(owner: self.owner, jid: self.owner)) == nil {
                        let instance = X509StorageItem()
                        instance.owner = self.owner
                        instance.jid = self.owner
                        instance.primary = X509StorageItem.genRpimary(owner: self.owner, jid: self.owner)
                        instance.certData = derData
                        instance.stamp = Double(Date().timeIntervalSince1970)
                        try realm.write {
                            realm.add(instance)
                        }
                    }
                } catch {
                    DDLogDebug("X509XMPPManager: \(#function). \(error.localizedDescription)")
                }
                
                x509cert.stringValue = derData.base64EncodedString()
                
                item.addChild(x509cert)
            }
        }
        
        publish.addChild(item)
        pubsub.addChild(publish)
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub))
        self.queryIds.insert(elementId)
    }
    
    public func retrieveCert(_ xmppStream: XMPPStream, for jid: String) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: getPrimaryNamespace())
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "id", stringValue: "current")
        items.addChild(item)
        pubsub.addChild(items)
        let elementId = xmppStream.generateUUID
        let iq = XMPPIQ(iqType: .get, to: jid == owner ? nil : XMPPJID(string: jid), elementID: elementId, child: pubsub)
        xmppStream.send(iq)
    }
    
    public final func readHeadline(_ message: XMPPMessage) -> Bool {
        guard let event = message.element(forName: "event", xmlns: "http://jabber.org/protocol/pubsub#event"),
              let items = event.element(forName: "items"),
              items.attributeStringValue(forName: "node") == getPrimaryNamespace(),
              let item = items.element(forName: "item"),
              item.attributeStringValue(forName: "id") == "current",
              let jid = message.from?.bare else {
                  return false
              }
        return storeCertificate(item, jid: jid, isError: false)
    }
    
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        guard let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              iq.element(forName: "error") == nil,
              let items = pubsub.element(forName: "items"),
              items.attributeStringValue(forName: "node") == getPrimaryNamespace(),
              let item = items.element(forName: "item"),
              item.attributeStringValue(forName: "id") == "current",
              let jid = iq.from?.bare else {
                  return false
              }
        
        
        return storeCertificate(item, jid: jid, isError: iq.isErrorIQ)
    }
    
    private final func storeCertificate(_ item: DDXMLElement, jid: String, isError: Bool) -> Bool {
        do {
            let realm = try WRealm.safe()
            if let certB64Data = item.element(forName: "x509-cert")?.stringValue,
                let certData = Data(base64Encoded: certB64Data) {
                if realm.object(ofType: X509StorageItem.self, forPrimaryKey: X509StorageItem.genRpimary(owner: self.owner, jid: jid)) == nil {
                    let instance = X509StorageItem()
                    instance.owner = self.owner
                    instance.jid = jid
                    instance.primary = X509StorageItem.genRpimary(owner: self.owner, jid: jid)
                    instance.certData = certData
                    instance.stamp = Double(Date().timeIntervalSince1970)
                    let messagesCollection = realm
                        .objects(MessageStorageItem.self)
                        .filter("owner == %@ AND opponent == %@ and conversationType_ == %@",
                                self.owner,
                                jid,
                                ClientSynchronizationManager.ConversationType.omemo.rawValue)
                    let bundlesCollection = realm
                        .objects(SignalDeviceStorageItem.self)
                        .filter("owner == %@ AND jid == %@", self.owner, jid)
                    try realm.write {
                        realm.add(instance, update: .modified)
                        try messagesCollection.forEach {
                            message in
                            guard let containerString = message.envelopeContainer else {
                                return
                            }
                            let document = try DDXMLDocument(xmlString: containerString, options: 0)
                            if let sign = document.rootElement() {
                                message.errorMetadata = try SignatureManager
                                    .shared
                                    .checkSignature(
                                        owner: self.owner,
                                        for: jid,
                                        signature: sign,
                                        messageDate: message.date
                                    ).errorMetadata
                            }
                        }
                        try bundlesCollection.forEach {
                            bundle in
                            guard let containerString = bundle.signature else {
                                return
                            }
                            let document = try DDXMLDocument(xmlString: containerString, options: 0)
                            if let sign = document.rootElement() {
                                let result = try SignatureManager.shared.checkBundleSignature(
                                    owner: self.owner,
                                    for: jid,
                                    signature: sign)
                                bundle.signedBy = result?.signedBy
                                bundle.signedAt = result?.signedAt ?? -1
                            }
                        }
                    }
                }
            } else if isError {
                let primary = X509StorageItem.genRpimary(owner: self.owner, jid: jid)
                try realm.write {
                    if let instance = realm.object(ofType: X509StorageItem.self, forPrimaryKey: primary) {
                        realm.delete(instance)
                    }
                }
            }
            
            
            
        } catch {
            DDLogDebug("X509XMPPManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(X509StorageItem.self)
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
    
}

