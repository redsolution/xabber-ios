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
        return "jid"
    }
    
    @objc dynamic var jid: String = ""
    @objc dynamic var rawQuota: Int = 0
    @objc dynamic var rawUsed: Int = 0
    @objc dynamic var rawImages: Int = 0
    @objc dynamic var rawVideos: Int = 0
    @objc dynamic var rawFiles: Int = 0
    @objc dynamic var rawVoices: Int = 0
    
    var quota: String {
        get {
            return AccountQuotaStorageItem.beautify(size: rawQuota)
        }
    }
    
    var used: String {
        get {
            return AccountQuotaStorageItem.beautify(size: rawUsed)
        }
    }
    
    var imagesUsed: String {
        get {
            return AccountQuotaStorageItem.beautify(size: rawImages)
        }
    }
    
    var videosUsed: String {
        get {
            return AccountQuotaStorageItem.beautify(size: rawVideos)
        }
    }
    
    var filesUsed: String {
        get {
            return AccountQuotaStorageItem.beautify(size: rawFiles)
        }
    }
    
    var voicesUsed: String {
        get {
            return AccountQuotaStorageItem.beautify(size: rawVoices)
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
}
