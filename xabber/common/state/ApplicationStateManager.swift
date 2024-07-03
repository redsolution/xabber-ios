//
//  ApplicationStateManager.swift
//  clandestino
//
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
import UIKit
import SwiftKeychainWrapper
import Alamofire
import RealmSwift
import CocoaLumberjack
import XMPPFramework.XMPPJID
import AVFoundation



class ApplicationStateManager: NSObject {
    
    open class var shared: ApplicationStateManager {
        struct ApplicationStateManagerSingleton {
            static let instance = ApplicationStateManager()
        }
        return ApplicationStateManagerSingleton.instance
    }
    
    enum State: Int {
        case unsecure = 0
        case unlocked
        case unsigned
        case locked
    }
    
    fileprivate var pincodeTaskTimer: Timer? = nil
    fileprivate var appState: State = .unsecure
    var isPincodeShowed: Bool = false
    var isSubscribtionsShowed: Bool = false
    
    var isApplicationBlockedState: Bool = false
    
    var period: TimeInterval = 0
    
    class ExpiredTokenAccountItem: Equatable, Hashable {
        static func == (lhs: ApplicationStateManager.ExpiredTokenAccountItem, rhs: ApplicationStateManager.ExpiredTokenAccountItem) -> Bool {
            return lhs.jid == rhs.jid
        }
        
        var jid: String
        var retryRemained: Int = 0
        
        init(jid: String) {
            self.jid = jid
            retryRemained = 3
        }
        
        func canRetry() -> Bool {
            self.retryRemained = self.retryRemained - 1
            return self.retryRemained > 0
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(jid)
        }
    }
    
    static let tokenWasExpired = Notification.Name("com.xabber.device.expired")
    public var expiredTokenAccountsList: Array<ExpiredTokenAccountItem> = Array<ExpiredTokenAccountItem>()
    
    public var state: State {
        get {
            return appState
        }
    }
    
    override init() {
        super.init()
        self.period = TimeInterval(SettingManager.shared.getInt(for: "", scope: .security, key: "passcode_timer"))
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: ApplicationStateManager.tokenWasExpired, object: nil)
    }
    
    private final func addObservers() {
        NotificationCenter
            .default
            .addObserver(
                self,
                selector: #selector(self.didReceiveDeviceExpireNotification),
                name: ApplicationStateManager.tokenWasExpired,
                object: nil
            )
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(showVerificationConfirmationViewController(_:)),
                                               name: NSNotification.Name(rawValue: "received_VerificationConfirmationViewController"),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(verificationSucceded(_:)),
                                               name: NSNotification.Name(rawValue: "show_success"),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(showAuthenticationCodeInputViewController(_:)),
                                               name: NSNotification.Name(rawValue: "show_AuthenticationCodeInputViewController"),
                                               object: nil)
    }
    
    public final func getApplicationBlockedDate() -> Date? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        if let ts = keychain.double(forKey: "application_blocked_date") {
            return Date(timeIntervalSince1970: ts)
        }
        return nil
    }
    
    public final func isApplicationBlocked() -> Bool {
        return isApplicationBlockedState
//        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
//                                       accessGroup: CredentialsManager.uniqueAccessGroup())
//        return keychain.bool(forKey: "application_blocked") ?? false
    }
    
    public final func unblockApplication(date: Date) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
