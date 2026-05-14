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

func getAppVersion() -> String {
    let dictionary = Bundle.main.infoDictionary!
    let version = dictionary["CFBundleShortVersionString"] as? String ?? "0"
    let build = dictionary["CFBundleVersion"] as? String ?? "0"
    return "\(version).\(build)"
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
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

        realmMigrations(scheme: 5)
        #if RELEASE
        _DEBUG = false
        DDLog.add(DDOSLogger.sharedInstance, with: DDLogLevel.all)
        #else
        DDLog.add(DDOSLogger.sharedInstance, with: DDLogLevel.all)
        #endif
        
        if SettingManager.logEnabled {
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
                
        NotifyManager.shared.setLastChats(displayed: true)
        
        pushRegistry = PKPushRegistry(queue: nil)
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
        
//        setupRootViewController()
        
        DDLogDebug("app didFinishLaunching accountAutoConnect=\(!self.isPushKit) pushKit=\(self.isPushKit)")
        AccountManager.shared.load(!self.isPushKit)
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
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(languageChanged),
                                               name: .newLanguageSelected,
                                               object: nil)
        
        ApplicationStateManager.shared.runPincodeTask(animated: false, force: true)
        return true
    }
    
    @objc
    func languageChanged() {
        
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        DDLogError("resign")
        guard AppRootCoordinator.active == nil else {
            return
        }
        addBlurredScreen()
        AccountManager.shared.load()
    }

    func addBlurredScreen() {
        AppRootCoordinator.active?.addBlurredScreen()
    }
     
    func applicationDidEnterBackground(_ application: UIApplication) {
        DDLogError("enter background")
        guard AppRootCoordinator.active == nil else {
            return
        }
        AccountManager.shared.users.forEach {
            user in
            user.xmppStream.asyncSocket.disconnect()
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
//            self.splitViewController?.show(.supplementary)
            self.splitController?.hide(.primary)
        } else {
            UIView.performWithoutAnimation {
                self.splitController?.show(.supplementary)
                self.splitController?.hide(.primary)
            }
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        DDLogError("enter foreground")
        guard AppRootCoordinator.active == nil else {
            return
        }
        AccountManager.shared.prepare()
        CloudStorageQuotaRefreshCoordinator.shared.refreshAll(reason: .foreground)
        NotifyManager.shared.setLastChats(displayed: true)
        ApplicationStateManager.shared.runPincodeTask(animated: false, force: true)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        DDLogError("did become active")
        guard AppRootCoordinator.active == nil else {
            return
        }
        removeBlurredScreen()
    }
     
     func presentPasscodeOrRemoveBlurredScreen() {
         if CredentialsManager.shared.isPincodeSetted(),
            PasscodeLockPolicy.canUsePasscodeLock {
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
        
        let textAction = UNTextInputNotificationAction(
            identifier: NotifyManager.notificationMessageActionReply,
            title: "Reply".localizeString(id: "chat_reply", arguments: []),
            options: [],
            textInputButtonTitle: "Send".localizeString(id: "chat_send", arguments: []),
            textInputPlaceholder: "Message text".localizeString(id: "chat_message_text", arguments: [])
        )
        
        let markAsRead = UNNotificationAction(
            identifier: NotifyManager.notificationMessageActionMarkAsRead,
            title: "Mark as read".localizeString(id: "action_mark_as_read", arguments: []),
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
        
        UNUserNotificationCenter
            .current()
            .setNotificationCategories([
                messageCategory,
                pushMessageCategory,
                subscribtionCategory,
                inviteCategory
            ])
        
        UIApplication.shared.registerForRemoteNotifications()
        UNUserNotificationCenter.current().delegate = self
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
        
        if CommonConfigManager.shared.config.use_large_title {
            svc.navigationItem.largeTitleDisplayMode = .automatic
        } else {
            svc.navigationItem.largeTitleDisplayMode = .never
        }
        svc.navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title
          // This guarantees the app launches in chart list when on portrait mode
        return .supplementary
    }
    
    
    
}
