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
import RxRealm
import RxSwift
import XMPPFramework

class XTokenManager: AbstractXMPPManager {
    
    internal var tokensSupport: Bool = false
    internal var tokens: Results<DeviceStorageItem>? = nil
    internal var server: XMPPJID
    internal var bag: DisposeBag = DisposeBag()
    
    override init(withOwner owner: String) {
        guard let serverJid = XMPPJID(string: owner)?.domainJID else {
            fatalError()
        }
        server = serverJid
        super.init(withOwner: owner)
        load()
        subscribe()
    }
    
    override func namespaces() -> [String] {
        return [
            "https://xabber.com/protocol/auth-tokens",
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    internal func load() {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner) {
                tokensSupport = instance.xTokenSupport
            }
            tokens = realm.objects(DeviceStorageItem.self).filter("owner == %@", owner)
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func subscribe() {
        if !tokensSupport { return }
        bag = DisposeBag()
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    open func revokeAll(_ xmppStream: XMPPStream) {
        if !tokensSupport { return }
        let elementId = xmppStream.generateUUID
        let revokeAll = DDXMLElement(name: "revoke-all", xmlns: getPrimaryNamespace())
        xmppStream.send(XMPPIQ(iqType: .set, to: server, elementID: elementId, child: revokeAll))
        queryIds.insert(elementId)
        do {
            let realm = try WRealm.safe()
            guard let currentToken = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.xTokenUID else {
                return
            }
            let collection = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND uid != %@", owner, currentToken)
            try realm.write {
                realm.delete(collection)
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    open func revoke(_ xmppStream: XMPPStream, uids: [String]) {
        if !tokensSupport { return }
        let elementId = xmppStream.generateUUID
        let revoke = DDXMLElement(name: "revoke", xmlns: getPrimaryNamespace())
        uids.compactMap {
            uid in
            let element = DDXMLElement(name: "xtoken")
            element.addAttribute(withName: "uid", stringValue: uid)
            return element
        }.forEach {
            revoke.addChild($0)
        }
        xmppStream.send(XMPPIQ(iqType: .set, to: server, elementID: elementId, child: revoke))
        queryIds.insert(elementId)
        do {
            let realm = try WRealm.safe()
            var query: [DeviceStorageItem] = []
            uids.forEach {
                if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [$0, owner].prp()) {
                    query.append(instance)
                }
            }
            try realm.write {
                realm.delete(query)
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    open func checkAndRequest(_ xmppStream: XMPPStream, features: DDXMLElement) {
        if features.element(forName: "starttls") != nil { return }
        guard let xToken = features.element(forName: "x-token"),
            xToken.xmlns() == getPrimaryNamespace(),
            tokensSupport == false else {
                return
        }
        tokensSupport = true
        requestNew(xmppStream)
    }
    
    open func requestElement() -> XMPPIQ? {
        if !tokensSupport { return nil}
        let elementId = UUID().uuidString
        return XMPPIQ(iqType: .set, to: server, elementID: elementId, child: genTokenBody())
    }
    
    open func genTokenBody() -> DDXMLElement {
        let deviceInfo = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        let clientInfo = "Xabber"
        let client = DDXMLElement(name: "client", stringValue: clientInfo)
        let device = DDXMLElement(name: "device", stringValue: deviceInfo)
        let descr = DDXMLElement(name: "description", stringValue: UIDevice.current.name)
        let issue = DDXMLElement(name: "issue", xmlns: getPrimaryNamespace())
        issue.addChild(client)
        issue.addChild(device)
        issue.addChild(descr)
        return issue
    }
    
    open func requestNew(_ xmppStream: XMPPStream) {
        if let iq = requestElement(),
            let elementId = iq.elementID {
            xmppStream.send(iq)
            queryIds.insert(elementId)
        }
    }
    
    open func requestList(_ xmppStream: XMPPStream) {
        if !tokensSupport { return }
        let elementID = xmppStream.generateUUID
        xmppStream.send(
            XMPPIQ(
                iqType: .get,
                to: server,
                elementID: elementID,
                child: DDXMLElement(
                    name: "query",
                    xmlns: [getPrimaryNamespace(),"items"].joined(separator: "#")
                )
            )
        )
        queryIds.insert(elementID)
    }
    
    open func read(features: [String]) -> Bool {
        if tokensSupport { return false }
        if features.contains(getPrimaryNamespace()) {
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner) {
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            instance.xTokenSupport = true
                        }
                    }
                }
            } catch {
                DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
            }
            self.tokensSupport = true
            return true
        }
        return false
    }
    
    public final func receive(_ xmppStream: XMPPStream, withMessage message: XMPPMessage) -> Bool {
        guard message.messageType == .headline else {
            return false
        }
        switch true {
        case self.readCurrentTokenAuth(message): return true
        case self.readRevoke(message): return true
        case self.readRevokeAll(message): return true
        default: return false
        }
    }
    
    private final func readRevokeAll(_ message: XMPPMessage) -> Bool {
        guard message.element(forName: "revoke-all",
                              xmlns: getPrimaryNamespace()) != nil else {
            return false
        }
        
        do {
            let realm = try WRealm.safe()
            try realm.write {
                realm.delete(realm.objects(DeviceStorageItem.self)
                                .filter("owner == %@", self.owner))
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    private final func readRevoke(_ message: XMPPMessage) -> Bool {
        guard let revoke = message.element(forName: "revoke", xmlns: getPrimaryNamespace()) else {
            return false
        }
        
        let uids = revoke
            .elements(forName: "token")
            .compactMap { return $0.attributeStringValue(forName: "uid") }
        
        do {
            let realm = try WRealm.safe()
            try realm.write {
                realm.delete(realm.objects(DeviceStorageItem.self)
                                .filter("owner == %@ AND uid IN %@", self.owner, uids))
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    private final func readCurrentTokenAuth(_ message: XMPPMessage) -> Bool {
        return false
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .result,
            let elementId = iq.elementID,
            queryIds.contains(elementId) else {
                return false
        }
        queryIds.remove(elementId)
        switch true {
        case readNewToken(iq): return true
        case readList(iq): return true
        case readSimpleResponse(iq): return true
        default: return false
        }
    }
    
    internal func readSimpleResponse(_ iq: XMPPIQ) -> Bool {
        return false
    }
    
//    TODO: Fix it
    internal func readNewToken(_ iq: XMPPIQ) -> Bool {
        guard let xtoken = iq.element(forName: "xtoken", xmlns: getPrimaryNamespace()),
              let uid = xtoken.attributeStringValue(forName: "uid"),
              let token = xtoken.element(forName: "token")?.stringValue,
              let expire = xtoken.element(forName: "expire")?.stringValueAsDouble() else {
            return false
        }
        
        CredentialsManager.shared.setItem(for: owner, token: token)
        let deviceInfo = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        let clientInfo = "Xabber"
        let descr = UIDevice.current.name
        let instance = DeviceStorageItem()
        instance.configure(
            for: owner,
            uid: uid,
            ip: "",
            client: clientInfo,
            device: deviceInfo,
            expire: expire,
            authDate: Date().timeIntervalSince1970,
            descr: descr
        )
        do {
            let realm = try WRealm.safe()
            if let account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner) {
                try realm.write {
                    realm.add(instance)
                    account.xTokenUID = uid
                    account.xTokenSupport = true
                }
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
            return false
        }
//        AccountManager.shared.find(for: self.owner)?.devices.update()
        return true
    }
    
    internal func readList(_ iq: XMPPIQ) -> Bool {
        guard let query = iq.element(forName: "query", xmlns: [getPrimaryNamespace(), "items"].joined(separator: "#")) else {
            return false
        }
        
        do {
            let realm = try WRealm.safe()
            let uids = query
                .elements(forName: "xtoken")
                .compactMap { $0.attributeStringValue(forName: "uid") }
            try realm.write {
                let tokensToDelete = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND NOT uid IN %@", self.owner, uids)
                
                realm.delete(tokensToDelete)
                
                query.elements(forName: "xtoken").forEach { item in
                    if let uid = item.attributeStringValue(forName: "uid"),
                       let client = item.element(forName: "client")?.stringValue,
                       let device = item.element(forName: "device")?.stringValue,
                       let descr = item.element(forName: "description")?.stringValue,
                       let expire = item.element(forName: "expire")?.stringValueAsDouble(),
                       let ip = item.element(forName: "ip")?.stringValue,
                       let lastAuth = item.element(forName: "last-auth")?
                        .stringValueAsDouble() {
                        if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [uid, self.owner].prp()) {
                            instance.client = client
                            instance.device = device
                            instance.descr = descr
                            instance.ip = ip
                            instance.expire = Date(timeIntervalSince1970: TimeInterval(expire))
                            instance.authDate = Date(timeIntervalSince1970: TimeInterval(lastAuth))
                        } else {
                            let instance = DeviceStorageItem()
                            instance.configure(
                                for: self.owner,
                                uid: uid,
                                ip: ip,
                                client: client,
                                device: device,
                                expire: expire,
                                authDate: lastAuth,
                                descr: descr
                            )
                            realm.add(instance)
                        }
                    }
                }
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    public final func update(_ xmppStream: XMPPStream, descr newDescr: String?) {
        let deviceInfo = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        let clientInfo = "Xabber"
        let client = DDXMLElement(name: "client", stringValue: clientInfo)
        let device = DDXMLElement(name: "device", stringValue: deviceInfo)
        let descr = DDXMLElement(name: "description", stringValue: newDescr)
        let xtoken = DDXMLElement(name: "xtoken")
        do {
            let realm = try WRealm.safe()
            guard let uid = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.xTokenUID else {
                return
            }
            xtoken.addAttribute(withName: "uid", stringValue: uid)
            xtoken.addChild(descr)
            xtoken.addChild(client)
            xtoken.addChild(device)
            let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
            query.addChild(xtoken)
            let elementId = xmppStream.generateUUID
            xmppStream.send(XMPPIQ(iqType: .set, to: server, elementID: elementId, child: query))
            self.queryIds.insert(elementId)
            if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [uid, self.owner].prp()) {
                try realm.write {
                    instance.client = clientInfo
                    instance.device = deviceInfo
                    instance.descr = newDescr ?? ""
                }
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    open func clearTokens(_ uid: String? = nil) {
        do {
            let realm = try WRealm.safe()
            let tokens: Results<DeviceStorageItem>
            if let uidUnwrap = uid {
                tokens = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND uid == %@", owner, uidUnwrap)
            } else {
                tokens = realm.objects(DeviceStorageItem.self).filter("owner == %@", owner)
            }
            if !realm.isInWriteTransaction {
                try realm.write {
                    realm.delete(tokens)
                }
            }
            
        } catch {
            DDLogDebug("cant remove tokens for \(owner)")
        }
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let tokens = realm.objects(DeviceStorageItem.self).filter("owner == %@", owner)
            if commitTransaction {
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.delete(tokens)
                    }
                }
            } else {
                realm.delete(tokens)
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func clearSession() {
        unsubscribe()
    }
    
}
