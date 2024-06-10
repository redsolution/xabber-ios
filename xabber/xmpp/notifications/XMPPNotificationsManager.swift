//
//  XMPPNotificationsManager.swift
//  xabber
//
//  Created by Игорь Болдин on 18.03.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import XMPPFramework
import RealmSwift
import CocoaLumberjack

class XMPPNotificationsManager: AbstractXMPPManager {
    
    static let xmlns: String = "urn:xabber:xen:0"
    
    open var node: String? =  nil
    
    enum Category: String {
        case trust = "trust"
        case contact = "contact"
        case device = "devoce"
        case mention = "mention"
        case none = "none"
    }
    
    override func namespaces() -> [String] {
        return [
            XMPPNotificationsManager.xmlns,
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        XMPPNotificationsManager.xmlns
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        loadLocal()
    }
    
    private final func loadLocal() {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: XMPPNotificationsManagerStorageItem.genPrimary(owner: self.owner)) {
                self.node = instance.node
            }
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func configure(for jid: String) {
        self.node = jid
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: XMPPNotificationsManagerStorageItem.genPrimary(owner: self.owner)) {
                try realm.write {
                    instance.node = jid
                }
            } else {
                let instance = XMPPNotificationsManagerStorageItem()
                instance.owner = self.owner
                instance.primary = XMPPNotificationsManagerStorageItem.genPrimary(owner: self.owner)
                instance.node = jid
                try realm.write {
                    realm.add(instance)
                }
            }
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.notifications.update(stream)
            })
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func isAvailable() -> Bool {
        if let node = self.node, node.isNotEmpty {
            return true
        }
        return false
    }
    
    public func read(withMessage message: XMPPMessage) -> Bool {
//        if message.from?.bare == self.node {
            var bareMessage: XMPPMessage = message
            if isArchivedMessage(message) {
                bareMessage = getArchivedMessageContainer(message) ?? message
            } else if isCarbonCopy(message) {
                bareMessage = getCarbonCopyMessageContainer(message) ?? message
            } else if isCarbonForwarded(message) {
                bareMessage = getCarbonForwardedMessageContainer(message) ?? message
            }
            if let notify = bareMessage.element(forName: "notify", xmlns: self.getPrimaryNamespace()) ?? bareMessage.element(forName: "notification", xmlns: self.getPrimaryNamespace()) {
                let uniqueMessageId = getUniqueMessageId(bareMessage, owner: self.owner)
                guard let messageContainer = notify.element(forName: "forwarded")?.element(forName: "message") else {
                    return false
                }
                guard let jidRaw = messageContainer.attributeStringValue(forName: "from"),
                      let jid = XMPPJID(string: jidRaw)?.bare else {
                    return false
                }
                do {
                    let realm = try WRealm.safe()
                    if realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: jid, uniqueId: uniqueMessageId)) != nil {
                        return true
                    }
                    let instance = NotificationStorageItem()
                    instance.owner = self.owner
                    instance.jid = jid
                    instance.uniqueId = uniqueMessageId
                    instance.primary = NotificationStorageItem.genPrimary(owner: self.owner, jid: jid, uniqueId: uniqueMessageId)
                    if let deviceElement = messageContainer.element(forName: "device") {
                        instance.category = .device
                        let deviceId = deviceElement.attributeStringValue(forName: "id", withDefaultValue: "none")
                        if let deviceInstance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: DeviceStorageItem.genPrimary(uid: deviceId, owner: self.owner)) {
                            instance.metadata = [
                                "deviceId": deviceId,
                                "ip": deviceInstance.ip,
                                "client": deviceInstance.client,
                                "device": deviceInstance.device,
                            ]
                            instance.shouldShow = true
                        } else {
                            instance.metadata = [
                                "deviceId": deviceId,
                            ]
                            instance.shouldShow = true
                        }
                        
                        instance.text = messageContainer.element(forName: "body")?.stringValue
                        guard let dateString = bareMessage
                            .elements(forName: "time")
                            .first(where: { $0.xmlns() == "https://xabber.com/protocol/delivery"
                                && $0.attributeStringValue(forName: "by", withDefaultValue: "none") == owner})?
                            .attributeStringValue(forName: "stamp", withDefaultValue: "0")
                            else {
                                return false
                        }
                        var date: Date? = nil
                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                        date = dateFormatter.date(from: dateString)
                        if date == nil {
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                            date = dateFormatter.date(from: dateString)
                        }
                        instance.date = date ?? Date()
                    } else {
                        return false
                    }
                    try realm.write {
                        realm.add(instance)
                    }
                } catch {
                    DDLogDebug("XMPPNotificationManager: \(#function). \(error.localizedDescription)")
                }
                return true
            } else {
                return false
            }
    }
    
    public func update(_ stream: XMPPStream) {
        guard isAvailable(), let node = self.node, node.isNotEmpty, XMPPJID(string: node)?.bare != nil else { return }
        do {
            let realm = try WRealm.safe()
            let lastId = realm.object(
                ofType: XMPPNotificationsManagerStorageItem.self,
                forPrimaryKey: XMPPNotificationsManagerStorageItem
                    .genPrimary(owner: self.owner)
            )?.lastItemId
            AccountManager
                .shared
                .find(for: self.owner)?
                .action({ user, stream in
                    user.mam.requestArchive(
                        stream,
                        jid: node,
                        isContinues: true,
                        conversationType: .notifications,
                        flipPage: false,
                        before: lastId
                    )
                })
        } catch {
            fatalError()
        }
        
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(XMPPNotificationsManagerStorageItem.self)
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
