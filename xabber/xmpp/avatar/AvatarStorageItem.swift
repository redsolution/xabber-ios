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

class AvatarStorageItem: Object {
    
    enum Kind: String {
        case none = "none"
        case vcard = "vcard"
        case pep = "pep"
        case xabber = "xabber"
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var imageHash: String? = nil
    @objc dynamic var imageMetadata_: String? = nil
    @objc dynamic var kind_: String = Kind.none.rawValue
    @objc dynamic var uploadUrl: String? = nil
    @objc dynamic var image32: String? = nil
    @objc dynamic var image48: String? = nil
    @objc dynamic var image64: String? = nil
    @objc dynamic var image96: String? = nil
    @objc dynamic var image128: String? = nil
    @objc dynamic var image192: String? = nil
    @objc dynamic var image256: String? = nil
    @objc dynamic var image384: String? = nil
    @objc dynamic var image512: String? = nil
    @objc dynamic var imageOriginal: String? = nil
    
    override class func indexedProperties() -> [String] {
        return ["jid", "owner"]
    }
    
    var kind: Kind {
        get {
            return Kind(rawValue: self.kind_) ?? .none
        } set {
            self.kind_ = newValue.rawValue
        }
    }
    
    var imageMetadata: [String: Any]? {
        get {
            if let metadata = imageMetadata_,
                let data = metadata.data(using: .utf8) {
                do {
                    return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                } catch {
                    DDLogDebug("cant create json object from avatar metadata for: \(primary)")
                }
            }
            return nil
        } set {
            if let value = newValue {
                do {
                    let data = try JSONSerialization.data(withJSONObject: value, options: [])
                    imageMetadata_ = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    DDLogDebug("cant encode avatar metadata for: \(primary)")
                }
            } else {
                imageMetadata_ = nil
            }
        }
    }
    
    var uri: URL? {
        get {
            if let fileUri = self.imageOriginal {
                return URL(string: fileUri)
            }
            return nil
        }
    }
    
    public static func genPrimary(jid: String, owner: String) -> String {
        return [jid, owner].prp()
    }
}
