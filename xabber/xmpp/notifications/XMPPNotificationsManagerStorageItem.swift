//
//  XMPPNotificationsManagerStorage.swift
//  xabber
//
//  Created by Игорь Болдин on 18.03.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import RealmSwift
import CocoaLumberjack
import XMPPFramework

class XMPPNotificationsManagerStorageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    
    @objc dynamic var lastItemId: String? = nil
    @objc dynamic var unread: Int = 0
    @objc dynamic var unreadAfterId: String? = nil
    
    @objc dynamic var node: String? = nil
    @objc dynamic var archiveSyncCompleted: Bool = false
    @objc dynamic var lastSyncedNotificationId: String? = nil
    @objc dynamic var lastSyncAt: Date? = nil
    
    static func genPrimary(owner: String) -> String {
        return [owner].prp()
    }
}

extension XMPPNotificationsManagerStorageItem {
    static func notificationUnreadBoundaryReadState(
        stanzaId: String?,
        storage: XMPPNotificationsManagerStorageItem?
    ) -> Bool? {
        guard let storage,
              let unreadAfterId = storage.unreadAfterId,
              storage.unread > 0,
              unreadAfterId.isNotEmpty,
              let isUnread = isArchiveId(stanzaId, newerThan: unreadAfterId) else {
            return nil
        }

        return !isUnread
    }

    static func reconcileStoredNotificationReadState(
        owner: String,
        storage: XMPPNotificationsManagerStorageItem,
        in realm: Realm
    ) {
        let notifications = realm.objects(NotificationStorageItem.self).filter("owner == %@", owner)

        if storage.unread == 0 {
            notifications.forEach { $0.isRead = true }
            MentionNotificationSync.refreshLastChatMentionIds(owner: owner, in: realm)
            return
        }

        guard let unreadAfterId = storage.unreadAfterId,
              unreadAfterId.isNotEmpty else {
            return
        }
        guard let notificationDate = realm.objects(NotificationStorageItem.self).filter("owner == %@ AND stanzaId == %@", owner, unreadAfterId).first?.date else {
            return
        }
        notifications.forEach { notification in
            if let readState = notificationUnreadBoundaryReadState(stanzaId: notification.stanzaId, storage: storage) {
                notification.isRead = readState
            } else {
                notification.isRead = notification.date.compare(notificationDate) == .orderedAscending
            }
        }

        MentionNotificationSync.refreshLastChatMentionIds(owner: owner, in: realm)
    }
}


class NotificationStorageItem: Object {
    enum MentionLinkStatus: String {
        case pending = "pending"
        case resolved = "resolved"
        case invalidated = "invalidated"
        case missing = "missing"
    }

    private enum MetadataKeys {
        static let sourceConversationType = "sourceConversationType_"
        static let sourceChatJid = "sourceChatJid"
        static let sourceArchivedId = "sourceArchivedId"
        static let sourceMessageId = "sourceMessageId"
        static let sourceSenderId = "sourceSenderId"
        static let mentionTargetUserId = "mentionTargetUserId"
        static let sourceMessageDate = "sourceMessageDate"
        static let sourceBodyFingerprint = "sourceBodyFingerprint"
        static let linkStatus = "linkStatus_"
        static let linkedAt = "linkedAt"
    }

    override static func primaryKey() -> String? {
        return "primary"
    }

