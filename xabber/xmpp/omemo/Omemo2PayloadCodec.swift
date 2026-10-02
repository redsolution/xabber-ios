import Foundation
import Security
import CryptoSwift
import CryptoKit
import XMPPFramework

/// Authenticates the payload and its SCE bindings before a receive transaction
/// may advance the ratchet. Empty protocol messages have a distinct shape.
enum Omemo2PayloadCodec {
    struct SealedPayload {
        let ciphertext: Data
        let keyAndMAC: Data
    }

    struct OpenedPayload {
        let envelope: DDXMLElement
        let content: DDXMLElement
    }

    static func secureRandom(_ count: Int) throws -> Data {
        guard count > 0 else { throw OmemoManagerError.encryptionFailed }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw OmemoManagerError.encryptionFailed }
        return data
    }

    static func seal(_ xml: String, randomBytes: (Int) throws -> Data = secureRandom) throws -> SealedPayload {
        let key = try randomBytes(32)
        guard key.count == 32 else { throw OmemoManagerError.encryptionFailed }
        let derived = try derive(key)
        let aes = try AES(key: Array(derived[0..<32]), blockMode: CBC(iv: Array(derived[64..<80])), padding: .pkcs7)
        let ciphertext = Data(try aes.encrypt(Array(xml.utf8)))
        let mac = CryptoKit.HMAC<SHA256>.authenticationCode(for: ciphertext, using: SymmetricKey(data: Data(derived[32..<64])))
        return SealedPayload(ciphertext: ciphertext, keyAndMAC: key + Data(mac.prefix(16)))
    }

    static func open(_ payload: Data?, keyAndMAC: Data, expectedFrom: String?, expectedTo: String?, requireTo: Bool = false) throws -> DDXMLElement? {
        try openVerified(payload, keyAndMAC: keyAndMAC, expectedFrom: expectedFrom, expectedTo: expectedTo, requireTo: requireTo)?.envelope
    }

    static func openVerified(_ payload: Data?, keyAndMAC: Data, expectedFrom: String?, expectedTo: String?, requireTo: Bool = false) throws -> OpenedPayload? {
        if payload == nil {
            guard keyAndMAC == Data(repeating: 0, count: 32) else { throw OmemoManagerError.invalidDecryptedPayload }
            return nil
        }
        guard let payload, !payload.isEmpty, payload.count.isMultiple(of: 16), keyAndMAC.count == 48 else {
            throw OmemoManagerError.invalidEncryptedPayload
        }
        let derived = try derive(Data(keyAndMAC.prefix(32)))
        let calculated = CryptoKit.HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: Data(derived[32..<64])))
        let supplied = Array(keyAndMAC.suffix(16))
        var difference: UInt8 = 0
        for (a, b) in zip(supplied, calculated.prefix(16)) { difference |= a ^ b }
        guard difference == 0 else { throw OmemoManagerError.payloadAuthenticationFailed }
        let aes = try AES(key: Array(derived[0..<32]), blockMode: CBC(iv: Array(derived[64..<80])), padding: .pkcs7)
        let plaintext = Data(try aes.decrypt(payload.bytes))
        guard let xml = String(data: plaintext, encoding: .utf8), !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else {
            throw OmemoManagerError.invalidDecryptedPayload
        }
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement(), root.localName == "envelope", root.uri == "urn:xmpp:sce:1" else {
            throw OmemoManagerError.invalidDecryptedPayload
        }
        let elements = root.children?.compactMap { $0 as? DDXMLElement } ?? []
        func children(_ name: String) -> [DDXMLElement] { elements.filter { $0.localName == name && $0.uri == "urn:xmpp:sce:1" } }
        guard children("content").count == 1, children("rpad").count == 1 else { throw OmemoManagerError.invalidDecryptedPayload }
        if requireTo && children("to").count != 1 { throw OmemoManagerError.invalidDecryptedPayload }
        for (name, expected) in [("from", expectedFrom), ("to", expectedTo)] {
            let affixes = children(name)
            guard affixes.count <= 1 else { throw OmemoManagerError.invalidDecryptedPayload }
            if let affix = affixes.first {
                guard let value = affix.attributeStringValue(forName: "jid"), let jid = XMPPJID(string: value),
                      jid.bare == value, expected == nil || jid.bare == expected else {
                    throw OmemoManagerError.invalidDecryptedPayload
                }
            }
        }
        let times = children("time")
        guard times.count <= 1 else { throw OmemoManagerError.invalidDecryptedPayload }
        if let time = times.first {
            guard let stamp = time.attributeStringValue(forName: "stamp"), parseTimestamp(stamp) else {
                throw OmemoManagerError.invalidDecryptedPayload
            }
        }
        let content = children("content")[0]
        for child in content.children?.compactMap({ $0 as? DDXMLElement }) ?? [] {
            if !SCEReceivePolicy.isClientContentElement(child) { child.detach() }
        }
        root.detach()
        return OpenedPayload(envelope: root, content: content)
    }

    static func decodeBase64(_ value: String) throws -> Data {
        let compact = value.filter { ![" ", "\t", "\r", "\n"].contains($0) }
        guard !compact.isEmpty, let data = Data(base64Encoded: compact), data.base64EncodedString() == compact else {
            throw OmemoManagerError.invalidEncryptedPayload
        }
        return data
    }

    private static func derive(_ key: Data) throws -> [UInt8] {
        try HKDF(password: key.bytes, salt: [UInt8](repeating: 0, count: 32),
                 info: Array("OMEMO Payload".utf8), keyLength: 80, variant: .sha2(.sha256)).calculate()
    }

    private static func parseTimestamp(_ stamp: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: stamp) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp) != nil
    }
}
