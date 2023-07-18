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

extension Data {
    
    public func encrypt(key: Array<UInt8>, iv: Array<UInt8>) throws -> Data? {
        let gcm = GCM(iv: iv, mode: .combined)
        let aes = try AES(key: key, blockMode: gcm, padding: .noPadding)
        let encrypted = try aes.encrypt(Array(self))
        return Data(encrypted)
    }
    
    static func decrypt(_ encrypted: Data, key: Array<UInt8>, iv: Array<UInt8>) throws -> Data? {
        let gcm = GCM(iv: iv, mode: .combined)
        let aes = try AES(key: key, blockMode: gcm, padding: .noPadding)
        let decrypted = try aes.decrypt(Array(encrypted))
        return Data(decrypted)
    }
    
}
