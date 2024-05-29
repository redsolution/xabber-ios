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
import RxSwift
import RxRealm
import UserNotifications
import CocoaLumberjack

import XMPPFramework

/**
 *    Notification requests enumeration
 **/
enum NotifyType {
    case newMessage
    case subscription
    case newResourceDetect
    case contactGoOnline
    case contactGoOffline
    case verification
}

class NotifyItem {
    var owner: String? = nil
    var from: String
    var to: String
    var message: String
    var timestamp: TimeInterval
    var showed: Bool = false
    var Id: String = ""
    var displayName: String = ""
    var archived: Bool = false
    var username: String? = nil
    var imageUrl: String? = nil
    var conversationType: String
    
    init(from: String, to: String, message: String, date: Date, conversationType: String) {
        self.from = from
        self.to = to
        self.message = message
        self.timestamp = date.timeIntervalSinceReferenceDate
        self.conversationType = conversationType
    }
}

class NotifyManagerStorage: Object {
    override static func primaryKey() -> String? {
        return "id"
    }
    @objc dynamic var id: Int = 0
    @objc dynamic var unread = 0
    @objc dynamic var lastOpenDate: Date = Date(timeIntervalSinceReferenceDate: 1000)
    @objc dynamic var showMessageNotify: Bool = true
    @objc dynamic var showSubscriptionNotify: Bool = true
    @objc dynamic var showNewResourceNotify: Bool = true
    @objc dynamic var showContactOnlineNotify: Bool = true
    @objc dynamic var showContactOfflineNotify: Bool = true
}

class NotifyPersonalStorageItem: Object {
    override static func primaryKey() -> String? {
        return "owner"
    }
    @objc dynamic var owner: String = ""
    @objc dynamic var muteAll: Bool = false
    var muteList: List<String> = List<String>()
//    var voipPushRegistered: Bool = false
}

class MuteItem: Equatable {
    
    static func == (lhs: MuteItem, rhs: MuteItem) -> Bool {
        return lhs.from == rhs.from && lhs.to == rhs.to
    }
    
    var to: String
    var from: String
    
    var manually: Bool = false
    
    init(fromJid from: String, toJid to: String) {
        self.from = from
        self.to = to
    }
    
}

class UnreadItem: Hashable {
    
    static func == (lhs: UnreadItem, rhs: UnreadItem) -> Bool {
        return lhs.owner == rhs.owner && lhs.opponent == rhs.opponent
    }
    
    var owner: String = ""
    var opponent: String = ""
    var count: Int = 0
    
    init(owner: String, opponent: String) {
        self.owner = owner
        self.opponent = opponent
        self.count = 1
    }
    
    func up() {
        self.count += 1
    }
    
    func primary() -> String {
        return [opponent, owner].prp()
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(owner)
        hasher.combine(opponent)
    }
}

class NotifyManager {
    open class var shared: NotifyManager {
        struct NotifyManagerSingleton {
//            SIGBRT
            static let instance = NotifyManager()
        }
        return NotifyManagerSingleton.instance
    }
    
    enum NotifyError: Error {
        case BadUserInfo
        case UndefinedAction
    }
    
    public static let notificationMessageCategory = "com.xabber.ios.message"
    public static let notificationPushMessageCategory = "com.xabber.ios.message.push"
    public static let notificationSubscribtionCategory = "com.xabber.ios.subscribtion"
    public static let notificationInviteCategory = "com.xabber.ios.invite"
    public static let notificationVerificationCategory = "com.xabber.ios.verification"
    public static let notificationMessageActionReply =          [notificationMessageCategory, ".reply"].joined()
    public static let notificationMessageActionMarkAsRead =     [notificationMessageCategory, ".read"].joined()
    public static let notificationMessageActionSetMute =        [notificationMessageCategory, ".mute"].joined()
    public static let notificationMessageActionSubscribe =      [notificationSubscribtionCategory, ".accept"].joined()
    public static let notificationMessageActionUnsubscribe =    [notificationSubscribtionCategory, ".decline"].joined()
    public static let notificationMessageActionBlock  =         [notificationSubscribtionCategory, ".block"].joined()
    public static let notificationMessageActionJoinGroup =      [notificationInviteCategory, ".join"].joined()
    public static let notificationMessageActionDeclineGroup =   [notificationInviteCategory, ".decline"].joined()
    
    public var currentDialog: String? = nil
//    var unread: Int = 0
    var lastOpen: Date = Date(timeIntervalSinceReferenceDate: 1)
    var message: NotifyItem
    var subscription: NotifyItem
    var newResource: NotifyItem
    var contactOnline: NotifyItem
    var contactOffline: NotifyItem
    var verification: NotifyItem

    var unreadMessagesCount: Int = 0
    
    var muteList: [MuteItem] = []
    var regjidQueue: [String] = []
    