    override static func indexedProperties() -> [String] {
        ["owner", "category_", "isRead", "associatedJid", "date"]
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var uniqueId: String = ""
    @objc dynamic var messageId: String = ""
    @objc dynamic var stanzaId: String = ""
    
    @objc dynamic var category_: String = ""
    @objc dynamic var isRead: Bool = true
    @objc dynamic var associatedJid: String? = nil
    @objc dynamic var displayedNick: String? = nil
    @objc dynamic var text: String? = nil
    @objc dynamic var metadata_: String? = nil
    @objc dynamic var date: Date = Date()
    @objc dynamic var notificationType: String? = nil
    @objc dynamic var originalSenderJid: String? = nil
    @objc dynamic var fallbackText: String? = nil
    
    @objc dynamic var shouldShow: Bool = false
    
    static func genPrimary(owner: String, jid: String, uniqueId: String) -> String {
        return [owner, jid, uniqueId].prp()
    }
    
    var category: XMPPNotificationsManager.Category {
        get {
            return XMPPNotificationsManager.Category(rawValue: self.category_) ?? .device
        } set {
            self.category_ = newValue.rawValue
        }
    }
    
    var metadata: [String: Any]? {
        get {
            if let metadata = self.metadata_,
                let data = metadata.data(using: .utf8) {
                do {
                    return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                } catch {
                    DDLogDebug("NotificationStorageItem: \(#function). \(error.localizedDescription)")
                }
            }
            return nil
        } set {
            if let value = newValue {
                do {
                    let data = try JSONSerialization.data(withJSONObject: value, options: [])
                    self.metadata_ = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    DDLogDebug("NotificationStorageItem: \(#function). \(error.localizedDescription)")
                }
            } else {
                self.metadata_ = nil
            }
        }
    }

    private func metadataString(forKey key: String) -> String? {
        self.metadata?[key] as? String
    }

    private func metadataDouble(forKey key: String) -> Double? {
        if let value = self.metadata?[key] as? Double {
            return value
        }
        if let value = self.metadata?[key] as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private func setMetadataValue(_ value: Any?, forKey key: String) {
        var nextMetadata = self.metadata ?? [:]
        nextMetadata[key] = value
        if nextMetadata.isEmpty {
            self.metadata = nil
        } else {
            self.metadata = nextMetadata
        }
    }

    var sourceConversationType: ClientSynchronizationManager.ConversationType? {
        get {
            guard let rawValue = metadataString(forKey: MetadataKeys.sourceConversationType) else {
                return nil
            }
            return ClientSynchronizationManager.ConversationType(rawValue: rawValue)
        }
        set {
            setMetadataValue(newValue?.rawValue, forKey: MetadataKeys.sourceConversationType)
        }
    }

    var sourceChatJid: String? {
        get { metadataString(forKey: MetadataKeys.sourceChatJid) }
        set { setMetadataValue(newValue, forKey: MetadataKeys.sourceChatJid) }
    }

    var sourceArchivedId: String? {
        get { metadataString(forKey: MetadataKeys.sourceArchivedId) }
        set { setMetadataValue(newValue, forKey: MetadataKeys.sourceArchivedId) }
    }

    var sourceMessageId: String? {
        get { metadataString(forKey: MetadataKeys.sourceMessageId) }
        set { setMetadataValue(newValue, forKey: MetadataKeys.sourceMessageId) }
    }

    var sourceSenderId: String? {
        get { metadataString(forKey: MetadataKeys.sourceSenderId) }
        set { setMetadataValue(newValue, forKey: MetadataKeys.sourceSenderId) }
    }

    var mentionTargetUserId: String? {
        get { metadataString(forKey: MetadataKeys.mentionTargetUserId) }
        set { setMetadataValue(newValue, forKey: MetadataKeys.mentionTargetUserId) }
    }

    var sourceMessageDate: Date? {
        get {
            guard let timestamp = metadataDouble(forKey: MetadataKeys.sourceMessageDate) else {
                return nil
            }
            return Date(timeIntervalSince1970: timestamp)
        }
        set {
            setMetadataValue(newValue?.timeIntervalSince1970, forKey: MetadataKeys.sourceMessageDate)
        }
    }

    var sourceBodyFingerprint: String? {
        get { metadataString(forKey: MetadataKeys.sourceBodyFingerprint) }
        set { setMetadataValue(newValue, forKey: MetadataKeys.sourceBodyFingerprint) }
    }

    var mentionLinkStatus: MentionLinkStatus? {
        get {
            guard let rawValue = metadataString(forKey: MetadataKeys.linkStatus) else {
                return nil
            }
            return MentionLinkStatus(rawValue: rawValue)
        }
        set {
            setMetadataValue(newValue?.rawValue, forKey: MetadataKeys.linkStatus)
        }
    }

    var linkedAt: Date? {
        get {
            guard let timestamp = metadataDouble(forKey: MetadataKeys.linkedAt) else {
                return nil
            }
            return Date(timeIntervalSince1970: timestamp)
        }
        set {
            setMetadataValue(newValue?.timeIntervalSince1970, forKey: MetadataKeys.linkedAt)
        }
    }

    var isMentionNotification: Bool {
        self.category == .mention
    }
}

struct MentionNotificationReconcileResult {
    let linkedMessagePrimaryToMarkRead: String?
}

enum MentionNotificationSync {

    static func normalizedBodyFingerprint(_ body: String?) -> String? {
        guard let body = body?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              body.isNotEmpty else {
            return nil
        }
        return body.lowercased()
    }

    static func currentGroupMemberId(owner: String, groupchatJid: String, in realm: Realm) -> String? {
        if let currentMemberId = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: groupchatJid,
                owner: owner,
                conversationType: .group
            )
        )?.groupchatMyId,
           currentMemberId.isNotEmpty {
            return currentMemberId
        }

        // Active chat and last chats must resolve "my" group member through the same composite key.
        return realm.objects(GroupchatUserStorageItem.self)
            .filter(
                "owner == %@ AND groupchatId == %@ AND isMe == true AND isHidden == false",
                owner,
                [groupchatJid, owner].prp()
            )
            .first?
            .userId
    }

