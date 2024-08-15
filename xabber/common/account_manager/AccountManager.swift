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
import RxCocoa
import CocoaLumberjack
import SwiftKeychainWrapper
import Kingfisher

public class AccountManager: NSObject {
    
    enum Pipeline {
        case short
        case full
    }

    struct BackgroundChatUpdateTaskItem {
        let owner: String
        let jid: String
        let conversationType: ClientSynchronizationManager.ConversationType
    }
    
    struct UserObserver {
        
        enum State {
            case none
            case startConnection
            case connect
            case auth
            case capsReceived([String])
            case dataLoaded
            case failure(String)
            case streamError(String)
        }
        
        let jid: String
        let state: State
        
    }
    
    static let defaultResource = "\(CommonConfigManager.shared.config.app_name.lowercased())-ios-\(String(describing: String(describing: UIDevice.current.identifierForVendor!).split(separator: "-").first!))"
    
    var newAccountJid: String = ""
    var newAccountObservable: BehaviorRelay<UserObserver> = BehaviorRelay(value: UserObserver(jid: "", state: .none))
    
    var users: [Account]
    
    var bag: DisposeBag = DisposeBag()
    var activeUsers: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    
    var xmppBackgroundTasks: [XMPPBackgroundTask] = []

    var authenticatedUsers: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    var connectingUsers: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    
    var backgroundUpdateTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
    
    private var backgroundChatUpdateTaskItem: BackgroundChatUpdateTaskItem? = nil
    
    var alreadyLoaded: Bool = false
    
    open class var shared: AccountManager {
        struct AccountManagerSingleton {
            static let instance = AccountManager()
        }
        return AccountManagerSingleton.instance
    }

    override init() {
        self.users = []
        super.init()
        addObservers()
    }
    
    private func addObservers() {
        NotificationCenter
            .default
            .addObserver(self,
                         selector: #selector(willEnterForeground),
                         name: UIApplication.willEnterForegroundNotification,
                         object: UIApplication.shared)

        NotificationCenter
            .default
            .addObserver(self,
                         selector: #selector(willEnterBackground),
                         name: UIApplication.didEnterBackgroundNotification,
                         object: UIApplication.shared)
    }
    
    public final func prepare() {
        
    }
    
    @objc
    private func willEnterForeground() {
        self.prepareForForeground()
//        let appDelegate = UIApplication.shared.delegate as? AppDelegate
//        appDelegate?.presentPasscodeOrRemoveBlurredScreen()
    }
    
