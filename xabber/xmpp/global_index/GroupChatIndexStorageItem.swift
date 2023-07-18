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

class GroupChatIndexStorageItem: Object {
    
    enum Membership: Int {
        case none
        case open
        case memberOnly
    }
    
    enum Privacy: Int {
        case none
        case isPublic
    }
    
    override static func primaryKey() -> String? {
        return "jid"
    }
    
    @objc dynamic var jid: String = ""
    @objc dynamic var itemId: String = ""
    @objc dynamic var name: String = ""
    @objc dynamic var text: String = ""
    @objc dynamic var membership_: Int = Membership.none.rawValue
    @objc dynamic var privacy_: Int = Privacy.none.rawValue
    @objc dynamic var members: Int = 0
    @objc dynamic var messagesCount: Int = 0
    
    var membership: Membership {
        get {
            switch membership_ {
            case Membership.none.rawValue: return .none
            case Membership.open.rawValue: return .open
            case Membership.memberOnly.rawValue: return .memberOnly
            default: return .none
            }
        } set {
            membership_ = newValue.rawValue
        }
    }
    var privacy: Privacy {
        get {
            switch privacy_ {
            case Privacy.none.rawValue: return .none
            case Privacy.isPublic.rawValue: return .isPublic
            default: return .none
            }
        } set {
            privacy_ = newValue.rawValue
        }
    }
    
}
