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
    let version = dictionary["CFBundleShortVersionString"] as! String
    let build = dictionary["CFBundleVersion"] as! String
    return "\(version).\(build)"
}

@UIApplicationMain
 class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    var pushRegistry: PKPushRegistry!
    var logFileManager: DDLogFileManager?
    
    var isPushKit: Bool = false
     
    var blurEffectView: UIVisualEffectView?
     
    var credentialsExpiredPresenterShowed: Bool = false
    
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        realmMigrations(scheme: 1)
        
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
    
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
                
        NotifyManager.shared.setLastChats(displayed: true)
        
        pushRegistry = PKPushRegistry(queue: nil)
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
        
        if AccountManager.shared.emptyAccountsList() {
            CredentialsManager.shared.clearKeyachain()
            let vc = OnboardingViewController()
            
            let navigationController = UINavigationController(rootViewController: vc)
            
            navigationController.isNavigationBarHidden = true
            window?.rootViewController = navigationController
        }
        
        ApplicationStateManager.shared.prepare()
        
        AccountManager.shared.load(!self.isPushKit)
        
        self.getNotificationSettings()
        
        if let keys = launchOptions?.keys,
            keys.contains(.remoteNotification),
            let userInfo = launchOptions?[UIApplication.LaunchOptionsKey.remoteNotification] as? NSDictionary {
            if let id = userInfo["stanzaId"] as? String {
                NotifyManager.shared.deliveredNotificationsIds.insert(id)
            }
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
            if #available(iOS 13.0, *) {
                try? AVAudioSession
                    .sharedInstance()
                    .setAllowHapticsAndSystemSoundsDuringRecording(true)
            }
        }
        
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(languageChanged),
                                               name: .newLanguageSelected,
                                               object: nil)
        
        ApplicationStateManager.shared.runPincodeTask(animated: false)
        return true
    }
    
    @objc
    func languageChanged() {
        DispatchQueue.main.async {
            let storyboard = UIStoryboard(name: "Main", bundle: nil)
            self.window?.rootViewController = storyboard.instantiateInitialViewController()
            self.appTabBarTitlesInit()
        }
    }
    
    func appTabBarTitlesInit() {
        
        let titleIDs: [String] = ["toolbar__menu_item__chats", "category_title_contacts", "category_settings"]
        let titles: [String] = ["Chats", "Contacts", "Settings"]
        
        guard let items = getAppTabBar()?.tabBar.items, items.count == 3 else { return }
        
        for (index, item) in items.enumerated() {
            item.title = titles[index].localizeString(id: titleIDs[index], arguments: [])
        }
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        DDLogError("resign")
    }

    func addBlurredScreen() {
        guard self.blurEffectView == nil,
           !ApplicationStateManager.shared.isPincodeShowed else {
            return
        }
        let blurEffect = UIBlurEffect(style: UIBlurEffect.Style.light)
        self.blurEffectView = UIVisualEffectView(effect: blurEffect)
        if let blurEffectView =  self.blurEffectView, let window = window {
            blurEffectView.frame = window.frame
            window.addSubview(blurEffectView)
        }
    }
     
    func applicationDidEnterBackground(_ application: UIApplication) {
        DDLogError("enter background")
        AccountManager.shared.users.forEach {
            user in
            user.xmppStream.asyncSocket.disconnect()
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        DDLogError("enter foreground")
        AccountManager.shared.prepare()
        NotifyManager.shared.setLastChats(displayed: true)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        DDLogError("did become active")
//        removeBlurredScreen()
    }
     
     func presentPasscodeOrRemoveBlurredScreen() {
         if CredentialsManager.shared.isPincodeSetted() {
             if !ApplicationStateManager.shared.isPincodeShowed {
                 ApplicationStateManager.shared.isPincodeShowed = true
                 DispatchQueue.main.async {
                     PincodePresenter().present(animated: true)
                 }
             }
         } else {
             self.blurEffectView?.removeFromSuperview()
             self.blurEffectView = nil
         }
     }
    
     func removeBlurredScreen() {
         self.blurEffectView?.removeFromSuperview()
         self.blurEffectView = nil
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
        print("device token: \(token)")
    }
    
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DDLogDebug("Failed to register: \(error)")
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) {
//        return
        DDLogDebug("PAYLOAD USER INFO: \(userInfo)")
        if VoIPManager.shared.onReceivePushUpdate(userInfo) {
            return
        }
        do {
            try APNSManager.shared.receive(userInfo, completionHandler: nil)
        } catch APNSManager.APNSError.undefinedTargetType {
            DDLogDebug("undefined target type")
        } catch APNSManager.APNSError.failedToDecodeString {
            DDLogDebug("failed to decode string")
        } catch APNSManager.APNSError.registrationFailed {
            DDLogDebug("registration failed")
        } catch APNSManager.APNSError.invalidPayload {
            DDLogDebug("invalid payload")
        } catch APNSManager.APNSError.userNotExist {
            APNSManager.shared.sendDeleteRequest(userInfo, voip: true)
            APNSManager.shared.sendDeleteRequest(userInfo, voip: false)
        } catch APNSManager.APNSError.registrationSuccess {
            DDLogDebug("registration success")
        } catch APNSManager.APNSError.featureNotImplemented {
            DDLogDebug("feature not implemented")
        } catch {
            DDLogDebug("common error. \(error.localizedDescription)")
        }
    }
    
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        func handler() {
            completionHandler(.newData)
        }
        DDLogDebug("USER INFO: \(userInfo)")
        if VoIPManager.shared.onReceivePushUpdate(userInfo) {
            completionHandler(.newData)
            return
        }
        do {
            try APNSManager.shared.receive(userInfo, completionHandler: handler)
        } catch APNSManager.APNSError.undefinedTargetType {
            DDLogDebug("undefined target type")
        } catch APNSManager.APNSError.failedToDecodeString {
            DDLogDebug("failed to decode string")
        } catch APNSManager.APNSError.registrationFailed {
            DDLogDebug("registration failed")
        } catch APNSManager.APNSError.invalidPayload {
            DDLogDebug("invalid payload")
        } catch APNSManager.APNSError.userNotExist {
            APNSManager.shared.sendDeleteRequest(userInfo, voip: true)
            APNSManager.shared.sendDeleteRequest(userInfo, voip: false)
        } catch APNSManager.APNSError.registrationSuccess {
            DDLogDebug("registration success")
        } catch APNSManager.APNSError.featureNotImplemented {
            DDLogDebug("feature not implemented")
        } catch {
            DDLogDebug("common error. \(error.localizedDescription)")
        }
    }
    
    func application(_ application: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:] ) -> Bool {


        // Determine who sent the URL.
        let sendingAppID = options[.sourceApplication]
        print("source application = \(sendingAppID ?? "Unknown")")


        // Process the URL.
        guard let components = NSURLComponents(url: url, resolvingAgainstBaseURL: true),
            let jid = components.path else {
                print("Invalid URL or album path missing")
                return false
        }
        getAppTabBar()?.displayAddContactVC(jid: jid, nickname: nil)
        return true
    }
    
}
