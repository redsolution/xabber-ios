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

class XMPPDeviceManager: AbstractXMPPManager {
    public var deviceId: String? = nil
    
    override func namespaces() -> [String] {
        return [
            "https://xabber.com/protocol/devices",
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    public var isAvailable: Bool = false
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        self.update()
    }
    
    public final func setAvailable(_ features: DDXMLElement) {
        if isAvailable {
            return
        }
        if features.element(forName: "starttls") != nil { return }
        
        guard let synchronization = features.element(forName: "devices"),
            synchronization.xmlns() == getPrimaryNamespace() else {
                isAvailable = false
                return
        }
        isAvailable = true
    }
    
    override func onStreamPrepared(_ stream: XMPPStream) {
        self.requestList(stream)
    }
    
    public final func update() {
        do {
            let realm = try WRealm.safe()
            deviceId = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.deviceUuid
            if let myDeviceId = deviceId,
               myDeviceId.isNotEmpty {
                self.isAvailable = true
            }
            try realm.write {
                realm
                    .objects(DeviceStorageItem.self)
                    .filter("owner == %@", self.owner)
                    .forEach { $0.resource = nil }
            }
        } catch {
            DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public var deviceElement: DDXMLElement? {
        get {
            guard let id = deviceId else { return nil }
            let element = DDXMLElement(name: "device", xmlns: getPrimaryNamespace())
            element.addAttribute(withName: "id", stringValue: id)
            return element
        }
    }
    
    public final func updateMyDevice(resource: String) {
        do {
            let realm = try WRealm.safe()
            guard let deviceId = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.deviceUuid else {
                return
            }
            if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [deviceId, self.owner].prp()) {
                try realm.write {
                    instance.resource = resource
                }
            }
            if let instance = realm.object(ofType: ResourceStorageItem.self, forPrimaryKey: ResourceStorageItem.genPrimary(jid: self.owner, owner: owner, resource: resource)) {
                try realm.write {
                    instance.deviceId = deviceId
                }
            }
        } catch {
            DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    open func requestList(_ xmppStream: XMPPStream) {
        if !isAvailable { return }
        let elementID = xmppStream.generateUUID
        xmppStream.send(
            XMPPIQ(
                iqType: .get,
                to: xmppStream.myJID?.domainJID,
                elementID: elementID,
                child: DDXMLElement(
                    name: "query",
                    xmlns: [getPrimaryNamespace(),"items"].joined(separator: "#")
                )
            )
        )
        queryIds.insert(elementID)
    }
    
    public final func update(_ xmppStream: XMPPStream, descr newDescr: String?) {
        let device = DDXMLElement(name: "device")
        let descr = DDXMLElement(name: "description", stringValue: newDescr)
        do {
            let realm = try WRealm.safe()
            guard let uid = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.deviceUuid else {
                return
            }
            device.addAttribute(withName: "id", stringValue: uid)
            
            device.addChild(descr)
            let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
            query.addChild(device)
            let elementId = xmppStream.generateUUID
            xmppStream.send(XMPPIQ(iqType: .set, to: xmppStream.myJID?.domainJID, elementID: elementId, child: query))
            self.queryIds.insert(elementId)
            if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [uid, self.owner].prp()) {
                try realm.write {
                    instance.descr = newDescr ?? ""
                }
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    open func revokeAll(_ xmppStream: XMPPStream) {
//        if !isAvailable { return }
        let elementId = xmppStream.generateUUID
        let revokeAll = DDXMLElement(name: "revoke-all", xmlns: getPrimaryNamespace())
        xmppStream.send(XMPPIQ(iqType: .set, to: xmppStream.myJID?.domainJID, elementID: elementId, child: revokeAll))
        queryIds.insert(elementId)
        do {
            let realm = try WRealm.safe()
            guard let currentToken = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.deviceUuid else {
                return
            }
            let collection = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND uid != %@", owner, currentToken)
            let deviceIds: [Int] = collection.compactMap {
                return $0.omemoDeviceId
            }
            try realm.write {
                realm.delete(collection)
                realm.delete(realm.objects(SignalDeviceStorageItem.self).filter("deviceId IN %@", deviceIds))
                realm.delete(realm.objects(SignalIdentityStorageItem.self).filter("deviceId IN %@", deviceIds))
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    open func revoke(_ xmppStream: XMPPStream, uids: [String]) {
//        if !isAvailable { return }
        let elementId = xmppStream.generateUUID
        let revoke = DDXMLElement(name: "revoke", xmlns: getPrimaryNamespace())
        uids.compactMap {
            uid in
            let element = DDXMLElement(name: "device")
            element.addAttribute(withName: "id", stringValue: uid)
            return element
        }.forEach {
            revoke.addChild($0)
        }
        xmppStream.send(XMPPIQ(iqType: .set, to: xmppStream.myJID?.domainJID, elementID: elementId, child: revoke))
        queryIds.insert(elementId)
        do {
            let realm = try WRealm.safe()
//            var query: [DeviceStorageItem] = []
//            uids.forEach {
//                if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [$0, owner].prp()) {
//                    query.append(instance)
//                }
//            }
            let collection = realm.objects(DeviceStorageItem.self).filter("uid IN %@", uids)
            let deviceIds: [Int] = collection.compactMap {
                return $0.omemoDeviceId
            }
            try realm.write {
                realm.delete(collection)
                realm.delete(realm.objects(SignalDeviceStorageItem.self).filter("deviceId IN %@", deviceIds))
                realm.delete(realm.objects(SignalIdentityStorageItem.self).filter("deviceId IN %@", deviceIds))
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    
    public final func read(withPresence presence: XMPPPresence, commitTransaction: Bool) -> Bool {
        func transaction(_ block: (() -> Void)) throws {
            if commitTransaction {
                let realm = try WRealm.safe()
                try realm.write(block)
            } else {
                block()
            }
        }
        if presence.presenceType == .unavailable {
            guard let from = presence.from,
                  let resource = from.resource else {
                return false
            }
            do {
                let realm = try WRealm.safe()
                
                if let instance =  realm.objects(DeviceStorageItem.self).filter("owner == %@ AND resource == %@", from.bare, resource).first {
                    try transaction {
                        instance.resource = nil
                    }
                }
                
                if let instance = realm.object(ofType: ResourceStorageItem.self, forPrimaryKey: ResourceStorageItem.genPrimary(jid: from.bare, owner: owner, resource: resource)) {
                    try transaction {
                        instance.deviceId = nil
                    }
                }
            } catch {
                DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
            }
            
            return true
        }
        guard let from = presence.from,
              let resource = from.resource,
              let device = presence.element(forName: "device", xmlns: getPrimaryNamespace()),
              let deviceId = device.attributeStringValue(forName: "id") else {
            return false
        }
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [deviceId, from.bare].prp()) {
                try transaction {
                    instance.resource = resource
                }
            }
            if let instance = realm.object(ofType: ResourceStorageItem.self, forPrimaryKey: ResourceStorageItem.genPrimary(jid: from.bare, owner: owner, resource: resource)) {
                try transaction {
                    instance.deviceId = deviceId
                }
            }
        } catch {
            DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    public final func readBatch(_ presences: [XMPPPresence], commitTransaction: Bool) {
        func transaction(_ block: (() -> Void)) {
            do {
                let realm = try WRealm.safe()
                if commitTransaction {
                    try realm.write(block)
                } else {
                    block()
                }
            } catch {
                DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
            }
        }
        transaction {
            presences.forEach {
                _ = read(withPresence: $0, commitTransaction: false)
            }
        }
        
        presences.forEach {
            onNewDeviceAnnouncedInPresence($0)
        }
    }
    
    private final func onNewDeviceAnnouncedInPresence(_ presence: XMPPPresence) {
        if let deviceUuid = presence.element(forName: "device", xmlns: getPrimaryNamespace())?.attributeStringValue(forName: "id"),
           let jid = presence.from?.bare,
           jid != owner,
           let deviceIdInteger = Int(deviceUuid.prefix(8)) {
            do {
                let realm = try WRealm.safe()
                if !(realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner))?.isOmemoDevicesListReceived ?? false) {
                    if realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceIdInteger)) == nil {
//                        AccountManager.shared.find(for: owner)?.action({ user, stream in
//                            user.omemo.getContactDevices(stream, jid: jid)
//                        })
                    }
                }
            } catch {
                DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    override func clearSession() {
        super.clearSession()
    }
    
    internal func readMessage(message: XMPPMessage) {
        guard (message.from?.isServer ?? false),
        message.element(forName: "device", xmlns: getPrimaryNamespace()) != nil else {
            return
        }
        AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
            if AccountManager.shared.newAccountJid != self.owner {
                user.devices.requestList(stream)
                user.omemo.getOwnDevices(stream)
            }
        })
    }
    
    /*<message xmlns="jabber:client" to="andrew@clandestino.chat/clandestino-ios-3F02F22F" from="clandestino.chat" type="headline" id="1437221776883290598">
     <revoke xmlns="https://xabber.com/protocol/devices">
       <device id="079329357b74be246cdc88c82950e7f6"/>
     </revoke>
   </message>*/
    internal func readHeadline(_ message: XMPPMessage) -> Bool {
        guard (message.from?.isServer ?? false),
              let deviceId = message
            .element(forName: "revoke", xmlns: getPrimaryNamespace())?
            .element(forName: "device")?
            .attributeStringValue(forName: "id") else {
            return false
        }
        do {
            let realm = try WRealm.safe()
            let myDeviceId = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.deviceUuid
            
            if myDeviceId == deviceId {
                NotificationCenter.default.post(name: ApplicationStateManager.tokenWasExpired, object: self.owner)
            }
        } catch {
            
        }
        
        return true
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case readRegisterDevice(iq): return true
        case readList(iq): return true
        default: return false
        }
    }
    
    internal func readList(_ iq: XMPPIQ) -> Bool {
        guard let query = iq.element(forName: "query", xmlns: [getPrimaryNamespace(), "items"].joined(separator: "#")) else {
            return false
        }
        
        do {
            let realm = try WRealm.safe()
            let uids = query
                .elements(forName: "device")
                .compactMap { $0.attributeStringValue(forName: "id") }
            try realm.write {
                let tokensToDelete = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND NOT uid IN %@", self.owner, uids)
                
                realm.delete(tokensToDelete)
                
                query.elements(forName: "device").forEach { item in
                    if let uid = item.attributeStringValue(forName: "id"),
                       let client = item.element(forName: "client")?.stringValue,
                       let device = item.element(forName: "info")?.stringValue,
                       let expire = item.element(forName: "expire")?.stringValueAsDouble(),
                       let ip = item.element(forName: "ip")?.stringValue,
                       let lastAuth = item.element(forName: "last-auth")?
                        .stringValueAsDouble() {
                        let omemoId = item.element(forName: "omemo-id")?.stringValueAsNSInteger()
                        let descr = item.element(forName: "description")?.stringValue
                        if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [uid, self.owner].prp()) {
                            instance.client = client
                            instance.device = device
                            instance.descr = descr ?? ""
                            instance.ip = ip
                            instance.omemoDeviceId = omemoId ?? -1
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
                                descr: descr ?? ""
                            )
                            instance.omemoDeviceId = omemoId ?? -1
                            realm.add(instance)
                        }
                    }
                }
                realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.isDevicesListReceived = true
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    private final func readRegisterDevice(_ iq: XMPPIQ) -> Bool {
        guard let device = iq.element(forName: "device", xmlns: getPrimaryNamespace()),
              let elementId = iq.elementID,
              queryIds.contains(elementId),
              let deviceId = device.attributeStringValue(forName: "id"),
              let secret = device.element(forName: "secret")?.stringValue,
              let expire = device.element(forName: "expire")?.stringValueAsDouble() else {
            return false
        }
//        print(self.deviceId, deviceId)
        self.deviceId = deviceId
        
        CredentialsManager.shared.setItem(for: owner, secret: secret)
        let deviceInfo = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        let clientInfo = CommonConfigManager.shared.config.app_name
        let descr = UIDevice.current.name
        let instance = DeviceStorageItem()
        instance.configure(
            for: owner,
            uid: deviceId,
            ip: "",
            client: clientInfo,
            device: deviceInfo,
            expire: expire,
            authDate: Date().timeIntervalSince1970,
            descr: descr
        )
        if let omemoDeviceId = CredentialsManager.shared.getDeviceId(for: self.owner) {
            instance.omemoDeviceId = omemoDeviceId
        }
        do {
            let realm = try WRealm.safe()
            
            if let oldInstance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: instance.primary) {
                try realm.write {
                    realm.delete(oldInstance)
                }
            }
            
            try realm.write {
                realm.add(instance)
            }
            if let account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner) {
                try realm.write {
                    account.deviceUuid = deviceId
                    account.xTokenUID = deviceId
                    account.xTokenSupport = true
                }
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
}