    static func unreadMentionNotificationPrimaries(
        owner: String,
        groupchatJid: String,
        matchingMessagePrimary: String,
        in realm: Realm
    ) -> Set<String> {
        guard matchingMessagePrimary.isNotEmpty else {
            return []
        }

        return Set(
            realm.objects(NotificationStorageItem.self)
                .filter(
                    "owner == %@ AND category_ == %@ AND isRead == false",
                    owner,
                    XMPPNotificationsManager.Category.mention.rawValue
                )
                .toArray()
                .filter {
                    ($0.sourceConversationType ?? .group) == .group
                        && $0.sourceChatJid == groupchatJid
                        && $0.mentionLinkStatus != .invalidated
                        && $0.mentionLinkStatus != .missing
                        && MentionNotificationSync.matchingMessage(for: $0, in: realm)?.primary == matchingMessagePrimary
                }
                .map(\.primary)
        )
    }

    static func mentionMetadata(
        from forwardedElement: DDXMLElement?,
        owner: String,
        originalSenderJid: String?,
        fallbackDate: Date
    ) -> [String: Any]? {
        guard let forwardedElement else {
            return [
                "linkStatus_": NotificationStorageItem.MentionLinkStatus.pending.rawValue,
                "sourceMessageDate": fallbackDate.timeIntervalSince1970
            ]
        }

        let forwardedMessage = XMPPMessage(from: forwardedElement)
        let fallbackChatJid = XMPPJID(
            string: forwardedElement.attributeStringValue(forName: "from", withDefaultValue: "")
        )?.bare
        let references = parseReferences(
            forwardedMessage,
            primary: "notification-mention",
            jid: fallbackChatJid ?? originalSenderJid ?? "",
            owner: owner
        )
        let sourceChatJid = references
            .compactMap { $0.metadata?["groupchatJid"] as? String }
            .first(where: { $0.isNotEmpty }) ?? fallbackChatJid
        let conversationType: ClientSynchronizationManager.ConversationType = sourceChatJid?.isNotEmpty == true ? .group : .regular
        let sourceSenderId = references
            .first(where: { $0.kind == .groupchat })?
            .metadata?["id"] as? String
        let sourceArchivedId = getStanzaId(forwardedMessage, owner: owner)
        let sourceMessageId = getOriginOrMessageId(forwardedMessage)
        let sourceMessageDate = forwardedMessage
            .element(forName: "time", xmlns: "https://xabber.com/protocol/delivery")?
            .attributeStringValue(forName: "stamp")?
            .xmppDate
            ?? forwardedMessage
                .element(forName: "delay", xmlns: "urn:xmpp:delay")?
                .attributeStringValue(forName: "stamp")?
                .xmppDate
            ?? fallbackDate

        var mentionTargetUserId: String?
        if let sourceChatJid,
           sourceChatJid.isNotEmpty,
           let realm = try? WRealm.safe(),
           let currentMemberId = currentGroupMemberId(owner: owner, groupchatJid: sourceChatJid, in: realm),
           currentMemberId.isNotEmpty {
            mentionTargetUserId = currentMemberId
        }

        var metadata: [String: Any] = [
            "sourceConversationType_": conversationType.rawValue,
            "sourceMessageDate": sourceMessageDate.timeIntervalSince1970,
            "linkStatus_": NotificationStorageItem.MentionLinkStatus.pending.rawValue
        ]

        if let sourceChatJid, sourceChatJid.isNotEmpty {
            metadata["sourceChatJid"] = sourceChatJid
        }
        if sourceArchivedId.isNotEmpty {
            metadata["sourceArchivedId"] = sourceArchivedId
        }
        if sourceMessageId.isNotEmpty {
            metadata["sourceMessageId"] = sourceMessageId
        }
        if let sourceSenderId, sourceSenderId.isNotEmpty {
            metadata["sourceSenderId"] = sourceSenderId
        }
        if let mentionTargetUserId, mentionTargetUserId.isNotEmpty {
            metadata["mentionTargetUserId"] = mentionTargetUserId
        }
        if let sourceBodyFingerprint = normalizedBodyFingerprint(forwardedMessage.body),
           sourceBodyFingerprint.isNotEmpty {
            metadata["sourceBodyFingerprint"] = sourceBodyFingerprint
        }

        return metadata
    }