    @objc
    private func willEnterBackground() {
        self.prepareForBackground()
//        let appDelegate = UIApplication.shared.delegate as? AppDelegate
//        appDelegate?.addBlurredScreen()
        self.users.forEach {
            $0.disconnect(hard: true)
        }
        XMPPUIActionManager.shared.close(disconnect: true)
    }
    
    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
    }
    
    var updatedChats: Set<String> = Set()
    
    func addUpdatedChat(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) {
        self.updatedChats.insert([jid, owner, conversationType.rawValue].prp())
    }
    
    func checkIsChatUpdated(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) -> Bool {
        return false//self.updatedChats.contains([jid, owner, conversationType.rawValue].prp())
    }
    
    func subscribe() {
        bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
            Observable
                .collection(from: realm.objects(AccountStorageItem.self))
                .debounce(.seconds(1), scheduler: ConcurrentDispatchQueueScheduler(qos: .default))
                .subscribe(onNext: { (results) in
                    results.forEach {
                        let jid = $0.jid
                        if $0.enabled {
                            if !self.activeUsers.value.contains(jid) {
                                var value = self.activeUsers.value
                                value.insert(jid)
                                self.activeUsers.accept(value)
                            }
                        } else {
                            if self.activeUsers.value.contains(jid) {
                                var value = self.activeUsers.value
                                value.remove(jid)
                                self.activeUsers.accept(value)
                            }
                        }
                    }
                })
                .disposed(by: bag)
        } catch {
            DDLogDebug("cant create observer on account list")
        }
    }
    
    func emptyAccountsList() -> Bool {
        
        do {
            let realm = try WRealm.safe()
            return realm.objects(AccountStorageItem.self).isEmpty
        } catch {
            DDLogDebug("cant checked accounts count")
        }
        
        return true
    }
    
    func load(_ autoConnect: Bool = true) {
        do {
            let realm = try WRealm.safe()
            realm
                .objects(AccountStorageItem.self)
                .filter("enabled == %@", true)
                .toArray()
                .compactMap { return $0.jid }
                .forEach {
                    DDLogDebug("Add account \($0), autoconnect \(autoConnect)")
                    self.add(withJid: $0, autoConnect: autoConnect)
                }
            SubscribtionsManager.shared.updateXMPPAccountsState()
        } catch {
            DDLogDebug("cant load accounts list from db")
        }
    }
    
    func find(for jid: String) -> Account? {
        return users.first(where: { $0.jid == jid })
    }
    
    public final func create(jid: String, password: String, nickname: String?, isFromRegister: Bool) {
        self.newAccountJid = jid
        SettingManager.shared.clear(for: jid)
        self.changeNewUserState(for: jid, to: .none)
        let uniqueServiceName = CredentialsManager.uniqueServiceName()
        let uniqueAccessGroup = CredentialsManager.uniqueAccessGroup()
        let keychain = KeychainWrapper(serviceName: uniqueServiceName,
                                       accessGroup: uniqueAccessGroup)

        _ = keychain.removeObject(forKey: jid)
        _ = keychain.removeObject(forKey: [jid, "token"].prp())
        
        if users.contains(where: { $0.jid == jid }) { return  }
        let queue = DispatchQueue(
            label: "com.xabber.stream.\(UUID().uuidString)",
            qos: .userInitiated,
            attributes: [],//[.concurrent],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        
        CredentialsManager.shared.setItem(for: jid, password: password)
        
        self.markAsConnecting(jid: jid)
        let newAccount = Account(jid: jid, queue: queue)
        self.users.append(newAccount)
        newAccount.asyncConnect()
        
        SubscribtionsManager.shared.updateXMPPAccountsState()
        
        if let nickname = nickname {
            newAccount.username = nickname
        }
        newAccount.savePassword = true
        newAccount.useSecureConnection = true
        newAccount.resource = AccountManager.defaultResource
        newAccount.create()
        newAccount.isNewAccount = isFromRegister
    }
    
    func reloadAccount(withJid jid: String, autoConnect: Bool = true) {
        if let index = self.users.firstIndex(where: { $0.jid == jid }) {
            self.users[index].disconnect(hard: true)
            self.users.remove(at: index)
        }
        self.add(withJid: jid, autoConnect: autoConnect)
    }
    
    func add(withJid jid: String, autoConnect: Bool = true) {
        
        if find(for: jid) != nil {
            if autoConnect {
                find(for: jid)?.restore()
            }
            return
        }
        
        self.markAsConnecting(jid: jid)
        let queue = DispatchQueue(
            label: "com.xabber.stream.\(jid).\(UUID().uuidString)",
            qos: .userInitiated,
            attributes: [],//[.concurrent],
            autoreleaseFrequency: .workItem,
            target: nil
        )

        let newAccount = Account(jid: jid, queue: queue)
        self.users.append(newAccount)
        if autoConnect {
            newAccount.asyncConnect()
        }
        let jids = Set(self.users.compactMap { $0.jid })
        let connectingUsers = self.connectingUsers.value
        connectingUsers.forEach {
            jid in
            if !jids.contains(jid) {
                self.markAsConnected(jid: jid)
            }
        }
    }
    
    func isExist(jid: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            if realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) != nil {
                return false
            }
        } catch {
            DDLogDebug("cant get information about new user \(jid)")
        }
        return true
    }
    
    func enable(jid: String) {
        add(withJid: jid)
        do {
            let realm = try WRealm.safe()
            try realm.write {
                realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?.enabled = true
            }
        } catch {
            DDLogDebug("AccountManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func disable(jid: String) {
        self.find(for: jid)?.disable()
        NotifyManager.shared.clearNotificationsFor(account: jid)
        do {
            if let index = users.firstIndex(where: { $0.jid == jid }) {
                users.remove(at: index)
            }
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) {
                try realm.write {
                    instance.enabled = false
                    instance.node = ""
                    instance.service = ""
                }
            }
        } catch {
            DDLogDebug("AccountManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func deleteAccount(by jid: String, hard: Bool = true) {
        
        if XMPPUIActionManager.shared.currentJid == jid {
            XMPPUIActionManager.shared.close(soft: !hard, disconnect: true)
            XMPPUIActionManager.shared.currentJid = nil
        }
        self.xmppBackgroundTasks.filter { $0.jid == jid }.forEach {
            $0.disconnect()
            $0.endBackgroundUpdateTask()
        }
        self.find(for: jid)?.unsafeAction({ user, stream in
            CredentialsManager.shared.removePushCredentials(for: user.push.node)
            user.devices.revoke(stream, uids: [user.devices.deviceId ?? ""])
            user.disconnect(hard: hard)
        })
        changeNewUserState(for: jid, to: .none)
        NotifyManager.shared.clearNotificationsFor(account: jid)
        SettingManager.shared.clear(for: jid)
        APNSManager.shared.sendDeleteRequest(jid: jid, voip: false)
        APNSManager.shared.sendDeleteRequest(jid: jid, voip: true)
        self.find(for: jid)?.dropData()
        
        XabberUploadManager.removeToken(for: jid)
        CredentialsManager.shared.clearSignature()
        CredentialsManager.shared.clearPincodes()
        CredentialsManager.shared.removeDeviceId(for: jid)
        SignatureManager.shared.clear()
        CredentialsManager.shared.clearSignature()
        ApplicationStateManager.shared.clearApplicationBlockedState()
        if !CommonConfigManager.shared.config.supports_multiaccounts {
            CredentialsManager.shared.clearKeyachain()
        }
        
        var connecting = self.connectingUsers.value
        connecting.remove(jid)
        self.connectingUsers.accept(connecting)
        
        do {
            if let index = users.firstIndex(where: { $0.jid == jid }) {
                autoreleasepool { () -> Void in
                    users.remove(at: index)
                }
                
            }
            let realm = try WRealm.safe()
            try autoreleasepool {
                try realm.write {
                    Account.remove(for: jid, commitTransaction: false)
                    VCardManager.remove(for: jid, commitTransaction: false)
                    MessageManager.remove(for: jid, commitTransaction: false)
                    PresenceManager.remove(for: jid, commitTransaction: false)
                    XTokenManager.remove(for: jid, commitTransaction: false)
                    GroupchatManager.remove(for: jid, commitTransaction: false)
                    LastChats.remove(for: jid, commitTransaction: false)
                    ClientSynchronizationManager.remove(for: jid, commitTransaction: false)
                    BlockManager.remove(for: jid, commitTransaction: false)
                    ServerDiscoManager.remove(for: jid, commitTransaction: false)
                    RosterManager.remove(for: jid, commitTransaction: false)
                    MessageDeleteManager.remove(for: jid, commitTransaction: false)
                    ReliableMessageDeliveryManager.remove(for: jid, commitTransaction: false)
                    OmemoManager.remove(for: jid, commitTransaction: false)
                    X509XMPPManager.remove(for: jid, commitTransaction: false)
                    XMPPNotificationsManager.remove(for: jid, commitTransaction: false)
                    XMPPFavoritesManager.remove(for: jid, commitTransaction: false)
                    AuthenticatedKeyExchangeManager.remove(for: jid, commitTransaction: false)
                }
            }
        } catch {
            DDLogDebug("AccountManager: \(#function). \(error.localizedDescription)")
        }
        if let index = ApplicationStateManager.shared.expiredTokenAccountsList.firstIndex(where: { $0.jid == jid }) {
            ApplicationStateManager.shared.expiredTokenAccountsList.remove(at: index)
        }
//        ApplicationStateManager.shared.expiredTokenAccountsList.remove(jid)
    }
    
    func changeNewUserState(for jid: String, to state: UserObserver.State) {
        if jid == newAccountJid {
            if newAccountJid.isNotEmpty {
                newAccountObservable.accept(UserObserver(jid: jid, state: state))
            }
        }
    }
    
    final func markAsConnected(jid: String) {
        RunLoop.main.perform {
            var value = self.connectingUsers.value
            value.remove(jid)
            self.connectingUsers.accept(value)
        }
        if newAccountJid == jid {
            self.find(for: jid)?.queue.asyncAfter(deadline: .now() + 2) {
                self.newAccountJid = ""
            }
        }
    }
    
    final func markAsAuthencticated(jid: String) {
        RunLoop.main.perform {
            var value = self.authenticatedUsers.value
            value.remove(jid)
            self.authenticatedUsers.accept(value)
        }
    }
    
    final func markAsConnecting(jid: String) {
        RunLoop.main.perform {
            var value = self.connectingUsers.value
            value.insert(jid)
            self.connectingUsers.accept(value)
        }
        RunLoop.main.perform {
            var value = self.authenticatedUsers.value
            value.insert(jid)
            self.authenticatedUsers.accept(value)
        }
    }
    
    final func prepareForForeground() {
        load()
    }
    
    final func prepareForBackground() {
        NotifyManager.shared.clearAllNotifications()
        NotifyManager.shared.setLastChats(displayed: false)
    }
    
    public final func tokenCounterIsIncorrect(jid: String) {
        
    }
    
    public final func tokenRevoked(jid: String) {
        
    }
}