    var showMessageNotify: Bool = true
    var showSubscriptionNotify: Bool = true
    var showNewResourceNotify: Bool = true
    var showContactOnlineNotify: Bool = true
    var showContactOfflineNotify: Bool = true
    var unreadItems: Set<UnreadItem> = Set<UnreadItem>()
    var canShowNotify: Bool = false
    var bag: DisposeBag = DisposeBag()
    var unreadsBag: DisposeBag = DisposeBag()
    var activeAccountCount: Int = 0
    
//    let dispatch = DispatchGroup()
    
    var deliveredNotificationsIds: Set<String> = Set<String>()
    var openViewControllerPayload: [String: String]? = nil
    
    internal var lastChatsDisplayedState: Bool = false

    public static let notificationCategories: [String] = [
        NotifyManager.notificationMessageCategory,
        NotifyManager.notificationPushMessageCategory,
    ]
    
    init() {
        self.message = NotifyItem(from: "", to: "", message: "", date: self.lastOpen, conversationType: "")
        self.subscription = NotifyItem(from: "", to: "", message: "", date: self.lastOpen, conversationType: "")
        self.newResource = NotifyItem(from: "", to: "", message: "", date: self.lastOpen, conversationType: "")
        self.contactOnline = NotifyItem(from: "", to: "", message: "", date: self.lastOpen, conversationType: "")
        self.contactOffline = NotifyItem(from: "", to: "", message: "", date: self.lastOpen, conversationType: "")
        self.verification = NotifyItem(from: "", to: "", message: "", date: self.lastOpen, conversationType: "")
        
        DispatchQueue.main.async {
            self.subscribe()
        }
    }
    
    public func updateSubscribtion() {
//        unsubscribe()
//        subscribe()
    }
    
    public final func subscribe() {
        do {
            bag = DisposeBag()
            let realm = try WRealm.safe()
            Observable
                .collection(from: realm.objects(AccountStorageItem.self).filter("enabled == %@", true))
                .compactMap({ return $0.toArray().compactMap({ return $0.jid }) })
                .debounce(.milliseconds(300), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if results.count != self.activeAccountCount {
                        self.activeAccountCount = results.count
                        self.unreadsBag = DisposeBag()
                        let accounts = results
                        do {
                            let realm = try WRealm.safe()
                            let predicate: NSPredicate
                            if CommonConfigManager.shared.config.locked_conversation_type.isNotEmpty {
                                var excludedJids = accounts.compactMap({XMPPJID(string: $0)!.domain})
                                excludedJids.append(CommonConfigManager.shared.config.support_jid)
                                predicate = NSPredicate(
                                    format: "(conversationType_ == %@ OR jid IN %@) AND muteExpired < 0 AND isArchived == false AND owner IN %@",
                                    argumentArray: [
                                        CommonConfigManager.shared.config.locked_conversation_type,
                                        excludedJids,
                                        accounts
                                    ]
                                )
                            } else {
                                predicate = NSPredicate(
                                    format: "muteExpired < 0 AND isArchived == false AND owner IN %@",
                                    argumentArray: [
                                        accounts
                                    ]
                                )
                            }
                            
                            let collection = realm
                                .objects(LastChatsStorageItem.self)
                                .filter(predicate)
                            Observable
                                .collection(from: collection)
                                .compactMap({ (results) -> Int? in
                                    return results
                                        .toArray()
                                        .compactMap { return $0.unread +
                                                            ($0.rosterItem?.isThereSubscriptionRequest() == true ? 1 : 0) }
                                        .reduce(0, +)
                                })
                                .debounce(.milliseconds(300), scheduler: ConcurrentDispatchQueueScheduler.init(qos: .default))
                                .subscribe(onNext: { (results) in
                                    DispatchQueue.main.async {
                                        if self.canShowNotify {
                                            self.showNotify(forType: .newMessage)
                                        }
                                        getAppTabBar()?.setUnreadsValue(results)
                                        self.unreadMessagesCount = results
                                    }
                                })
                                .disposed(by: self.unreadsBag)
                            Observable
                                .collection(from: realm.objects(RosterStorageItem.self).filter("owner IN %@ AND ask_ IN %@ AND removed == false AND isHidden == false", accounts, [RosterStorageItem.Ask.in.rawValue, RosterStorageItem.Ask.both.rawValue]))
                                .debounce(.milliseconds(500), scheduler: MainScheduler.asyncInstance)
                                .subscribe { (results) in
                                    do {
                                        let realm = try WRealm.safe()
                                        let predicate: NSPredicate
                                        if CommonConfigManager.shared.config.locked_conversation_type.isNotEmpty {
                                            var excludedJids = accounts.compactMap({XMPPJID(string: $0)!.domain})
                                            excludedJids.append(CommonConfigManager.shared.config.support_jid)
                                            predicate = NSPredicate(
                                                format: "(conversationType_ == %@ OR jid IN %@) AND muteExpired < 0 AND isArchived == false AND owner IN %@",
                                                argumentArray: [
                                                    CommonConfigManager.shared.config.locked_conversation_type,
                                                    excludedJids,
                                                    accounts
                                                ]
                                            )
                                        } else {
                                            predicate = NSPredicate(
                                                format: "muteExpired < 0 AND isArchived == false AND owner IN %@",
                                                argumentArray: [
                                                    accounts
                                                ]
                                            )
                                        }
                                        
                                        let unread = realm
                                            .objects(LastChatsStorageItem.self)
                                            .filter(predicate)
                                            .toArray()
                                            .compactMap { return $0.unread +
                                                                ($0.rosterItem?.isThereSubscriptionRequest() == true ? 1 : 0) }
                                            .reduce(0, +)
                                        DispatchQueue.main.async {
                                            getAppTabBar()?.setUnreadsValue(unread)
                                            self.unreadMessagesCount = unread
                                        }
                                    } catch {
                                        DDLogDebug("NotifyManager: \(#function). \(error.localizedDescription)")
                                    }
                                }
                                .disposed(by: self.unreadsBag)

                        } catch {
                            DDLogDebug("NotifyManager: \(#function). \(error.localizedDescription)")
                        }
                    }
                })
                .disposed(by: bag)
        } catch {
            DDLogError("NotifyManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func unsubscribe() {
        self.unreadsBag = DisposeBag()
    }
    
//    sometimes in push notify, it dont count unreads for dialogs
    func countUnread(_ results: Results<MessageStorageItem>) {
        self.unreadItems.removeAll()
        results.forEach {
            item in
            if let item = unreadItems.first(where: { $0.opponent == item.opponent && $0.owner == item.owner }) {
                item.up()
            } else {
                unreadItems.insert(UnreadItem(owner: item.owner, opponent: item.opponent))
            }
        }
        
        do {
            let realm = try WRealm.safe()
            if realm.isInWriteTransaction {
                try realm.write {
                    for item in self.unreadItems {
                        if let chatItem = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: item.primary()) {
                            chatItem.unread = item.count
                        }
                    }
                }
            }
        } catch {
            DDLogDebug("cant update unreads for contacts")
        }
    }
    
