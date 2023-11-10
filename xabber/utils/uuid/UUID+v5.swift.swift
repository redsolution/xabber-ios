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
import CommonCrypto

extension UUID {

    enum UUIDVersion: Int {
        case v5 = 5
    }

    enum UUIDv5NameSpace: String {
        case dns  = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
        case url  = "6ba7b811-9dad-11d1-80b4-00c04fd430c8"
        case oid  = "6ba7b812-9dad-11d1-80b4-00c04fd430c8"
        case x500 = "6ba7b814-9dad-11d1-80b4-00c04fd430c8"
        case xmpp = ""
    }

    static func getNSForXMPPUUIDV5() -> String {
        guard let path = Bundle.main.path(forResource: "subscribtions_secret", ofType: "plist"),
              let xml = FileManager.default.contents(atPath: path),
              let value = try? PropertyListDecoder().decode(SubscribtionsSecretStore.self, from: xml) else {
              return ""
        }
        
        return value.uuid_ns
    }
    
    init(name: String, nameSpace: String) {
        // Get UUID bytes from name space:
        var spaceUID = UUID(uuidString: nameSpace)?.uuid
        var data = withUnsafePointer(to: &spaceUID) { [count =  MemoryLayout.size(ofValue: spaceUID)] in
            Data(bytes: $0, count: count)
        }

        // Append name string in UTF-8 encoding:
        data.append(contentsOf: name.utf8)

        // Compute digest (MD5 or SHA1, depending on the version):
        var digest = [UInt8](repeating: 0, count:Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Void in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }

        // Set version bits:
        digest[6] &= 0x0F
        digest[6] |= 5 << 4
        // Set variant bits:
        digest[8] &= 0x3F
        digest[8] |= 0x80

        // Create UUID from digest:
        self = NSUUID(uuidBytes: digest) as UUID
    }
    
}
