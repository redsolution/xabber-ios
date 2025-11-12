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
    
    public static func genPrimary(inviteId: String, owner: String) -> String {
        return [inviteId, owner].prp()
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var groupchat: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var sender: String = ""
    @objc dynamic var inviteId: String = ""
    @objc dynamic var date: Date = Date(timeIntervalSinceReferenceDate: 0)
    @objc dynamic var reason: String? = nil
    @objc dynamic var outgoing: Bool = true
    @objc dynamic var isRead: Bool = false
    @objc dynamic var isHidden: Bool = false
    @objc dynamic var temporary: Bool = true
    @objc dynamic var isProcessed: Bool = false
    @objc dynamic var entity_: String = RosterItemEntity.groupchat.rawValue
    
    @objc dynamic var isGroupInfoLoaded: Bool = false
    
    @objc dynamic var isAnonymous: Bool = false
    
    var entity: RosterItemEntity {
        get {
            return RosterItemEntity(rawValue: self.entity_) ?? .groupchat
        } set {
            self.entity_ = newValue.rawValue
        }
    }
    
}
