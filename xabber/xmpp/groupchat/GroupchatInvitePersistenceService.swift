import Foundation
import RealmSwift
import XMPPFramework

enum GroupchatInviteStoreResult: Equatable {
    case inserted
    case updated
    case duplicate
    case older
    case ignoredOutgoing
    case invalid

    var shouldConsume: Bool {
        self != .invalid
    }

    var didCreateOrUpdate: Bool {
        self == .inserted || self == .updated
    }
}

final class GroupchatInvitePersistenceService {
    private let owner: String
    private let now: () -> Date
    private let showLocalNotification: (PushNotificationPreview) -> Void

    init(
        owner: String,
        now: @escaping () -> Date = Date.init,
        showLocalNotification: @escaping (PushNotificationPreview) -> Void = { preview in
            DispatchQueue.main.async {
                NotifyManager.shared.showInviteNotification(preview: preview)
            }
        }
    ) {
        self.owner = owner
        self.now = now
        self.showLocalNotification = showLocalNotification
    }

    @discardableResult
    func receive(
        message: XMPPMessage,
        date: Date,
        isRead: Bool?,
        commit: Bool = true,
        notifyLocally: Bool = false
    ) -> GroupchatInviteStoreResult {
        do {
            let realm = try WRealm.safe()
            return receive(
                message: message,
                date: date,
                isRead: isRead,
                realm: realm,
                commit: commit,
                notifyLocally: notifyLocally
            )
        } catch {
            DDLogDebug("GroupchatInvitePersistenceService: \(#function). \(error.localizedDescription)")
            return .invalid
        }
    }

    @discardableResult
    func receive(
        message: XMPPMessage,
        date: Date,
        isRead: Bool?,
        realm: Realm,
        commit: Bool,
        notifyLocally: Bool = false
    ) -> GroupchatInviteStoreResult {
        guard let payload = GroupchatInviteV3Parser.parse(message, owner: owner, date: date, archiveId: nil) else {
            return .invalid
        }
        let notificationPreview = PushNotificationArchiveParser.parseArchivedMessage(
            xmlString: message.xmlString,
            owner: owner
        )
        return store(
            payload: payload,
            isRead: isRead,
            realm: realm,
            commit: commit,
            notifyLocally: notifyLocally,
            notificationPreview: notificationPreview
        )
    }

    @discardableResult
    func receiveArchivedEnvelope(
        _ message: XMPPMessage,
        isRead: Bool?,
        commit: Bool = true
    ) -> GroupchatInviteStoreResult {
        guard let bareMessage = getArchivedMessageContainer(message) else {
            return .invalid
        }
        let date = getDeliveryTime(bareMessage, owner: owner) ?? getDelayedDate(message) ?? Date()
        do {
            let realm = try WRealm.safe()
            return receiveArchivedEnvelope(message, bareMessage: bareMessage, date: date, isRead: isRead, realm: realm, commit: commit)
        } catch {
            DDLogDebug("GroupchatInvitePersistenceService: \(#function). \(error.localizedDescription)")
            return .invalid
        }
    }

    @discardableResult
    func receiveArchivedEnvelope(
        _ message: XMPPMessage,
        bareMessage: XMPPMessage,
        date: Date,
        isRead: Bool?,
        realm: Realm,
        commit: Bool
    ) -> GroupchatInviteStoreResult {
        let archiveId = message.element(forName: "result")?.attributeStringValue(forName: "id")
        guard let payload = GroupchatInviteV3Parser.parse(bareMessage, owner: owner, date: date, archiveId: archiveId) else {
            return .invalid
        }
        return store(
            payload: payload,
            isRead: isRead,
            realm: realm,
            commit: commit,
            notifyLocally: false,
            notificationPreview: nil
        )
    }

    @discardableResult
    func store(
        payload: GroupchatInviteV3Payload,
        isRead: Bool?,
        realm: Realm,
        commit: Bool,
        notifyLocally: Bool = false,
        notificationPreview: PushNotificationPreview? = nil
    ) -> GroupchatInviteStoreResult {
        guard payload.owner == owner,
              payload.groupchat.isNotEmpty,
              payload.sender.isNotEmpty else {
            return .invalid
        }
        guard !payload.isOutgoing else {
            return .ignoredOutgoing
        }

        let primary = GroupchatInvitesStorageItem.genIncomingPrimary(groupchat: payload.groupchat, owner: owner)
        let existing = realm.object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: primary)
        let result: GroupchatInviteStoreResult
        if let existing {
            if existing.date > payload.date {
                return .older
            }
            if existing.date == payload.date {
                return .duplicate
            }
            result = .updated
        } else {
            result = .inserted
        }

        let mutation = {
            let item = existing ?? GroupchatInvitesStorageItem()
            if existing == nil {
                item.primary = primary
            }
            item.owner = self.owner
            item.groupchat = payload.groupchat
            item.jid = payload.sender
            item.sender = payload.sender
            item.date = payload.date
            item.reason = payload.reason
            item.outgoing = false
            item.isRead = isRead ?? false
            item.isProcessed = false
            item.isAnonymous = payload.isAnonymous
            item.messageId = payload.messageId ?? ""
            item.originId = payload.originId ?? ""
            item.stanzaId = payload.stanzaId ?? ""
            item.archiveId = payload.archiveId ?? payload.stanzaId ?? ""
            item.isFromGroupchat = payload.isFromGroupchat
            realm.add(item, update: .modified)

            if item.isRead {
                return
            }
            let notificationPrimary = UINotificationStorageItem.genPrimary(owner: self.owner, jid: payload.groupchat)
            let existingNotification = realm.object(ofType: UINotificationStorageItem.self, forPrimaryKey: notificationPrimary)
            let notification = existingNotification ?? UINotificationStorageItem()
            if existingNotification == nil {
                notification.primary = notificationPrimary
            }
            notification.owner = self.owner
            notification.jid = payload.groupchat
            notification.kind = .invite
            notification.date = Date()
            notification.readAt = nil
            realm.add(notification, update: .modified)
        }

        let ownsCommit = commit && !realm.isInWriteTransaction
        do {
            if ownsCommit {
                try realm.write(mutation)
            } else {
                mutation()
            }
        } catch {
            DDLogDebug("GroupchatInvitePersistenceService: \(#function). \(error.localizedDescription)")
            return .invalid
        }

        let age = abs(now().timeIntervalSince(payload.date))
        if ownsCommit,
           notifyLocally,
           isRead == false,
           result.didCreateOrUpdate,
           age <= 10,
           let notificationPreview,
           notificationPreview.route.kind == .groupInvite {
            showLocalNotification(notificationPreview)
        }
        return result
    }
}
