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
        if [.group, .channel].contains(conversationType) {
            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                session.retract?.enableForGroupchat(stream, jid: jid)
                session.groupchat?.requestUsers(stream, groupchat: jid)
                _ = session.groupchat?.requestChatSettingsForm(stream, groupchat: jid, callback: nil)
                _ = session.groupchat?.requestMyRights(stream, groupchat: jid)
            }) {
                AccountManager.shared.find(for: self.owner)?.delayedAction(delay: 3, toExecute: { (user, stream) in
                    user.msgDeleteManager.enableForGroupchat(stream, jid: jid)
                    user.groupchats.requestUsers(stream, groupchat: jid)
                    _ = user.groupchats.requestMyRights(stream, groupchat: jid)
                    _ = user.groupchats.requestChatSettingsForm(stream, groupchat: jid, callback: nil)
                })
            }
        }
    }
}
