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

class SignalDeviceStorageItem: Object {
    enum TrustState: String {
        case unknown = "unknown"
        case Ignore = "ignore"
        case trusted = "trusted"
        case fingerprintChanged = "fingerprintChanged"
    }

    override static func primaryKey() -> String? {
        return "primary"
    }

    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var deviceId: Int = 0
    @objc dynamic var name: String? = nil
    @objc dynamic var state_: String = TrustState.unknown.rawValue

    @objc dynamic var updateDate: Date = Date()
    @objc dynamic var fingerprint: String = ""
    @objc dynamic var freshlyUpdated: Bool = false
    @objc dynamic var isTrustedByCertificate: Bool = false
    @objc dynamic var signature: String? = nil
    @objc dynamic var signedBy: String? = nil
    @objc dynamic var signedAt: Double = -1
    @objc dynamic var isPublicated: Bool = false
    

    var state: TrustState {
        get {
            return TrustState(rawValue: self.state_) ?? .unknown
        } set {
            self.state_ = newValue.rawValue
        }
    }

    static func genPrimary(owner: String, jid: String, deviceId: Int) -> String {
        return [owner, jid, "\(deviceId)"].prp()
    }
}
