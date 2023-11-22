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
    
    init?(namespaceString ns: String, name: String) {
        
        guard let uuns = UUID(uuidString: ns) else {
            return nil
        }
        
        self.init(namespace: uuns, name: name)
    }
    
    init?(namespace ns: UUID, name: String) {
        
        if name.isEmpty {
            return nil
        }
        
        let nsdata = Data(ns.byteArray())
        guard let nameData = name.data(using: .utf8) else {
            return nil
        }
        
        let concatData = NSMutableData()
        concatData.append(nsdata)
        concatData.append(nameData)
        
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(concatData.bytes, CC_LONG(concatData.length), &digest)
        
        // set UUID version to 5
        digest[6] = ((digest[6] & 0x0F) | 0x50)
        
        // set variant accordingly to RFC4122 (reserved)
        digest[8] = ((digest[8] & 0x3F) | 0x80)
        
        // build uuid_t tuple
        let uuid_t = (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7], digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15])
        
        self.init(uuid: uuid_t)
    }
    
    private func byteArray() -> [UInt8] {
        
        let innerIterator = Mirror(reflecting: self.uuid).children
        
        var result = [UInt8]()
        for item in innerIterator {
            if let value = item.value as? UInt8 {
                result.append(value)
            }
        }
        
        return result
    }
}
