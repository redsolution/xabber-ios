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

struct PasscodeAutoLockPolicy {
    static func shouldLockOnResume(
        period: TimeInterval,
        leftAt: Date?,
        now: Date
    ) -> Bool {
        guard period > 0 else { return false }
        guard let leftAt else { return true }
        let elapsed = now.timeIntervalSince(leftAt)
        return elapsed < 0 || elapsed >= period
    }
}

struct PasscodeUnlockPresentationPolicy {
    static func canComplete(
        isLocked: Bool,
        isPINWindow: Bool,
        sceneState: UIScene.ActivationState?,
        wipePending: Bool
    ) -> Bool {
        isLocked && isPINWindow && sceneState == .foregroundActive && !wipePending
    }
}

struct PasscodeAccountStoreRecoveryPolicy {
    static func requiresPIN(
        hasEnrolledPIN: Bool,
        period: TimeInterval,
        wasDueWhenForegrounded: Bool,
        pendingBackgroundAt: Date?,
        now: Date
    ) -> Bool {
        guard hasEnrolledPIN, period > 0 else { return false }
        if wasDueWhenForegrounded { return true }
        guard let pendingBackgroundAt else { return false }
        return PasscodeAutoLockPolicy.shouldLockOnResume(
            period: period,
            leftAt: pendingBackgroundAt,
            now: now
        )
    }
}

final class PasscodeWipeBlockingViewController: UIViewController {
    var onRetry: (() -> Void)?

    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "passcode.wipeBlockingScreen"

        let stack = UIStackView(arrangedSubviews: [messageLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])

        messageLabel.text = L10n.text(
            "passcode__content__deleting_local_data",
            fallback: "Deleting local data"
        )
        messageLabel.font = .preferredFont(forTextStyle: .headline)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.accessibilityIdentifier = "passcode.wipeStatus"

        retryButton.setTitle(
            L10n.text("common__action__retry", fallback: "Retry"),
            for: .normal
        )
        retryButton.accessibilityIdentifier = "passcode.wipeRetry"
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.isHidden = true
    }

    func showRetry() {
        loadViewIfNeeded()
        messageLabel.text = L10n.text(
            "passcode__content__local_data_deletion_failed",
            fallback: "Could not delete local data. Try again."
        )
        retryButton.isHidden = false
    }

    func showAccountStoreError() {
        loadViewIfNeeded()
        view.accessibilityIdentifier = "passcode.accountStoreBlockingScreen"
        messageLabel.text = L10n.text(
            "passcode__content__local_data_unavailable",
            fallback: "Could not open local data. Try again."
        )
        retryButton.isHidden = false
    }

    @objc private func retryTapped() {
        retryButton.isHidden = true
        messageLabel.text = L10n.text(
            "passcode__content__deleting_local_data",
            fallback: "Deleting local data"
        )
        onRetry?()
    }
}

final class PasscodeLockCoordinator {
    static let shared = PasscodeLockCoordinator()

    private var lockWindow: UIWindow?
    private weak var mainWindow: UIWindow?
    private var detachedRootViewController: UIViewController?
    private var neutralRootViewController: UIViewController?
    private var previousAccessibilityElementsHidden = false
    private var accountStoreBlockerActive = false

    init() {}

    var isShowing: Bool {
        lockWindow != nil
    }

    var isProtected: Bool {
        neutralRootViewController != nil
    }

    var visibleWindow: UIWindow? {
        lockWindow
    }

    var isShowingAccountStoreBlocker: Bool {
        accountStoreBlockerActive
    }

    var protectedMainWindow: UIWindow? {
        mainWindow
    }

    @discardableResult
    func protect(mainWindow requestedWindow: UIWindow? = nil) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let window = requestedWindow ?? AppRootCoordinator.active?.window
            ?? (UIApplication.shared.delegate as? AppDelegate)?.window,
              window !== lockWindow else {
            return false
        }
        if mainWindow === window, neutralRootViewController != nil {
            return true
        }
        guard neutralRootViewController == nil else { return false }

        let neutralRoot = UIViewController()
        neutralRoot.view.backgroundColor = .systemBackground
        neutralRoot.view.isOpaque = true
        neutralRoot.view.accessibilityIdentifier = "passcode.neutralRoot"

