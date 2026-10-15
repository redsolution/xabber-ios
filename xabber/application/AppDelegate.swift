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
import UserNotifications
import PushKit
import CocoaLumberjack
import AVFoundation
import UIKit
import RealmSwift

var _DEBUG: Bool = true

enum AppLoggingPolicy {
    static func osLogLevel(isRelease: Bool) -> DDLogLevel {
        isRelease ? .info : .debug
    }

    static func shouldEnablePersistentLogging(
        developerSettingEnabled: Bool
    ) -> Bool {
        developerSettingEnabled
    }
}

func getAppVersion() -> String {
    let dictionary = Bundle.main.infoDictionary!
    let version = dictionary["CFBundleShortVersionString"] as? String ?? "0"
    let build = dictionary["CFBundleVersion"] as? String ?? "0"
    return "\(version).\(build)"
}

enum AppLaunchEnvironmentPolicy {
    struct IsolatedStorageDescriptor: Equatable {
        let inMemoryIdentifier: String
    }

    // xcodebuild strips TEST_RUNNER_ before forwarding these variables to a
    // hosted test process. Keep the runtime keys here; shell commands use the
    // corresponding TEST_RUNNER_XABBER_* names.
    static let hostedXCTestEnvironmentKey = HostedXCTestIsolationPolicy.hostedXCTestEnvironmentKey
    static let disableAccountAutoconnectEnvironmentKey = HostedXCTestIsolationPolicy.disableAccountAutoconnectEnvironmentKey
    static let isolatedStorageEnvironmentKey = HostedXCTestIsolationPolicy.isolatedStorageEnvironmentKey

    static func shouldAutoconnectAccounts(
        isPushKit: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        guard !isPushKit else { return false }
        guard !PushExtensionDiagnostics.isOfflineHostRun(environment: environment) else { return false }

        #if DEBUG || CHAT_PERFORMANCE_LAB
        if ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: arguments,
            environment: environment
        ) != nil {
            return false
        }
        #endif

