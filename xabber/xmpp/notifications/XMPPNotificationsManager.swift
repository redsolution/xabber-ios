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
    private static let archivePageSize: Int = 100
    
    open var node: String? =  nil

    private enum SyncRequestKind {
        case latest
        case backfill
    }

    private enum LatestSyncCursorSource: String {
        case persistedHighWater = "lastItemId"
        case newestStoredNotification = "newestStoredNotification"
        case bootstrap = "bootstrap"
    }
    
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

    private let syncStateQueue = DispatchQueue(label: "com.xabber.notifications.sync-state")
    private var isLatestSyncInProgress: Bool = false
    private var isBackfillInProgress: Bool = false
    
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
    
    public final func formIQ(to: XMPPJID, child: DDXMLElement) -> DDXMLElement {
        let elementId = "XEN: \(NanoID.new(9))"
        let notify = DDXMLElement(name: "notify", xmlns: self.getPrimaryNamespace())
        let notification = DDXMLElement(name: "notification", xmlns: self.getPrimaryNamespace())

        let addresses = DDXMLElement(name: "addresses", xmlns: "http://jabber.org/protocol/address")
        let toAddress = DDXMLElement(name: "address")
        toAddress.addAttribute(withName: "type", stringValue: "to")
        let targetJid = to.full.isEmpty ? to.bare : to.full
        toAddress.addAttribute(withName: "jid", stringValue: targetJid)
        addresses.addChild(toAddress)

        if let originalFrom = child.attributeStringValue(forName: "from"), !originalFrom.isEmpty {
            let originalFromAddress = DDXMLElement(name: "address")
            originalFromAddress.addAttribute(withName: "type", stringValue: "ofrom")
            originalFromAddress.addAttribute(withName: "jid", stringValue: originalFrom)
            addresses.addChild(originalFromAddress)
        }

        let forwarded = DDXMLElement(name: "forwarded", xmlns: "urn:xmpp:forward:0")
        if let forwardedChild = child.copy() as? DDXMLElement {
            forwarded.addChild(forwardedChild)
        }
        notification.addChild(forwarded)
        notify.addChild(notification)
        notify.addChild(addresses)

        let iq = XMPPIQ(iqType: .set, to: to, elementID: elementId, child: notify)

        return iq
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
        self.reconcileMentionNotificationsOnStartup()
    }

    private final func reconcileMentionNotificationsOnStartup() {
        do {
            let realm = try WRealm.safe()
            var messagePrimariesToMarkRead: Set<String> = []
            try realm.write {
                messagePrimariesToMarkRead = MentionNotificationSync.reconcileMentionNotifications(
                    for: self.owner,
                    in: realm
                )
            }
            messagePrimariesToMarkRead.forEach { primary in
                AccountManager.shared.find(for: self.owner)?.messages.readMessage(primary, last: false)
            }
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }
    }

    @discardableResult
    private final func beginSync(_ kind: SyncRequestKind) -> Bool {
        self.syncStateQueue.sync {
            switch kind {
            case .latest:
                guard !self.isLatestSyncInProgress else {
                    return false
                }
                self.isLatestSyncInProgress = true
                return true
            case .backfill:
                guard !self.isBackfillInProgress else {
                    return false
                }
                self.isBackfillInProgress = true
                return true
            }
        }
    }

    private final func endSync(_ kind: SyncRequestKind) {
        self.syncStateQueue.sync {
            switch kind {
            case .latest:
                self.isLatestSyncInProgress = false
            case .backfill:
                self.isBackfillInProgress = false
            }
        }
    }

    private final func resetSyncState() {
        self.syncStateQueue.sync {
            self.isLatestSyncInProgress = false
            self.isBackfillInProgress = false
        }
    }

    private final func archiveManager() -> MessageArchiveManager? {
        AccountManager.shared.find(for: self.owner)?.mam
    }

    @discardableResult
    private final func ensureStorage(in realm: Realm) -> XMPPNotificationsManagerStorageItem {
        if let existing = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary) {
            return existing
        }

        let created = XMPPNotificationsManagerStorageItem()
        created.owner = self.owner
        created.primary = self.storagePrimary
        created.node = self.node
        realm.add(created)
        return created
    }

    private final func newestStoredArchiveId(in realm: Realm) -> String? {
        realm.objects(NotificationStorageItem.self)
            .filter("owner == %@ AND stanzaId != ''", self.owner)
            .sorted(byKeyPath: "date", ascending: false)
            .first?
            .stanzaId
    }

    private final func latestSyncCursor(in realm: Realm) -> (cursor: String?, source: LatestSyncCursorSource) {
        if let persisted = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary)?
            .lastItemId,
           persisted.isNotEmpty {
            return (persisted, .persistedHighWater)
        }

        if let newestStored = newestStoredArchiveId(in: realm), newestStored.isNotEmpty {
            return (newestStored, .newestStoredNotification)
        }

        return (nil, .bootstrap)
    }

    private final func oldestStoredArchiveId(in realm: Realm) -> String? {
        realm.objects(NotificationStorageItem.self)
            .filter("owner == %@ AND stanzaId != ''", self.owner)
            .sorted(byKeyPath: "date", ascending: true)
            .first?
            .stanzaId
    }

    private final func storedBackfillCursor(in realm: Realm, fallback: String? = nil) -> String? {
        let persisted = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary)?
            .lastSyncedNotificationId
        if let persisted, persisted.isNotEmpty {
            return persisted
        }
        if let oldestStored = oldestStoredArchiveId(in: realm), oldestStored.isNotEmpty {
            return oldestStored
        }
        if let fallback, fallback.isNotEmpty {
            return fallback
        }
        return nil
    }

    private final func updateSyncProgress(
        in realm: Realm,
        archiveSyncCompleted: Bool? = nil,
        latestScannedArchiveId: String? = nil,
        fallbackOldestArchiveId: String? = nil
    ) throws {
        let oldestLoadedArchiveId = oldestStoredArchiveId(in: realm)
            ?? fallbackOldestArchiveId
            ?? realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary)?.lastSyncedNotificationId

        try realm.write {
            let storage = ensureStorage(in: realm)
            storage.lastSyncedNotificationId = oldestLoadedArchiveId
            if let latestScannedArchiveId,
               latestScannedArchiveId.isNotEmpty {
                storage.lastItemId = latestScannedArchiveId
                DDLogDebug("XMPPNotificationsManager: persisted latest cursor owner=\(self.owner) node=\(storage.node ?? "") lastItemId=\(latestScannedArchiveId)")
            }
            if let archiveSyncCompleted {
                storage.archiveSyncCompleted = archiveSyncCompleted
            }
            storage.lastSyncAt = Date()
        }
    }
    
    public final func configure(for jid: String) {
        self.node = jid
        do {
            let realm = try WRealm.safe()
            var didChangeNode = false
            if let instance = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: XMPPNotificationsManagerStorageItem.genPrimary(owner: self.owner)) {
                didChangeNode = instance.node != jid && instance.node?.isNotEmpty == true
                try realm.write {
                    instance.node = jid
                    if didChangeNode {
                        instance.archiveSyncCompleted = false
                        instance.lastSyncedNotificationId = nil
                        instance.lastItemId = nil
                        instance.lastSyncAt = nil
                    }
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
            if didChangeNode {
                self.resetSyncState()
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

        return dateString.xmppDate
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

    private static func normalizedCategory(
        from notification: DDXMLElement,
        forwardedMessage: DDXMLElement?
    ) -> Category? {
        let rawCategory = notification
            .attributeStringValue(forName: "category", withDefaultValue: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch rawCategory {
        case Category.mention.rawValue:
            return .mention
        case "security", Category.device.rawValue:
            return .device
        case Category.info.rawValue:
            return .info
        case Category.contact.rawValue:
            return .contact
        default:
            break
        }

        if forwardedMessage?.element(forName: "device") != nil {
            return .device
        }

        if notification.element(forName: "mention") != nil {
            return .mention
        }

        if notification.element(forName: "info") != nil {
            return .info
        }

        return nil
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
           forwardedFrom != originalSender,
           forwardedMessage.attributeStringValue(forName: "type", withDefaultValue: "chat") != "groupchat" {
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

        guard let category = Self.normalizedCategory(from: notification, forwardedMessage: forwardedMessage) else {
            return nil
        }

        let forwardedBody = forwardedMessage?
            .element(forName: "body")?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch category {
        case .device:
            let deviceId = forwardedMessage?
                .element(forName: "device")?
                .attributeStringValue(forName: "id", withDefaultValue: "none")
            let deviceMetadata = deviceId.flatMap { $0.isNotEmpty ? ["deviceId": $0] : nil }
            return ParsedPayload(
                jid: jid,
                originalSenderJid: originalSender,
                category: .device,
                notificationType: notificationType,
                fallbackText: fallbackText,
                forwardedMessage: forwardedMessage,
                text: forwardedBody ?? fallbackText,
                metadata: deviceMetadata,
                displayNick: displayNick,
                shouldShow: notificationType != "system",
                date: date
            )
        case .mention:
            let mentionText = notification
                .element(forName: "mention")?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedPayload(
                jid: jid,
                originalSenderJid: originalSender,
                category: .mention,
                notificationType: notificationType,
                fallbackText: fallbackText,
                forwardedMessage: forwardedMessage,
                text: forwardedBody ?? mentionText ?? fallbackText,
                metadata: MentionNotificationSync.mentionMetadata(
                    from: forwardedMessage,
                    owner: owner,
                    originalSenderJid: originalSender,
                    fallbackDate: date
                ),
                displayNick: displayNick,
                shouldShow: notificationType != "system",
                date: date
            )
        case .info:
            let infoText = notification
                .element(forName: "info")?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedPayload(
                jid: jid,
                originalSenderJid: originalSender,
                category: .info,
                notificationType: notificationType,
                fallbackText: fallbackText,
                forwardedMessage: forwardedMessage,
                text: forwardedBody ?? infoText ?? fallbackText,
                metadata: infoText.map { ["text": $0] },
                displayNick: displayNick,
                shouldShow: notificationType != "system",
                date: date
            )
        case .contact:
            return ParsedPayload(
                jid: jid,
                originalSenderJid: originalSender,
                category: .contact,
                notificationType: notificationType,
                fallbackText: fallbackText,
                forwardedMessage: forwardedMessage,
                text: forwardedBody ?? fallbackText,
                metadata: nil,
                displayNick: displayNick,
                shouldShow: notificationType != "system",
                date: date
            )
        }
    }

    private final func lastReadNotificationDate(in realm: Realm) -> TimeInterval {
        realm.objects(NotificationStorageItem.self)
            .filter("owner == %@ AND isRead == true", self.owner)
            .sorted(byKeyPath: "date", ascending: false)
            .first?
            .date
            .timeIntervalSince1970 ?? 0
    }

    private final func resolvedNotificationReadState(
        stanzaId: String,
        date: Date,
        in realm: Realm
    ) -> Bool {
        let storage = realm.object(
            ofType: XMPPNotificationsManagerStorageItem.self,
            forPrimaryKey: self.storagePrimary
        )

        if let boundaryReadState = XMPPNotificationsManagerStorageItem.notificationUnreadBoundaryReadState(
            stanzaId: stanzaId,
            storage: storage
        ) {
            return boundaryReadState
        }

        return date.timeIntervalSince1970 <= lastReadNotificationDate(in: realm)
    }

    private final func reconcileStoredReadStateIfPossible(in realm: Realm) throws {
        guard let storage = realm.object(
            ofType: XMPPNotificationsManagerStorageItem.self,
            forPrimaryKey: self.storagePrimary
        ) else {
            return
        }

        guard storage.unread == 0 || storage.unreadAfterId?.isNotEmpty == true else {
            return
        }

        try realm.write {
            XMPPNotificationsManagerStorageItem.reconcileStoredNotificationReadState(
                owner: self.owner,
                storage: storage,
                in: realm
            )
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
        let stanzaId = getStanzaId(bareMessage, owner: self.owner)

        do {
            let realm = try WRealm.safe()
            let resolvedIsRead = resolvedNotificationReadState(
                stanzaId: stanzaId,
                date: parsed.date,
                in: realm
            )
            var messagePrimariesToMarkRead: Set<String> = []
            var affectedGroupchatJids: Set<String> = []

            try realm.write {
                if let existingMention = parsed.category == .mention
                    ? MentionNotificationSync.existingMentionNotification(owner: self.owner, metadata: parsed.metadata, in: realm)
                    : nil {
                    existingMention.associatedJid = parsed.metadata?["sourceChatJid"] as? String ?? parsed.originalSenderJid
                    existingMention.displayedNick = parsed.displayNick ?? existingMention.displayedNick
                    existingMention.messageId = messageId.isNotEmpty ? messageId : existingMention.messageId
                    existingMention.stanzaId = stanzaId.isNotEmpty ? stanzaId : existingMention.stanzaId
                    existingMention.notificationType = parsed.notificationType
                    existingMention.originalSenderJid = parsed.originalSenderJid
                    existingMention.fallbackText = parsed.fallbackText
                    existingMention.text = parsed.text
                    existingMention.metadata = parsed.metadata ?? existingMention.metadata
                    existingMention.date = parsed.date
                    existingMention.shouldShow = existingMention.shouldShow || parsed.shouldShow
                    existingMention.isRead = existingMention.isRead || resolvedIsRead
                    let reconcileResult = MentionNotificationSync.reconcile(notification: existingMention, in: realm)
                    if let messagePrimary = reconcileResult.linkedMessagePrimaryToMarkRead {
                        messagePrimariesToMarkRead.insert(messagePrimary)
                    }
                    if let sourceChatJid = MentionNotificationSync.groupchatJidForLastChatMentionState(from: existingMention) {
                        affectedGroupchatJids.insert(sourceChatJid)
                    }
                } else {
                    let notificationPrimary = NotificationStorageItem.genPrimary(owner: self.owner, jid: parsed.jid, uniqueId: uniqueMessageId)
                    let instance: NotificationStorageItem
                    if let existing = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: notificationPrimary) {
                        instance = existing
                    } else {
                        let created = NotificationStorageItem()
                        created.owner = self.owner
                        created.jid = parsed.jid
                        created.uniqueId = uniqueMessageId
                        created.primary = notificationPrimary
                        created.category = parsed.category
                        created.isRead = resolvedIsRead
                        realm.add(created)
                        instance = created
                    }

                    instance.associatedJid = parsed.metadata?["sourceChatJid"] as? String ?? parsed.originalSenderJid ?? instance.associatedJid
                    instance.displayedNick = parsed.displayNick ?? instance.displayedNick
                    instance.messageId = messageId.isNotEmpty ? messageId : instance.messageId
                    instance.stanzaId = stanzaId.isNotEmpty ? stanzaId : instance.stanzaId
                    instance.notificationType = parsed.notificationType ?? instance.notificationType
                    instance.originalSenderJid = parsed.originalSenderJid ?? instance.originalSenderJid
                    instance.fallbackText = parsed.fallbackText ?? instance.fallbackText
                    instance.text = parsed.text ?? instance.text
                    instance.metadata = parsed.metadata ?? instance.metadata
                    instance.date = parsed.date
                    instance.shouldShow = instance.shouldShow || parsed.shouldShow
                    instance.isRead = instance.isRead || resolvedIsRead

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

                    if parsed.category == .mention {
                        let reconcileResult = MentionNotificationSync.reconcile(notification: instance, in: realm)
                        if let messagePrimary = reconcileResult.linkedMessagePrimaryToMarkRead,
                           messagePrimary.isNotEmpty {
                            messagePrimariesToMarkRead.insert(messagePrimary)
                        }
                        if let sourceChatJid = MentionNotificationSync.groupchatJidForLastChatMentionState(from: instance) {
                            affectedGroupchatJids.insert(sourceChatJid)
                        }
                    }
                }

                if affectedGroupchatJids.isNotEmpty {
                    MentionNotificationSync.refreshLastChatMentionIds(
                        owner: self.owner,
                        groupchatJids: affectedGroupchatJids,
                        in: realm
                    )
                }
            }
            try updateSyncProgress(in: realm)
            messagePrimariesToMarkRead.forEach { primary in
                AccountManager.shared.find(for: self.owner)?.messages.readMessage(primary, last: false)
            }
        } catch {
            DDLogDebug("XMPPNotificationManager: \(#function). \(error.localizedDescription)")
        }

        return true
    }

    private final func requestLatestPage(
        _ stream: XMPPStream,
        node: String,
        afterId: String?,
        bootstrapFromNewestPage: Bool
    ) {
        guard let archiveManager = archiveManager() else {
            endSync(.latest)
            return
        }

        DDLogDebug("XMPPNotificationsManager: request latest page owner=\(self.owner) node=\(node) afterId=\(afterId ?? "") bootstrap=\(bootstrapFromNewestPage)")
        archiveManager.requestArchive(
            stream,
            jid: node,
            isContinues: false,
            conversationType: .notifications,
            purpose: .latest,
            queryId: "MAM notifications latest: \(NanoID.new(8))",
            flipPage: false,
            before: bootstrapFromNewestPage ? "" : nil,
            afterId: afterId,
            nextPage: bootstrapFromNewestPage ? "" : nil,
            max: Self.archivePageSize,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { [weak self] _, state, first, last, count in
                    self?.handleLatestPageResult(
                        stream,
                        node: node,
                        bootstrapFromNewestPage: bootstrapFromNewestPage,
                        state: state,
                        first: first,
                        last: last,
                        count: count
                    )
                }
            )
        )
    }

    private final func handleLatestPageResult(
        _ stream: XMPPStream,
        node: String,
        bootstrapFromNewestPage: Bool,
        state: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int
    ) {
        var archiveSyncCompleted = false
        var backfillCursor: String?

        DDLogDebug("XMPPNotificationsManager: latest page result owner=\(self.owner) node=\(node) first=\(first) last=\(last) count=\(count) complete=\(state.queryExhausted) persistedMessages=\(state.persistedMessageCount)")

        do {
            let realm = try WRealm.safe()
            let shouldMarkArchiveComplete = bootstrapFromNewestPage && state.queryExhausted
            try updateSyncProgress(
                in: realm,
                archiveSyncCompleted: shouldMarkArchiveComplete ? true : nil,
                latestScannedArchiveId: last,
                fallbackOldestArchiveId: first
            )
            try reconcileStoredReadStateIfPossible(in: realm)
            let storage = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary)
            archiveSyncCompleted = storage?.archiveSyncCompleted ?? false
            backfillCursor = storedBackfillCursor(in: realm, fallback: first)
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }

        if !bootstrapFromNewestPage && !state.queryExhausted && last.isNotEmpty {
            requestLatestPage(
                stream,
                node: node,
                afterId: last,
                bootstrapFromNewestPage: false
            )
            return
        }

        endSync(.latest)

        guard !archiveSyncCompleted else {
            return
        }

        startHistoricalBackfillIfNeeded(stream, node: node, fallbackCursor: backfillCursor)
    }

    private final func startHistoricalBackfillIfNeeded(
        _ stream: XMPPStream,
        node: String,
        fallbackCursor: String?
    ) {
        guard beginSync(.backfill) else {
            return
        }

        do {
            let realm = try WRealm.safe()
            let storage = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary)
            guard storage?.archiveSyncCompleted != true else {
                endSync(.backfill)
                return
            }

            guard let cursor = storedBackfillCursor(in: realm, fallback: fallbackCursor), cursor.isNotEmpty else {
                endSync(.backfill)
                return
            }

            requestOlderBackfillPage(stream, node: node, beforeId: cursor)
        } catch {
            endSync(.backfill)
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }
    }

    private final func requestOlderBackfillPage(
        _ stream: XMPPStream,
        node: String,
        beforeId: String
    ) {
        guard let archiveManager = archiveManager() else {
            endSync(.backfill)
            return
        }

        archiveManager.requestArchive(
            stream,
            jid: node,
            isContinues: false,
            conversationType: .notifications,
            purpose: .pageOlder,
            queryId: "MAM notifications backfill: \(NanoID.new(8))",
            flipPage: false,
            before: beforeId,
            nextPage: beforeId,
            max: Self.archivePageSize,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { [weak self] _, state, first, _, _ in
                    self?.handleBackfillPageResult(
                        stream,
                        node: node,
                        state: state,
                        first: first
                    )
                }
            )
        )
    }

    private final func handleBackfillPageResult(
        _ stream: XMPPStream,
        node: String,
        state: MessageArchivePageEndState,
        first: String
    ) {
        do {
            let realm = try WRealm.safe()
            try updateSyncProgress(
                in: realm,
                archiveSyncCompleted: state.queryExhausted ? true : nil,
                fallbackOldestArchiveId: first
            )
            try reconcileStoredReadStateIfPossible(in: realm)
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }

        if state.queryExhausted {
            endSync(.backfill)
            return
        }

        guard first.isNotEmpty else {
            endSync(.backfill)
            return
        }

        requestOlderBackfillPage(stream, node: node, beforeId: first)
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
                let unreadMentionChats = Set(
                    realm.objects(NotificationStorageItem.self)
                        .filter(
                            "owner == %@ AND category_ == %@ AND isRead == false",
                            self.owner,
                            XMPPNotificationsManager.Category.mention.rawValue
                        )
                        .toArray()
                        .compactMap { MentionNotificationSync.groupchatJidForLastChatMentionState(from: $0) }
                )
                
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
                    storage.unread = 0
                    if lastReadNotification.stanzaId.isNotEmpty {
                        storage.unreadAfterId = lastReadNotification.stanzaId
                    }
                    storage.lastSyncAt = Date()
                    if unreadMentionChats.isNotEmpty {
                        MentionNotificationSync.refreshLastChatMentionIds(
                            owner: self.owner,
                            groupchatJids: unreadMentionChats,
                            in: realm
                        )
                    }
                }
            }
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public func update(_ stream: XMPPStream) {
        guard isAvailable(), let node = self.node else { return }

        guard beginSync(.latest) else {
            return
        }

        do {
            let realm = try WRealm.safe()
            let latestCursor = latestSyncCursor(in: realm)
            DDLogDebug("XMPPNotificationsManager: latest cursor selected owner=\(self.owner) node=\(node) source=\(latestCursor.source.rawValue) afterId=\(latestCursor.cursor ?? "")")
            if latestCursor.source == .newestStoredNotification {
                DDLogDebug("XMPPNotificationsManager: using newest stored notification as migration fallback for latest cursor owner=\(self.owner) node=\(node) afterId=\(latestCursor.cursor ?? "")")
            }
            requestLatestPage(
                stream,
                node: node,
                afterId: latestCursor.cursor,
                bootstrapFromNewestPage: latestCursor.cursor?.isNotEmpty != true
            )
        } catch {
            endSync(.latest)
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
