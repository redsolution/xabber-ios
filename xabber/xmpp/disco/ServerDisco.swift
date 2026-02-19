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
import RealmSwift
import CryptoSwift
import XMPPFramework

class ServerDiscoManager: AbstractXMPPManager {
    
    static let clientName: String = CommonConfigManager.shared.config.app_name
    
    var hasCachedFeatures: Bool = false
    var features: SynchronizedArray<String> = SynchronizedArray<String>()
    
    var clientFeatures: [String] = []
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        clientFeatures.append("http://jabber.org/protocol/disco#info")
        clientFeatures.append("http://jabber.org/protocol/disco#items")
//        clientFeatures.append("http://jabber.org/protocol/caps")
    }
    
    open func register(_ module: AbstractXMPPManager) {
        module.namespaces().forEach { feature in
            if !features.contains(feature) {
                clientFeatures.append(feature)
            }
        }
    }
    
    open func configure(_ xmppStream: XMPPStream) {
        if !self.loadFeatures() {
            self.requestFeatures(xmppStream)
            self.requestItems(xmppStream)
        } else {
            self.hasCachedFeatures = true
//            AccountManager.shared.changeNewUserState(for: owner, to: .capsReceived([]))
        }
    }
    
    
    open func generateVer() -> String {
        let featuresList: String = clientFeatures.sorted().compactMap { (item) -> String? in
            if item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return ["<", item.trimmingCharacters(in: .whitespacesAndNewlines)].joined()
        }.joined()
//        if !((SettingManager.shared.getString(for: "privacy_level") ?? "none") == SettingManager.PrivacyLevel.incognito.rawValue) {
            return "client/phone//\(ServerDiscoManager.clientName)\(featuresList)<"
                .data(using: String.Encoding.utf8)!
                .sha1()
                .base64EncodedString()
//        }
//        return "client/phone/en/\(featuresList)<"
//            .data(using: String.Encoding.utf8)!
//            .sha1()
//            .base64EncodedString()
    }
    
    func requestFeatures(_ xmppStream: XMPPStream) {
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: xmppStream.myJID?.bareJID,
                               elementID: elementId,
                               child: DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#info")))
        self.queryIds.insert(elementId)
    }
    
    func requestItems(_ xmppStream: XMPPStream) {
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: xmppStream.myJID?.domainJID,
                               elementID: elementId,
                               child: DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#items")))
        self.queryIds.insert(elementId)
    }
    
    func checkItem(_ xmppStream: XMPPStream, in jid: String, node: String?) {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
        if let node = node {
            query.addAttribute(withName: "node", stringValue: node)
        }
        xmppStream.send(XMPPIQ(iqType: .get, to: XMPPJID(string: jid), elementID: elementId, child: query))
        self.queryIds.insert(elementId)
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case readIdentityRequest(withIQ: iq): return true
        case readFeatures(withIQ: iq): return true
        default: return false
        }
    }