    func load(_ config: NotifyManagerStorage) {
        self.lastOpen = config.lastOpenDate
        self.showMessageNotify = config.showMessageNotify
        self.showSubscriptionNotify = config.showSubscriptionNotify
        self.showNewResourceNotify = config.showNewResourceNotify
        self.showContactOnlineNotify = config.showContactOnlineNotify
        self.showContactOfflineNotify = config.showContactOfflineNotify
//        self.countUnread(self.unreadsMsgRaw!)
    }
    
    func showInviteNotification(title: String, subtitle: String, text: String, jid: String, owner: String) {
        if self.lastChatsDisplayedState { return }
        
        let notifyId = [jid, owner, NotifyManager.notificationInviteCategory].prp()

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = text
        content.sound = MusicBox.shared.getNotificationSound()
        content.categoryIdentifier = NotifyManager.notificationInviteCategory
        content.userInfo = [
            "jid": jid,
            "owner": owner,
        ]
        
        
        
        let trigger = UNTimeIntervalNotificationTrigger.init(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: notifyId, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().delegate = (UIApplication.shared.delegate as! UNUserNotificationCenterDelegate)
        UNUserNotificationCenter.current().add(request) {
            error in
            DDLogDebug("cant show notify \(NotifyManager.notificationInviteCategory): \(error?.localizedDescription ?? "")")
        }
    }
    
    func update(withMessage message: String,
                messageId Id: String,
                username: String?,
                opponent: String,
                owner: String,
                date: Date = Date(),
                displayName: String = "",
                imageUrl: String? = nil,
                conversationType: ClientSynchronizationManager.ConversationType) {
        if self.isMuted(forOwner: owner, contact: opponent, conversationType: conversationType) {
            return
        }
        do {
            let realm = try WRealm.safe()
            if realm
                .object(ofType: ShowedNotificationRequests.self,
                        forPrimaryKey: ShowedNotificationRequests.genPrimary(stanzaId: Id, owner: owner)) != nil {
                return
            }
        } catch {
            DDLogDebug("NotifyManager: \(#function). \(error.localizedDescription)")
        }
        if date.timeIntervalSinceReferenceDate > self.message.timestamp && Id != self.message.Id {
            if !self.message.showed {
                self.showNotify(forType: .newMessage)
            }
            self.message.to = opponent
            self.message.from = owner
            self.message.message = message
            self.message.timestamp = date.timeIntervalSinceReferenceDate
            self.message.Id = Id
//            print(Id)
            self.message.showed = false
            self.message.displayName = displayName
            self.message.username = username
            self.message.imageUrl = imageUrl
            self.message.conversationType = conversationType.rawValue
            self.canShowNotify = true
        }
    }

    func update(withSubscription subscription: String, opponent: String, owner: String, displayName: String, date: Date = Date()) {
        if self.isMuted(forOwner: owner, contact: opponent, conversationType: .omemo) {
            return
        }
        if date.timeIntervalSinceReferenceDate > self.message.timestamp {
            self.subscription.to = opponent
            self.subscription.from = owner
            self.subscription.message = subscription
            self.subscription.displayName = displayName
            self.subscription.timestamp = date.timeIntervalSinceReferenceDate
            self.showNotify(forType: .subscription)
        }
    }

    func update(withNewResource resource: String, opponent: String, owner: String, date: Date = Date()) {
        if self.isMuted(forOwner: owner, contact: opponent, conversationType: .omemo) {
            return
        }
        if date.timeIntervalSinceReferenceDate > self.message.timestamp {
            self.newResource.to = opponent
            self.newResource.from = owner
            self.newResource.message = resource
            self.newResource.timestamp = date.timeIntervalSinceReferenceDate
            self.showNotify(forType: .newResourceDetect)
        }
    }

    func update(withContactOnline online: String, opponent: String, owner: String, date: Date = Date()) {
//        if self.muteList.contains(MuteItem(fromJid: from, toJid: to)) {
//            return
//        }
        if self.isMuted(forOwner: owner, contact: opponent, conversationType: .omemo) {
            return
        }
        if date.timeIntervalSinceReferenceDate > self.message.timestamp {
            self.contactOnline.to = opponent
            self.contactOnline.from = owner
            self.contactOnline.message = online
            self.contactOnline.timestamp = date.timeIntervalSinceReferenceDate
            self.showNotify(forType: .contactGoOnline)
        }
    }

    func update(withContactOffline offline: String, opponent: String, owner: String, date: Date = Date()) {
//        if self.muteList.contains(MuteItem(fromJid: from, toJid: to)) {
//            return
//        }
        if self.isMuted(forOwner: owner, contact: opponent, conversationType: .omemo) {
            return
        }
        if date.timeIntervalSinceReferenceDate > self.message.timestamp {
            self.contactOffline.to = opponent
            self.contactOffline.from = owner
            self.contactOffline.message = offline
            self.contactOffline.timestamp = date.timeIntervalSinceReferenceDate
            self.showNotify(forType: .contactGoOffline)
        }
    }
    
    func update(withVerificationMessage message: String, owner: String, displayName: String, sid: String, timestamp: TimeInterval) {
        self.verification.message = message
        self.verification.displayName = displayName
        self.verification.timestamp = timestamp
        self.verification.Id = sid
        self.verification.owner = owner
        self.showNotify(forType: .verification)
    }

    func showNotify(forType type: NotifyType) {
        let content = UNMutableNotificationContent()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        var notificationRequest = ""
        switch type {
        case .newMessage:
            if self.message.showed {
                return
            }
            DDLogDebug("notify of new message")
            self.message.showed = true
            if let currentDialog = currentDialog,
                [message.to, message.from].prp() == currentDialog {
                return
            }
            content.threadIdentifier = [message.from, message.to].prp()
            content.categoryIdentifier = NotifyManager.notificationMessageCategory
            if let uri = message.imageUrl,
                let url = URL(string: uri),
                let data = try? Data(contentsOf: url),
                let image = UIImage(data: data),
                let attachment = UNNotificationAttachment
                    .create(identifier: url.lastPathComponent,
                            image: image,
                            options: nil) {
                    content.attachments = [attachment]
                }
            
            content.userInfo = [
                "owner":  self.message.from,
                "jid": self.message.to,
                "stanzaId": self.message.Id,
                "timestamp": Date().timeIntervalSinceReferenceDate,
                "conversation_type": self.message.conversationType
            ]
            content.title = ["📱", self.message.displayName].joined(separator: " ")
            if let username = self.message.username {
                content.subtitle = username
            }
            content.body = self.message.message
            content.sound = MusicBox.shared.getNotificationSound(for: .newMessage)
            notificationRequest = self.message.Id
            break
        case .subscription:
            DDLogDebug("notify of new subscription")
            if self.subscription.showed {
                return
            }
            content.categoryIdentifier = NotifyManager.notificationSubscribtionCategory
            content.userInfo = [
                "owner": self.subscription.from,
                "jid": self.subscription.to
            ]
            content.title = self.subscription.displayName
            //content.subtitle = "📱"
            content.body = "Contact \(self.subscription.to) wants to add you to contact list".localizeString(id: "desktop_notifications_add_you_to_contact", arguments: ["\(self.subscription.to)"])
            content.sound = MusicBox.shared.getNotificationSound(for: .subscription)
            notificationRequest = [subscription.to, subscription.from, NotifyManager.notificationMessageCategory].prp()
            //self.subscription.showed = true
            break
        case .newResourceDetect:
            DDLogDebug("notify of new resource detect")
            break
        case .contactGoOnline:
            DDLogDebug("notify of some contact go online")
            break
        case .contactGoOffline:
            DDLogDebug("notify of some contact go offline")
            break
        case .verification:
            DDLogDebug("notify of verification message")
            content.categoryIdentifier = NotifyManager.notificationVerificationCategory
            content.userInfo = [
                "owner": self.verification.owner!,
                "sid": self.verification.Id
            ]
            content.title = self.verification.displayName
            content.body = self.verification.message
            content.sound = MusicBox.shared.getNotificationSound(for: .newMessage)
            notificationRequest = self.verification.Id
            break
        }
        let trigger = UNTimeIntervalNotificationTrigger.init(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: notificationRequest, content: content, trigger: trigger)
        DispatchQueue.main.async {
            
            UNUserNotificationCenter.current().getDeliveredNotifications { (notifications) in
//                print(notifications.compactMap({ return $0.request.content.userInfo }))
//                print(request.content.userInfo)
                if !notifications.compactMap({ $0.request.content.userInfo["stanzaId"] as? String }).contains(request.content.userInfo["stanzaId"] as? String ?? "none"),
                !self.deliveredNotificationsIds.contains(request.content.userInfo["stanzaId"] as? String ?? "none") {
                    UNUserNotificationCenter.current().add(request) {
                        error in
                        if error != nil {
                            DDLogDebug("cant show notify \(notificationRequest): \(error?.localizedDescription ?? "")")
                            return
                        }
                    }
                }
            }
//            UNUserNotificationCenter.current().add(request) {
//                error in
//                DDLogDebug("cant show notify \(notificationRequest): \(error?.localizedDescription ?? "")")
//            }
        }
    }
    
    func showSimpleNotify(withTitle title: String, subtitle: String, body: String) {
        let content = UNMutableNotificationContent()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        var notificationRequest = "simpleNotify \(UUID().uuidString)"
        content.title = title
        content.subtitle = subtitle
        content.body = "\(body)\n\(dateFormatter.string(from: Date()))"
        let trigger = UNTimeIntervalNotificationTrigger.init(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: notificationRequest, content: content, trigger: trigger)
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().delegate = (UIApplication.shared.delegate as! UNUserNotificationCenterDelegate)
            UNUserNotificationCenter.current().add(request) {
                error in
                DDLogDebug("cant show notify \(notificationRequest): \(error?.localizedDescription ?? "")")
            }
        }
    }
        
