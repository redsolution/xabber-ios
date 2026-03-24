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
        case contact = "contact"
        case device = "device"
        case mention = "mention"
        case info = "info"
    }

    struct ParsedPayload {
        let jid: String
        let originalSenderJid: String?
        let category: Category
        let notificationType: String?
        let fallbackText: String?
        let forwardedMessage: DDXMLElement?
        let text: String?
        let metadata: [String: Any]?
        let displayNick: String?
        let shouldShow: Bool
        let date: Date
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

    private var storagePrimary: String {
        XMPPNotificationsManagerStorageItem.genPrimary(owner: self.owner)
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
                    instance.archiveSyncCompleted = false
                    instance.lastSyncedNotificationId = nil
                    instance.lastSyncAt = nil
                }
            } else {
                let instance = XMPPNotificationsManagerStorageItem()
                instance.owner = self.owner
                instance.primary = XMPPNotificationsManagerStorageItem.genPrimary(owner: self.owner)
                instance.node = jid
                instance.archiveSyncCompleted = false
                try realm.write {
                    realm.add(instance)
                }
            }
            if let chatInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)) {
                try realm.write {
                    realm.delete(chatInstance)
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

    private static func parseNotificationDate(from message: XMPPMessage, owner: String) -> Date? {
        guard let dateString = message
            .elements(forName: "time")
            .first(where: {
                $0.xmlns() == "https://xabber.com/protocol/delivery"
                && $0.attributeStringValue(forName: "by", withDefaultValue: "none") == owner
            })?
            .attributeStringValue(forName: "stamp", withDefaultValue: "0") else {
            return nil
        }

        let formatterWithMillis = DateFormatter()
        formatterWithMillis.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        if let date = formatterWithMillis.date(from: dateString) {
            return date
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: dateString)
    }

    private static func notificationAddressMap(from message: XMPPMessage) -> [String: String] {
        let addresses = message.element(forName: "addresses", xmlns: "http://jabber.org/protocol/address")
            ?? message.element(forName: "addresses")

        return addresses?
            .elements(forName: "address")
            .reduce(into: [String: String]()) { partialResult, element in
                let type = element.attributeStringValue(forName: "type", withDefaultValue: "")
                let jid = element.attributeStringValue(forName: "jid", withDefaultValue: "")
                if type.isNotEmpty, jid.isNotEmpty {
                    partialResult[type] = jid
                }
            } ?? [:]
    }

    static func parsePayload(
        from message: XMPPMessage,
        owner: String,
        notificationNamespace: String = XMPPNotificationsManager.xmlns
    ) -> ParsedPayload? {
        var bareMessage: XMPPMessage = message
        if isArchivedMessage(message) {
            bareMessage = getArchivedMessageContainer(message) ?? message
        } else if isCarbonCopy(message) {
            bareMessage = getCarbonCopyMessageContainer(message) ?? message
        } else if isCarbonForwarded(message) {
            bareMessage = getCarbonForwardedMessageContainer(message) ?? message
        }

        guard let notification = bareMessage.element(forName: "notification", xmlns: notificationNamespace),
              let date = Self.parseNotificationDate(from: bareMessage, owner: owner) else {
            return nil
        }

        let addresses = Self.notificationAddressMap(from: bareMessage)
        let originalSenderRaw = addresses["ofrom"] ?? addresses["from"] ?? addresses["jid"] ?? addresses["to"]
        let originalSender = XMPPJID(string: originalSenderRaw ?? "")?.bare
        let notificationType = notification.attributeStringValue(forName: "type")
        let fallbackText = bareMessage.element(forName: "body")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        let forwardedMessage = notification
            .element(forName: "forwarded", xmlns: "urn:xmpp:forward:0")?
            .element(forName: "message")
            ?? notification.element(forName: "forwarded")?.element(forName: "message")

        if let forwardedMessage,
           let originalSender,
           let forwardedFrom = XMPPJID(string: forwardedMessage.attributeStringValue(forName: "from", withDefaultValue: ""))?.bare,
           forwardedFrom != originalSender {
            return nil
        }

        let displayNick = forwardedMessage?
            .element(forName: "nick", xmlns: "http://jabber.org/protocol/nick")?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let targetJid = originalSender
            ?? XMPPJID(string: forwardedMessage?.attributeStringValue(forName: "from", withDefaultValue: "") ?? "")?.bare
            ?? XMPPJID(string: bareMessage.from?.bare ?? "")?.bare

        guard let jid = targetJid, jid.isNotEmpty else {
            return nil
        }

        if let messageContainer = forwardedMessage,
           let deviceElement = messageContainer.element(forName: "device") {
            let deviceId = deviceElement.attributeStringValue(forName: "id", withDefaultValue: "none")
            let body = messageContainer.element(forName: "body")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedPayload(
                jid: jid,
                originalSenderJid: originalSender,
                category: .device,
                notificationType: notificationType,
                fallbackText: fallbackText,
                forwardedMessage: messageContainer,
                text: body ?? fallbackText,
                metadata: ["deviceId": deviceId],
                displayNick: displayNick,
                shouldShow: notificationType != "system",
                date: date
            )
        }

        if let mentionElement = notification.element(forName: "mention") {
            let mentionText = mentionElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = forwardedMessage?.element(forName: "body")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedPayload(
                jid: jid,
                originalSenderJid: originalSender,
                category: .mention,
                notificationType: notificationType,
                fallbackText: fallbackText,
                forwardedMessage: forwardedMessage,
                text: body ?? mentionText ?? fallbackText,
                metadata: nil,
                displayNick: displayNick,
                shouldShow: notificationType != "system",
                date: date
            )
        }

        if let infoElement = notification.element(forName: "info") {
            let infoText = infoElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = forwardedMessage?.element(forName: "body")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedPayload(
                jid: jid,
                originalSenderJid: originalSender,
                category: .info,
                notificationType: notificationType,
                fallbackText: fallbackText,
                forwardedMessage: forwardedMessage,
                text: body ?? infoText ?? fallbackText,
                metadata: infoText.map { ["text": $0] },
                displayNick: displayNick,
                shouldShow: notificationType != "system",
                date: date
            )
        }

        return nil
    }

    private final func lastReadNotificationDate(in realm: Realm) -> TimeInterval {
        realm.objects(NotificationStorageItem.self)
            .filter("owner == %@ AND isRead == true", self.owner)
            .sorted(byKeyPath: "date", ascending: false)
            .first?
            .date
            .timeIntervalSince1970 ?? 0
    }

    private final func updateSyncProgress(with uniqueId: String, date: Date, in realm: Realm) throws {
        let oldestLoaded = realm.objects(NotificationStorageItem.self)
            .filter("owner == %@", self.owner)
            .sorted(byKeyPath: "date", ascending: true)
            .first?
            .uniqueId

        try realm.write {
            let storage: XMPPNotificationsManagerStorageItem
            if let existing = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary) {
                storage = existing
            } else {
                let created = XMPPNotificationsManagerStorageItem()
                created.owner = self.owner
                created.primary = self.storagePrimary
                created.node = self.node
                realm.add(created)
                storage = created
            }
            storage.lastSyncedNotificationId = oldestLoaded ?? uniqueId
            storage.lastSyncAt = Date()
        }
    }
    
    public func read(withMessage message: XMPPMessage) -> Bool {
        guard let parsed = Self.parsePayload(from: message, owner: self.owner, notificationNamespace: self.getPrimaryNamespace()) else {
            return false
        }

        var bareMessage: XMPPMessage = message
        if isArchivedMessage(message) {
            bareMessage = getArchivedMessageContainer(message) ?? message
        } else if isCarbonCopy(message) {
            bareMessage = getCarbonCopyMessageContainer(message) ?? message
        } else if isCarbonForwarded(message) {
            bareMessage = getCarbonForwardedMessageContainer(message) ?? message
        }

        let uniqueMessageId = getUniqueMessageId(bareMessage, owner: self.owner)
        let messageId = getOriginOrMessageId(bareMessage)

        do {
            let realm = try WRealm.safe()
            if realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: parsed.jid, uniqueId: uniqueMessageId)) != nil {
                return true
            }

            let instance = NotificationStorageItem()
            instance.owner = self.owner
            instance.jid = parsed.jid
            instance.associatedJid = parsed.originalSenderJid
            instance.displayedNick = parsed.displayNick
            instance.uniqueId = uniqueMessageId
            instance.messageId = messageId
            instance.primary = NotificationStorageItem.genPrimary(owner: self.owner, jid: parsed.jid, uniqueId: uniqueMessageId)
            instance.category = parsed.category
            instance.notificationType = parsed.notificationType
            instance.originalSenderJid = parsed.originalSenderJid
            instance.fallbackText = parsed.fallbackText
            instance.text = parsed.text
            instance.metadata = parsed.metadata
            instance.date = parsed.date
            instance.shouldShow = parsed.shouldShow
            let lastReadDate = lastReadNotificationDate(in: realm)
            instance.isRead = parsed.date.timeIntervalSince1970 <= lastReadDate

            if parsed.category == .device,
               let deviceId = parsed.metadata?["deviceId"] as? String,
               let deviceInstance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: DeviceStorageItem.genPrimary(uid: deviceId, owner: self.owner)) {
                instance.metadata = [
                    "deviceId": deviceId,
                    "ip": deviceInstance.ip,
                    "client": deviceInstance.client,
                    "device": deviceInstance.device,
                ]
            }

            try realm.write {
                realm.add(instance)
            }
            try updateSyncProgress(with: uniqueMessageId, date: parsed.date, in: realm)
        } catch {
            DDLogDebug("XMPPNotificationManager: \(#function). \(error.localizedDescription)")
        }

        return true
    }
    
    public func readAll(_ stream: XMPPStream) {
        do {
            let realm = try WRealm.safe()
            guard let node = self.node else {
                return
            }
            if let lastReadNotification = realm
                .objects(NotificationStorageItem.self)
                .filter("owner == %@ AND isRead == false", self.owner)
                .sorted(byKeyPath: "date", ascending: false)
                .first {
                
                let elementId = "ChatMarkers: \(NanoID.new(8))"
                let displayed = DDXMLElement(name: "displayed", xmlns: getPrimaryNamespace())
                displayed.addAttribute(withName: "id", stringValue: lastReadNotification.messageId)
                
                let response = XMPPMessage(messageType: .chat, to: XMPPJID(string: node), elementID: elementId, child: displayed)
                let conversationType = ClientSynchronizationManager.ConversationType.notifications
                let conversation = DDXMLElement(name: "conversation", xmlns: "https://xabber.com/protocol/synchronization")
                conversation.addAttribute(withName: "type", stringValue: conversationType.rawValue)
                conversation.addAttribute(withName: "jid", stringValue: node)
                response.addChild(conversation)
                stream.send(response)

                try realm.write {
                    realm.objects(NotificationStorageItem.self)
                        .filter("owner == %@ AND isRead == false", self.owner)
                        .forEach { $0.isRead = true }
                    let storage: XMPPNotificationsManagerStorageItem
                    if let existing = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary) {
                        storage = existing
                    } else {
                        let created = XMPPNotificationsManagerStorageItem()
                        created.owner = self.owner
                        created.primary = self.storagePrimary
                        created.node = self.node
                        realm.add(created)
                        storage = created
                    }
                    storage.lastSyncAt = Date()
                }
            }
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public func update(_ stream: XMPPStream) {
        guard isAvailable(), let node = self.node else { return }
        do {
            let realm = try WRealm.safe()
            let storage = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: storagePrimary)
            let latestLocalId = realm
                .objects(NotificationStorageItem.self)
                .filter("owner == %@", self.owner)
                .sorted(byKeyPath: "date", ascending: false)
                .first?
                .uniqueId
            if storage?.archiveSyncCompleted == true, let latestLocalId, latestLocalId.isNotEmpty {
                AccountManager.shared.find(for: self.owner)?.mam.requestArchive(
                    stream,
                    jid: node,
                    isContinues: false,
                    conversationType: .notifications,
                    flipPage: false,
                    afterId: latestLocalId,
                    max: 200
                )
            } else {
                let nextPage = storage?.lastSyncedNotificationId?.isEmpty == false ? storage?.lastSyncedNotificationId : ""
                AccountManager.shared.find(for: self.owner)?.mam.requestArchive(
                    stream,
                    jid: node,
                    isContinues: true,
                    conversationType: .notifications,
                    queryId: "MAM notifications: \(NanoID.new(8))",
                    flipPage: false,
                    nextPage: nextPage,
                    max: 200,
                    callback: { [weak self] in
                        guard let self else { return }
                        do {
                            let realm = try WRealm.safe()
                            if let storage = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary) {
                                let latestArchivedId = realm.objects(NotificationStorageItem.self)
                                    .filter("owner == %@", self.owner)
                                    .sorted(byKeyPath: "date", ascending: true)
                                    .first?
                                    .uniqueId
                                try realm.write {
                                    storage.archiveSyncCompleted = true
                                    storage.lastSyncedNotificationId = latestArchivedId ?? storage.lastSyncedNotificationId
                                    storage.lastSyncAt = Date()
                                }
                            }
                        } catch {
                            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
                        }
                    }
                )
            }
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(XMPPNotificationsManagerStorageItem.self)
                .filter("owner == %@", owner)
            let notifications = realm.objects(NotificationStorageItem.self)
                .filter("owner == %@", owner)
            if commitTransaction {
                try realm.write {
                    realm.delete(collection)
                    realm.delete(notifications)
                }
            } else {
                realm.delete(collection)
                realm.delete(notifications)
            }
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }
    }
}