//        _ = keychain.set(false, forKey: "application_blocked", withAccessibility: .always)
        self.isApplicationBlockedState = false
        _ = keychain.set(date.timeIntervalSince1970, forKey: "application_blocked_date")
    }
    
    public final func clearApplicationBlockedState() {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
//        _ = keychain.set(false, forKey: "application_blocked", withAccessibility: .always)
        self.isApplicationBlockedState = false
        self.isSubscribtionsShowed = false
        keychain.removeObject(forKey: "application_blocked_date")
    }
    
    public final func blockApplication(date: Date) {
        preBlockApplication()
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
//        _ = keychain.set(true, forKey: "application_blocked", withAccessibility: .always)
        self.isApplicationBlockedState = true
        _ = keychain.set(date.timeIntervalSince1970, forKey: "application_blocked_date")
        postBlockApplication()
    }
    
    private final func preBlockApplication() {
        if !isApplicationBlocked() {
            DispatchQueue.main.async {
                SubscribtionsPresenter().present(animated: true)
            }
        }
    }
    
    private final func postBlockApplication() {
        
    }

    private final func tokenWasInvalidated(for jid: String) {
        func show() {
            XTokenInvalidatePresenter().present(
                jid: jid,
                title: "Access revoked".localizeString(id: "account_access_revoke", arguments: []),
                message: "Access to account \(jid) was revoked. Locally stored data deleted.".localizeString(id: "account_access_to_account_was_revoked", arguments: [jid]),
                animated: true,
                completion: nil
            )
        }
        AccountManager.shared.deleteAccount(by: jid)
        DispatchQueue.main.async {
            if AccountManager.shared.emptyAccountsList() {
                (UIApplication.shared.delegate as? AppDelegate)?.setupRootViewController()
                show()
            } else {
                show()
            }
        }
    }
    
    @objc
    private final func didReceiveDeviceExpireNotification(_ notification: Notification) {
        guard let jid = notification.object as? String else {
            return
        }
        self.tokenWasInvalidated(for: jid)
//        if let index = self.expiredTokenAccountsList.firstIndex(where: { $0.jid == jid }) {
//            if !self.expiredTokenAccountsList[index].canRetry() {
//                self.tokenWasInvalidated(for: jid)
//            }
//        } else {
//            self.expiredTokenAccountsList.append(ExpiredTokenAccountItem(jid: jid))
//        }
    }
    
    @objc
    func showVerificationConfirmationViewController(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            let sid = userInfo["sid"] as! String
            let deviceId = userInfo["device-id"] as! String
            
            var isVerificationWithOwnDevice = false
            
            let jids = AccountManager.shared.users.compactMap { return $0.jid }
            
            do {
                let realm = try WRealm.safe()
                
                for owner in jids {
                    let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid))
                    if instance != nil {
                        if instance!.jid == owner {
                            isVerificationWithOwnDevice = true
                        }
                        let jid = instance!.jid
                        
                        let vc = VerificationConfirmationViewController()
                        vc.owner = owner
                        vc.jid = jid
                        vc.sid = sid
                        vc.deviceId = deviceId
                        vc.isVerificationWithOwnDevice = isVerificationWithOwnDevice

                        showModal(vc, replaceParent: false)
                    }
                }
            } catch {
                DDLogDebug("ApplicationStateManager: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    @objc
    func showAuthenticationCodeInputViewController(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            let owner = userInfo["owner"] as! String
            let jid = userInfo["jid"] as! String
            let sid = userInfo["sid"] as! String
            let vc = AuthenticationCodeInputViewController()
            vc.owner = owner
            vc.jid = jid
            vc.sid = sid
            vc.isVerificationWithUsersDevice = owner == jid ? true : false
            
            showModal(vc, replaceParent: false)
        }
    }
    
    @objc
    func verificationSucceded(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            guard let owner = userInfo["owner"] as? String,
                  let deviceId = userInfo["deviceId"] as? String,
                  let jid = userInfo["jid"] as? String else {
                return
            }
            
            do {
                let realm = try WRealm.safe()
                let instance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND opponentDeviceId == %@", owner, Int(deviceId) ?? -1).first
                if instance?.state != .trusted {
                    return
                }
            } catch {
                DDLogDebug("ApplicationStateManager: \(#function). \(error.localizedDescription)")
                return
            }
            
            DispatchQueue.main.async {
                let vc = SuccessfulVerificationViewController()
                vc.owner = owner
                vc.jid = jid
                vc.deviceId = deviceId
                
                showModal(vc, replaceParent: false)
            }
        }
    }
    
    public final func prepare() {
        addObservers()
        VoIPManager.shared.prepare()
        SignatureManager.shared.prepare()
        SubscribtionsManager.shared.prepare()
        AccountColorManager.shared.load()
        DefaultAvatarManager.shared.preheat()
        MusicBox.shared.prepare()
        TranslationsManager.shared.prepare()
        NotifyManager.shared.clearAllNotifications()
        if AccountMasksManager.shared.load() == nil {
            if let mask = AccountMasksManager.shared.masksList().first {
                AccountMasksManager.shared.save(mask: mask)
            }
        }
        if CommonConfigManager.shared.config.required_touch_id_or_password {
            self.runPincodeTask()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
            if #available(iOS 13.0, *) {
                try? AVAudioSession
                    .sharedInstance()
                    .setAllowHapticsAndSystemSoundsDuringRecording(true)
            }
        }
        self.runAutoDeleteTask()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            AuthenticatedKeyExchangeManager.prepare()
        }
    }
    
    var autoDeleteTaskTimer: Timer? = nil
    func runAutoDeleteTask() {
        if CommonConfigManager.shared.config.auto_delete_messages_interval > 0 {
            if self.autoDeleteTaskTimer != nil {
                self.autoDeleteTaskTimer?.fire()
                self.autoDeleteTaskTimer?.invalidate()
                self.autoDeleteTaskTimer = nil
            }
            self.autoDeleteTask()
            self.autoDeleteTaskTimer = Timer.scheduledTimer(
                timeInterval: 60,
                target: self,
                selector: #selector(autoDeleteTask),
                userInfo: nil,
                repeats: true
            )
            RunLoop.current.add(self.autoDeleteTaskTimer!, forMode: .default)
        }
    }
    
    @objc
    func autoDeleteTask() {
        do {
            let realm = try WRealm.safe()
            let jids = AccountManager.shared.users.compactMap { return $0.jid }
            try jids.forEach {
                owner in
                let oldMessagesCollection = realm
                    .objects(MessageStorageItem.self)
                    .filter(
                        "owner == %@ and opponent != %@ AND date < %@ AND messageType != %@ AND isDeleted == false",
                        owner,
                        XMPPJID(string: owner)?.domain ?? "",
                        Date(timeIntervalSince1970: Date().timeIntervalSince1970 - Double(CommonConfigManager.shared.config.auto_delete_messages_interval)),
                        MessageStorageItem.MessageDisplayType.initial.rawValue
                    )
                if oldMessagesCollection.isEmpty {
                    return
                }
                var jids: Set<String> = Set<String>()
                oldMessagesCollection.forEach {
                    jids.insert($0.opponent)
                }
                
                let chats = realm.objects(LastChatsStorageItem.self).filter("owner == %@ AND jid IN %@", owner, Array(jids))
                
                try realm.write {
                    oldMessagesCollection.forEach {
                        $0.isDeleted = true
                        $0.body = ""
                        $0.legacyBody = ""
                    }
                    
                    chats.forEach {
                        let lastMessage = realm
                            .objects(MessageStorageItem.self)
                            .filter("owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@", owner, $0.jid, $0.conversationType_)
                            .sorted(byKeyPath: "date", ascending: false)
                            .first
                        $0.lastMessage = lastMessage
//                        $0.lastMessageId = lastMessage?.messageId ?? ""
                    }
                }
            }
        } catch {
            DDLogDebug("ApplicationStateManager: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    private final func runPincodeTask() {
        if self.period == 0 {
            self.pincodeTaskTimer?.invalidate()
            self.pincodeTaskTimer = nil
            return
        }
        self.pincodeTaskTimer?.invalidate()
        self.pincodeTaskTimer = nil
        self.pincodeTaskTimer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(self.pincodeTask),
            userInfo: nil,
            repeats: true
        )
    }
    
    @objc
    private func pincodeTask(_ sender: AnyObject) {
        runPincodeTask(animated: true)
    }
    
    public final func runPincodeTask(animated: Bool, force: Bool = false) {
        if !CredentialsManager.shared.isPincodeSetted() {
            return
        }
        switch self.state {
        case .unsecure:
            if CommonConfigManager.shared.config.required_touch_id_or_password {
                if AccountManager.shared.users.isNotEmpty {
                    if (Date().timeIntervalSince1970 -  CredentialsManager.shared.getPincodeTimestamp() > self.period) || force {
                        self.appState = .locked
                        self.showPincodeScreen(animated: animated)
                    } else {
                        self.appState = .unlocked
                    }
                }
            }
            break
        default:
            if CommonConfigManager.shared.config.required_touch_id_or_password {
                if (Date().timeIntervalSince1970 -  CredentialsManager.shared.getPincodeTimestamp() > self.period) || force {
                    self.appState = .locked
                    self.showPincodeScreen(animated: animated)
                }
            }
            break
        }
    }
    
    fileprivate final func showPincodeScreen(animated: Bool) {
        if !self.isPincodeShowed {
//            let subscribtion = SubscribtionsManager.shared.subscribtionEnd
//            guard subscribtion != nil else {
//                CredentialsManager.shared.clearPincodes()
//                SettingManager.shared.saveItem(for: "", scope: .security, key: "support_touch_id", value: false)
//                return
//            }
            self.isPincodeShowed = true
            DispatchQueue.main.async {
                PincodePresenter().present(animated: animated)
            }
        }
    }
}
