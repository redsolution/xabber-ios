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
import CryptoKit



extension DataProtocol {
    var sha256Digest: SHA256Digest { SHA256.hash(data: self) }
    var sha256Data: Data { .init(sha256Digest) }
}

extension SHA256Digest {
    var data: Data { .init(self) }
}

extension StringProtocol {
    var data: Data { .init(utf8) }
    var sha256Digest: SHA256Digest { data.sha256Digest }
    var sha256Data: Data { data.sha256Data }
}

extension Data {
    struct HexEncodingOptions: OptionSet {
        let rawValue: Int
        static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
    }

    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        let format = options.contains(.upperCase) ? "%02hhX" : "%02hhx"
        return self.map { String(format: format, $0) }.joined()
    }
    
    func formattedFingerprint() -> String {
        return self
            .sha256Digest
            .data
            .map { String(format: "%02hhX", $0) }
            .joined()
            .chunked(of: 8)
//            .compactMap{ return $0.count == 8 ? $0 : nil }
            .joined(separator: " ")
    }
}
