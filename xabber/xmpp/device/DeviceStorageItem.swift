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

class DeviceStorageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    override static func indexedProperties() -> [String] {
        return ["owner", "uid"]
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var uid: String = ""
    @objc dynamic var client: String = ""
    @objc dynamic var device: String = ""
    @objc dynamic var descr: String = ""
    @objc dynamic var ip: String = ""
    @objc dynamic var authDate: Date = Date()
    @objc dynamic var expire: Date = Date()
    @objc dynamic var resource: String? = nil
    @objc dynamic var isEncryptionEnabled: Bool = false
    @objc dynamic var omemoDeviceId: Int = -1
    
    open func configure(for owner: String, uid: String, ip: String, client: String, device: String, expire: Double, authDate: Double, descr: String) {
        self.primary = DeviceStorageItem.genPrimary(uid: uid, owner: owner)
        self.owner = owner
        self.uid = uid
        self.ip = ip
        self.client = client
        self.device = device
        self.descr = descr
        self.expire = Date(timeIntervalSince1970: TimeInterval(exactly: expire)!)
        self.authDate = Date(timeIntervalSince1970: TimeInterval(exactly: authDate)!)
    }
    
    public final func getResource() -> ResourceStorageItem? {
        do {
            let realm = try WRealm.safe()
            if let resource = self.resource {
                return realm.object(
                    ofType: ResourceStorageItem.self,
                    forPrimaryKey: ResourceStorageItem.genPrimary(
                        jid: self.owner,
                        owner: self.owner,
                        resource: resource
                    )
                )
            }
        } catch {
            DDLogDebug("DeviceStorageItem: \(#function). \(error.localizedDescription)")
        }
        return nil
    }
    
    var encryptionEnabled: Bool {
        get {
            return self.omemoDeviceId >= 0
        }
    }
    
    public static func genPrimary(uid: String, owner: String) -> String {
        return [uid, owner].prp()
    }
}