    static func existingMentionNotification(
        owner: String,
        metadata: [String: Any]?,
        in realm: Realm
    ) -> NotificationStorageItem? {
        guard let metadata else {
            return nil
        }

        let notifications = realm.objects(NotificationStorageItem.self)
            .filter("owner == %@ AND category_ == %@", owner, XMPPNotificationsManager.Category.mention.rawValue)
            .toArray()

        if let sourceChatJid = metadata["sourceChatJid"] as? String,
           let sourceArchivedId = metadata["sourceArchivedId"] as? String,
           sourceChatJid.isNotEmpty,
           sourceArchivedId.isNotEmpty,
           let notification = notifications.first(where: {
               $0.sourceChatJid == sourceChatJid && $0.sourceArchivedId == sourceArchivedId
           }) {
            return notification
        }

        if let sourceChatJid = metadata["sourceChatJid"] as? String,
           let sourceMessageId = metadata["sourceMessageId"] as? String,
           sourceChatJid.isNotEmpty,
           sourceMessageId.isNotEmpty,
           let notification = notifications.first(where: {
               $0.sourceChatJid == sourceChatJid && $0.sourceMessageId == sourceMessageId
           }) {
            return notification
        }

        let sourceMessageDate = (metadata["sourceMessageDate"] as? NSNumber)?.doubleValue
            ?? metadata["sourceMessageDate"] as? Double
        let sourceBodyFingerprint = metadata["sourceBodyFingerprint"] as? String

        if let sourceChatJid = metadata["sourceChatJid"] as? String,
           let sourceSenderId = metadata["sourceSenderId"] as? String,
           let sourceMessageDate {
            let datedMatches = notifications.filter {
                $0.sourceChatJid == sourceChatJid
                && $0.sourceSenderId == sourceSenderId
                && $0.sourceMessageDate?.timeIntervalSince1970 == sourceMessageDate
            }

            if let sourceBodyFingerprint, sourceBodyFingerprint.isNotEmpty {
                let fingerprintMatches = datedMatches.filter { $0.sourceBodyFingerprint == sourceBodyFingerprint }
                if fingerprintMatches.count == 1 {
                    return fingerprintMatches.first
                }
                return nil
            }

            if datedMatches.count == 1 {
                return datedMatches.first
            }
        }

        return nil
    }

    static func matchingMessage(
        owner: String,
        sourceChatJid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        sourceArchivedId: String?,
        sourceMessageId: String?,
        sourceMessageDate: Date,
        sourceSenderId: String?,
        sourceBodyFingerprint: String?,
        in realm: Realm
    ) -> MessageStorageItem? {
        if let sourceArchivedId,
           sourceArchivedId.isNotEmpty {
            let matches = realm.objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND archivedId == %@",
                    owner,
                    sourceChatJid,
                    conversationType.rawValue,
                    sourceArchivedId
                )
                .toArray()
            if matches.count == 1 {
                return matches.first
            }
            if matches.count > 1 {
                return nil
            }
        }