//    <iq xmlns="jabber:client" lang="ru" to="igor.boldin@redsolution.com/xabber-ios-BF9ED1E2" from="notify.redsolution.com" type="result" id="DA41EFEC-DB97-42F1-BAA1-31DB09E0A438">
//      <query xmlns="http://jabber.org/protocol/disco#info">
//        <identity name="Notification service" type="notification" category="component"/>
//        <feature var="http://jabber.org/protocol/disco#info"/>
//        <feature var="http://jabber.org/protocol/disco#items"/>
//        <feature var="urn:xabber:notify:0"/>
//      </query>
//    </iq>
    func readFeatures(withIQ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            iq.iqType == .result,
            let query = iq.element(forName: "query",
                                   xmlns: "http://jabber.org/protocol/disco#info") ??
                iq.element(forName: "query",
                           xmlns: "http://jabber.org/protocol/disco#items"),
            self.queryIds.contains(elementId)  else {
                return false
        }
        
        switch query.xmlns() ?? "none" {
        case "http://jabber.org/protocol/disco#info":
            if parseClientIdentity(iq: iq) {
                return true
            }
            if let jid = iq.from?.bare {
                switch true {
                    case getNotificationServiceNode(query, jid: jid): return true
                    case getFavoritesServiceNode(query, jid: jid): return true
                    default: break
                }
            }
                
            if let identity = query.element(forName: "identity") {
                let type = identity.attributeStringValue(forName: "type")
                let category = identity.attributeStringValue(forName: "category")
                let name = identity.attributeStringValue(forName: "name")
                
                if category == "client" {
                    return true
                } else if type == "file" && category == "store" {
                    self.parseHTTPSettings(query, node: iq.from?.full ?? "")
                    return true
                }
//                else if type == "server" && category == "conference" && name == "Groupchat Service" {
//                    SettingManager.shared.saveItem(for: owner,
//                                                       scope: .globalIndex,
//                                                       key: "localJid",
//                                                       value: iq.from?.bare ?? "")
//                    SettingManager.shared.saveItem(for: owner,
//                                                       scope: .globalIndex,
//                                                       key: "localNode",
//                                                       value: query.attributeStringValue(forName: "node") ?? "")
//                    return true
//                }
            }
            
            self.parseAndStoreUrls(query: query, nspace: "urn:xabber:http:url")
                        
            let features = query.elements(forName: "feature")
            var caps: [String] = []
            features.forEach {
                feature in
                if let node = feature.attributeStringValue(forName: "var") {
//                    print("NODE", node)
                    switch node {
                    case "urn:xmpp:mam:0":
                        let item = "mam"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "urn:xmpp:mam:1":
                        let item = "mam"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "urn:xmpp:mam:2":
                        let item = "mam"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "https://xabber.com/protocol/rewrite":
                        let item = "rewrite"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "https://xabber.com/protocol/auth-tokens":
                        let item = "xtokens"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "http://jabber.org/protocol/pubsub":
                        let item = "pubsub"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "urn:xmpp:push:0":
                        let item = "push"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "https://xabber.com/protocol/push":
                        let item = "xpush"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    default: break
                    }
                }
            }
            AccountManager.shared.changeNewUserState(for: owner, to: .capsReceived(caps))
            parseReliableMessageDeliverySettings(query.elements(forName: "feature"))
            parseMessagesDeleteRewriteSettings(query.elements(forName: "feature"))
            return true
        case "http://jabber.org/protocol/disco#items":
            query.elements(forName: "item").forEach { item in
                if let jid = item.attributeStringValue(forName: "jid") {
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        user.disco.checkItem(stream, in: jid, node: item.attributeStringValue(forName: "node"))
                    })
                }
            }
            return true
        default: return false
        }
    }

    private func parseAndStoreUrls(query: DDXMLElement, nspace: String) {
        var xDictionary: [String : String] = [:]
        
        for x in query.elements(forName: "x") {
            
            xDictionary = [:]
            let fields = x.elements(forName: "field")
            
            for field in fields {
                
                let fieldType = field.attributeStringValue(forName: "var")
                
                switch fieldType {
                    case "FORM_TYPE":
                        if let value = field.element(forName: "value"),
                            let namespace = value.stringValue {
                            xDictionary["namespace"] = namespace
                        }
                    case "urn:xabber:http:url:mediagallery":
                        if let value = field.element(forName: "value"),
                            let url = value.stringValue {
                            xDictionary["galleryURL"] = url
                        }
                    case "urn:xabber:http:url:clandestino:purchases:products:v1":
                        if let value = field.element(forName: "value"),
                            let url = value.stringValue {
                            xDictionary["productsUrl"] = url
                        }
                    case "abuse-addresses":
                        if let value = field.element(forName: "value"),
                           let jid = value.stringValue {
                            AccountManager.shared.find(for: self.owner)?.abuse.register(address: jid, for: self.owner, isGroup: false)
                        }
                    default:
                        continue
                }
            }

            if let namespace = xDictionary["namespace"], namespace == nspace {
                
                if let galleryURL = xDictionary["galleryURL"] {
                    SettingManager.shared.saveItem(for: self.owner, scope: .xabberUploadManager, key: "node", value: galleryURL)
                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, _ in
                        user.cloudStorage.node = galleryURL
                        user.cloudStorage.enable()
                        user.avatarUploader.node = galleryURL
                    })
                }
                
                if let productsUrl = xDictionary["productsUrl"] {
                    SettingManager.shared.saveItem(for: self.owner, scope: .products, key: "productsUrl", value: productsUrl)
                }
            }
        }
    }
    
    private func getNotificationServiceNode(_ query: DDXMLElement, jid: String) -> Bool {
        if let identity = query.element(forName: "identity"),
           identity.attributeStringValue(forName: "type") == "notification",
           identity.attributeStringValue(forName: "category") == "component" {
            AccountManager.shared.find(for: self.owner)?.notifications.configure(for: jid)
            return true
        }
        return false
    }
    
    private func getFavoritesServiceNode(_ query: DDXMLElement, jid: String)-> Bool {
        guard let identity = query.element(forName: "identity"),
              identity.attributeStringValue(forName: "type") == "archive",
              identity.attributeStringValue(forName: "category") == "component" else {
                  return false
              }
        
        AccountManager.shared.find(for: self.owner)?.favorites.configure(for: jid)
        return true
    }
    
    private func parseHTTPSettings(_ query: DDXMLElement, node: String) {
        var namespace: String = ""
        for feature in query.elements(forName: "feature") {
            if let featureVar = feature.attributeStringValue(forName: "var") {
                if featureVar == "urn:xmpp:http:upload" {
                    namespace = "urn:xmpp:http:upload"
                } else if featureVar == "urn:xmpp:http:upload:0" {
                    namespace = "urn:xmpp:http:upload:0"
                    break
                }
            }
        }
        if namespace.isEmpty { return }
        var maxFileSize: Int32 = 0
        for x in query.elements(forName: "x") {
            var xNamespace: String = ""
            for field in x.elements(forName: "field") {
                let fieldType = field.attributeStringValue(forName: "var")
                if fieldType == "FORM_TYPE" {
                    xNamespace = field.element(forName: "value")?.stringValue ?? ""
                } else if fieldType == "max-file-size" {
                    maxFileSize = field.element(forName: "value")?.stringValueAsInt() ?? 0
                }
            }
            if xNamespace == namespace {
                break
            } else {
                maxFileSize = 0
            }
        }
        self.saveHTTPSettings(node, namespace: namespace, max: Int(maxFileSize))
    }
    
    private func saveHTTPSettings(_ node: String, namespace: String, max fileSize: Int) {
        if node.isEmpty { return }
        SettingManager.shared.saveItem(for: owner, scope: .httpUploader, key: "node", value: node)
        SettingManager.shared.saveItem(for: owner, scope: .httpUploader, key: "namespace", value: namespace)
        SettingManager.shared.saveItem(for: owner, scope: .httpUploader, key: "max_file_size", value: "\(fileSize)")
        
        //If XabberUploadManager will implemet disco in future
//        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: "node", value: node)
//        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: "namespace", value: namespace)
//        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: "max_file_size", value: "\(fileSize)")
    }
    
    private func parseReliableMessageDeliverySettings(_ features: [DDXMLElement]) {
        if features.map({ //item in
            return $0.attributeStringValue(forName: "var")
        }).contains("https://xabber.com/protocol/delivery") {
            saveReliableMessageDeliverySettings("https://xabber.com/protocol/delivery")
        }
    }
    
    
    private func parseMessagesDeleteRewriteSettings(_ features: [DDXMLElement]) {
        if features.map({ //item in
            return $0.attributeStringValue(forName: "var")
        }).contains("https://xabber.com/protocol/rewrite") {
            saveMessagesDeleteRewriteSettings("https://xabber.com/protocol/rewrite")
        }
    }
    
    private func saveReliableMessageDeliverySettings(_ node: String) {
        SettingManager.shared.saveItem(for: owner,
                                           scope: .reliableMessageDelivery,
                                           key: "node",
                                           value: node)
        AccountManager.shared.find(for: owner)?.action({ (user, _) in
            user.deliveryManager.checkAvailability()
        })
    }
    
    private func saveMessagesDeleteRewriteSettings(_ node: String) {
        SettingManager.shared.saveItem(for: owner,
                                           scope: .messageDeleteRewrite,
                                           key: "node",
                                           value: node)
        AccountManager.shared.find(for: owner)?.action({ (user, _) in
            user.msgDeleteManager.checkAvailability()
        })
    }
    
    func loadFeatures() -> Bool {
        if SettingManager
            .shared
            .getKey(for: owner, scope: .httpUploader, key: "node")?
//            .getKey(for: owner, scope: .xabberUploadManager, key: "node")?
            .isNotEmpty ?? false { return true}
        return false
    }
    
