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
import CryptoSwift
import XMPPFramework

struct EncryptedPushDate: Codable {
            
    let actionElement: String
    let encrypted: String?
    
    private enum CodingKeys: String, CodingKey {
        case actionElement = "action"
        case encrypted = "encrypted"
    }
    
    init(_ body: String) {
        let documentBody = "<root>\(body)</root>"
        guard let document = try? DDXMLDocument(xmlString: documentBody, options: 0),
              let root = document.rootElement(),
              let encrypted = root.elements(forName: "encrypted").first?.xmlString,
              let xForm = root.elements(forName: "x").first,
              let action = xForm.elements(forName: "field").first(where: { $0.attribute(forName: "var")?.stringValue == "type"})?.elements(forName: "value").first?.stringValue else {
//            fatalError(documentBody)
            self.encrypted = nil
            self.actionElement = ""
            return
        }
        self.encrypted = encrypted
        self.actionElement = action
    }
    
    
    var rootElement: DDXMLElement? {
        get {
            guard let encrypted = encrypted?.replacingOccurrences(of: "\"", with: "\'"),
                let document = try? DDXMLDocument(xmlString: encrypted, options: 0),
                let root = document.rootElement() else {
                    return nil
            }
            return root
        }
    }
    
    var iv: ArraySlice<UInt8>? {
        get {
            guard let encrypted = encrypted?.replacingOccurrences(of: "\"", with: "\'"),
                let document = try? DDXMLDocument(xmlString: encrypted, options: 0),
                let root = document.rootElement(),
                let encryptedStr = root.stringValue,
                let data = Data(base64Encoded: encryptedStr, options: .ignoreUnknownCharacters),
                let ivCountRaw = root.attribute(forName: "iv-length")?.stringValue,
                let ivCount = Int(ivCountRaw),
                ivCount < data.count else {
                return nil
            }
            return data.bytes.prefix(upTo: ivCount)
        }
    }
    
    var encryptedData: Array<UInt8>? {
        get {
            guard let root = rootElement,
                let encryptedStr = root.stringValue,
                let data = Data(base64Encoded: encryptedStr),
                let ivCountRaw = root.attribute(forName: "iv-length")?.stringValue,
                let ivCount = Int(ivCountRaw),
                ivCount < data.count else {
                return nil
            }
            print(encryptedStr)
            return Padding.zeroPadding.add(to: Array(data.bytes.suffix(from: ivCount)), blockSize: 16)
        }
    }
    
    var encryptedLen: Int {
        get {
            guard let root = rootElement,
                let encryptedStr = root.stringValue,
                let data = Data(base64Encoded: encryptedStr),
                let ivCountRaw = root.attribute(forName: "iv-length")?.stringValue,
                let ivCount = Int(ivCountRaw),
                ivCount < data.count else {
                return 0
            }
            return data.bytes.suffix(from: ivCount).count
        }
    }
    
    public func payloadStanza(key: String) -> DDXMLElement? {
        if let decrypted = decrypt(by: key),
            let document = try? DDXMLDocument(xmlString: decrypted, options: 0),
            let root = document.rootElement() {
            return root
        }
        return nil
    }
    
    public func decrypt(by key: String) -> String? {
        do {
            guard let encrypted = encryptedData,
                let iv = iv else {
                return nil
            }

            var out: String? = nil
            
            func transform(_ retry: Int = 0) throws {
                if retry > 100 {
                    return
                }
                
                let decryptedRaw = try AES(key: Array(key.utf8),
                                        blockMode: CBC(iv: Array(iv)),
                                        padding: .zeroPadding).decrypt(encrypted)

                let decrypted: [UInt8] = decryptedRaw.map { $0 }
                
                let nsdata = NSData(bytes: Array<UInt8>(decrypted.prefix(upTo: encryptedLen)), length: encryptedLen)
                let data = Data(nsdata)
                let dstr = String(data: data, encoding: .utf8)

                if let result = dstr {
                    out = result
                }
                out = String(bytes: decrypted.prefix(upTo: encryptedLen), encoding: .utf8)
                
                if out == nil {
                    try? transform(retry + 1)
                }
            }
            try transform()
            return out
        } catch {
            DDLogDebug("EncryptedPushDate: \(#function). \(error.localizedDescription)")
        }
        return nil
    }
}