        let isHostedXCTest = environment[hostedXCTestEnvironmentKey] != nil
        let disablesAutoconnect = environment[disableAccountAutoconnectEnvironmentKey] == "1"
        return !(isHostedXCTest && disablesAutoconnect)
    }

    static func isolatedStorageDescriptor(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> IsolatedStorageDescriptor? {
        #if DEBUG || CHAT_PERFORMANCE_LAB
        if ChatPerformanceUITestLaunchPolicy.descriptor(
            arguments: arguments,
            environment: environment
        ) != nil {
            return IsolatedStorageDescriptor(
                inMemoryIdentifier: "xabber-chat-performance-ui-\(processIdentifier)"
            )
        }
        #endif

        guard HostedXCTestIsolationPolicy.isEnabled(environment: environment) else {
            return nil
        }

        return IsolatedStorageDescriptor(
            inMemoryIdentifier: "xabber-hosted-xctest-\(processIdentifier)"
        )
    }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    private var deferredAccountLoadForPasscodeStorageError = false
    enum RemoteNotificationOutcome: Equatable {
        case voip
        case push(APNSManager.ReceiveResult)
        case noData
    }

    var window: UIWindow?
    var pushRegistry: PKPushRegistry!
    var logFileManager: DDLogFileManager?
    
    var isPushKit: Bool = false
    var excludeBlur: Bool = false
     
    var blurEffectView: UIVisualEffectView?
     
    var splitController: UISplitViewController? = nil
    var tabController: UITabBarController? = nil
    var currentPresentedVc: UIViewController? = nil
    
    var credentialsExpiredPresenterShowed: Bool = false
    
    
    
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        var configurationName: String = "Default Configuration"
        return UISceneConfiguration(
            name: configurationName,
            sessionRole: connectingSceneSession.role
        )
    }
    
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        let appGroupSuiteName = CredentialsManager.uniqueAccessGroup()
        LocalizationRuntime.shared.bootstrap(
            appGroupSuiteName: appGroupSuiteName.isEmpty ? nil : appGroupSuiteName
        )

        let isolatedStorage = AppLaunchEnvironmentPolicy.isolatedStorageDescriptor()
        realmMigrations(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: isolatedStorage?.inMemoryIdentifier
        )
        #if RELEASE
        _DEBUG = false
        let isReleaseBuild = true
        #else
        let isReleaseBuild = false
        #endif

        DDLog.add(
            DDOSLogger.sharedInstance,
            with: AppLoggingPolicy.osLogLevel(isRelease: isReleaseBuild)
        )
        let shouldEnableFileLogging =
            AppLoggingPolicy.shouldEnablePersistentLogging(
                developerSettingEnabled: SettingManager.logEnabled
            )

        if shouldEnableFileLogging {
            let fileLogger = DDFileLogger()
            fileLogger.doNotReuseLogFiles = true
            fileLogger.rollingFrequency = 60 * 60 * 24
            fileLogger.logFileManager.maximumNumberOfLogFiles = 12
            logFileManager = fileLogger.logFileManager
            DDLog.add(fileLogger, with: DDLogLevel.all)
        }
        return true
    }
    
    
    static func setupRootViewController(instance: AppDelegate?, window: UIWindow?, userInfo: [AnyHashable: Any]?) {
        guard let window = window ?? instance?.window else {
            return
        }

        if let active = AppRootCoordinator.active, active.window === window {
            active.rebuildRoot(userInfo: userInfo)
        } else {
            let coordinator = AppRootCoordinator(window: window, appDelegate: instance)
            coordinator.rebuildRoot(userInfo: userInfo)
        }
    }
    
    var startUserInfo: NSDictionary = NSDictionary() {
        didSet {
            print("START USER INFO: \(startUserInfo)")
        }
    }
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG || CHAT_PERFORMANCE_LAB
        if AvatarPickerUITestLaunchPolicy.isEnabled() {
            return true
        }
        if ChatPerformanceUITestLaunchPolicy.descriptor() != nil {
            return true
        }
        #endif
                
        _ = try? PasscodeCredentialStore.shared.clearOrphanedCredentialsIfSafe(
            hasLocalAccounts: {
                let realm = try WRealm.safe()
                realm.refresh()
                return !realm.objects(AccountStorageItem.self).isEmpty
            },
            isWipePending: { PasscodeWipeCoordinator.shared.isPending }
        )

        if PasscodeWipeCoordinator.shared.isPending {
            // The scene attaches only a neutral root and the wipe blocker.
            getNotificationSettings()
            return true
        }

        do {
            let enrollment = try PasscodeCredentialStore.shared.enrollmentState()
            if enrollment != .notEnrolled {
                let remaining = try PasscodeCredentialStore.shared.remainingAttempts()
                if remaining == 0 {
                    // A previous terminal attempt may have failed to persist the wipe marker.
                    getNotificationSettings()
                    return true
                }
            }
        } catch {
            // No account data is loaded until this credential can be verified.
            deferredAccountLoadForPasscodeStorageError = true
            getNotificationSettings()
            return true
        }

        NotifyManager.shared.setLastChats(displayed: true)
        
        pushRegistry = PKPushRegistry(queue: nil)
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
        
