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

class SDPParser {
    let sdp: String
    var array: [Substring]
    
    init(sdp: String) {
        self.sdp = sdp
        self.array = sdp.split(separator: "\r\n")
        if array.count == 1 {
            self.array = sdp.split(separator: "\n")
        }
    }
    
    private func getElementByName(_ name: String) -> Substring? {
        var result: Substring? = nil
        self.array.forEach { (substring) in
            if let element = substring.split(separator: "=").first {
                if element == name {
                    result = substring
                }
            }
        }
        return result
    }
    
    private func getElementsByName(_ name: String) -> [Substring] {
        var result: [Substring] = []
        self.array.forEach { (substring) in
            if let element = substring.split(separator: "=").first {
                if element == name {
                    result.append(substring)
                }
            }
        }
        return result
    }
    
    func getFingerprint() -> String {
        let elements = getElementsByName("a")
        var fingerprint: String = ""
        
        elements.forEach { (substring) in
            if let payload = substring.split(separator: "=").dropFirst().first {
                let key = payload.split(separator: ":").first
                let value = payload.split(separator: ":").dropFirst().joined(separator: ":")
                if key == "fingerprint" {
                    fingerprint = value.split(separator: " ").dropFirst().joined(separator: " ")
                }
            }
        }
        return fingerprint
    }
}