        if let sourceMessageId,
           sourceMessageId.isNotEmpty {
            let matches = realm.objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND messageId == %@",
                    owner,
                    sourceChatJid,
                    conversationType.rawValue,
                    sourceMessageId
                )
                .toArray()
            if matches.count == 1 {
                return matches.first
            }
            if matches.count > 1 {
                return nil
            }
        }

        let candidates = realm.objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@",
                owner,
                sourceChatJid,
                conversationType.rawValue
            )
            .toArray()

        let filteredByDate = candidates.filter { candidate in
            abs(candidate.date.timeIntervalSince1970 - sourceMessageDate.timeIntervalSince1970) < 1
        }

        let filteredBySender = filteredByDate.filter { candidate in
            guard let sourceSenderId,
                  sourceSenderId.isNotEmpty else {
                return true
            }
            return candidate.groupchatAuthorId == sourceSenderId
        }

        let filteredByFingerprint = filteredBySender.filter { candidate in
            guard let sourceBodyFingerprint,
                  sourceBodyFingerprint.isNotEmpty else {
                return true
            }
            return normalizedBodyFingerprint(candidate.body) == sourceBodyFingerprint
        }

        return filteredByFingerprint.count == 1 ? filteredByFingerprint.first : nil
    }

    static func matchingMessage(
        for notification: NotificationStorageItem,
        in realm: Realm
    ) -> MessageStorageItem? {
        guard notification.isMentionNotification,
              let sourceChatJid = notification.sourceChatJid,
              sourceChatJid.isNotEmpty else {
            return nil
        }

        let conversationType = notification.sourceConversationType ?? .group
        guard let sourceMessageDate = notification.sourceMessageDate else {
            return nil
        }

        return matchingMessage(
            owner: notification.owner,
            sourceChatJid: sourceChatJid,
            conversationType: conversationType,
            sourceArchivedId: notification.sourceArchivedId,
            sourceMessageId: notification.sourceMessageId,
            sourceMessageDate: sourceMessageDate,
            sourceSenderId: notification.sourceSenderId,
            sourceBodyFingerprint: notification.sourceBodyFingerprint,
            in: realm
        )
    }

    static func groupchatJidForLastChatMentionState(
        from notification: NotificationStorageItem
    ) -> String? {
        guard notification.isMentionNotification,
              (notification.sourceConversationType ?? .group) == .group,
              let sourceChatJid = notification.sourceChatJid,
              sourceChatJid.isNotEmpty else {
            return nil
        }

        return sourceChatJid
    }

    private static func newestUnreadMentionArchivedId(
        owner: String,
        groupchatJid: String,
        in realm: Realm
    ) -> String? {
        realm.objects(NotificationStorageItem.self)
            .filter(
                "owner == %@ AND category_ == %@ AND isRead == false",
                owner,
                XMPPNotificationsManager.Category.mention.rawValue
            )
            .toArray()
            .filter {
                $0.sourceChatJid == groupchatJid
                    && $0.isMentionNotification
                    && ($0.sourceConversationType ?? .group) == .group
                    && $0.mentionLinkStatus != .invalidated
                    && $0.mentionLinkStatus != .missing
                    && ($0.sourceArchivedId?.isNotEmpty ?? false)
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.sourceMessageDate ?? lhs.date
                let rhsDate = rhs.sourceMessageDate ?? rhs.date
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }

                return (lhs.sourceArchivedId ?? "") > (rhs.sourceArchivedId ?? "")
            }
            .first?
            .sourceArchivedId
    }

    static func refreshLastChatMentionId(
        owner: String,
        groupchatJid: String,
        in realm: Realm
    ) {
        guard groupchatJid.isNotEmpty,
              let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: groupchatJid,
                    owner: owner,
                    conversationType: .group
                )
              ) else {
            return
        }

        chat.mentionId = newestUnreadMentionArchivedId(
            owner: owner,
            groupchatJid: groupchatJid,
            in: realm
        )
    }

    static func refreshLastChatMentionIds(
        owner: String,
        groupchatJids: Set<String>? = nil,
        in realm: Realm
    ) {
        let targetGroupchatJids: Set<String>
        if let groupchatJids, groupchatJids.isNotEmpty {
            targetGroupchatJids = Set(groupchatJids.filter { $0.isNotEmpty })
        } else {
            targetGroupchatJids = Set(
                realm.objects(LastChatsStorageItem.self)
                    .filter(
                        "owner == %@ AND conversationType_ == %@",
                        owner,
                        ClientSynchronizationManager.ConversationType.group.rawValue
                    )
                    .toArray()
                    .compactMap { $0.jid.isNotEmpty ? $0.jid : nil }
            )
        }

        targetGroupchatJids.forEach {
            refreshLastChatMentionId(owner: owner, groupchatJid: $0, in: realm)
        }
    }

    static func messageStillMentionsTarget(
        _ message: MessageStorageItem,
        notification: NotificationStorageItem,
        in realm: Realm
    ) -> Bool {
        guard message.conversationType == .group else {
            return false
        }

        let targetMemberId = notification.mentionTargetUserId
            ?? currentGroupMemberId(owner: message.owner, groupchatJid: message.opponent, in: realm)

        guard let targetMemberId, targetMemberId.isNotEmpty else {
            return false
        }

        return message.references.contains {
            $0.kind == .mention
                && ($0.metadata?["memberId"] as? String) == targetMemberId
                && (($0.metadata?["groupchatJid"] as? String) ?? message.opponent) == message.opponent
        }
    }

    @discardableResult
    static func reconcile(
        notification: NotificationStorageItem,
        in realm: Realm
    ) -> MentionNotificationReconcileResult {
        guard notification.isMentionNotification else {
            return MentionNotificationReconcileResult(linkedMessagePrimaryToMarkRead: nil)
        }

        guard let message = matchingMessage(for: notification, in: realm) else {
            notification.mentionLinkStatus = .pending
            return MentionNotificationReconcileResult(linkedMessagePrimaryToMarkRead: nil)
        }

        if message.isDeleted {
            notification.isRead = true
            notification.shouldShow = false
            notification.mentionLinkStatus = .missing
            notification.linkedAt = notification.linkedAt ?? Date()
            return MentionNotificationReconcileResult(linkedMessagePrimaryToMarkRead: nil)
        }

        if notification.mentionTargetUserId == nil,
           let currentMemberId = currentGroupMemberId(owner: message.owner, groupchatJid: message.opponent, in: realm) {
            notification.mentionTargetUserId = currentMemberId
        }

        guard notification.mentionTargetUserId?.isEmpty == false else {
            notification.mentionLinkStatus = .pending
            notification.linkedAt = nil
            return MentionNotificationReconcileResult(linkedMessagePrimaryToMarkRead: nil)
        }

        if !messageStillMentionsTarget(message, notification: notification, in: realm) {
            notification.isRead = true
            notification.shouldShow = false
            notification.mentionLinkStatus = .invalidated
            notification.linkedAt = notification.linkedAt ?? Date()
            return MentionNotificationReconcileResult(linkedMessagePrimaryToMarkRead: nil)
        }

        if notification.sourceConversationType == nil {
            notification.sourceConversationType = message.conversationType
        }
        if notification.sourceChatJid == nil || notification.sourceChatJid?.isEmpty == true {
            notification.sourceChatJid = message.opponent
        }
        if notification.sourceArchivedId == nil || notification.sourceArchivedId?.isEmpty == true {
            notification.sourceArchivedId = message.archivedId
        }
        if notification.sourceMessageId == nil || notification.sourceMessageId?.isEmpty == true {
            notification.sourceMessageId = message.messageId
        }
        if notification.sourceSenderId == nil || notification.sourceSenderId?.isEmpty == true {
            notification.sourceSenderId = message.groupchatAuthorId
        }
        if notification.sourceMessageDate == nil {
            notification.sourceMessageDate = message.date
        }
        if notification.sourceBodyFingerprint == nil || notification.sourceBodyFingerprint?.isEmpty == true {
            notification.sourceBodyFingerprint = normalizedBodyFingerprint(message.body)
        }

        notification.associatedJid = notification.sourceChatJid ?? notification.associatedJid
        notification.linkedAt = notification.linkedAt ?? Date()
        notification.mentionLinkStatus = .resolved

        let linkedMessagePrimaryToMarkRead = notification.isRead && !message.isRead && !message.outgoing
            ? message.primary
            : nil

        return MentionNotificationReconcileResult(linkedMessagePrimaryToMarkRead: linkedMessagePrimaryToMarkRead)
    }

    static func reconcileMentionNotifications(
        for owner: String,
        chats: Set<String>? = nil,
        in realm: Realm
    ) -> Set<String> {
        let notifications = realm.objects(NotificationStorageItem.self)
            .filter("owner == %@ AND category_ == %@", owner, XMPPNotificationsManager.Category.mention.rawValue)
            .toArray()
            .filter {
                guard let chats, chats.isNotEmpty else {
                    return true
                }
                guard let sourceChatJid = $0.sourceChatJid else {
                    return false
                }
                return chats.contains(sourceChatJid)
            }

        var messagePrimariesToMarkRead: Set<String> = []
        notifications.forEach { notification in
            let result = reconcile(notification: notification, in: realm)
            if let messagePrimary = result.linkedMessagePrimaryToMarkRead,
               messagePrimary.isNotEmpty {
                messagePrimariesToMarkRead.insert(messagePrimary)
            }
        }

        refreshLastChatMentionIds(owner: owner, groupchatJids: chats, in: realm)

        return messagePrimariesToMarkRead
    }
}