//        setupRootViewController()
        
        let shouldAutoconnectAccounts = AppLaunchEnvironmentPolicy.shouldAutoconnectAccounts(isPushKit: self.isPushKit)
        DDLogDebug("app didFinishLaunching accountAutoConnect=\(shouldAutoconnectAccounts) pushKit=\(self.isPushKit)")
        AccountManager.shared.load(shouldAutoconnectAccounts)
        if PushExtensionDiagnostics.isOfflineHostRun() {
            let streams = AccountManager.shared.users.map {
                "\($0.jid):connected=\($0.xmppStream.isConnected),disconnected=\($0.xmppStream.isDisconnected)"
            }
            PushExtensionDiagnostics.log("event=host_offline_ready primary=\(streams) uiConnected=\(XMPPUIActionManager.shared.stream.isConnected) uiDisconnected=\(XMPPUIActionManager.shared.stream.isDisconnected) logFile=\(PushExtensionDiagnostics.shared.fileURL.path)")
        }
        ApplicationStateManager.shared.prepare()
        CloudStorageQuotaRefreshCoordinator.shared.refreshAll(reason: .appLaunch)
        
        self.getNotificationSettings()
        
        if let keys = launchOptions?.keys,
            keys.contains(.remoteNotification),
            let userInfo = launchOptions?[UIApplication.LaunchOptionsKey.remoteNotification] as? NSDictionary {
            if let id = userInfo["stanzaId"] as? String {
                NotifyManager.shared.deliveredNotificationsIds.insert(id)
            }
            self.startUserInfo = userInfo
        }
        
        return true
    }

    func loadAccountsAfterPasscodeStorageRecoversIfNeeded() {
        guard deferredAccountLoadForPasscodeStorageError else { return }
        deferredAccountLoadForPasscodeStorageError = false
        NotifyManager.shared.setLastChats(displayed: true)
        pushRegistry = PKPushRegistry(queue: nil)
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
        let shouldAutoconnect = AppLaunchEnvironmentPolicy.shouldAutoconnectAccounts(
            isPushKit: isPushKit
        )
        AccountManager.shared.load(shouldAutoconnect)
        ApplicationStateManager.shared.prepare()
        CloudStorageQuotaRefreshCoordinator.shared.refreshAll(reason: .appLaunch)
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        DDLogError("resign")
        ConnectionDiagnosticsLogger.log(
            event: "app_lifecycle_will_resign_active",
            stream: .primary,
            jid: nil,
            details: [
                "source": "appDelegate",
                "activeSceneCoordinator": AppRootCoordinator.active != nil,
                "willLoadAccounts": AppRootCoordinator.active == nil
            ]
        )
        guard AppRootCoordinator.active == nil else {
            return
        }
        if let window {
            ApplicationStateManager.shared.sceneWillResignActive(mainWindow: window)
        }
        addBlurredScreen()
        AccountManager.shared.load()
    }

    func addBlurredScreen() {
        AppRootCoordinator.active?.addBlurredScreen()
    }
     
    func applicationDidEnterBackground(_ application: UIApplication) {
        DDLogError("enter background")
        ConnectionDiagnosticsLogger.log(
            event: "app_lifecycle_did_enter_background",
            stream: .primary,
            jid: nil,
            details: [
                "source": "appDelegate",
                "activeSceneCoordinator": AppRootCoordinator.active != nil,
                "willDisconnectAccounts": AppRootCoordinator.active == nil,
                "accountCount": AccountManager.shared.users.count
            ]
        )
        guard AppRootCoordinator.active == nil else {
            return
        }
        if let window {
            ApplicationStateManager.shared.sceneDidEnterBackground(mainWindow: window)
        }
        AccountManager.shared.users.forEach {
            user in
            user.disconnect(hard: true, cause: .backgroundSuspension)
        }
        if !PasscodeLockCoordinator.shared.isProtected {
            if UIDevice.current.userInterfaceIdiom == .pad {
//              self.splitViewController?.show(.supplementary)
                self.splitController?.hide(.primary)
            } else {
                UIView.performWithoutAnimation {
                    self.splitController?.show(.supplementary)
                    self.splitController?.hide(.primary)
                }
            }
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        DDLogError("enter foreground")
        ConnectionDiagnosticsLogger.log(
            event: "app_lifecycle_will_enter_foreground",
            stream: .primary,
            jid: nil,
            details: [
                "source": "appDelegate",
                "activeSceneCoordinator": AppRootCoordinator.active != nil
            ]
        )
        guard AppRootCoordinator.active == nil else {
            return
        }
        if PasscodeWipeCoordinator.shared.isPending {
            ApplicationStateManager.shared.sceneWillEnterForeground()
            return
        }
        if refreshLocalizationContextIfNeeded(), let window {
            Self.setupRootViewController(
                instance: self,
                window: window,
                userInfo: nil
            )
        }
        AccountManager.shared.prepare()
        CloudStorageQuotaRefreshCoordinator.shared.refreshAll(reason: .foreground)
        NotifyManager.shared.setLastChats(displayed: true)
        ApplicationStateManager.shared.sceneWillEnterForeground()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        DDLogError("did become active")
        ConnectionDiagnosticsLogger.log(
            event: "app_lifecycle_did_become_active",
            stream: .primary,
            jid: nil,
            details: [
                "source": "appDelegate",
                "activeSceneCoordinator": AppRootCoordinator.active != nil
            ]
        )
        guard AppRootCoordinator.active == nil else {
            return
        }
        ApplicationStateManager.shared.sceneDidBecomeActive()
        removeBlurredScreen()
    }
     
     func presentPasscodeOrRemoveBlurredScreen() {
         if CredentialsManager.shared.isPincodeSetted() {
             ApplicationStateManager.shared.runPincodeTask(animated: true, force: true)
         } else {
             self.blurEffectView?.removeFromSuperview()
             self.blurEffectView = nil
         }
     }
    
     func removeBlurredScreen() {
         AppRootCoordinator.active?.removeBlurredScreen()
     }
     
    func applicationWillTerminate(_ application: UIApplication) {
        AccountManager.shared.prepareForBackground()
        AccountManager
            .shared
            .users
            .compactMap { return $0.jid }
            .forEach {
                PushNotificationsManager.setAccountStateForPush(jid: $0, active: false)
            }
    }
    
    func getNotificationSettings() {
        registerLocalizedNotificationCategories()
        UIApplication.shared.registerForRemoteNotifications()
        UNUserNotificationCenter.current().delegate = self
    }

    func registerLocalizedNotificationCategories() {
        let textAction = UNTextInputNotificationAction(
            identifier: NotifyManager.notificationMessageActionReply,
            title: L10n.text("chat_reply", fallback: "Reply"),
            options: [],
            textInputButtonTitle: L10n.text("chat_send", fallback: "Send"),
            textInputPlaceholder: L10n.text(
                "chat_message_text",
                fallback: "Message text"
            )
        )
        
        let markAsRead = UNNotificationAction(
            identifier: NotifyManager.notificationMessageActionMarkAsRead,
            title: L10n.text("action_mark_as_read", fallback: "Mark as read"),
            options: []
        )
        
        let messageCategory = UNNotificationCategory(
            identifier: NotifyManager.notificationMessageCategory,
            actions: [textAction, markAsRead],
            intentIdentifiers: [],
            options: []
        )
        
        let pushMessageCategory = UNNotificationCategory(
            identifier: NotifyManager.notificationPushMessageCategory,
            actions: [],//[textAction, markAsRead],
            intentIdentifiers: [],
            options: []
        )
        
        let subscribtionCategory = UNNotificationCategory(
            identifier: NotifyManager.notificationSubscribtionCategory,
            actions: [],//[subscribe, unsubscribe],
            intentIdentifiers: [],
            options: []
        )
        
        let inviteCategory = UNNotificationCategory(
            identifier: NotifyManager.notificationInviteCategory,
            actions: [],//[joinGroup, declineGroup],
            intentIdentifiers: [],
            options: []
        )

        let verificationCategory = UNNotificationCategory(
            identifier: NotifyManager.notificationVerificationCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        
        UNUserNotificationCenter
            .current()
            .setNotificationCategories([
                messageCategory,
                pushMessageCategory,
                subscribtionCategory,
                inviteCategory,
                verificationCategory
            ])
    }

    func refreshLocalizationDependentState() {
        dispatchPrecondition(condition: .onQueue(.main))
        SettingManager.shared.loadSettings()
        AccountColorManager.shared.load()
        registerLocalizedNotificationCategories()
    }

    @discardableResult
    func refreshLocalizationContextIfNeeded() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let previous = LocalizationRuntime.shared.context
        let current = LocalizationRuntime.shared.refresh()
        guard !previous.isSemanticallyEquivalent(to: current) else {
            return false
        }
        refreshLocalizationDependentState()
        return true
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenParts = deviceToken.map { data -> String in
            return String(format: "%02.2hhx", data)
        }
        let token = tokenParts.joined()
        APNSManager.shared.receive(deviceToken: token)
        DDLogDebug("registered for remote notifications tokenLength=\(token.count)")
    }
    
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DDLogDebug("Failed to register: \(error)")
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) {
//        return
        DDLogDebug("PAYLOAD USER INFO: \(userInfo)")
        _ = Self.processRemoteNotification(
            userInfo: userInfo,
            voipHandler: { VoIPManager.shared.onReceivePushUpdate($0) },
            apnsHandler: { payload, completion in
                try APNSManager.shared.receive(payload, completionHandler: completion)
            },
            cleanupHandler: {
                APNSManager.shared.sendDeleteRequest(userInfo, voip: true)
                APNSManager.shared.sendDeleteRequest(userInfo, voip: false)
            }
        )
    }
    
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        DDLogDebug("USER INFO: \(userInfo)")
        Self.processRemoteNotification(
            userInfo: userInfo,
            voipHandler: { VoIPManager.shared.onReceivePushUpdate($0) },
            apnsHandler: { payload, completion in
                try APNSManager.shared.receive(payload, completionHandler: completion)
            },
            cleanupHandler: {
                APNSManager.shared.sendDeleteRequest(userInfo, voip: true)
                APNSManager.shared.sendDeleteRequest(userInfo, voip: false)
            },
            fetchCompletionHandler: completionHandler
        )
    }
    
    func application(_ application: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:] ) -> Bool {

        // Determine who sent the URL.
        let sendingAppID = options[.sourceApplication]
//        print("source application = \(sendingAppID ?? "Unknown")")


        // Process the URL.
        guard let components = NSURLComponents(url: url, resolvingAgainstBaseURL: true),
            let jid = components.path else {
//                print("Invalid URL or album path missing")
                return false
        }
//        getAppTabBar()?.displayAddContactVC(jid: jid, nickname: nil)
        return true
    }
    
}