        detachedRootViewController = window.rootViewController
        mainWindow = window
        neutralRootViewController = neutralRoot
        previousAccessibilityElementsHidden = window.accessibilityElementsHidden
        window.accessibilityElementsHidden = true
        window.backgroundColor = .systemBackground
        UIView.performWithoutAnimation {
            window.rootViewController = neutralRoot
        }
        if AppRootCoordinator.active?.window === window {
            AppRootCoordinator.active?.removeBlurredScreen()
        }
        return true
    }

    @discardableResult
    func show(
        animated: Bool,
        mainWindow requestedWindow: UIWindow? = nil,
        onUnlock: @escaping () -> Void
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard protect(mainWindow: requestedWindow) else { return false }
        if let window = lockWindow {
            guard accountStoreBlockerActive else { return true }
            let viewController = PasscodeOrBiometricViewController()
            viewController.onUnlockSucceeded = onUnlock
            accountStoreBlockerActive = false
            window.rootViewController = viewController
            window.alpha = 1
            window.makeKeyAndVisible()
            return true
        }

        guard let scene = mainWindow?.windowScene else {
            return false
        }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds

        let viewController = PasscodeOrBiometricViewController()
        viewController.onUnlockSucceeded = onUnlock
        accountStoreBlockerActive = false

        window.rootViewController = viewController
        window.backgroundColor = .systemBackground
        window.isOpaque = true
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.accessibilityViewIsModal = true
        window.alpha = 1
        window.isHidden = false
        lockWindow = window
        window.makeKeyAndVisible()
        return true
    }

    @discardableResult
    func showWipeBlocker(
        mainWindow requestedWindow: UIWindow? = nil,
        onRetry: @escaping () -> Void
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard protect(mainWindow: requestedWindow),
              let scene = mainWindow?.windowScene else { return false }

        detachedRootViewController = nil
        accountStoreBlockerActive = false
        let blocker = PasscodeWipeBlockingViewController()
        blocker.onRetry = onRetry
        let window = lockWindow ?? UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = blocker
        window.backgroundColor = .systemBackground
        window.isOpaque = true
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.accessibilityViewIsModal = true
        window.alpha = 1
        lockWindow = window
        window.makeKeyAndVisible()
        return true
    }

    func showWipeRetry() {
        (lockWindow?.rootViewController as? PasscodeWipeBlockingViewController)?.showRetry()
    }

    @discardableResult
    func showAccountStoreBlocker(
        mainWindow requestedWindow: UIWindow? = nil,
        onRetry: @escaping () -> Void
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard protect(mainWindow: requestedWindow),
              let scene = mainWindow?.windowScene else { return false }
        let blocker = PasscodeWipeBlockingViewController()
        blocker.onRetry = onRetry
        accountStoreBlockerActive = true
        let window = lockWindow ?? UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = blocker
        window.backgroundColor = .systemBackground
        window.isOpaque = true
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.accessibilityViewIsModal = true
        window.alpha = 1
        lockWindow = window
        window.makeKeyAndVisible()
        blocker.showAccountStoreError()
        return true
    }

    /// Wipe has completed. The new onboarding root is installed while the
    /// blocker still covers the scene, then `hide` reveals it in one step.
    func allowRootReplacementAfterWipe() {
        dispatchPrecondition(condition: .onQueue(.main))
        detachedRootViewController = nil
        neutralRootViewController = nil
    }

    func hide(animated: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let mainWindow,
           neutralRootViewController != nil {
            UIView.performWithoutAnimation {
                mainWindow.rootViewController = detachedRootViewController
            }
        }
        mainWindow?.accessibilityElementsHidden = previousAccessibilityElementsHidden
        detachedRootViewController = nil
        neutralRootViewController = nil
        accountStoreBlockerActive = false
        if let window = lockWindow {
            window.isHidden = true
            window.rootViewController = nil
            lockWindow = nil
        }
        mainWindow?.makeKeyAndVisible()
        mainWindow = nil
    }

    func sceneDidDisconnect(mainWindow disconnectedWindow: UIWindow) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard mainWindow === disconnectedWindow else { return }
        if let window = lockWindow {
            window.isHidden = true
            window.rootViewController = nil
        }
        lockWindow = nil
        detachedRootViewController = nil
        neutralRootViewController = nil
        accountStoreBlockerActive = false
        disconnectedWindow.accessibilityElementsHidden = previousAccessibilityElementsHidden
        mainWindow = nil
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
    
    fileprivate var appState: State = .unsecure
    private var backgroundEnteredAt: Date?
    private var didEnterBackgroundSinceActivation = false
    private var accountStoreResumeRequiresPIN = false
    private var wipeInProgress = false
    private var didPrepare = false
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
                                       accessGroup: CredentialsManager.uniqueKeychainAccessGroup())
        if let ts = keychain.double(forKey: "application_blocked_date") {
            return Date(timeIntervalSince1970: ts)
        }
        return nil
    }
    
    public final func isApplicationBlocked() -> Bool {
        return isApplicationBlockedState
//        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
//                                       accessGroup: CredentialsManager.uniqueKeychainAccessGroup())
//        return keychain.bool(forKey: "application_blocked") ?? false
    }
    
    public final func unblockApplication(date: Date) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueKeychainAccessGroup())
