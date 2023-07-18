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

extension LastCallsViewController {
    internal func onCall(jid: String, owner: String) {
        VoIPManager.shared.startCall(owner: owner, jid: jid)
//        CallManager.shared.startCall(self, owner: owner, to: jid, type: .audio)
    }
    
    internal func onDelete(_ sid: String) {
//        DispatchQueue.global(qos: .utility).async {
            do {
                let realm = try WRealm.safe()
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm
                            .object(ofType: CallMetadataStorageItem.self, forPrimaryKey: sid)?
                            .isDeleted = true
                    }
                }
            } catch {
                DDLogDebug("cant delete call")
            }
//        }
    }
}
