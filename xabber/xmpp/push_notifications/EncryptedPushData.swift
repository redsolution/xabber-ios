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
import KissXML

struct EncryptedPushDate: Codable {
    let actionElement: String
    let encrypted: String?

    private enum CodingKeys: String, CodingKey {
        case actionElement = "action"
        case encrypted
    }

    init(_ body: String) {
        guard body.utf8.count <= PushPayloadXML.maximumSize else {
            actionElement = "none"
            encrypted = nil
            return
        }
        if let envelope = PushPayloadEnvelope(body) {
            actionElement = envelope.actionElement
            encrypted = envelope.encrypted
            return
        }
        // App background relay supplies an encrypted element in plain/base64 JSON.
        let data = Data(body.utf8)
        let decoded = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            ?? Data(base64Encoded: body).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        actionElement = decoded?["action"] as? String ?? "message"
        encrypted = decoded?["encrypted"] as? String
    }

    func payloadStanza(key: String) -> DDXMLElement? { payloadStanza(key: Array(key.utf8)) }

    func payloadStanza(key: [UInt8]) -> DDXMLElement? {
        guard let encrypted else { return nil }
        return PushPayloadXML.element(encryptedXML: encrypted, key: key)
    }

    func decrypt(by key: String) -> String? { decrypt(by: Array(key.utf8)) }

    func decrypt(by key: [UInt8]) -> String? {
        guard let encrypted else { return nil }
        return PushPayloadXML.decrypt(encryptedXML: encrypted, key: key)
    }
}
