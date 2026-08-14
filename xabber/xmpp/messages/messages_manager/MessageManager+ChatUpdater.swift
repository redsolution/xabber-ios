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
import XMPPFramework
import RealmSwift

extension MessageManager {
        
    public func runChatUpdateTasks(_ xmppStream: XMPPStream, for jid: String, conversationType: ClientSynchronizationManager.ConversationType, callback: (() -> Void)?) {
        if conversationType == .group {
            refreshCanonicalGroupState(jid)
            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                session.retract?.enableForGroupchat(stream, jid: jid)
            }) {
                AccountManager.shared.find(for: self.owner)?.delayedAction(delay: 3, toExecute: { (user, stream) in
                    user.msgDeleteManager.enableForGroupchat(stream, jid: jid)
                })
            }
        } else if conversationType == .channel {
            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                session.retract?.enableForGroupchat(stream, jid: jid)
            }) {
                AccountManager.shared.find(for: self.owner)?.delayedAction(delay: 3, toExecute: { (user, stream) in
                    user.msgDeleteManager.enableForGroupchat(stream, jid: jid)
                })
            }
        }
    }

    private func refreshCanonicalGroupState(_ rawGroupJID: String) {
        guard let account = AccountManager.shared.find(for: owner) else {
            return
        }
        let groupJID = GroupStorageKey.bareJID(rawGroupJID)

        Task { [weak account] in
            guard let account else { return }
            do {
                let initialProjection = try GroupRepository(
                    realm: WRealm.safe()
                ).projection(owner: account.jid, groupJID: groupJID)
                guard initialProjection.state.selfSubscription == .both else {
                    return
                }

                let snapshot = try await account.groupchatService.refreshGroup(
                    groupJID: groupJID
                )
                guard try GroupRepository(realm: WRealm.safe()).applySnapshot(
                    snapshot,
                    owner: account.jid,
                    groupJID: groupJID
                ) == .applied else {
                    return
                }

                let members = try await account.groupchatService.refreshMembers(
                    groupJID: groupJID
                )
                let selfMemberID: String? = try {
                    let repository = GroupRepository(realm: try WRealm.safe())
                    guard try repository.replaceMembers(
                        members,
                        owner: account.jid,
                        groupJID: groupJID
                    ) == .applied else {
                        return nil
                    }

                    let ownerBareJID = GroupStorageKey.bareJID(account.jid)
                    let memberID = initialProjection.selfMemberID ?? members.first {
                        $0.jid.map(GroupStorageKey.bareJID) == ownerBareJID
                    }?.id
                    try repository.setSelfMembership(
                        .both,
                        memberID: memberID,
                        owner: account.jid,
                        groupJID: groupJID
                    )
                    return memberID
                }()
                guard let selfMemberID else {
                    return
                }

                let permissions = try await account.groupchatService.getPermissions(
                    groupJID: groupJID,
                    scope: .direct,
                    targetMemberID: selfMemberID
                )
                try GroupRepository(realm: WRealm.safe()).replacePermissionSet(
                    permissions,
                    owner: account.jid,
                    groupJID: groupJID
                )
            } catch is CancellationError {
                return
            } catch {
                DDLogDebug(
                    "Canonical group chat refresh failed for \(groupJID): \(error)"
                )
            }
        }
    }
}
