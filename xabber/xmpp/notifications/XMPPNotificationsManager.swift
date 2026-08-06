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
    private static let historicalBackfillPageBudgetPerRun: Int = 3
    
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

    private struct PendingNotification {
        let jid: String
        let originalSenderJid: String?
        let category: Category
        let notificationType: String?
        let fallbackText: String?
        let text: String?
        let metadata: [String: Any]?
        let displayNick: String?
        let shouldShow: Bool
        let date: Date
        let uniqueMessageId: String
        let messageId: String
        let stanzaId: String

        init(parsed: ParsedPayload, uniqueMessageId: String, messageId: String, stanzaId: String) {
            self.jid = parsed.jid
            self.originalSenderJid = parsed.originalSenderJid
            self.category = parsed.category
            self.notificationType = parsed.notificationType
            self.fallbackText = parsed.fallbackText
            self.text = parsed.text
            self.metadata = parsed.metadata
            self.displayNick = parsed.displayNick
            self.shouldShow = parsed.shouldShow
            self.date = parsed.date
            self.uniqueMessageId = uniqueMessageId
            self.messageId = messageId
            self.stanzaId = stanzaId
        }
    }

    private struct QueuedNotification {
        let sequence: UInt64
        let notification: PendingNotification
    }

    private struct NotificationSyncIdentity: Equatable {
        let node: String
        let generation: UInt64
    }

    private struct ReadAllMarker {
        let node: String
        let messageId: String
    }

    private struct NotificationPersistenceBarrier {
        let id: UUID
        let watermark: UInt64
    }

    private enum NotificationPersistenceResult {
        case persisted
        case retry
        case invalidated
    }

    private enum NotificationDrainResult {
        case completed
        case moreWork
        case retry
        case invalidated
    }

    private let syncStateQueue = DispatchQueue(label: "com.xabber.notifications.sync-state")
    private var isLatestSyncInProgress: Bool = false
    private var isBackfillInProgress: Bool = false
    private var remainingHistoricalBackfillPageBudget: Int = 0

    private let notificationLifecycleLock = NSLock()
    private var notificationLifecycleNode: String?
    private var notificationLifecycleGeneration: UInt64 = 0

    private let notificationPersistenceQueue = DispatchQueue(
        label: "com.xabber.notifications.persistence",
        qos: .utility
    )
    private let notificationPersistenceLock = NSLock()
    private var pendingNotifications: [QueuedNotification] = []
    private var nextNotificationPersistenceSequence: UInt64 = 0
    private var notificationPersistenceBarriers: [UUID: UInt64] = [:]
    private var isNotificationPersistenceDrainScheduled = false
    private var isNotificationPersistenceInvalidated = false
    private static let notificationPersistenceCoalescingInterval: TimeInterval = 0.05
    private static let notificationPersistenceRetryInterval: TimeInterval = 0.25
    private static let notificationPersistenceYieldInterval: TimeInterval = 0.001
    private static let notificationPersistenceBarrierRetryLimit = 3
    private static let notificationPersistenceMaxChunksPerPass = 4

    // Internal seams are intentionally limited to persistence regression coverage.
    var notificationPersistenceChunkSize: Int = 25
    var notificationPersistenceChunkAttemptObserver: (() -> Void)?
    var notificationPersistenceChunkObserver: ((Int, Int) -> Void)?
    var notificationSyncProgressAttemptObserver: (() -> Void)?
    
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
                if let node = instance.node, node.isNotEmpty {
                    _ = self.recordConfiguredNotificationNode(node)
                }
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
            self.remainingHistoricalBackfillPageBudget = 0
        }
    }

    private final func resetHistoricalBackfillBudget() {
        self.syncStateQueue.sync {
            self.remainingHistoricalBackfillPageBudget = Self.historicalBackfillPageBudgetPerRun
        }
    }

    private final func consumeHistoricalBackfillBudget() -> Bool {
        self.syncStateQueue.sync {
            guard self.remainingHistoricalBackfillPageBudget > 0 else {
                return false
            }
            self.remainingHistoricalBackfillPageBudget -= 1
            return true
        }
    }

    private final func archiveManager() -> MessageArchiveManager? {
        guard let account = AccountManager.shared.find(for: self.owner),
              account.notifications === self else {
            return nil
        }
        return account.mam
    }

    @discardableResult
    private final func recordConfiguredNotificationNode(
        _ node: String
    ) -> NotificationSyncIdentity {
        self.notificationLifecycleLock.lock()
        defer { self.notificationLifecycleLock.unlock() }

        if self.notificationLifecycleNode != node {
            self.notificationLifecycleGeneration &+= 1
            self.notificationLifecycleNode = node
        }
        return NotificationSyncIdentity(
            node: node,
            generation: self.notificationLifecycleGeneration
        )
    }

    /// Called from the account/UI lane before a sync is scheduled. Callback and
    /// persistence lanes only consume the returned immutable identity.
    private final func captureCurrentNotificationSyncIdentity() -> NotificationSyncIdentity? {
        guard let node = self.node, node.isNotEmpty else {
            return nil
        }
        return self.recordConfiguredNotificationNode(node)
    }

    private final func isCurrentNotificationSyncIdentity(
        _ identity: NotificationSyncIdentity
    ) -> Bool {
        self.notificationLifecycleLock.lock()
        defer { self.notificationLifecycleLock.unlock() }
        return self.notificationLifecycleNode == identity.node
            && self.notificationLifecycleGeneration == identity.generation
    }

    private final func invalidateNotificationSyncIdentity() {
        self.notificationLifecycleLock.lock()
        self.notificationLifecycleGeneration &+= 1
        self.notificationLifecycleNode = nil
        self.notificationLifecycleLock.unlock()
    }

    /// Invalidates callbacks tied to the current XMPP stream without dropping
    /// queued detached notification rows. Account.resetStream() calls this on
    /// its account lane before replacing the stream instance.
    final func invalidateNotificationSyncSession() {
        self.notificationLifecycleLock.lock()
        self.notificationLifecycleGeneration &+= 1
        self.notificationLifecycleLock.unlock()
        self.resetSyncState()
    }

    private final func owningAccount(
        expectedIdentity: NotificationSyncIdentity
    ) -> Account? {
        guard self.isNotificationPersistenceActive(),
              let account = AccountManager.shared.find(for: self.owner),
              account.notifications === self,
              self.isCurrentNotificationSyncIdentity(expectedIdentity),
              account.sendReadiness.snapshot.canFlushApplicationStanzas else {
            return nil
        }
        return account
    }

    private final func performOnOwningAccountQueue(
        expectedStream: XMPPStream,
        expectedIdentity: NotificationSyncIdentity,
        unavailable: @escaping () -> Void,
        action: @escaping () -> Void
    ) {
        guard let account = self.owningAccount(
            expectedIdentity: expectedIdentity
        ) else {
            unavailable()
            return
        }

        account.action { [weak self] currentAccount, currentStream in
            guard let self,
                  self.isNotificationPersistenceActive(),
                  AccountManager.shared.find(for: self.owner) === currentAccount,
                  currentAccount.notifications === self,
                  currentStream === expectedStream,
                  self.isCurrentNotificationSyncIdentity(expectedIdentity),
                  currentAccount.sendReadiness.snapshot.canFlushApplicationStanzas else {
                unavailable()
                return
            }
            action()
        }
    }

    @discardableResult
    private final func ensureStorage(
        in realm: Realm,
        node: String
    ) -> XMPPNotificationsManagerStorageItem {
        if let existing = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary) {
            return existing
        }

        let created = XMPPNotificationsManagerStorageItem()
        created.owner = self.owner
        created.primary = self.storagePrimary
        created.node = node
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

    @discardableResult
    private final func updateSyncProgress(
        in realm: Realm,
        expectedIdentity: NotificationSyncIdentity,
        archiveSyncCompleted: Bool? = nil,
        latestScannedArchiveId: String? = nil,
        fallbackOldestArchiveId: String? = nil
    ) throws -> Bool {
        guard self.isCurrentNotificationSyncIdentity(expectedIdentity),
              self.isNotificationPersistenceActive() else {
            return false
        }
        let nonEmptyFallbackOldestArchiveId = fallbackOldestArchiveId.flatMap {
            $0.isNotEmpty ? $0 : nil
        }
        let oldestLoadedArchiveId = oldestStoredArchiveId(in: realm)
            ?? nonEmptyFallbackOldestArchiveId
            ?? realm.object(
                ofType: XMPPNotificationsManagerStorageItem.self,
                forPrimaryKey: self.storagePrimary
            )?.lastSyncedNotificationId
        var didUpdate = false

        self.notificationSyncProgressAttemptObserver?()
        try realm.write {
            guard self.isCurrentNotificationSyncIdentity(expectedIdentity),
                  self.isNotificationPersistenceActive() else {
                return
            }
            let storage = ensureStorage(in: realm, node: expectedIdentity.node)
            guard storage.node == expectedIdentity.node else { return }
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
            didUpdate = true
        }
        return didUpdate
    }
    
    public final func configure(for jid: String) {
        guard self.isNotificationPersistenceActive() else {
            return
        }
        _ = self.recordConfiguredNotificationNode(jid)
        self.node = jid
        do {
            guard self.isNotificationPersistenceActive() else {
                return
            }
            let realm = try WRealm.safe()
            var didChangeNode = false
            if let instance = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: XMPPNotificationsManagerStorageItem.genPrimary(owner: self.owner)) {
                try realm.write {
                    guard self.isNotificationPersistenceActive() else {
                        return
                    }
                    didChangeNode = instance.node != jid && instance.node?.isNotEmpty == true
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
                    guard self.isNotificationPersistenceActive() else {
                        return
                    }
                    realm.add(instance)
                }
            }
            guard self.isNotificationPersistenceActive() else {
                return
            }
            if let chatInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)) {
                try realm.write {
                    guard self.isNotificationPersistenceActive() else {
                        return
                    }
                    realm.delete(chatInstance)
                }
            }
            guard self.isNotificationPersistenceActive() else {
                return
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

    private final func enqueueNotificationPersistence(_ notification: PendingNotification) {
        var shouldScheduleDrain = false
        self.notificationPersistenceLock.lock()
        guard !self.isNotificationPersistenceInvalidated else {
            self.notificationPersistenceLock.unlock()
            return
        }
        self.nextNotificationPersistenceSequence &+= 1
        self.pendingNotifications.append(
            QueuedNotification(
                sequence: self.nextNotificationPersistenceSequence,
                notification: notification
            )
        )
        if !self.isNotificationPersistenceDrainScheduled {
            self.isNotificationPersistenceDrainScheduled = true
            shouldScheduleDrain = true
        }
        self.notificationPersistenceLock.unlock()

        guard shouldScheduleDrain else {
            return
        }

        self.notificationPersistenceQueue.asyncAfter(
            deadline: .now() + Self.notificationPersistenceCoalescingInterval
        ) { [weak self] in
            self?.drainScheduledNotificationPersistence()
        }
    }

    /// Stops queued persistence before account storage cleanup. This method is
    /// intentionally lock-only so deletion never waits for the Realm worker.
    final func invalidatePendingNotificationPersistence() {
        self.notificationPersistenceLock.lock()
        self.isNotificationPersistenceInvalidated = true
        self.pendingNotifications.removeAll(keepingCapacity: false)
        self.notificationPersistenceBarriers.removeAll(keepingCapacity: false)
        self.isNotificationPersistenceDrainScheduled = false
        self.notificationPersistenceLock.unlock()
        self.invalidateNotificationSyncIdentity()
        self.resetSyncState()
    }

    private final func isNotificationPersistenceActive() -> Bool {
        self.notificationPersistenceLock.lock()
        defer { self.notificationPersistenceLock.unlock() }
        return !self.isNotificationPersistenceInvalidated
    }

    private final func notificationPersistenceWatermark() -> UInt64 {
        self.notificationPersistenceLock.lock()
        defer { self.notificationPersistenceLock.unlock() }
        return self.nextNotificationPersistenceSequence
    }

    private final func registerNotificationPersistenceBarrier() -> NotificationPersistenceBarrier? {
        self.notificationPersistenceLock.lock()
        defer { self.notificationPersistenceLock.unlock() }
        guard !self.isNotificationPersistenceInvalidated else {
            return nil
        }
        let barrier = NotificationPersistenceBarrier(
            id: UUID(),
            watermark: self.nextNotificationPersistenceSequence
        )
        self.notificationPersistenceBarriers[barrier.id] = barrier.watermark
        return barrier
    }

    private final func releaseNotificationPersistenceBarrier(
        _ barrier: NotificationPersistenceBarrier
    ) {
        self.notificationPersistenceLock.lock()
        self.notificationPersistenceBarriers.removeValue(forKey: barrier.id)
        self.notificationPersistenceLock.unlock()
    }

    /// Must only be called while `notificationPersistenceLock` is held.
    private final func effectiveNotificationPersistenceWatermarkLocked(
        _ requestedWatermark: UInt64?
    ) -> UInt64? {
        guard let registeredWatermark = self.notificationPersistenceBarriers.values.min() else {
            return requestedWatermark
        }
        guard let requestedWatermark else {
            return registeredWatermark
        }
        return min(requestedWatermark, registeredWatermark)
    }

    private final func nextPendingNotificationChunk(
        through watermark: UInt64?
    ) -> [QueuedNotification]? {
        self.notificationPersistenceLock.lock()
        defer { self.notificationPersistenceLock.unlock() }

        guard self.pendingNotifications.isNotEmpty else {
            self.isNotificationPersistenceDrainScheduled = false
            return nil
        }

        let eligibleCount: Int
        if let effectiveWatermark = self.effectiveNotificationPersistenceWatermarkLocked(watermark) {
            guard self.pendingNotifications[0].sequence <= effectiveWatermark else {
                return nil
            }
            eligibleCount = self.pendingNotifications.prefix {
                $0.sequence <= effectiveWatermark
            }.count
        } else {
            eligibleCount = self.pendingNotifications.count
        }

        let chunkSize = min(max(1, self.notificationPersistenceChunkSize), eligibleCount)
        let chunk = Array(self.pendingNotifications.prefix(chunkSize))
        self.pendingNotifications.removeFirst(chunkSize)
        return chunk
    }

    private final func pendingNotificationCount() -> Int {
        self.notificationPersistenceLock.lock()
        defer { self.notificationPersistenceLock.unlock() }
        return self.pendingNotifications.count
    }

    private final func finishNotificationDrainPass(
        through watermark: UInt64?
    ) -> NotificationDrainResult {
        self.notificationPersistenceLock.lock()
        defer { self.notificationPersistenceLock.unlock() }
        guard !self.isNotificationPersistenceInvalidated else {
            return .invalidated
        }
        guard let first = self.pendingNotifications.first else {
            self.isNotificationPersistenceDrainScheduled = false
            return .completed
        }
        if let effectiveWatermark = self.effectiveNotificationPersistenceWatermarkLocked(watermark),
           first.sequence > effectiveWatermark {
            if let watermark, first.sequence > watermark {
                return .completed
            }
            // A synchronously registered read-all barrier paused this drain.
            // Yield so the already-enqueued barrier action can run first.
            return .moreWork
        }
        return .moreWork
    }

    private final func requeuePendingNotificationChunk(_ chunk: [QueuedNotification]) {
        self.notificationPersistenceLock.lock()
        defer { self.notificationPersistenceLock.unlock() }
        guard !self.isNotificationPersistenceInvalidated else {
            return
        }
        self.pendingNotifications.insert(contentsOf: chunk, at: 0)
        self.isNotificationPersistenceDrainScheduled = true
    }

    private final func drainPendingNotifications(
        through watermark: UInt64?
    ) -> NotificationDrainResult {
        for _ in 0..<Self.notificationPersistenceMaxChunksPerPass {
            guard let chunk = self.nextPendingNotificationChunk(through: watermark) else {
                return self.finishNotificationDrainPass(through: watermark)
            }
            switch self.persistNotificationChunk(chunk.map(\.notification)) {
            case .persisted:
                self.notificationPersistenceChunkObserver?(chunk.count, self.pendingNotificationCount())
            case .retry:
                self.requeuePendingNotificationChunk(chunk)
                return .retry
            case .invalidated:
                return .invalidated
            }
        }
        return self.finishNotificationDrainPass(through: watermark)
    }

    private final func drainScheduledNotificationPersistence() {
        let delay: TimeInterval
        switch self.drainPendingNotifications(through: nil) {
        case .completed, .invalidated:
            return
        case .moreWork:
            delay = Self.notificationPersistenceYieldInterval
        case .retry:
            delay = Self.notificationPersistenceRetryInterval
        }
        self.notificationPersistenceQueue.asyncAfter(
            deadline: .now() + delay
        ) { [weak self] in
            self?.drainScheduledNotificationPersistence()
        }
    }

    private final func performAfterPendingNotificationPersistence(
        through watermark: UInt64,
        retryCount: Int = 0,
        _ action: @escaping (Bool) -> Void
    ) {
        self.notificationPersistenceQueue.async { [weak self] in
            guard let self else {
                action(false)
                return
            }
            guard self.isNotificationPersistenceActive() else {
                action(false)
                return
            }
            switch self.drainPendingNotifications(through: watermark) {
            case .completed:
                action(true)
            case .invalidated:
                action(false)
            case .moreWork:
                self.notificationPersistenceQueue.asyncAfter(
                    deadline: .now() + Self.notificationPersistenceYieldInterval
                ) { [weak self] in
                    self?.performAfterPendingNotificationPersistence(
                        through: watermark,
                        retryCount: retryCount,
                        action
                    )
                }
            case .retry:
                guard retryCount < Self.notificationPersistenceBarrierRetryLimit,
                      self.isNotificationPersistenceActive() else {
                    action(false)
                    self.drainScheduledNotificationPersistence()
                    return
                }
                self.notificationPersistenceQueue.asyncAfter(
                    deadline: .now() + Self.notificationPersistenceRetryInterval
                ) { [weak self] in
                    self?.performAfterPendingNotificationPersistence(
                        through: watermark,
                        retryCount: retryCount + 1,
                        action
                    )
                }
            }
        }
    }

#if DEBUG
    final func notificationPersistenceWatermarkForTests() -> UInt64 {
        self.notificationPersistenceWatermark()
    }

    final func flushPendingNotificationPersistenceForTests(
        through watermark: UInt64? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        self.performAfterPendingNotificationPersistence(
            through: watermark ?? self.notificationPersistenceWatermark(),
            completion
        )
    }
#endif

    @discardableResult
    private final func persistNotificationChunk(
        _ notifications: [PendingNotification]
    ) -> NotificationPersistenceResult {
        guard notifications.isNotEmpty else {
            return .persisted
        }
        guard self.isNotificationPersistenceActive() else {
            return .invalidated
        }
        self.notificationPersistenceChunkAttemptObserver?()

        do {
            let realm = try WRealm.safe()
            var messagePrimariesToMarkRead: Set<String> = []
            var affectedGroupchatJids: Set<String> = []
            var didPersist = false

            try realm.write {
                guard self.isNotificationPersistenceActive() else {
                    return
                }
                let storage = realm.object(
                    ofType: XMPPNotificationsManagerStorageItem.self,
                    forPrimaryKey: self.storagePrimary
                )
                var lastReadDate = self.lastReadNotificationDate(in: realm)

                for pending in notifications {
                    let resolvedIsRead = XMPPNotificationsManagerStorageItem.notificationUnreadBoundaryReadState(
                        stanzaId: pending.stanzaId,
                        storage: storage
                    ) ?? (pending.date.timeIntervalSince1970 <= lastReadDate)

                    if let existingMention = pending.category == .mention
                        ? MentionNotificationSync.existingMentionNotification(
                            owner: self.owner,
                            metadata: pending.metadata,
                            in: realm
                        )
                        : nil {
                        existingMention.associatedJid = pending.metadata?["sourceChatJid"] as? String
                            ?? pending.originalSenderJid
                        existingMention.displayedNick = pending.displayNick ?? existingMention.displayedNick
                        existingMention.messageId = pending.messageId.isNotEmpty
                            ? pending.messageId
                            : existingMention.messageId
                        existingMention.stanzaId = pending.stanzaId.isNotEmpty
                            ? pending.stanzaId
                            : existingMention.stanzaId
                        existingMention.notificationType = pending.notificationType
                        existingMention.originalSenderJid = pending.originalSenderJid
                        existingMention.fallbackText = pending.fallbackText
                        existingMention.text = pending.text
                        existingMention.metadata = pending.metadata ?? existingMention.metadata
                        existingMention.date = pending.date
                        existingMention.shouldShow = existingMention.shouldShow || pending.shouldShow
                        existingMention.isRead = existingMention.isRead || resolvedIsRead
                        if existingMention.isRead {
                            lastReadDate = max(lastReadDate, pending.date.timeIntervalSince1970)
                        }
                        let reconcileResult = MentionNotificationSync.reconcile(
                            notification: existingMention,
                            in: realm
                        )
                        if let messagePrimary = reconcileResult.linkedMessagePrimaryToMarkRead {
                            messagePrimariesToMarkRead.insert(messagePrimary)
                        }
                        if let sourceChatJid = MentionNotificationSync.groupchatJidForLastChatMentionState(
                            from: existingMention
                        ) {
                            affectedGroupchatJids.insert(sourceChatJid)
                        }
                        continue
                    }

                    let notificationPrimary = NotificationStorageItem.genPrimary(
                        owner: self.owner,
                        jid: pending.jid,
                        uniqueId: pending.uniqueMessageId
                    )
                    let instance: NotificationStorageItem
                    if let existing = realm.object(
                        ofType: NotificationStorageItem.self,
                        forPrimaryKey: notificationPrimary
                    ) {
                        instance = existing
                    } else {
                        let created = NotificationStorageItem()
                        created.owner = self.owner
                        created.jid = pending.jid
                        created.uniqueId = pending.uniqueMessageId
                        created.primary = notificationPrimary
                        created.category = pending.category
                        created.isRead = resolvedIsRead
                        realm.add(created)
                        instance = created
                    }

                    instance.associatedJid = pending.metadata?["sourceChatJid"] as? String
                        ?? pending.originalSenderJid
                        ?? instance.associatedJid
                    instance.displayedNick = pending.displayNick ?? instance.displayedNick
                    instance.messageId = pending.messageId.isNotEmpty ? pending.messageId : instance.messageId
                    instance.stanzaId = pending.stanzaId.isNotEmpty ? pending.stanzaId : instance.stanzaId
                    instance.notificationType = pending.notificationType ?? instance.notificationType
                    instance.originalSenderJid = pending.originalSenderJid ?? instance.originalSenderJid
                    instance.fallbackText = pending.fallbackText ?? instance.fallbackText
                    instance.text = pending.text ?? instance.text
                    instance.metadata = pending.metadata ?? instance.metadata
                    instance.date = pending.date
                    instance.shouldShow = instance.shouldShow || pending.shouldShow
                    instance.isRead = instance.isRead || resolvedIsRead
                    if instance.isRead {
                        lastReadDate = max(lastReadDate, pending.date.timeIntervalSince1970)
                    }

                    if pending.category == .device,
                       let deviceId = pending.metadata?["deviceId"] as? String,
                       let deviceInstance = realm.object(
                            ofType: DeviceStorageItem.self,
                            forPrimaryKey: DeviceStorageItem.genPrimary(uid: deviceId, owner: self.owner)
                       ) {
                        instance.metadata = [
                            "deviceId": deviceId,
                            "ip": deviceInstance.ip,
                            "client": deviceInstance.client,
                            "device": deviceInstance.device,
                        ]
                    }

                    if pending.category == .mention {
                        let reconcileResult = MentionNotificationSync.reconcile(
                            notification: instance,
                            in: realm
                        )
                        if let messagePrimary = reconcileResult.linkedMessagePrimaryToMarkRead,
                           messagePrimary.isNotEmpty {
                            messagePrimariesToMarkRead.insert(messagePrimary)
                        }
                        if let sourceChatJid = MentionNotificationSync.groupchatJidForLastChatMentionState(
                            from: instance
                        ) {
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
                didPersist = true
            }

            guard didPersist else {
                return .invalidated
            }

            messagePrimariesToMarkRead.forEach { primary in
                AccountManager.shared.find(for: self.owner)?.messages.readMessage(primary, last: false)
            }
            return .persisted
        } catch {
            DDLogDebug("XMPPNotificationManager: \(#function). \(error.localizedDescription)")
            return .retry
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

        self.enqueueNotificationPersistence(
            PendingNotification(
                parsed: parsed,
                uniqueMessageId: uniqueMessageId,
                messageId: messageId,
                stanzaId: stanzaId
            )
        )

        return true
    }

    private final func requestLatestPage(
        _ stream: XMPPStream,
        identity: NotificationSyncIdentity,
        afterId: String?,
        bootstrapFromNewestPage: Bool,
        completion: @escaping () -> Void
    ) {
        let node = identity.node
        guard self.owningAccount(expectedIdentity: identity) != nil,
              let archiveManager = archiveManager() else {
            endSync(.latest)
            completion()
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
                    guard let self else {
                        completion()
                        return
                    }
                    let pageWatermark = self.notificationPersistenceWatermark()
                    self.performAfterPendingNotificationPersistence(
                        through: pageWatermark
                    ) { didPersist in
                        guard didPersist else {
                            self.endSync(.latest)
                            completion()
                            return
                        }
                        self.handleLatestPageResult(
                            stream,
                            identity: identity,
                            bootstrapFromNewestPage: bootstrapFromNewestPage,
                            state: state,
                            first: first,
                            last: last,
                            count: count,
                            completion: completion
                        )
                    }
                },
                onFailure: { [weak self] event in
                    DDLogDebug(
                        "XMPPNotificationsManager: latest archive request failed owner=\(self?.owner ?? "") node=\(node) reason=\(event.reason.rawValue)"
                    )
                    self?.endSync(.latest)
                    completion()
                }
            )
        )
    }

    private final func handleLatestPageResult(
        _ stream: XMPPStream,
        identity: NotificationSyncIdentity,
        bootstrapFromNewestPage: Bool,
        state: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int,
        completion: @escaping () -> Void
    ) {
        let node = identity.node
        guard self.owningAccount(expectedIdentity: identity) != nil else {
            self.endSync(.latest)
            completion()
            return
        }

        var archiveSyncCompleted = false
        var backfillCursor: String?

        DDLogDebug("XMPPNotificationsManager: latest page result owner=\(self.owner) node=\(node) first=\(first) last=\(last) count=\(count) complete=\(state.queryExhausted) persistedMessages=\(state.persistedMessageCount)")

        do {
            let realm = try WRealm.safe()
            let shouldMarkArchiveComplete = bootstrapFromNewestPage && state.queryExhausted
            guard try updateSyncProgress(
                in: realm,
                expectedIdentity: identity,
                archiveSyncCompleted: shouldMarkArchiveComplete ? true : nil,
                latestScannedArchiveId: last,
                fallbackOldestArchiveId: first
            ) else {
                self.endSync(.latest)
                completion()
                return
            }
            try reconcileStoredReadStateIfPossible(in: realm)
            let storage = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary)
            archiveSyncCompleted = storage?.archiveSyncCompleted ?? false
            backfillCursor = storedBackfillCursor(in: realm, fallback: first)
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
            self.endSync(.latest)
            completion()
            return
        }

        self.performOnOwningAccountQueue(
            expectedStream: stream,
            expectedIdentity: identity,
            unavailable: { [weak self] in
                self?.endSync(.latest)
                completion()
            },
            action: { [weak self] in
                guard let self else {
                    completion()
                    return
                }

                if !bootstrapFromNewestPage && !state.queryExhausted && last.isNotEmpty {
                    self.requestLatestPage(
                        stream,
                        identity: identity,
                        afterId: last,
                        bootstrapFromNewestPage: false,
                        completion: completion
                    )
                    return
                }

                self.endSync(.latest)
                completion()

                guard !archiveSyncCompleted else {
                    return
                }

                self.startHistoricalBackfillIfNeeded(
                    stream,
                    identity: identity,
                    fallbackCursor: backfillCursor
                )
            }
        )
    }

    private final func startHistoricalBackfillIfNeeded(
        _ stream: XMPPStream,
        identity: NotificationSyncIdentity,
        fallbackCursor: String?
    ) {
        let node = identity.node
        guard consumeHistoricalBackfillBudget() else {
            DDLogDebug("XMPPNotificationsManager: historical backfill budget exhausted owner=\(self.owner) node=\(node)")
            return
        }

        guard let account = self.owningAccount(expectedIdentity: identity) else {
            return
        }

        account.xmppTaskScheduler.enqueueAccountTask(
            priority: .background,
            resource: .mamArchive,
            deduplicationKey: "notifications.backfill.\(self.owner).\(node).\(identity.generation)"
        ) { [weak self] _, stream, finish in
            guard let self else {
                finish()
                return
            }
            self.performHistoricalBackfillPage(
                stream,
                identity: identity,
                fallbackCursor: fallbackCursor,
                completion: finish
            )
        }
    }

    private final func performHistoricalBackfillPage(
        _ stream: XMPPStream,
        identity: NotificationSyncIdentity,
        fallbackCursor: String?,
        completion: @escaping () -> Void
    ) {
        guard self.isCurrentNotificationSyncIdentity(identity) else {
            completion()
            return
        }
        guard beginSync(.backfill) else {
            completion()
            return
        }

        do {
            let realm = try WRealm.safe()
            let storage = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: self.storagePrimary)
            guard storage?.archiveSyncCompleted != true else {
                endSync(.backfill)
                completion()
                return
            }

            guard let cursor = storedBackfillCursor(in: realm, fallback: fallbackCursor), cursor.isNotEmpty else {
                endSync(.backfill)
                completion()
                return
            }

            requestOlderBackfillPage(
                stream,
                identity: identity,
                beforeId: cursor,
                completion: completion
            )
        } catch {
            endSync(.backfill)
            completion()
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }
    }

    private final func requestOlderBackfillPage(
        _ stream: XMPPStream,
        identity: NotificationSyncIdentity,
        beforeId: String,
        completion: @escaping () -> Void
    ) {
        let node = identity.node
        guard self.owningAccount(expectedIdentity: identity) != nil,
              let archiveManager = archiveManager() else {
            endSync(.backfill)
            completion()
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
                    guard let self else {
                        completion()
                        return
                    }
                    let pageWatermark = self.notificationPersistenceWatermark()
                    self.performAfterPendingNotificationPersistence(
                        through: pageWatermark
                    ) { didPersist in
                        guard didPersist else {
                            self.endSync(.backfill)
                            completion()
                            return
                        }
                        self.handleBackfillPageResult(
                            stream,
                            identity: identity,
                            state: state,
                            first: first,
                            completion: completion
                        )
                    }
                },
                onFailure: { [weak self] event in
                    DDLogDebug(
                        "XMPPNotificationsManager: backfill archive request failed owner=\(self?.owner ?? "") node=\(node) reason=\(event.reason.rawValue)"
                    )
                    self?.endSync(.backfill)
                    completion()
                }
            )
        )
    }

    private final func handleBackfillPageResult(
        _ stream: XMPPStream,
        identity: NotificationSyncIdentity,
        state: MessageArchivePageEndState,
        first: String,
        completion: @escaping () -> Void
    ) {
        guard self.owningAccount(expectedIdentity: identity) != nil else {
            self.endSync(.backfill)
            completion()
            return
        }

        do {
            let realm = try WRealm.safe()
            guard try updateSyncProgress(
                in: realm,
                expectedIdentity: identity,
                archiveSyncCompleted: state.queryExhausted ? true : nil,
                fallbackOldestArchiveId: first
            ) else {
                self.endSync(.backfill)
                completion()
                return
            }
            try reconcileStoredReadStateIfPossible(in: realm)
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
            self.endSync(.backfill)
            completion()
            return
        }

        self.performOnOwningAccountQueue(
            expectedStream: stream,
            expectedIdentity: identity,
            unavailable: { [weak self] in
                self?.endSync(.backfill)
                completion()
            },
            action: { [weak self] in
                guard let self else {
                    completion()
                    return
                }

                if state.queryExhausted {
                    self.endSync(.backfill)
                    completion()
                    return
                }

                guard first.isNotEmpty else {
                    self.endSync(.backfill)
                    completion()
                    return
                }

                self.endSync(.backfill)
                completion()
                self.startHistoricalBackfillIfNeeded(
                    stream,
                    identity: identity,
                    fallbackCursor: first
                )
            }
        )
    }
    
    private final func persistReadAll(
        expectedIdentity: NotificationSyncIdentity
    ) -> ReadAllMarker? {
        guard self.isNotificationPersistenceActive(),
              self.isCurrentNotificationSyncIdentity(expectedIdentity) else {
            return nil
        }

        do {
            let realm = try WRealm.safe()
            var marker: ReadAllMarker?
            try realm.write {
                guard self.isNotificationPersistenceActive(),
                      self.isCurrentNotificationSyncIdentity(expectedIdentity),
                      let lastReadNotification = realm
                        .objects(NotificationStorageItem.self)
                        .filter("owner == %@ AND isRead == false", self.owner)
                        .sorted(byKeyPath: "date", ascending: false)
                        .first else {
                    return
                }
                let messageId = lastReadNotification.messageId
                let stanzaId = lastReadNotification.stanzaId
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

                realm.objects(NotificationStorageItem.self)
                    .filter("owner == %@ AND isRead == false", self.owner)
                    .forEach { $0.isRead = true }
                let storage: XMPPNotificationsManagerStorageItem
                if let existing = realm.object(
                    ofType: XMPPNotificationsManagerStorageItem.self,
                    forPrimaryKey: self.storagePrimary
                ) {
                    storage = existing
                } else {
                    let created = XMPPNotificationsManagerStorageItem()
                    created.owner = self.owner
                    created.primary = self.storagePrimary
                    created.node = expectedIdentity.node
                    realm.add(created)
                    storage = created
                }
                storage.unread = 0
                if stanzaId.isNotEmpty {
                    storage.unreadAfterId = stanzaId
                }
                storage.lastSyncAt = Date()
                if unreadMentionChats.isNotEmpty {
                    MentionNotificationSync.refreshLastChatMentionIds(
                        owner: self.owner,
                        groupchatJids: unreadMentionChats,
                        in: realm
                    )
                }
                marker = ReadAllMarker(
                    node: expectedIdentity.node,
                    messageId: messageId
                )
            }
            guard self.isNotificationPersistenceActive(),
                  self.isCurrentNotificationSyncIdentity(expectedIdentity) else {
                return nil
            }
            return marker
        } catch {
            DDLogDebug("XMPPNotificationsManager: \(#function). \(error.localizedDescription)")
        }
        return nil
    }

    private final func sendReadAllMarker(
        _ marker: ReadAllMarker,
        stream: XMPPStream
    ) {
        let elementId = "ChatMarkers: \(NanoID.new(8))"
        let displayed = DDXMLElement(name: "displayed", xmlns: getPrimaryNamespace())
        displayed.addAttribute(withName: "id", stringValue: marker.messageId)

        let response = XMPPMessage(
            messageType: .chat,
            to: XMPPJID(string: marker.node),
            elementID: elementId,
            child: displayed
        )
        let conversationType = ClientSynchronizationManager.ConversationType.notifications
        let conversation = DDXMLElement(
            name: "conversation",
            xmlns: "https://xabber.com/protocol/synchronization"
        )
        conversation.addAttribute(withName: "type", stringValue: conversationType.rawValue)
        conversation.addAttribute(withName: "jid", stringValue: marker.node)
        response.addChild(conversation)
        stream.send(response)
    }

    public func readAll(_ stream: XMPPStream) {
        guard self.isNotificationPersistenceActive(),
              let identity = self.captureCurrentNotificationSyncIdentity(),
              let barrier = self.registerNotificationPersistenceBarrier() else {
            return
        }
        self.performAfterPendingNotificationPersistence(
            through: barrier.watermark
        ) { [weak self] didPersistPending in
            guard let self else {
                return
            }
            defer { self.releaseNotificationPersistenceBarrier(barrier) }
            guard didPersistPending,
                  let marker = self.persistReadAll(expectedIdentity: identity) else {
                return
            }

            guard AccountManager.shared.find(for: self.owner) != nil else {
                return
            }
            self.performOnOwningAccountQueue(
                expectedStream: stream,
                expectedIdentity: identity,
                unavailable: {},
                action: { [weak self] in
                    self?.sendReadAllMarker(marker, stream: stream)
                }
            )
        }
    }
    
    public func update(_ stream: XMPPStream) {
        guard self.isNotificationPersistenceActive(),
              let identity = self.captureCurrentNotificationSyncIdentity() else {
            return
        }
        let node = identity.node

        let runLatestSync: (XMPPStream, @escaping () -> Void) -> Void = { [weak self] stream, completion in
            guard let self else {
                completion()
                return
            }
            self.performLatestSync(
                stream,
                identity: identity,
                completion: completion
            )
        }

        if let account = AccountManager.shared.find(for: self.owner) {
            account.xmppTaskScheduler.enqueueAccountTask(
                priority: .foreground,
                resource: .mamArchive,
                deduplicationKey: "notifications.latest.\(self.owner).\(node).\(identity.generation)"
            ) { _, stream, finish in
                runLatestSync(stream, finish)
            }
            return
        }

        runLatestSync(stream, {})
    }

    private final func performLatestSync(
        _ stream: XMPPStream,
        identity: NotificationSyncIdentity,
        completion: @escaping () -> Void
    ) {
        guard self.isCurrentNotificationSyncIdentity(identity) else {
            completion()
            return
        }
        guard beginSync(.latest) else {
            completion()
            return
        }
        resetHistoricalBackfillBudget()
        let node = identity.node

        do {
            let realm = try WRealm.safe()
            let latestCursor = latestSyncCursor(in: realm)
            DDLogDebug("XMPPNotificationsManager: latest cursor selected owner=\(self.owner) node=\(node) source=\(latestCursor.source.rawValue) afterId=\(latestCursor.cursor ?? "")")
            if latestCursor.source == .newestStoredNotification {
                DDLogDebug("XMPPNotificationsManager: using newest stored notification as migration fallback for latest cursor owner=\(self.owner) node=\(node) afterId=\(latestCursor.cursor ?? "")")
            }
            requestLatestPage(
                stream,
                identity: identity,
                afterId: latestCursor.cursor,
                bootstrapFromNewestPage: latestCursor.cursor?.isNotEmpty != true,
                completion: completion
            )
        } catch {
            endSync(.latest)
            completion()
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
