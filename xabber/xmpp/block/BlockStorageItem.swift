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


class BlockStorageItem: Object {
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var timestamp: Date = Date()
    @objc dynamic var isGroupchatInvitation: Bool = false
    
    func set(jid: String, owner: String) {
        self.primary = [jid, owner].prp()
        self.jid = jid
        self.owner = owner
        self.timestamp = Date()
        if let resource = XMPPJID(string: jid)?.resource,
            TimeInterval(resource) != nil {
            self.isGroupchatInvitation = true
        }
    }
    
}