//        _ = keychain.set(false, forKey: "application_blocked", withAccessibility: .always)
        self.isApplicationBlockedState = false
        _ = keychain.set(date.timeIntervalSince1970, forKey: "application_blocked_date")
    }
    
    public final func clearApplicationBlockedState() {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueKeychainAccessGroup())
//        _ = keychain.set(false, forKey: "application_blocked", withAccessibility: .always)
        self.isApplicationBlockedState = false
        self.isSubscribtionsShowed = false
        keychain.removeObject(forKey: "application_blocked_date")
    }
    
    public final func blockApplication(date: Date) {
        preBlockApplication()
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueKeychainAccessGroup())
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
        guard !didPrepare else { return }
        didPrepare = true
        addObservers()
//        VoIPManager.shared.prepare()
        SignatureManager.shared.prepare()
        SubscribtionsManager.shared.prepare()
        AccountColorManager.shared.load()
        DefaultAvatarManager.shared.preheat()
        MusicBox.shared.prepare()
        NotifyManager.shared.clearAllNotifications()
        if AccountMasksManager.shared.load() == nil {
            if let mask = AccountMasksManager.shared.masksList().first {
                AccountMasksManager.shared.save(mask: mask)
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
    
    public final func sceneWillResignActive(mainWindow: UIWindow) {
        (PasscodeLockCoordinator.shared.visibleWindow?.rootViewController
            as? PasscodeOrBiometricViewController)?
            .cancelAuthenticationForBackground()
        guard shouldProtectContent else { return }
        _ = PasscodeLockCoordinator.shared.protect(mainWindow: mainWindow)
    }

    public final func sceneDidEnterBackground(mainWindow: UIWindow) {
        backgroundEnteredAt = Date()
        didEnterBackgroundSinceActivation = true
        sceneWillResignActive(mainWindow: mainWindow)
    }

    public final func sceneWillEnterForeground() {
        guard didEnterBackgroundSinceActivation ||
                PasscodeLockCoordinator.shared.isProtected else { return }
        didEnterBackgroundSinceActivation = false
        if PasscodeLockCoordinator.shared.isShowingAccountStoreBlocker {
            if PasscodeAutoLockPolicy.shouldLockOnResume(
                period: period,
                leftAt: backgroundEnteredAt,
                now: Date()
            ) {
                accountStoreResumeRequiresPIN = true
            }
            backgroundEnteredAt = nil
            return
        }
        runPincodeTask(animated: false)
    }

    public final func sceneDidBecomeActive() {
        if PasscodeLockCoordinator.shared.isProtected,
           !PasscodeLockCoordinator.shared.isShowing {
            if PasscodeWipeCoordinator.shared.isPending {
                showWipeScreen(shouldBegin: false)
            } else if backgroundEnteredAt != nil {
                runPincodeTask(animated: false)
            } else {
                // A short inactive interruption has no Auto-Lock timestamp.
                // Check storage health without treating it as a background trip.
                do {
                    let enrollment = try PasscodeCredentialStore.shared.enrollmentState()
                    if enrollment != .notEnrolled {
                        let remaining = try PasscodeCredentialStore.shared.remainingAttempts()
                        if remaining == 0 {
                            showWipeScreen(shouldBegin: true)
                        }
                    }
                } catch {
                    appState = .locked
                    showPincodeScreen(animated: false)
                }
            }
        }
        guard appState != .locked,
              !PasscodeLockCoordinator.shared.isShowing,
              !PasscodeWipeCoordinator.shared.isPending else { return }
        backgroundEnteredAt = nil
        if PasscodeLockCoordinator.shared.isProtected {
            PasscodeLockCoordinator.shared.hide(animated: false)
        }
    }

    public final func sceneDidDisconnect(mainWindow: UIWindow) {
        PasscodeLockCoordinator.shared.sceneDidDisconnect(mainWindow: mainWindow)
        isPincodeShowed = false
        backgroundEnteredAt = nil
        didEnterBackgroundSinceActivation = false
        accountStoreResumeRequiresPIN = false
        appState = .unsecure
    }

    private var shouldProtectContent: Bool {
        if PasscodeWipeCoordinator.shared.isPending { return true }
        do {
            return try PasscodeCredentialStore.shared.enrollmentState() != .notEnrolled
        } catch {
            // A storage failure cannot be treated as an absent PIN.
            return true
        }
    }

    public final func runPincodeTask(animated: Bool, force: Bool = false) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.runPincodeTask(animated: animated, force: force)
            }
            return
        }

        if PasscodeWipeCoordinator.shared.isPending {
            showWipeScreen(shouldBegin: false)
            return
        }

        // A failed Realm read has its own blocker and retry path. In particular,
        // an unenrolled app must not dismiss it on the next foreground event.
        if PasscodeLockCoordinator.shared.isShowingAccountStoreBlocker {
            return
        }

        do {
            let enrollment = try PasscodeCredentialStore.shared.enrollmentState()
            if enrollment != .notEnrolled,
               try PasscodeCredentialStore.shared.remainingAttempts() == 0 {
                showWipeScreen(shouldBegin: true)
                return
            }

            if enrollment == .notEnrolled {
                appState = .unlocked
                hidePincodeScreen(animated: false)
                return
            }

            if appState == .locked || force || shouldLockPasscode() {
                appState = .locked
                showPincodeScreen(animated: animated)
            } else {
                appState = .unlocked
            }
        } catch {
            // A missing or inaccessible verifier keeps the screen protected.
            appState = .locked
            showPincodeScreen(animated: false)
        }
    }

    private final func shouldLockPasscode() -> Bool {
        PasscodeAutoLockPolicy.shouldLockOnResume(
            period: period,
            leftAt: backgroundEnteredAt,
            now: Date()
        )
    }
    
    fileprivate final func showPincodeScreen(animated: Bool) {
        guard !isPincodeShowed else { return }
        let didShow = PasscodeLockCoordinator.shared.show(animated: animated) { [weak self] in
            self?.unlockPincode()
        }
        isPincodeShowed = didShow
    }

    private func showWipeScreen(shouldBegin: Bool) {
        appState = .locked
        let didShow = PasscodeLockCoordinator.shared.showWipeBlocker { [weak self] in
            self?.resumeWipe()
        }
        isPincodeShowed = didShow
        guard didShow, !wipeInProgress else { return }
        AppRootCoordinator.active?.discardProtectedContentForWipe()
        wipeInProgress = true
        let completion: (Bool) -> Void = { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                self.wipeInProgress = false
                if success {
                    self.appState = .unsecure
                    self.isPincodeShowed = false
                    self.accountStoreResumeRequiresPIN = false
                    self.prepare()
                    let rootCoordinator = AppRootCoordinator.active
                        ?? PasscodeLockCoordinator.shared.protectedMainWindow.map {
                            AppRootCoordinator(
                                window: $0,
                                appDelegate: UIApplication.shared.delegate as? AppDelegate
                            )
                        }
                    guard let rootCoordinator else { return }
                    PasscodeLockCoordinator.shared.allowRootReplacementAfterWipe()
                    rootCoordinator.resumeAfterWipe()
                    if !PasscodeLockCoordinator.shared.isProtected {
                        PasscodeLockCoordinator.shared.hide(animated: false)
                    }
                } else {
                    PasscodeLockCoordinator.shared.showWipeRetry()
                }
            }
        }
        if shouldBegin {
            if !PasscodeWipeCoordinator.shared.beginWipe(completion: completion) {
                wipeInProgress = false
                PasscodeLockCoordinator.shared.showWipeRetry()
            }
        } else {
            PasscodeWipeCoordinator.shared.resumeIfNeeded(completion: completion)
        }
    }

    public final func beginTerminalWipe() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.beginTerminalWipe() }
            return
        }
        showWipeScreen(shouldBegin: true)
    }

    /// Called only after the account store can be read again. The blocker stays
    /// in place until this returns false or a fresh PIN unlock succeeds.
    public final func accountStoreDidRecover() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard PasscodeLockCoordinator.shared.isShowingAccountStoreBlocker else {
            return PasscodeLockCoordinator.shared.isProtected
        }
        if PasscodeWipeCoordinator.shared.isPending {
            showWipeScreen(shouldBegin: false)
            return true
        }
        do {
            let enrollment = try PasscodeCredentialStore.shared.enrollmentState()
            if enrollment == .notEnrolled {
                accountStoreResumeRequiresPIN = false
                backgroundEnteredAt = nil
                return false
            }
            if try PasscodeCredentialStore.shared.remainingAttempts() == 0 {
                showWipeScreen(shouldBegin: true)
                return true
            }
            let requiresPIN = appState == .locked ||
                PasscodeAccountStoreRecoveryPolicy.requiresPIN(
                    hasEnrolledPIN: true,
                    period: period,
                    wasDueWhenForegrounded: accountStoreResumeRequiresPIN,
                    pendingBackgroundAt: backgroundEnteredAt,
                    now: Date()
                )
            if requiresPIN {
                appState = .locked
                showPincodeScreen(animated: false)
                return true
            }
            accountStoreResumeRequiresPIN = false
            backgroundEnteredAt = nil
            return false
        } catch {
            appState = .locked
            showPincodeScreen(animated: false)
            return true
        }
    }

    private func resumeWipe() {
        guard !wipeInProgress else { return }
        showWipeScreen(shouldBegin: !PasscodeWipeCoordinator.shared.isPending)
    }

    public final func unlockPincode() {
        let finish = { [weak self] in
            guard let self else { return }
            let lockWindow = PasscodeLockCoordinator.shared.visibleWindow
            guard PasscodeUnlockPresentationPolicy.canComplete(
                isLocked: self.appState == .locked,
                isPINWindow: lockWindow?.rootViewController is PasscodeOrBiometricViewController,
                sceneState: lockWindow?.windowScene?.activationState,
                wipePending: PasscodeWipeCoordinator.shared.isPending
            ) else { return }
            do {
                guard try PasscodeCredentialStore.shared.enrollmentState() == .enrolled,
                      try PasscodeCredentialStore.shared.remainingAttempts() != 0 else {
                    return
                }
            } catch {
                return
            }
            let accountPresence = AccountManager.shared.accountStorePresence()
            guard accountPresence != .unavailable else {
                return
            }
            self.appState = .unlocked
            self.backgroundEnteredAt = nil
            self.accountStoreResumeRequiresPIN = false
            let appDelegate = UIApplication.shared.delegate as? AppDelegate
            appDelegate?.loadAccountsAfterPasscodeStorageRecoversIfNeeded()
            if accountPresence == .hasAccounts,
               AccountManager.shared.users.isEmpty {
                AccountManager.shared.load(
                    AppLaunchEnvironmentPolicy.shouldAutoconnectAccounts(
                        isPushKit: appDelegate?.isPushKit ?? false
                    )
                )
            }
            self.hidePincodeScreen(animated: false)
            AppRootCoordinator.active?.resumeAfterUnlock()
            (UIApplication.shared.delegate as? AppDelegate)?.removeBlurredScreen()
        }
        if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
    }

    public final func hidePincodeScreen(animated: Bool) {
        let hide = { [weak self] in
            self?.isPincodeShowed = false
            PasscodeLockCoordinator.shared.hide(animated: animated)
        }
        if Thread.isMainThread { hide() } else { DispatchQueue.main.async(execute: hide) }
    }
}
