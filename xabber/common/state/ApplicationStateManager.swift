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
import CocoaLumberjack

public struct SubscribtionsSecretStore: Codable {
    var uuid_ns: String
    var api_url: String
}

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
    
    static let tokenWasExpired = Notification.Name("com.xabber.device.expired")
    public var expiredTokenAccountsList: Set<String> = Set<String>()
    
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
    
    public final func checkApplicationBlockedState(for jid: String, callback: (() -> Void)? = nil) {
        
        guard let path = Bundle.main.path(forResource: "subscribtions_secret", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let store = try? PropertyListDecoder().decode(SubscribtionsSecretStore.self, from: xml) else {
              return
        }
        
        let url = store.api_url + "/v1/accounts/\(jid.uuidString().lowercased())/"
        
        Alamofire
            .request(
                url,
                method: .get,
                parameters: [:],
                encoding: URLEncoding.default,
                headers: ["Cache-Control": "no-cache"]
            ).responseJSON {
                response in
                switch response.result {
                case .success(let value):
                    guard let dict = value as? NSDictionary else {
                        callback?()
                        return
                    }
                    let expiresDateRaw: String? = dict["expires"] as? String
                    if let expiresDateRaw = expiresDateRaw,
                       let expiresDate = Date.parseXMPPFormattedString(expiresDateRaw) {
                        SubscribtionsManager.shared.accountExpirationDate = expiresDate
                        if Date().timeIntervalSinceReferenceDate > expiresDate.timeIntervalSinceReferenceDate {
                            self.blockApplication(date: expiresDate)
                        } else {
                            self.unblockApplication(date: expiresDate)
                        }
                    }
                    if let subscribtionsListRaw = dict["subscriptions"] as? Array<NSDictionary> {
                        let subscribtionsList: [SubscribtionsManager.AppSubscribtions] = subscribtionsListRaw.compactMap{
                            if let product_id = $0["product_id"] as? String,
                               let expiresRaw = $0["expires"] as? String,
                               let expires = Date.parseXMPPFormattedString(expiresRaw) {
                                return SubscribtionsManager.AppSubscribtions(product_id: product_id, expires: expires)
                            }
                            return nil
                        }
                        SubscribtionsManager.shared.subscribtionsList = subscribtionsList
                    }
                    SubscribtionsManager.shared.setSubscribtionsInfoUpdated()
                    callback?()
                case .failure(let error):
                    DDLogDebug(error.localizedDescription)
                    callback?()
                }
            }
    }
    
    private final func tokenWasInvalidated(for jid: String) {
        func show(_ jid: String, in viewController: UIViewController) {
            XTokenInvalidatePresenter().present(
                in: viewController,
                jid: jid,
                title: "Access revoked".localizeString(id: "account_access_revoke", arguments: []),
                message: "Access to account \(jid) was revoked. Locally stored data deleted.".localizeString(id: "account_access_to_account_was_revoked", arguments: [jid]),
                animated: true,
                completion: nil
            )
        }
        AccountManager.shared.deleteAccount(by: jid)
        if AccountManager.shared.emptyAccountsList() {
            DispatchQueue.main.async {
                let vc = OnboardingViewController()
                
                let navigationController = UINavigationController(rootViewController: vc)
                
                navigationController.isNavigationBarHidden = true
                (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = navigationController
                show(jid, in: vc)
            }
            
            DispatchQueue.main.async {
                if let vc = getAppTabBar() {
                    show(jid, in: vc)
                }
            }
        } else {
            DispatchQueue.main.async {
                (getAppTabBar()?
                    .viewControllers?[XabberTabBar.settingsVCIndex] as? UINavigationController)?
                    .popToRootViewController(animated: false)
                if let vc = getAppTabBar() {
                    show(jid, in: vc)
                }
            }
        }
    }
    
    @objc
    private final func didReceiveDeviceExpireNotification(_ notification: Notification) {
        guard let jid = notification.object as? String else {
            return
        }
        if !self.expiredTokenAccountsList.contains(jid) {
            self.expiredTokenAccountsList.insert(jid)
            self.tokenWasInvalidated(for: jid)
        }
    }
    
    public final func prepare() {
        addObservers()
        Store.shared.prepare()
        VoIPManager.shared.prepare()
        SignatureManager.shared.prepare()
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
    
    public final func runPincodeTask(animated: Bool) {
        if !CredentialsManager.shared.isPincodeSetted() {
            return
        }
        switch self.state {
        case .unsecure:
            if CommonConfigManager.shared.config.required_touch_id_or_password {
                if AccountManager.shared.users.isNotEmpty {
                    if Date().timeIntervalSince1970 -  CredentialsManager.shared.getPincodeTimestamp() > self.period {
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
                if Date().timeIntervalSince1970 -  CredentialsManager.shared.getPincodeTimestamp() > self.period {
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
