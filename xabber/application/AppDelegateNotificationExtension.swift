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
import UserNotifications
import XMPPFramework


@available(iOS 10, *)
extension AppDelegate : UNUserNotificationCenterDelegate {
    // Receive displayed notifications for iOS 10 devices.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        
        let category = notification.request.content.categoryIdentifier
        let notificationInAppAlertLastChats = SettingManager.shared.get(bool: SettingsViewController.Datasource.Keys.notificationInAppAlertLastChats.rawValue)
        let notificationInAppSound = SettingManager.shared.get(bool: SettingsViewController.Datasource.Keys.notificationInAppSound.rawValue)
        let messageCategory = NotifyManager.notificationMessageCategory
        let pushMessageCategory = NotifyManager.notificationPushMessageCategory
        let subscriptionCategory = NotifyManager.notificationSubscribtionCategory
        let inviteCategory = NotifyManager.notificationInviteCategory
        let verificationCategory = NotifyManager.notificationVerificationCategory
        
        switch category {
        case messageCategory, pushMessageCategory, subscriptionCategory, inviteCategory:
            if notificationInAppAlertLastChats {
                if notificationInAppSound {
                    completionHandler([.banner, .sound])
                } else {
                    completionHandler([.banner])
                }
            } else {
                if NotifyManager.shared.isLastChatsDisplayed() {
                    if notificationInAppSound {
                        completionHandler([])
                    } else {
                        completionHandler([])
                    }
                } else {
                    if notificationInAppSound {
                        completionHandler([.banner, .sound])
                    } else {
                        completionHandler([.banner])
                    }
                }
            }
        case verificationCategory:
            if notificationInAppAlertLastChats {
                if notificationInAppSound {
                    completionHandler([.banner, .sound])
                } else {
                    completionHandler([.banner])
                }
            } else {
                if NotifyManager.shared.isLastChatsDisplayed() {
                    if notificationInAppSound {
                        completionHandler([.banner])
                    } else {
                        completionHandler([.banner])
                    }
                } else {
                    if notificationInAppSound {
                        completionHandler([.banner, .sound])
                    } else {
                        completionHandler([.banner])
                    }
                }
            }
        default:
            completionHandler([])
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case NotifyManager.notificationMessageActionReply:
            _ = NotifyManager.shared.onReplyMessageNotification(response: response, handler: completionHandler)
        case NotifyManager.notificationMessageActionMarkAsRead:
            _ = NotifyManager.shared.onMarkAsReadMessageNotification(response: response, handler: completionHandler)
        case NotifyManager.notificationMessageActionSubscribe:
            _ = NotifyManager.shared.onSubscribeContactNotification(response: response, handler: completionHandler)
        case NotifyManager.notificationMessageActionUnsubscribe:
            _ = NotifyManager.shared.onUnsubscribeContactNotification(response: response, handler: completionHandler)
        case NotifyManager.notificationMessageActionJoinGroup:
            _ = NotifyManager.shared.onJoinGroupNotification(response: response, handler: completionHandler)
        case NotifyManager.notificationMessageActionDeclineGroup:
            _ = NotifyManager.shared.onDeclineGroupNotification(response: response, handler: completionHandler)
        default:
            _ = NotifyManager.shared.onTouchNotificationRequest(
                response.notification.request,
                actionIdentifier: response.actionIdentifier,
                atStart: false,
                handler: completionHandler
            )
        }
    }
}
