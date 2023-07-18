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
import Realm

class WRealm {
//    var bgtask: UIBackgroundTaskIdentifier?
    
    static func safe() throws -> Realm {
        return try Realm()
//        do {
//            let realm = try Realm()
//            WRealm().bgtask = UIApplication.shared.beginBackgroundTask(withName: "com.clandestino.realm.bg_task.\(String.randomString(length: 8, includeNumber: true))", expirationHandler: nil)
//            return realm
//        } catch {
//            throw(error)
//
//        }
    }
    
//    @objc
//    private func onExpire() {
//        if let id = self.bgtask {
//            UIApplication.shared.endBackgroundTask(id)
//        }
//    }
//
//    deinit {
//        if let id = self.bgtask {
//            UIApplication.shared.endBackgroundTask(id)
//        }
//    }
}
