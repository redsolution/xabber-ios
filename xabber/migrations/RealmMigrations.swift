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


func realmMigrations(scheme: UInt64) {
    let config = Realm.Configuration(
//        fileURL: FileManager
//            .default
//            .containerURL(forSecurityApplicationGroupIdentifier: "group.clandestino.shared")?
//            .appendingPathComponent("clandestino.realm"),
//        encryptionKey: Data("absdasdfadsfasdfsadfadsfsadfadsfasddfasdfasdfdfghjfgjfghjfghjgfhjfgjfgjfgjfghjfghhjfgjhfghjadsf".bytes.prefix(64)),
        schemaVersion: scheme,
        
        
        migrationBlock: {
            migration, oldSchemaVersion in
            
        },
        deleteRealmIfMigrationNeeded: true) { total, used in
            let limit = 100 * 1024 * 1024
            return total > limit && Double(used) / Double(total) < 0/5
        }

    if _DEBUG {
        print(config.fileURL)
    }
    Realm.Configuration.defaultConfiguration = config
}
