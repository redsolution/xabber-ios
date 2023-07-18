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

class CallMetadataStorageItem: Object {
    
    enum CallState: Int {
        case initiated
        case started
        case ended
        case rejected
        case failed
        case retracted
    }
    
    override static func primaryKey() -> String? {
        return "sid"
    }
    
    @objc dynamic var sid: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var opponent: String = ""
    @objc dynamic var dateStart: Date = Date()
    @objc dynamic var dateEnd: Date? = nil
    @objc dynamic var isCallEnded: Bool = false
    @objc dynamic var _callState: Int = 0
    
    @objc dynamic var income: Bool = false
    @objc dynamic var cancelled: Bool = false
    
    @objc dynamic var isDeleted: Bool = false
    
    open var callState: CallState {
        get {
            switch _callState {
            case CallState.initiated.rawValue:  return .initiated
            case CallState.started.rawValue:    return .started
            case CallState.ended.rawValue:      return .ended
            case CallState.rejected.rawValue:   return .rejected
            case CallState.failed.rawValue:     return .failed
            case CallState.retracted.rawValue:  return .retracted
            default: return .failed
            }
        } set {
            _callState = newValue.rawValue
        }
    }
    
    open var duration: TimeInterval {
        get {
            return dateStart.timeIntervalSince(dateEnd ?? dateStart)
        }
    }
}
