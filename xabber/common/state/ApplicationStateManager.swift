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

struct PasscodeLockPolicy {
    enum Access: Equatable {
        case available
        case premiumRequired
        case disabledByConfig
    }

    static func access(
        requiredByConfig: Bool,
        subscriptionsEnabled: Bool,
        hasActiveSubscription: Bool
    ) -> Access {
        guard requiredByConfig else {
            return .disabledByConfig
        }

        if subscriptionsEnabled && !hasActiveSubscription {
            return .premiumRequired
        }

        return .available
    }

    static func accessForCurrentState(jid: String? = nil) -> Access {
        access(
            requiredByConfig: CommonConfigManager.shared.config.required_touch_id_or_password,
            subscriptionsEnabled: CommonConfigManager.shared.config.support_subscribtions,
            hasActiveSubscription: SubscribtionsManager.shared.hasActiveSubsription(for: jid)
        )
    }

    static var currentAccess: Access {
        accessForCurrentState()
    }

    static var canUsePasscodeLock: Bool {
        currentAccess == .available
    }

    static var shouldShowSettingsEntry: Bool {
        currentAccess != .disabledByConfig
    }
}

struct AutoDeleteMessagesPolicy {
    enum Access: Equatable {
        case available
        case premiumRequired
    }

    static func access(
        timerSeconds: Double,
        subscriptionsEnabled: Bool,
        hasActiveSubscription: Bool
    ) -> Access {
        guard timerSeconds > 0 else {
            return .available
        }

        if subscriptionsEnabled && !hasActiveSubscription {
            return .premiumRequired
        }

        return .available
    }

    static func currentAccess(timerSeconds: Double) -> Access {
        currentAccess(timerSeconds: timerSeconds, jid: nil)
    }

    static func currentAccess(timerSeconds: Double, jid: String?) -> Access {
        access(
            timerSeconds: timerSeconds,
            subscriptionsEnabled: CommonConfigManager.shared.config.support_subscribtions,
            hasActiveSubscription: SubscribtionsManager.shared.hasActiveSubsription(for: jid)
        )
    }

    static func canConfigure(timerSeconds: Double) -> Bool {
        currentAccess(timerSeconds: timerSeconds) == .available
    }
}

struct MediaUploadQuotaPolicy {
    enum Access: Equatable {
        case available
        case premiumRequired
    }

    static func access(
        subscriptionsEnabled: Bool,
        hasActiveSubscription: Bool,
        hasQuotaItem: Bool,
        quotaBytes: Int,
        totalBytes: Int
    ) -> Access {
        guard subscriptionsEnabled else {
            return .available
        }

        guard !hasActiveSubscription else {
            return .available
        }

        guard hasQuotaItem else {
            return .available
        }

        if quotaBytes < 0 {
            return .available
        }

        if quotaBytes == 0 || totalBytes >= quotaBytes {
            return .premiumRequired
        }

        return .available
    }

    static func currentAccess(jid: String?) -> Access {
        let subscriptionsEnabled = CommonConfigManager.shared.config.support_subscribtions
        let hasActiveSubscription = SubscribtionsManager.shared.hasActiveSubsription(for: jid)

        guard subscriptionsEnabled, !hasActiveSubscription else {
            return .available
        }

        guard let jid = jid, jid.isNotEmpty else {
            return .available
        }

        do {
            let realm = try WRealm.safe()
            realm.refresh()
            guard let quotaItem = realm.object(
                ofType: AccountQuotaStorageItem.self,
                forPrimaryKey: AccountQuotaStorageItem.genPrimary(jid: jid)
            ) else {
                return .available
            }

            return access(
                subscriptionsEnabled: subscriptionsEnabled,
                hasActiveSubscription: hasActiveSubscription,
                hasQuotaItem: true,
                quotaBytes: quotaItem.quotaBytes,
                totalBytes: quotaItem.totalBytes
            )
        } catch {
            DDLogDebug("MediaUploadQuotaPolicy: \(#function). \(error.localizedDescription)")
            return .available
        }
    }
}

