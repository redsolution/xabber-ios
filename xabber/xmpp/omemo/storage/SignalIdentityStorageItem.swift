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

class SignalIdentityStorageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var deviceId: Int = 0
    
    @objc dynamic var primary: String = ""
    @objc dynamic var identityKey: String? = nil
    @objc dynamic var signedPreKey: String? = nil
    @objc dynamic var signedPreKeyId: Int = 0
    @objc dynamic var signedPreKeyTimestamp: Double = 0
    @objc dynamic var signedPreKeySignature: String? = nil
    @objc dynamic var name: String = ""
    
    @objc dynamic var isPublicated: Bool = false
    
    static func genRpimary(owner: String, jid: String, deviceId: Int) -> String {
        return [owner, jid, "\(deviceId)"].prp()
    }
    
}
