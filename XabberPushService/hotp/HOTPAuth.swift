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
import CryptoSwift
import SwiftKeychainWrapper


class HOTPAuth {
    
    let digits = 8
    
    //let uniqueServiceName = "clandestino.keychain"
    //let uniqueAccessGroup = "group.clandestino.dev"
    
    var jid: String
    
    init(jid: String) {
        self.jid = jid
    }
    
//    var counterRaw: UInt64 {
//        get {
//            if let counterRaw = self.retrieveCreditionals(for: [jid, "counter"].prp()),
//               let counter = UInt64(counterRaw) {
//                return counter
//            }
//            return 0
//        } set {
//            self.storeCreditionals(for: [jid, "counter"].prp(), value: "\(newValue)")
//        }
//    }
    
    private func storeCreditionals(for key: String, value: String) {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        _ = keychain.set(value, forKey: key, withAccessibility: .always)
    }
    
    private func retrieveCreditionals(for key: String) -> String? {
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        return keychain.string(forKey: key)
    }
    
    
    public func getHOTPValueFor() -> String? {
        guard let secretString = self.retrieveCreditionals(for: [jid, "secret"].prp()),
              let secret = Data(base64Encoded: secretString) else {
            return nil
        }
        guard let counterValue = self.retrieveCreditionals(for: [jid, "counter"].prp()),
              let counterValue64 = UInt64(counterValue) else {
            return nil
        }
        var counterRaw: UInt64 = counterValue64 + 1
        self.storeCreditionals(for: [jid, "counter"].prp(), value: "\(counterRaw)")
        
        
        print(counterRaw, secretString, "olololo")
//        let key = secret.bytes
        
        let counter = withUnsafeBytes(of: counterRaw.bigEndian, { Data($0) })

        guard let hmac = try? HMAC(key: secret.bytes, variant: HMAC.Variant.sha1).authenticate(counter.bytes) else { return nil }
        
        let offset = Int((hmac.last ?? 0x00) & 0x0f)
        
        let truncatedHMAC = Array(hmac[offset...offset + 3])
        
        let data =  Data(truncatedHMAC)
        
        var number = UInt32(strtoul(data.toHexString(), nil, 16))
        
        number &= 0x7fffffff
        number = number % UInt32(pow(10, Float(digits)))

        let strNum = "\(number)"
        if strNum.count == digits {
            return strNum
        }
        let prefixedZeros = String(repeatElement("0", count: (digits - strNum.count)))
        return (prefixedZeros + strNum)
    }
}

