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

class RosterDisplayNameStorageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var displayName: String = ""
    
    public static func genPrimary(jid: String, owner: String) -> String {
        return [jid, owner].prp()
    }
    
    public static func createOrUpdate(jid: String, owner: String, displayName: String, commitTransaction: Bool) {
        func transaction(_ commitTransaction: Bool, block: (() -> Void)) {
            do {
                let realm = try Realm()
                if commitTransaction {
                    try realm.write(block)
                } else {
                    block()
                }
            } catch {
                print(error.localizedDescription)
            }
        }
        do {
            let realm = try Realm()
            let primary = RosterDisplayNameStorageItem.genPrimary(jid: jid, owner: owner)
            if let instance = realm.object(ofType: RosterDisplayNameStorageItem.self,
                                           forPrimaryKey: primary) {
                transaction(commitTransaction) {
                    instance.displayName = displayName
                }
            } else {
                let instance = RosterDisplayNameStorageItem()
                instance.primary = primary
                instance.owner = owner
                instance.displayName = displayName
                transaction(commitTransaction) {
                    realm.add(instance, update: .modified)
                }
            }
        } catch {
            print(error.localizedDescription)
        }
    }
}