extension AppDelegate {
    private static func completeOnce(
        _ completionHandler: ((UIBackgroundFetchResult) -> Void)?
    ) -> (UIBackgroundFetchResult) -> Void {
        guard let completionHandler else {
            return { _ in }
        }

        let lock = NSLock()
        var isCompleted = false
        return { result in
            lock.lock()
            defer { lock.unlock() }
            guard !isCompleted else {
                return
            }
            isCompleted = true
            completionHandler(result)
        }
    }

    @discardableResult
    static func processRemoteNotification(
        userInfo: [AnyHashable: Any],
        voipHandler: ([AnyHashable: Any]) -> Bool,
        apnsHandler: ([AnyHashable: Any], (() -> Void)?) throws -> APNSManager.ReceiveResult,
        cleanupHandler: () -> Void,
        fetchCompletionHandler: ((UIBackgroundFetchResult) -> Void)? = nil
    ) -> RemoteNotificationOutcome {
        let complete = completeOnce(fetchCompletionHandler)

        if voipHandler(userInfo) {
            complete(.newData)
            return .voip
        }

        do {
            let result = try apnsHandler(userInfo, {
                complete(.newData)
            })
            if fetchCompletionHandler != nil {
                switch result {
                case .registration, .displayed, .data:
                    complete(.newData)
                case .ignored:
                    complete(.noData)
                }
            }
            return .push(result)
        } catch APNSManager.APNSError.undefinedTargetType {
            DDLogDebug("undefined target type")
        } catch APNSManager.APNSError.failedToDecodeString {
            DDLogDebug("failed to decode string")
        } catch APNSManager.APNSError.registrationFailed {
            DDLogDebug("registration failed")
        } catch APNSManager.APNSError.invalidPayload {
            DDLogDebug("invalid payload")
        } catch APNSManager.APNSError.userNotExist {
            cleanupHandler()
        } catch APNSManager.APNSError.featureNotImplemented {
            DDLogDebug("feature not implemented")
        } catch {
            DDLogDebug("common error. \(error.localizedDescription)")
        }

        complete(.noData)
        return .noData
    }
}

extension AppDelegate: UISplitViewControllerDelegate {
    
    func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        
        NavigationLargeTitlePolicy.apply(to: svc)
          // This guarantees the app launches in chart list when on portrait mode
        return .supplementary
    }
    
    
    
}