//    Identity block
    open func sendIdentity(_ xmppStream: XMPPStream, to jid: XMPPJID?, for elementId: String) {
        let query = DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
        query.addAttribute(withName: "node", stringValue: "https://www.xabber.com/clients/xabber/ios")
        let identity = DDXMLElement.element(withName: "identity") as! DDXMLElement
        identity.addAttribute(withName: "category", stringValue: "client")
        identity.addAttribute(withName: "name", stringValue: ServerDiscoManager.clientName)
        identity.addAttribute(withName: "type", stringValue: "phone")
        for feature in clientFeatures.sorted() {
            if feature.isEmpty { continue }
            let element = DDXMLElement.element(withName: "feature") as! DDXMLElement
            element.addAttribute(withName: "var", stringValue: feature)
            query.addChild(element)
        }
        query.addChild(identity)
        xmppStream.send(XMPPIQ(iqType: .result, to: jid, elementID: elementId, child: query))
    }
    
    func readIdentityRequest(withIQ iq: XMPPIQ) -> Bool {
        if iq.iqType == .get {
            if iq.element(forName: "query")?.xmlns() == "http://jabber.org/protocol/disco#info" {
                guard let from = iq.from else { return false }
                guard let elementId = iq.elementID else { return false }
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.disco.sendIdentity(stream, to: from, for: elementId)
                })
                return true
            }
        }
        return false
    }
    
    private func parseClientIdentity(iq: XMPPIQ) -> Bool {
        guard let from = iq.from,
            let resource = from.resource,
            let identity = iq.element(forName: "query")?.element(forName: "identity"),
            let category = identity.attributeStringValue(forName: "category"),
            category == "client" else { return false }
        return true
    }
    
    func requestIdentity(_ xmppStream: XMPPStream, by presence: XMPPPresence) {
        guard let jid = presence.from else {
            return
        }
        guard let caps = presence.element(forName: "c"),
            let node = caps.attributeStringValue(forName: "node"),
            let ver = caps.attributeStringValue(forName: "ver") else {
                requestIdentity(xmppStream, for: jid)
                return
        }
        requestIdentity(xmppStream, for: jid, node: [node, ver].joined(separator: "#"))
    }
    
    func requestIdentity(_ xmppStream: XMPPStream, for jid: XMPPJID, node: String? = nil) {
        if isResourseCached(for: jid) { return }
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement.element(withName: "query") as! DDXMLElement
        query.setXmlns("http://jabber.org/protocol/disco#info")
        if let node = node {
            query.addAttribute(withName: "node", stringValue: node)
        }
        let iq = XMPPIQ(iqType: .get, to: jid, elementID: elementId, child: query)
        xmppStream.send(iq)
        self.queryIds.insert(elementId)
    }
    
    func requestIdentityForAllResources(_ xmppStream: XMPPStream, for jid: String) {
        do {
            let realm = try WRealm.safe()
            realm.objects(ResourceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, jid).forEach {
                if let jid = XMPPJID(string: jid, resource: $0.resource) {
                    requestIdentity(xmppStream, for: jid) // fail when resources not found
                }
            }
        } catch {
            DDLogDebug("cant get roster item for jid \(jid), account: \(self.owner) to build list of resources")
        }
    }
    
    func parseClientFeatures(_ query: DDXMLElement?) -> ClientDiscoStorageItem {
        let item = ClientDiscoStorageItem()
        if query == nil { return item }
        for feature in query!.elements(forName: "feature") {
            if let value = feature.attributeStringValue(forName: "var") {
                item.features.append(value)
            }
        }
        return item
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        
    }
    
    func isResourseCached(for jid: XMPPJID) -> Bool {
        do {
            let realm = try WRealm.safe()
            return !realm.objects(ClientDiscoStorageItem.self).filter("owner == %@ AND jid == %@ AND resource == %@", self.owner, jid.bare, jid.resource ?? "").isEmpty
        } catch {
            DDLogDebug("cant check cached resource. \(error.localizedDescription)")
        }
        return false
    }
    
    func isAnyClient(has feature: String, jid: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            let resources = realm.objects(ClientDiscoStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, jid)
            for resource in resources {
                if resource.features.contains(feature) {
                    return true
                }
            }
        } catch {
            DDLogDebug("cant check fature. \(error.localizedDescription)")
        }
        return false
    }
}
