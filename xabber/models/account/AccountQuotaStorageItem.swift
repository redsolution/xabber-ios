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

class AccountQuotaStorageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    
    @objc dynamic var jid: String = ""
    @objc dynamic var quotaBytes: Int = 0
    @objc dynamic var totalBytes: Int = 0
    @objc dynamic var totalCount: Int = 0
    @objc dynamic var imagesBytes: Int = 0
    @objc dynamic var imagesCount: Int = 0
    @objc dynamic var videosBytes: Int = 0
    @objc dynamic var videosCount: Int = 0
    @objc dynamic var filesBytes: Int = 0
    @objc dynamic var filesCount: Int = 0
    @objc dynamic var audioBytes: Int = 0
    @objc dynamic var audioCount: Int = 0
    @objc dynamic var voicesBytes: Int = 0
    @objc dynamic var voicesCount: Int = 0
    @objc dynamic var avatarsBytes: Int = 0
    @objc dynamic var avatarsCount: Int = 0
    
    var quota: String {
        get {
            return AccountQuotaStorageItem.beautify(size: quotaBytes)
        }
    }
    
    var total: String {
        get {
            return AccountQuotaStorageItem.beautify(size: totalBytes)
        }
    }
    
    var imagesUsed: String {
        get {
            return AccountQuotaStorageItem.beautify(size: imagesBytes)
        }
    }
    
    var videosUsed: String {
        get {
            return AccountQuotaStorageItem.beautify(size: videosBytes)
        }
    }
    
    var filesUsed: String {
        get {
            return AccountQuotaStorageItem.beautify(size: filesBytes)
        }
    }
    
    var voicesUsed: String {
        get {
            return AccountQuotaStorageItem.beautify(size: voicesBytes)
        }
    }
    
    var avatarUsed: String {
        get {
            return AccountQuotaStorageItem.beautify(size: avatarsBytes)
        }
    }
    
    static func beautify(size: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .decimal
        return formatter
            .string(fromByteCount: Int64(size))
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "MB", with: "MiB")
            .replacingOccurrences(of: "МБ", with: "MiB")
            .replacingOccurrences(of: "KB", with: "KiB")
            .replacingOccurrences(of: "КБ", with: "KiB")
            .replacingOccurrences(of: "Zero", with: "0")
        
    }
    
    static func genPrimary(jid: String) -> String {
        return jid
    }
}
