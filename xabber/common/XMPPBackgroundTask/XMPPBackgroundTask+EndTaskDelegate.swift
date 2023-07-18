//
//  XMPPBackgroundTask+EndTaskDelegate.swift
//  xabber
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
import RealmSwift
import CocoaLumberjack

protocol XMPPBackgroundTaskDelegate {
    func backgroundTaskDidEnd(shouldContinue: Bool)
}

extension XMPPBackgroundTask: XMPPBackgroundTaskDelegate {
    func backgroundTaskDidEnd(shouldContinue: Bool) {
        switch taskType {
        case .messageHistory(let targetJid, let conversationType):
//            if shouldContinue {
//                AccountManager.shared.continueBackgroundUpdateChat(owner: jid, jid: targetJid, conversationType: conversationType)
//            }
            do {
                let realm = try WRealm.safe()
                try realm.write {
                    realm
                        .object(ofType: LastChatsStorageItem.self,
                                forPrimaryKey: LastChatsStorageItem
                                    .genPrimary(
                                        jid: targetJid,
                                        owner: jid,
                                        conversationType: conversationType))?
                        .isHistoryGapFixedForSession = true
                }
            } catch {
                DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
            }
//        case .fixHistory(let targetJid, let conversationType):
//            NotificationCenter.default.post(name: XMPPBackgroundTask.endFixHistoryTask, object: nil, userInfo: ["jid": targetJid])
//            do {
//                let realm = try WRealm.safe()
//                try realm.write {
//                    realm
//                        .object(ofType: LastChatsStorageItem.self,
//                                forPrimaryKey: LastChatsStorageItem
//                                    .genPrimary(
//                                        jid: targetJid,
//                                        owner: jid,
//                                        conversationType: conversationType))?
//                        .isHistoryGapFixedForSession = true
//                }
//            } catch {
//                DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
//            }
        default: break
        }
        self.queue.asyncAfter(deadline: .now() + 2) {
            self.stream.disconnectAfterSending()
            self.endBackgroundUpdateTask()
        }
        
    }
    
    func backgroundTaskStop() {
        self.queue.asyncAfter(deadline: .now() + 2) {
            self.stream.disconnect()
            self.stream.removeDelegate(self)
            self.endBackgroundUpdateTask()
        }
    }
}