final class PasscodeLockCoordinator {
    static let shared = PasscodeLockCoordinator()

    private var lockWindow: UIWindow?

    private init() {}

    var isShowing: Bool {
        lockWindow != nil
    }

    @discardableResult
    func show(animated: Bool, onUnlock: @escaping () -> Void) -> Bool {
        guard lockWindow == nil else {
            return true
        }

        guard let window = makeWindow() else {
            return false
        }

        let viewController = PasscodeOrBiometricViewController()
        viewController.onUnlockSucceeded = onUnlock
        viewController.modalPresentationStyle = .fullScreen
        viewController.isModalInPresentation = true

        window.rootViewController = viewController
        window.backgroundColor = .systemBackground
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.accessibilityViewIsModal = true
        window.alpha = animated ? 0 : 1
        window.isHidden = false
        window.makeKeyAndVisible()
        lockWindow = window

        if animated {
            UIView.animate(withDuration: 0.2) {
                window.alpha = 1
            }
        }
        return true
    }

    func hide(animated: Bool) {
        guard let window = lockWindow else {
            restoreMainWindow()
            return
        }

        let cleanup = { [weak self] in
            window.isHidden = true
            window.rootViewController = nil
            self?.lockWindow = nil
            self?.restoreMainWindow()
        }

        if animated {
            UIView.animate(withDuration: 0.2, animations: {
                window.alpha = 0
            }, completion: { _ in
                cleanup()
            })
        } else {
            cleanup()
        }
    }

    private func makeWindow() -> UIWindow? {
        if #available(iOS 13.0, *) {
            if let scene = SceneWindowProvider.activeWindow?.windowScene {
                return UIWindow(windowScene: scene)
            }

            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { scene in
                    scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
                }

            if let scene = scene {
                return UIWindow(windowScene: scene)
            }
        }

        return UIWindow(frame: UIScreen.main.bounds)
    }

    private func restoreMainWindow() {
        SceneWindowProvider.activeWindow?.makeKeyAndVisible()
    }
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
    private let accountRevocationProcessingGate = AccountRevocationProcessingGate()
    
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
                                               name: AuthenticatedKeyExchangeManager.showConfirmationViewNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(verificationSucceded(_:)),
                                               name: AuthenticatedKeyExchangeManager.showSuccessViewNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(showAuthenticationCodeInputViewController(_:)),
                                               name: AuthenticatedKeyExchangeManager.showCodeInputViewNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(showVerificationCodeViewController(_:)),
                                               name: AuthenticatedKeyExchangeManager.showCodeOutputViewNotification,
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

    @discardableResult
    public final func removeAccountForAuthenticationFailure(
        _ request: AccountRevocationRequest
    ) -> Bool {
        guard accountRevocationProcessingGate.claim(request) else {
            return false
        }
        AccountManager.shared.deleteAccount(by: request.jid)
        DispatchQueue.main.async {
            if AccountManager.shared.emptyAccountsList() {
                let appDelegate = UIApplication.shared.delegate as? AppDelegate
                AppDelegate.setupRootViewController(instance: appDelegate, window: appDelegate?.window, userInfo: nil)
            }
            XTokenInvalidatePresenter().present(
                jid: request.jid,
                title: "Access revoked".localizeString(id: "account_access_revoke", arguments: []),
                message: request.message,
                animated: true,
                completion: nil
            )
        }
        return true
    }

    @discardableResult
    private final func tokenWasInvalidated(
        for request: AccountRevocationRequest
    ) -> Bool {
        guard accountRevocationProcessingGate.claim(request) else {
            return false
        }
        func show() {
            XTokenInvalidatePresenter().present(
                jid: request.jid,
                title: "Access revoked".localizeString(id: "account_access_revoke", arguments: []),
                message: request.message,
                animated: true,
                completion: nil
            )
        }
        AccountManager.shared.deleteAccount(by: request.jid)
        DispatchQueue.main.async {
            if AccountManager.shared.emptyAccountsList() {
                let appDelegate = UIApplication.shared.delegate as? AppDelegate
                AppDelegate.setupRootViewController(instance: appDelegate, window: appDelegate?.window, userInfo: nil)
                show()
            } else {
                show()
            }
        }
        return true
    }
    
    @objc
    private final func didReceiveDeviceExpireNotification(_ notification: Notification) {
        guard let request = AccountRevocationNotificationParser.request(from: notification) else {
            return
        }
        self.tokenWasInvalidated(for: request)
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
            let owner = userInfo["owner"] as? String
            let sid = userInfo["sid"] as? String
            
            do {
                let realm = try WRealm.safe()
                
                let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner ?? "", sid: sid ?? ""))
                    if instance == nil {
                        return
                    }
                
                let jid = instance!.jid
                let deviceId = instance!.opponentDeviceId
                
                let vc = VerificationViewController()
                vc.owner = owner ?? ""
                vc.jid = jid
                vc.sid = sid ?? ""
                vc.deviceId = String(deviceId)

