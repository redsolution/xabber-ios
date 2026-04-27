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
import RealmSwift
import CocoaLumberjack

extension LastChatsViewController: UITableViewDelegate {

    internal static func unreadMentionOpenRequest(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        in realm: Realm
    ) -> ChatOpenMessageRequest? {
        guard conversationType == .group,
              let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: conversationType
                )
              ),
              let mentionId = chat.mentionId,
              mentionId.isNotEmpty else {
            return nil
        }

        let notification = realm.objects(NotificationStorageItem.self)
            .filter(
                "owner == %@ AND category_ == %@ AND isRead == false",
                owner,
                XMPPNotificationsManager.Category.mention.rawValue
            )
            .toArray()
            .filter {
                ($0.sourceConversationType ?? .group) == .group
                    && $0.sourceChatJid == jid
                    && $0.sourceArchivedId == mentionId
                    && $0.mentionLinkStatus != .invalidated
                    && $0.mentionLinkStatus != .missing
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.sourceMessageDate ?? lhs.date
                let rhsDate = rhs.sourceMessageDate ?? rhs.date
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }

                return (lhs.sourceArchivedId ?? "") > (rhs.sourceArchivedId ?? "")
            }
            .first

        let sourceDate = notification?.sourceMessageDate
            ?? notification?.date
            ?? (chat.messageDate == Date(timeIntervalSince1970: 0) ? nil : chat.messageDate)
            ?? Date()

        return ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: mentionId,
                messageId: notification?.sourceMessageId,
                authorId: notification?.sourceSenderId,
                bodyFingerprint: notification?.sourceBodyFingerprint,
                sourceDate: sourceDate
            ),
            highlight: false,
            markReadOnVisible: true,
            source: .mentionNotification
        )
    }

    internal func unreadMentionOpenRequest(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ChatOpenMessageRequest? {
        do {
            let realm = try WRealm.safe()
            return Self.unreadMentionOpenRequest(
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                in: realm
            )
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if AudioManager.shared.player == nil {
            return 0
        } else {
            return 44
        }
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = self.datasource[indexPath.row]
        switch item.specialMessageKind {
            case .none: return 84
            default: return 48
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if self.showSkeleton.value {
            return
        }
        let item = self.datasource[indexPath.row]
        switch item.specialMessageKind {
            case .contact:
                self.leftMenuSelectRootCategoryDelegate?.selectRootScreenAndCategory(screen: "contacts", category: "show_all_contacts")
            case .invite:
                self.leftMenuSelectRootCategoryDelegate?.selectRootScreenAndCategory(screen: "groups", category: "show_all_invites")
            case .none:
                self.stackNewChat(
                    owner: item.owner,
                    jid: item.jid,
                    conversationType: item.conversationType,
                    openMessageRequest: self.unreadMentionOpenRequest(
                        owner: item.owner,
                        jid: item.jid,
                        conversationType: item.conversationType
                    )
                )
        }
    }
    
    public func stackNewChat(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        openMessageRequest: ChatOpenMessageRequest? = nil,
        configure configureCallback: ((ChatViewController?) -> Void)? = nil
    ) {
        if let oldVc = self.currentChatVC,
           oldVc.jid == jid, oldVc.owner == owner, oldVc.conversationType == conversationType {
            configureCallback?(oldVc)
            if let openMessageRequest,
               oldVc.pendingOpenMessageRequest == nil {
                oldVc.queueOpenMessageRequest(openMessageRequest)
            } else if oldVc.pendingOpenMessageRequest != nil {
                oldVc.performPendingOpenMessageRequestIfNeeded()
            } else {
                oldVc.scrollToLastOrUnreadItem()
            }
            return
        }
        self.currentChatVC = nil
        let vc = ChatViewController()
        vc.owner = owner
        vc.jid = jid
        vc.conversationType = conversationType
        vc.sharedPlayerPaneldelegae = self
        vc.lastChatsDisplayDelegate = self
        if let openMessageRequest {
            vc.pendingOpenMessageRequest = openMessageRequest
        }
        configureCallback?(vc)
        if UIDevice.current.userInterfaceIdiom == .pad && CommonConfigManager.shared.config.interface_type == "split" {
            self.currentChatVC = vc
            self.playerViewToolbar.delegate = vc
        }
        showStacked(vc, in: self)
    }
}

protocol LastChatsDisplayDelegate {
    func shouldMakeDialogSelected(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType)
}

extension LastChatsViewController: LastChatsDisplayDelegate {
    func shouldMakeDialogSelected(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) {
        if let index = self.datasource.firstIndex(where: {
            return $0.jid == jid && $0.owner == owner && $0.conversationType == conversationType
        }) {
            self.tableView
                .indexPathsForSelectedRows?
                .compactMap { $0 }
                .forEach { self.tableView.deselectRow(at: $0, animated: true) }
            self.tableView.selectRow(at: IndexPath(row: index, section: 0), animated: true, scrollPosition: .middle)
        }
    }
    
    
}
