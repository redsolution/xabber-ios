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

class RosterGroupStorageItem: Object {
    
    static let systemGroupName = "com.xabber.system.roster.group"
    static let notInRosterGroupName = "com.xabber.system.roster.noInRoster"
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var name: String = ""
    @objc dynamic var isSystemGroup: Bool = false
    @objc dynamic var isCollapsed: Bool = false
    @objc dynamic var order: Int = 0
    
    var contacts: List<RosterStorageItem> = List<RosterStorageItem>()
    
    public static func genPrimary(name: String, owner: String) -> String {
        return [name, owner].prp()
    }
    
    var groupName: String {
        get {
            switch name {
            case RosterGroupStorageItem.systemGroupName: return "General".localizeString(id: "groupchat_general", arguments: [])
            case RosterGroupStorageItem.notInRosterGroupName: return "Not in roster".localizeString(id: "groupchat_not_roster", arguments: [])
            default: return name
            }
        }
    }
}

