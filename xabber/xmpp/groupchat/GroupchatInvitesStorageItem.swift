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


class GroupchatInvitesStorageItem: Object {
    
    public static func genPrimary(jid: String, groupchat: String, owner: String) -> String {
        return [jid, owner].prp()
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var groupchat: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var sender: String = ""
    @objc dynamic var date: Date = Date(timeIntervalSinceReferenceDate: 0)
    @objc dynamic var reason: String? = nil
    @objc dynamic var outgoing: Bool = true
    @objc dynamic var isRead: Bool = false
    @objc dynamic var isProcessed: Bool = false
    @objc dynamic var isAnonymous: Bool = false
    @objc dynamic var messageId: String = ""
    @objc dynamic var isFromGroupchat: Bool = false
}