//                showModal(vc, replaceParent: false)
                
            } catch {
                DDLogDebug("ApplicationStateManager: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    @objc
    func showVerificationCodeViewController(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            let owner = userInfo["owner"] as? String
            let sid = userInfo["sid"] as? String
            
            do {
                let realm = try WRealm.safe()
                let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner ?? "", sid: sid ?? ""))
                if instance == nil || instance?.state != VerificationSessionStorageItem.VerififcationState.acceptedRequest {
                    return
                }
                
                let jid = instance!.jid
                let deviceId = instance!.opponentDeviceId
                let code = instance!.code
                
                let vc = VerificationViewController()
                vc.owner = owner ?? ""
                vc.state = .acceptedRequest
                vc.jid = jid
                vc.sid = sid ?? ""
                vc.deviceId = String(deviceId)
                vc.code = code
                
                showModal(vc, replaceParent: false)
                
            } catch {
                DDLogDebug("ApplicationStateManager: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    @objc
    func showAuthenticationCodeInputViewController(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            let owner = userInfo["owner"] as? String
            let sid = userInfo["sid"] as? String
            
            do {
                let realm = try WRealm.safe()
                let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner ?? "", sid: sid ?? ""))
                if instance == nil || instance?.state != VerificationSessionStorageItem.VerififcationState.receivedRequestAccept {
                    return
                }
                
                let jid = instance!.jid
                let deviceId = instance!.opponentDeviceId
                
                let vc = VerificationViewController()
                vc.owner = owner ?? ""
                vc.state = .receivedRequestAccept
                vc.jid = jid
                vc.sid = sid ?? ""
                vc.deviceId = String(deviceId)
                
                showModal(vc, replaceParent: false)
                
            } catch {
                DDLogDebug("ApplicationStateManager: \(#function). \(error.localizedDescription)")
            }
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
                
                let sid = instance!.sid
                
                let vc = VerificationViewController()
                vc.owner = owner
                vc.state = .trusted
                vc.jid = jid
                vc.sid = sid
                vc.deviceId = deviceId
                
                DispatchQueue.main.async {
                    let parent: UIViewController?
                    switch CommonConfigManager.shared.interfaceType {
                    case .tabs:
                        parent = (UIApplication.shared.delegate as? AppDelegate)?.tabController
                    case .split:
                        parent = (UIApplication.shared.delegate as? AppDelegate)?.splitController
                    }
                    
                    // so that a second window of successful verification does not open when it is already open
                    if (parent?.presentedViewController as? UINavigationController)?.topViewController as? VerificationViewController == nil {
                        showModal(vc, replaceParent: false)
                    }
                }
                
            } catch {
                DDLogDebug("ApplicationStateManager: \(#function). \(error.localizedDescription)")
                return
            }
        }
    }
    
    public final func prepare() {
        addObservers()
//        VoIPManager.shared.prepare()
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
        if PasscodeLockPolicy.canUsePasscodeLock {
            self.runPincodeTask()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            let diagnostics = ChatComposerFirstFocusDiagnostics.shared
            let categorySpan = diagnostics.beginPreFocusSpan(
                stage: .audioBootstrapCategoryBegin
            )
            do {
                try AVAudioSession.sharedInstance().setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: .defaultToSpeaker
                )
                diagnostics.endPreFocusSpan(
                    categorySpan,
                    stage: .audioBootstrapCategoryEnd,
                    succeeded: true
                )
            } catch {
                diagnostics.endPreFocusSpan(
                    categorySpan,
                    stage: .audioBootstrapCategoryEnd,
                    succeeded: false,
                    errorCode: (error as NSError).code
                )
            }
            if #available(iOS 13.0, *) {
                let hapticsSpan = diagnostics.beginPreFocusSpan(
                    stage: .audioBootstrapHapticsBegin
                )
                do {
                    try AVAudioSession
                        .sharedInstance()
                        .setAllowHapticsAndSystemSoundsDuringRecording(true)
                    diagnostics.endPreFocusSpan(
                        hapticsSpan,
                        stage: .audioBootstrapHapticsEnd,
                        succeeded: true
                    )
                } catch {
                    diagnostics.endPreFocusSpan(
                        hapticsSpan,
                        stage: .audioBootstrapHapticsEnd,
                        succeeded: false,
                        errorCode: (error as NSError).code
                    )
                }
            }
        }
        self.runAutoDeleteTask()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            AuthenticatedKeyExchangeManager.prepare()
        }
        SensitiveMediaAnalysisStartupScheduler.shared.prepareForLaunch()
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
                        "owner == %@ and opponent != %@ AND date < %@ AND isDeleted == false",
                        owner,
                        XMPPJID(string: owner)?.domain ?? "",
                        Date(timeIntervalSince1970: Date().timeIntervalSince1970 - Double(CommonConfigManager.shared.config.auto_delete_messages_interval))
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
                        $0.markDeleted()
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
            self.appState = .unlocked
            hidePincodeScreen(animated: animated)
            return
        }
        guard PasscodeLockPolicy.canUsePasscodeLock else {
            self.appState = .unlocked
            hidePincodeScreen(animated: animated)
            return
        }
        switch self.state {
        case .unsecure:
            if AccountManager.shared.users.isNotEmpty {
                if shouldLockPasscode(force: force) {
                    self.appState = .locked
                    self.showPincodeScreen(animated: animated)
                } else {
                    self.appState = .unlocked
                }
            }
            break
        default:
            if shouldLockPasscode(force: force) {
                self.appState = .locked
                self.showPincodeScreen(animated: animated)
            }
            break
        }
    }

    private final func shouldLockPasscode(force: Bool) -> Bool {
        force || Date().timeIntervalSince1970 - CredentialsManager.shared.getPincodeTimestamp() > self.period
    }
    
    fileprivate final func showPincodeScreen(animated: Bool) {
        if !self.isPincodeShowed {
            self.isPincodeShowed = true
            DispatchQueue.main.async {
                let didShow = PasscodeLockCoordinator.shared.show(animated: animated) { [weak self] in
                    self?.unlockPincode()
                }
                if !didShow {
                    self.isPincodeShowed = false
                }
            }
        }
    }

    public final func unlockPincode() {
        self.appState = .unlocked
        DispatchQueue.main.async {
            self.hidePincodeScreen(animated: true)
            (UIApplication.shared.delegate as? AppDelegate)?.removeBlurredScreen()
        }
    }

    public final func hidePincodeScreen(animated: Bool) {
        self.isPincodeShowed = false
        DispatchQueue.main.async {
            PasscodeLockCoordinator.shared.hide(animated: animated)
        }
    }
}
