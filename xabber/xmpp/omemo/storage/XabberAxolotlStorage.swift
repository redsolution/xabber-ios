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

// Historical Realm type names remain stable so existing local history and
// device/trust projections can be opened without a database migration.
enum XabberAxolotlStorageError: Error {
    case localKeyMaterialUnavailable
}

/// Public device binding only. Cryptographic keys and sessions belong to the
/// protected XabberOMEMO2Storage aggregate backed by XabberCryptoSwift.
class XabberAxolotlStorage: NSObject {
    private var deviceId: Int
    let owner: String

    init(withOwner owner: String) {
        self.owner = owner
        self.deviceId = CredentialsManager.shared.getDeviceId(for: owner) ?? -1
        super.init()
    }

    func localDeviceId() -> Int { deviceId }

    func bindExistingDevice(deviceID: Int) throws {
        guard deviceID > 0, deviceID <= Int(Int32.max) else {
            throw XabberAxolotlStorageError.localKeyMaterialUnavailable
        }
        deviceId = deviceID
    }
}

class SessionRecordStorageItem: Object {
    static let legacyProfile = "legacy-signal"
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var deviceId: Int = 0
    
    @objc dynamic var primary: String = ""
    
    @objc dynamic var record: Data? = nil
    @objc dynamic var profile_: String = SessionRecordStorageItem.legacyProfile
    
    static func genPrimary(owner: String, jid: String, deviceId: Int) -> String {
        return [owner, jid, "\(deviceId)"].prp()
    }
    
}

class SignalTrustedIdentityStoreageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var deviceId: Int = 0
    
    @objc dynamic var primary: String = ""
    
    @objc dynamic var identity: Data? = nil
    
    static func genPrimary(owner: String, jid: String, deviceId: Int) -> String {
        return [owner, jid, "\(deviceId)"].prp()
    }
    
}

class SignalSenderKeyStoreageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var deviceId: Int = 0
    @objc dynamic var groupId: String = ""
    
    @objc dynamic var primary: String = ""
    
    @objc dynamic var senderKey: Data? = nil
    
    static func genPrimary(owner: String, jid: String, deviceId: Int, groupId: String) -> String {
        return [owner, jid, "\(deviceId)", groupId].prp()
    }
    
}
