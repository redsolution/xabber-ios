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
    func tableView(_ tableView: UITableView, canFocusRowAt indexPath: IndexPath) -> Bool {
        false
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

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

        let request = ChatOpenMessageRequest(
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

        return request
    }

    internal static func initialOpenRequest(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        explicitOpenMessageRequest: ChatOpenMessageRequest?,
        in realm: Realm
    ) -> ChatOpenMessageRequest? {
        let chat = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
        )

        guard let chat = chat else {
            guard let explicitOpenMessageRequest,
                  ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: explicitOpenMessageRequest.source) else {
                return nil
            }
            return explicitOpenMessageRequest
        }

        let savedPosition = ChatSavedVisiblePosition(
            messagePrimary: ChatInitialPositionPolicy.normalizedId(chat.lastVisibleMessagePrimary),
            archivedId: ChatInitialPositionPolicy.normalizedId(chat.lastVisibleMessageArchivedId),
            messageId: ChatInitialPositionPolicy.normalizedId(chat.lastVisibleMessageId),
            sourceDate: chat.lastVisibleMessageDate ?? chat.messageDate
        )
        let state = ChatInitialPositionPolicy.ChatState(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            unread: chat.unread,
            syncUnreadCount: chat.syncUnreadCount,
            syncUnreadAfterId: chat.syncUnreadAfterId,
            lastReadId: chat.lastReadId,
            lastMessageId: chat.lastMessageId,
            syncSnapshotLastArchiveId: chat.syncSnapshotLastArchiveId,
            messageDate: chat.messageDate,
            savedPosition: savedPosition.hasAnchor ? savedPosition : nil,
            savedAtLastMessageId: chat.lastVisiblePositionSavedAtLastMessageId,
            savedAtSnapshotLastArchiveId: chat.lastVisiblePositionSavedAtSnapshotLastArchiveId
        )

        let decision = ChatInitialPositionPolicy.decision(for: state, explicitRequest: explicitOpenMessageRequest)
        let result: ChatOpenMessageRequest?
        switch decision {
        case .open(let request):
            result = request
        case .bottom:
            result = nil
        }
        return result
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

    internal func initialOpenRequest(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        explicitOpenMessageRequest: ChatOpenMessageRequest? = nil
    ) -> ChatOpenMessageRequest? {
        do {
            let realm = try WRealm.safe()
            return Self.initialOpenRequest(
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                explicitOpenMessageRequest: explicitOpenMessageRequest,
                in: realm
            )
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
            guard let explicitOpenMessageRequest,
                  ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: explicitOpenMessageRequest.source) else {
                return nil
            }
            return explicitOpenMessageRequest
        }
    }

    internal static func voicePlayerOpenRequest(route: VoiceMessagePlaybackRoute) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: route.jid,
            owner: route.owner,
            conversationType: route.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: route.messagePrimary,
                archivedId: route.archivedId,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: route.sourceDate
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .voicePlayer
        )
    }

    private func applyInitialOpenIntent(
        to chatVc: ChatViewController,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        explicitOpenMessageRequest: ChatOpenMessageRequest? = nil
    ) {
        if let initialRequest = self.initialOpenRequest(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            explicitOpenMessageRequest: explicitOpenMessageRequest
        ) {
            chatVc.queueOpenMessageRequest(initialRequest)
            return
        }

        if chatVc.pendingOpenMessageRequest != nil || chatVc.activeAnchorExecutionState != nil {
            chatVc.performPendingOpenMessageRequestIfNeeded()
            return
        }

        if !chatVc.pendingForceLatestOpen,
           ChatOpenMessageRequestHandlingPolicy.shouldForceLatestOnOpen() {
            chatVc.requestForceLatestOpen(animated: false)
        }
    }

    private func applyUnreadMentionIntentIfAllowed(
        _ openMessageRequest: ChatOpenMessageRequest?,
        to chatVc: ChatViewController
    ) {
        if let openMessageRequest,
           ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: openMessageRequest.source) {
            chatVc.queueOpenMessageRequest(openMessageRequest)
            return
        }

        if chatVc.pendingOpenMessageRequest != nil || chatVc.activeAnchorExecutionState != nil {
            chatVc.performPendingOpenMessageRequestIfNeeded()
            return
        }

        if !chatVc.pendingForceLatestOpen,
           ChatOpenMessageRequestHandlingPolicy.shouldForceLatestOnOpen() {
            chatVc.requestForceLatestOpen(animated: false)
        }
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if isShowingSearchResults {
            return 84
        }
        guard let item = self.item(at: indexPath) else { return 0 }
        switch item.specialMessageKind {
            case .none: return 84
            default: return 48
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isShowingSearchResults {
            guard let item = chatSearchResultsController.item(at: indexPath) else { return }
            openSearchResult(item)
            return
        }
        if self.showSkeleton.value {
            return
        }
        guard let item = self.item(at: indexPath) else {
            return
        }
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
                    openMessageRequest: nil
                ) { [weak self] chatVc in
                    guard let self,
                          let chatVc,
                          item.conversationType == .group else {
                        return
                    }
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        let openMessageRequest = self.unreadMentionOpenRequest(
                            owner: item.owner,
                            jid: item.jid,
                            conversationType: item.conversationType
                        )
                        DispatchQueue.main.async {
                            self.applyUnreadMentionIntentIfAllowed(openMessageRequest, to: chatVc)
                        }
                    }
                }
        }
    }
    
    public func stackNewChat(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        openMessageRequest: ChatOpenMessageRequest? = nil,
        configure configureCallback: ((ChatViewController?) -> Void)? = nil
    ) {
        let route = stackedNavigationRoute(for: self)
        let usesSplitDetailColumn = route == .splitDetailReplacement
        setSelectedChat(
            jid: jid,
            owner: owner,
            conversationType: conversationType,
            animated: true
        )

        if !usesSplitDetailColumn {
            self.currentChatVC = nil
        }

        if usesSplitDetailColumn,
           let oldVc = self.currentChatVC,
           oldVc.jid == jid, oldVc.owner == owner, oldVc.conversationType == conversationType {
            self.playerViewToolbar.delegate = oldVc
            configureCallback?(oldVc)
            self.applyInitialOpenIntent(
                to: oldVc,
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                explicitOpenMessageRequest: openMessageRequest
            )
            return
        }
        self.currentChatVC = nil
        let vc = ChatViewController()
        vc.owner = owner
        vc.jid = jid
        vc.conversationType = conversationType
        vc.sharedPlayerPaneldelegae = self
        vc.lastChatsDisplayDelegate = self
        self.applyInitialOpenIntent(
            to: vc,
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            explicitOpenMessageRequest: openMessageRequest
        )
        configureCallback?(vc)
        if usesSplitDetailColumn {
            self.currentChatVC = vc
            self.playerViewToolbar.delegate = vc
        } else {
            self.currentChatVC = nil
        }
        showStacked(vc, in: self)
    }
}

protocol LastChatsDisplayDelegate {
    func shouldMakeDialogSelected(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType)
}

extension LastChatsViewController: LastChatsDisplayDelegate {
    func shouldMakeDialogSelected(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) {
        setSelectedChat(
            jid: jid,
            owner: owner,
            conversationType: conversationType,
            animated: true,
            scrollPosition: .middle
        )
    }
    
    
}
