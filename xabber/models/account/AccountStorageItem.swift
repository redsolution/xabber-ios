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

/**
 *    Account properties representation in database
 *    primary key for instance is an account JID
 **/
class AccountStorageItem: Object {
    override static func primaryKey() -> String? {
        return "jid"
    }
    @objc dynamic var order: Int = 0
    @objc dynamic var jid: String = ""
    @objc dynamic var host: String = ""
    @objc dynamic var savePassword: Bool = true
    @objc dynamic var manuallySetHost: Bool = false
    @objc dynamic var port: Int = 5222
    
    @objc dynamic var username: String = ""
    @objc dynamic var enabled: Bool = true
    @objc dynamic var node: String = ""
    @objc dynamic var service: String = ""
    @objc dynamic var away: Date = Date(timeIntervalSinceReferenceDate: 1000)
    @objc dynamic var statusMessage: String = ""
    
    @objc dynamic var colorKey: String = ""
        
    @objc dynamic var deviceUuid: String = ""
    @objc dynamic var xTokenUID: String = ""
    @objc dynamic var xTokenSupport: Bool = false
    @objc dynamic var clientSyncSupport: Bool = false
        
    @objc dynamic var resource: ResourceStorageItem? = nil
    
    @objc dynamic var isCollapsed: Bool = false
    
    @objc dynamic var isEncryptionEnabled: Bool = true
    @objc dynamic var isOmemoDevicesListReceived: Bool = false
    @objc dynamic var isDevicesListReceived: Bool = false
    
    @objc dynamic var createdAt: Date = Date()
    
    @objc dynamic var deviceName: String = ""
    
    @objc dynamic var oldschoolAvatarKey: String? = nil
    @objc dynamic var avatarMaxUrl: String? = nil
    @objc dynamic var avatarMinUrl: String? = nil
    @objc dynamic var avatarUpdatedTS: Double = -1
    @objc dynamic var updatedTS: Double = -1
    @objc dynamic var encryptionUpdatedTS: Double = -1
    @objc dynamic var counter: String = "1"
    
    public var avatarUrl: String? {
        return avatarMaxUrl ?? avatarMinUrl ?? oldschoolAvatarKey
    }
}
