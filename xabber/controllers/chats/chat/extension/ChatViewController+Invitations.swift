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
import CocoaLumberjack


extension ChatViewController {
    
    private final func onInviteActionSelected() {
        DispatchQueue.main.async {
            self.view.makeToastActivity(.center)
        }
    }
    
    private final func onInviteCallbackCalled() {
        DispatchQueue.main.async {
            self.view.hideToastActivity()
        }
    }
    
    internal func didReceiveInvite(_ primary: String) {
        do {
            let repository = GroupRepository(realm: try WRealm.safe())
            guard let invite = try repository.invite(primary: primary),
                  invite.owner == GroupStorageKey.bareJID(owner),
                  invite.groupJID == GroupStorageKey.bareJID(jid) else {
                return
            }
            let projection = try repository.projection(
                owner: owner,
                groupJID: jid
            )
            if projection.state.isActive {
                AccountManager.shared.find(for: owner)?
                    .removeCanonicalGroupInvite(jid)
                return
            }
            showInviteActionsMenu(invite)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func showInviteActionsMenuFromNotification() {
        let invite: GroupInviteRecord
        do {
            guard let storedInvite = try GroupRepository(
                realm: WRealm.safe()
            ).incomingInvite(owner: owner, groupJID: jid) else {
                return
            }
            invite = storedInvite
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return
        }
        showInviteActionsMenu(invite)
    }

    private final func showInviteActionsMenu(_ invite: GroupInviteRecord) {
        DispatchQueue.main.async {
            guard self.presentedViewController == nil else {
                return
            }
            let message: String
            if invite.preview?.parentJID != nil {
                message = "You are invited to join this chat"
            } else if invite.preview?.privacy == .incognito {
                message = "You are invited to join this incognito group"
            } else {
                message = "You are invited to join this group"
            }

            let alert = UIAlertController(title: nil, message: message, preferredStyle: .actionSheet)
            let joinTitle = invite.preview?.parentJID == nil
                ? "Join group".localizeString(id: "join_group", arguments: [])
                : "Join chat".localizeString(id: "join_chat", arguments: [])
            alert.addAction(UIAlertAction(title: joinTitle, style: .default) { _ in
                self.onInviteActionSelected()
                self.onAcceptInvite()
            })
            alert.addAction(UIAlertAction(title: "Decline".localizeString(id: "decline", arguments: []), style: .default) { _ in
                self.onInviteActionSelected()
                self.onDeclineInvite()
            })
            if invite.inviter?.jid != nil {
                alert.addAction(UIAlertAction(title: "Block".localizeString(id: "contact_bar_block", arguments: []), style: .destructive) { _ in
                    self.onInviteActionSelected()
                    self.onBlockInvite()
                })
            }
            alert.addAction(UIAlertAction(title: "Cancel".localizeString(id: "cancel", arguments: []), style: .cancel))
            if let popover = alert.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            self.present(alert, animated: true)
        }
    }
    
    private final func onAcceptInvite() {
        guard let account = AccountManager.shared.find(for: owner) else {
            onReceiveInviteError(GroupchatServiceError.notPrepared)
            return
        }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                try await CanonicalGroupMembershipLifecycle.join(
                    account: account,
                    groupJID: self.jid
                )
                account.removeCanonicalGroupInvite(self.jid)
                self.onInviteCallbackCalled()
            } catch {
                self.onReceiveInviteError(error)
            }
        }
    }
    
    private final func onReceiveInviteError(_ error: Error) {
        self.onInviteCallbackCalled()
        DispatchQueue.main.async {
            ErrorMessagePresenter().present(
                in: self,
                alert: true,
                message: [
                    "Error".localizeString(id: "error", arguments: []),
                    CanonicalGroupMembershipLifecycle.localizedErrorMessage(error)
                ].joined(separator: ": "),
                animated: true
            ) {
                self.navigationController?.popViewController(animated: true)
            }
        }
    }
    
    private final func onDeclineInvite() {
        performDeclineInvite(block: false)
    }
    
    private final func performDeclineInvite(block: Bool) {
        guard let account = AccountManager.shared.find(for: owner) else {
            onReceiveInviteError(GroupchatServiceError.notPrepared)
            return
        }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                let invite = try GroupRepository(
                    realm: WRealm.safe()
                ).incomingInvite(owner: self.owner, groupJID: self.jid)
                try await account.groupchatService.declineInvite(groupJID: self.jid)
                account.removeCanonicalGroupInvite(self.jid)
                if block, let inviterJID = invite?.inviter?.jid {
                    account.action { user, stream in
                        user.blocked.blockContact(stream, jid: inviterJID)
                    }
                }
                self.onInviteCallbackCalled()
                self.navigationController?.popToRootViewController(animated: true)
            } catch {
                self.onReceiveInviteError(error)
            }
        }
    }
    
    private final func onBlockInvite() {
        performDeclineInvite(block: true)
    }
    
}