    func isManuallyMuted(forOwner owner: String, contact: String, conversationType: ClientSynchronizationManager.ConversationType) -> Bool {
        do {
            let realm = try WRealm.safe()
            if let settings = realm.object(ofType: NotifyPersonalStorageItem.self, forPrimaryKey: owner) {
                if settings.muteAll {
                    return true
                } else if let chatItem = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: contact,
                        owner: owner,
                        conversationType: conversationType
                    )) {
                    return chatItem.isMuted
                }
            }
        } catch {
            DDLogDebug("cant get personal settings for \(owner)")
        }
        return false
    }
    
    func isMuted(forOwner owner: String, contact: String, conversationType: ClientSynchronizationManager.ConversationType) -> Bool {
        do {
            let realm = try WRealm.safe()
            if let chatItem = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: contact,
                    owner: owner,
                    conversationType: conversationType
                )) {
                return chatItem.isMuted
            }
        } catch {
            DDLogDebug("cant get personal settings for \(owner)")
        }
        return false
    }
    
    func muteAll(forOwner owner: String) {
        do {
            let realm = try WRealm.safe()
            if let settings = realm.object(ofType: NotifyPersonalStorageItem.self, forPrimaryKey: owner) {
                try realm.write {
                    settings.muteAll = true
                }
            } else {
                let newSettings = NotifyPersonalStorageItem()
                newSettings.muteAll = true
                newSettings.owner = owner
                try realm.write {
                    realm.add(newSettings)
                }
            }
        } catch {
            DDLogDebug("cant get personal settings for \(owner)")
        }
    }
    
    func unmuteAll(forOwner owner: String) {
        do {
            let realm = try WRealm.safe()
            if let settings = realm.object(ofType: NotifyPersonalStorageItem.self, forPrimaryKey: owner) {
                try realm.write {
                    settings.muteAll = false
                }
            }
        } catch {
            DDLogDebug("cant get personal settings for \(owner)")
        }
    }
    
    func isMutedAll(forOwner owner: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            if let settings = realm.object(ofType: NotifyPersonalStorageItem.self, forPrimaryKey: owner) {
                return settings.muteAll
            }
        } catch {
            DDLogDebug("cant get personal settings for \(owner)")
        }
        return false
    }
    
    func clearNotifications(jid: String, owner: String) {
        DispatchQueue.main.async {
            UNUserNotificationCenter
                .current()
                .getDeliveredNotifications { (notifications) in
                let ids = notifications
                    .filter({ ($0.request.content.userInfo["jid"] as? String) == jid && ($0.request.content.userInfo["owner"] as? String) == owner })
                    .compactMap({ return $0.request.identifier })
                    
                UNUserNotificationCenter
                    .current()
                    .removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }
    
    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    
    func clearNotificationsFor(account jid: String) {
        DispatchQueue.main.async {
            UNUserNotificationCenter
                .current()
                .getDeliveredNotifications { (notifications) in
                    let identifiers = notifications
                        .filter({ $0.request.content.userInfo["owner"] as? String == jid })
                        .compactMap{ return $0.request.identifier }
                    UNUserNotificationCenter
                        .current()
                        .removeDeliveredNotifications(withIdentifiers: identifiers)
                }
        }
        clearUncategorizedNotifications()
    }
    
    func clearUncategorizedNotifications() {
        DispatchQueue.main.async {
            UNUserNotificationCenter
                .current()
                .getDeliveredNotifications { (notifications) in
                    let identifiers = notifications
                        .filter{ !NotifyManager.notificationCategories.contains($0.request.content.categoryIdentifier) }
                        .compactMap{ return $0.request.identifier }
                    UNUserNotificationCenter
                        .current()
                        .removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }
    
    func clearNotifications(for timestamp: TimeInterval, owner: String, jid: String) {
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().getDeliveredNotifications { (notifications) in
                    UNUserNotificationCenter
                        .current()
                        .removeDeliveredNotifications(
                            withIdentifiers: notifications
                                .filter({ $0.request.content.userInfo["jid"] as? String == jid && $0.request.content.userInfo["owner"] as? String == owner })
                                .filter({ $0.request.content.userInfo["timestamp"] as? TimeInterval ?? 0 < timestamp })
                                .compactMap({ $0.request.identifier })
                    )
            }
        }
    }
    
    func clearNotifications(forMessage stanzaIds: [String]) {
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().getDeliveredNotifications { (notifications) in
                var identifiers: [String] = []
                stanzaIds.forEach {
                    stanzaId in
                    if let userInfo = notifications.first(where: { return $0.request.content.userInfo["stanzaId"] as? String == stanzaId })?.request.content.userInfo,
                        let timestamp = userInfo["timestamp"] as? TimeInterval,
                        let jid = userInfo["jid"] as? String,
                        let owner = userInfo["owner"] as? String {
                        identifiers.append(contentsOf: notifications
                            .filter{ $0.request.content.userInfo["jid"] as? String == jid && $0.request.content.userInfo["owner"] as? String == owner }
                            .filter{ $0.request.content.userInfo["timestamp"] as? TimeInterval ?? 0 <= timestamp }
                            .compactMap{ $0.request.identifier })
                        
                    }
                    
                }
            identifiers.append(contentsOf: notifications
                .filter{ !NotifyManager.notificationCategories
                    .contains($0.request.content.categoryIdentifier) }
                .compactMap{ return $0.request.identifier })
             
            UNUserNotificationCenter
                .current()
                .removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }
    
    public final func onMarkAsReadMessageNotification(response: UNNotificationResponse, handler completionHandler: (() -> Void)? = nil) -> Bool {
        let userInfo = response.notification.request.content.userInfo
        guard let owner = userInfo["owner"] as? String,
            let jid = userInfo["jid"] as? String,
            let stanzaId = userInfo["stanzaId"]  as? String,
            let stanza = userInfo["stanza"] as? String,
            let document = try? DDXMLDocument(xmlString: stanza, options: 0),
            let message = document.rootElement() else {
                completionHandler?()
                return false
        }
        
        let displayed = DDXMLElement(name: "displayed", xmlns: "urn:xmpp:chat-markers:0")
        displayed.addAttribute(withName: "id", stringValue: stanzaId)
        let bareMessage = getArchivedMessageContainer(XMPPMessage(from: message))
        bareMessage?
            .elements(forName: "stanza-id")
            .forEach { displayed.addChild($0.copy() as! DDXMLElement) }
        
        let response = XMPPMessage(messageType: .chat,
                                   to: XMPPJID(string: jid),
                                   elementID: UUID().uuidString,
                                   child: displayed)
        XMPPActionManager.shared.sendStanzas(jid: owner, stanzas: [response])
        return true
    }
    
    public final func onReplyMessageNotification(response: UNNotificationResponse, handler completionHandler: (() -> Void)? = nil) -> Bool {
        let userInfo = response.notification.request.content.userInfo
        guard let owner = userInfo["owner"] as? String,
            let jid = userInfo["jid"] as? String,
            let textResponse = response as? UNTextInputNotificationResponse
            else {
                completionHandler?()
                return false
        }
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: jid), elementID: UUID().uuidString, child: nil)
        message.addOriginId(UUID().uuidString)
        message.addBody(textResponse.userText)
        XMPPActionManager.shared.sendStanzas(jid: owner, stanzas: [message])
        completionHandler?()
        return true
    }
    
    public final func onSubscribeContactNotification(response: UNNotificationResponse, handler completionHandler: (() -> Void)? = nil) -> Bool {
        let userInfo = response.notification.request.content.userInfo
        guard let owner = userInfo["owner"] as? String,
            let jid = userInfo["jid"] as? String else {
                completionHandler?()
                return false
        }
        let subscribe = XMPPPresence(type: .subscribe, to: XMPPJID(string: jid))
        let subscribed = XMPPPresence(type: .subscribed, to: XMPPJID(string: jid))
        XMPPActionManager.shared.sendStanzas(jid: owner, stanzas: [subscribe, subscribed])
        completionHandler?()
        return true
    }
    
    public final func onUnsubscribeContactNotification(response: UNNotificationResponse, handler completionHandler: (() -> Void)? = nil) -> Bool {
        let userInfo = response.notification.request.content.userInfo
        guard let owner = userInfo["owner"] as? String,
            let jid = userInfo["jid"] as? String else {
                completionHandler?()
                return false
        }
        let unsubscribe = XMPPPresence(type: .unsubscribe, to: XMPPJID(string: jid))
        let unsubscribed = XMPPPresence(type: .unsubscribe, to: XMPPJID(string: jid))
        let block = DDXMLElement(name: "block", xmlns: "urn:xmpp:blocking")
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "jid", stringValue: jid)
        block.addChild(item)
        let blockIq = XMPPIQ(iqType: .set, to: nil, elementID: UUID().uuidString, child: block)
        XMPPActionManager.shared.sendStanzas(jid: owner, stanzas: [unsubscribe, unsubscribed, blockIq])
        completionHandler?()
        return true
    }
    
    public final func onJoinGroupNotification(response: UNNotificationResponse, handler completionHandler: (() -> Void)? = nil) -> Bool {
        let userInfo = response.notification.request.content.userInfo
        guard let owner = userInfo["owner"] as? String,
            let jid = userInfo["groupchat"] as? String else {
                completionHandler?()
                return false
        }
        let subscribe = XMPPPresence(type: .subscribe, to: XMPPJID(string: jid))
        XMPPActionManager.shared.sendStanzas(jid: owner, stanzas: [subscribe])
        completionHandler?()
        return true
    }
    
    public final func onDeclineGroupNotification(response: UNNotificationResponse, handler completionHandler: (() -> Void)? = nil) -> Bool {
        let userInfo = response.notification.request.content.userInfo
        guard let owner = userInfo["owner"] as? String,
            let jid = userInfo["groupchat"] as? String else {
                completionHandler?()
                return false
        }
        let unsubscribe = XMPPPresence(type: .unsubscribe, to: XMPPJID(string: jid))
        let unsubscribed = XMPPPresence(type: .unsubscribe, to: XMPPJID(string: jid))
        XMPPActionManager.shared.sendStanzas(jid: owner, stanzas: [unsubscribe, unsubscribed])
        completionHandler?()
        return true
    }
    
    public final func onTouchMessageNotification(userInfo: [AnyHashable: Any], atStart: Bool, handler completionHandler: (() -> Void)? = nil) {
        guard let owner = userInfo["owner"] as? String,
            let jid = userInfo["jid"] as? String,
            jid != owner else {
                completionHandler?()
                return
        }
        
        if let stanzaId = userInfo["stanzaId"]  as? String,
            let stanza = userInfo["stanza"] as? String,
            let document = try? DDXMLDocument(xmlString: stanza, options: 0),
            let message = document.rootElement() {
            let displayed = DDXMLElement(name: "displayed", xmlns: "urn:xmpp:chat-markers:0")
            displayed.addAttribute(withName: "id", stringValue: stanzaId)
            let bareMessage = getArchivedMessageContainer(XMPPMessage(from: message))
            bareMessage?
                .elements(forName: "stanza-id")
                .forEach { displayed.addChild($0.copy() as! DDXMLElement) }
            
            let response = XMPPMessage(messageType: .chat,
                                       to: XMPPJID(string: jid),
                                       elementID: UUID().uuidString,
                                       child: displayed)
            XMPPActionManager.shared.sendStanzas(jid: owner, stanzas: [response])
        }
        
        var isGroupchat: Bool = false
        var isIncognito: Bool = false
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: GroupChatStorageItem.self,
                                           forPrimaryKey: [jid, owner].prp()) {
                isGroupchat = true
                isIncognito = instance.privacy == .incognito
            } else {
                print(userInfo)
                if let stanza = userInfo["stanza"] as? String,
                   let document = try? DDXMLDocument(xmlString: stanza, options: 0),
                   let message = document.rootElement(),
                   let bareMessage = getArchivedMessageContainer(XMPPMessage(from: message)) {
                    print("bareMessage", bareMessage.prettyXMLString!)
                }
                if let stanza = userInfo["stanza"] as? String,
                   let document = try? DDXMLDocument(xmlString: stanza, options: 0),
                   let message = document.rootElement(),
                   let bareMessage = getArchivedMessageContainer(XMPPMessage(from: message)),
                   let x = bareMessage.element(forName: "x", xmlns: GroupchatManager.staticGetNamespace() + "#system-message"),
                   let privacy = x.element(forName: "privacy", xmlns: GroupchatManager.staticGetNamespace())?.stringValue {
                    isGroupchat = true
                    isIncognito = privacy == "incognito"
                    print("isIncognito", isIncognito)
                }
            }

        } catch {
            DDLogDebug("NotifyManager: \(#function). \(error.localizedDescription)")
        }
        
        var entity: RosterItemEntity = isGroupchat ? (isIncognito ? .incognitoChat : .groupchat) : RosterItemEntity.contact
        var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        if let invite_kind = userInfo["invite_kind"] as? String {
            switch invite_kind {
            case "group":
                entity = .groupchat
                conversationType = .group
            case "incognito":
                entity = .incognitoChat
                conversationType = .group
            case "peer-to-peer":
                entity = .privateChat
                conversationType = .group
            default: break
            }
        }
        
        if let conversationTypeRaw = userInfo["conversation_type"] as? String {
            conversationType = ClientSynchronizationManager.ConversationType(rawValue: conversationTypeRaw) ?? .omemo
        }
        
        if UIApplication.shared.applicationState == .active {
            getAppTabBar()?.displayChat(
                owner: owner,
                jid: jid,
                entity: entity,
                conversationType: conversationType
            )
            completionHandler?()
        } else {
            if atStart {
                self.openViewControllerPayload = ["owner": owner, "jid": jid, "action": "initialChat"]
            } else {
                self.openViewControllerPayload = ["owner": owner, "jid": jid, "action": "foregroundChat"]
                getAppTabBar()?.displayChat(
                    owner: owner,
                    jid: jid,
                    entity: entity,
                    conversationType: conversationType
                )
                completionHandler?()
            }
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: jid,
                        owner: owner,
                        conversationType: conversationType
                    )) {
                    try realm.write {
                        if !instance.isSynced {
                            instance.isPrereaded = true
                        }
                        instance.unread = 0
                    }
                }
            } catch {
                DDLogDebug("NotifyManager: \(#function). \(error.localizedDescription)")
            }
            
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { (_) in
                completionHandler?()
            }
        }
    }
    
    public final func onTouchVerificationNotification(userInfo: [AnyHashable: Any], handler completionHandler: (() -> Void)? = nil) {
        guard let owner = userInfo["owner"] as? String,
              let sid = userInfo["sid"] as? String else {
            fatalError()
        }
        
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid)),
                  let akeManager = AccountManager.shared.find(for: owner)?.akeManager,
                  let presenter = (UIApplication.shared.delegate as? AppDelegate)?.splitController else {
                return
            }
            
            var isVerificationWithUsersDevice = false
            if instance.jid == owner {
                isVerificationWithUsersDevice = true
            }
            
            switch instance.state {
            case VerificationSessionStorageItem.VerififcationState.receivedRequest:
                let agreeAction = UIAlertAction(title: "Accept", style: UIAlertAction.Style.default) { action in
                    guard let code = akeManager.acceptVerificationRequest(jid: instance.jid, sid: sid) else {
                        return
                    }
                    let vc = ShowCodeViewController(owner: owner, jid: instance.jid, code: code, sid: sid, isVerificationWithUsersDevice: isVerificationWithUsersDevice)
                    vc.configure()
                    presenter.present(vc, animated: true)
                }
                let disagreeAction = UIAlertAction(title: "Reject", style: .destructive) { action in
                    akeManager.rejectRequestToVerify(jid: instance.jid, sid: sid)
                }
                let alert = UIAlertController(title: "Verification session", message: "Do you want to accept verification request from \(instance.jid)?", preferredStyle: UIAlertController.Style.alert)
                alert.addAction(agreeAction)
                alert.addAction(disagreeAction)
                
                presenter.present(alert, animated: true)
                break
            case VerificationSessionStorageItem.VerififcationState.acceptedRequest:
                let vc = ShowCodeViewController(owner: owner, jid: instance.jid, code: instance.code, sid: sid, isVerificationWithUsersDevice: isVerificationWithUsersDevice)
                vc.configure()
                presenter.present(vc, animated: true)
                break
            case VerificationSessionStorageItem.VerififcationState.receivedRequestAccept:
                let vc = AuthenticationCodeInputViewController()
                vc.configure(owner: owner, jid: instance.jid, sid: sid, isVerificationWithUsersDevice: isVerificationWithUsersDevice)
                presenter.present(vc, animated: true)
                break
            case VerificationSessionStorageItem.VerififcationState.failed:
                akeManager.showFailedRejectedSuccessfulAlert(state: .failed, jid: instance.jid, sid: sid)
                try realm.write {
                    realm.delete(instance)
                }
                break
            case VerificationSessionStorageItem.VerififcationState.rejected:
                akeManager.showFailedRejectedSuccessfulAlert(state: .rejected, jid: instance.jid, sid: sid)
                try realm.write {
                    realm.delete(instance)
                }
                break
            case VerificationSessionStorageItem.VerififcationState.trusted:
                akeManager.showFailedRejectedSuccessfulAlert(state: .trusted, jid: instance.jid, sid: sid)
                try realm.write {
                    realm.delete(instance)
                }
                break
            default:
                break
            }
        } catch {
            fatalError()
        }
    }
    
    public final func setLastChats(displayed state: Bool) {
        lastChatsDisplayedState = state
    }
    
    public final func isLastChatsDisplayed() -> Bool {
        return lastChatsDisplayedState
    }
}

