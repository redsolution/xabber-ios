import Foundation
import Security
import CryptoSwift
import CryptoKit
import XMPPFramework

/// Authenticates the payload and its SCE bindings before a receive transaction
/// may advance the ratchet. Empty protocol messages have a distinct shape.
enum Omemo2PayloadCodec {
    static let minimumEnvelopeByteCount = 512
    static let clockSkewAllowance: TimeInterval = 300

    enum SCETimeValidation: Equatable {
        case absent, unavailable
        case verified(OMEMOOriginalSendingTime)
    }
    struct SealedPayload {
        let ciphertext: Data
        let keyAndMAC: Data
    }

    struct OpenedPayload {
        let envelope: DDXMLElement
        let content: DDXMLElement
        let timeValidation: SCETimeValidation
    }

    /// The minimum covers the serialized UTF-8 envelope, not just its body.
    /// ASCII from a 64-character alphabet avoids XML escaping and modulo bias.
    static func applyPadding(to envelope: DDXMLElement, extraLength: Int? = nil,
                             randomBytes: (Int) throws -> Data = secureRandom) throws {
        guard SCEReceivePolicy.matches(envelope, name: "envelope", namespace: "urn:xmpp:sce:1") else {
            throw OmemoManagerError.invalidDecryptedPayload
        }
        let pads = SCEReceivePolicy.children(of: envelope, named: "rpad", xmlns: "urn:xmpp:sce:1")
        guard pads.count == 1, !hasElementChildren(pads[0]) else { throw OmemoManagerError.invalidDecryptedPayload }
        let extra: Int
        if let extraLength {
            guard (0...200).contains(extraLength) else { throw OmemoManagerError.encryptionFailed }
            extra = extraLength
        } else {
            // Reject 201...255 so each allowed length has equal probability.
            var selected: Int?
            for _ in 0..<32 {
                let byte = try randomBytes(1)
                guard byte.count == 1 else { throw OmemoManagerError.encryptionFailed }
                if let value = byte.first, value <= 200 { selected = Int(value); break }
            }
            guard let selected else { throw OmemoManagerError.encryptionFailed }
            extra = selected
        }
        let pad = pads[0]
        pad.stringValue = ""
        guard let emptyXML = envelope.compactXMLString else { throw OmemoManagerError.encryptionFailed }
        let emptySize = emptyXML.utf8.count
        pad.stringValue = "A"
        guard let expandedXML = envelope.compactXMLString else { throw OmemoManagerError.encryptionFailed }
        let frameSize = expandedXML.utf8.count - 1
        var count = max(0, minimumEnvelopeByteCount - frameSize) + extra
        // A self-closing empty rpad can be smaller than its expanded XML frame.
        if count == 0 && emptySize < minimumEnvelopeByteCount { count = max(1, minimumEnvelopeByteCount - frameSize) }
        if count == 0 {
            pad.stringValue = ""
        } else {
            let bytes = try randomBytes(count)
            guard bytes.count == count else { throw OmemoManagerError.encryptionFailed }
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
            pad.stringValue = String(decoding: bytes.map { alphabet[Int($0 & 63)] }, as: UTF8.self)
        }
    }

    /// Refresh only when preparing new ciphertext. Retransmitting an already
    /// encrypted stanza keeps its original protected timestamp and padding.
    static func prepareOutgoingXML(_ xml: String, encryptionTime: Date = Date()) throws -> String {
        let envelope = try parseEnvelope(xml)
        guard encryptionTime.timeIntervalSince1970.isFinite,
              SCEReceivePolicy.children(of: envelope, named: "content", xmlns: "urn:xmpp:sce:1").count == 1 else {
            throw OmemoManagerError.invalidDecryptedPayload
        }
        let times = SCEReceivePolicy.children(of: envelope, named: "time", xmlns: "urn:xmpp:sce:1")
        guard times.count <= 1 else { throw OmemoManagerError.invalidDecryptedPayload }
        times.first?.detach()
        let time = DDXMLElement(name: "time", xmlns: "urn:xmpp:sce:1")
        time.addAttribute(withName: "stamp", stringValue: encryptionTime.XMPPFormattedDate)
        envelope.addChild(time)
        try applyPadding(to: envelope)
        guard let result = envelope.compactXMLString else { throw OmemoManagerError.encryptionFailed }
        return result
    }

    /// Strict XEP-0082 dateTime parsing. Calendar round-tripping rejects values
    /// Foundation formatters normalize; fractions retain Date's precision.
    static func timestamp(_ stamp: String) throws -> Date {
        let pattern = #"^(-?[0-9]{4,})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?(Z|[+-][0-9]{2}:[0-9]{2})$"#
        let range = NSRange(stamp.startIndex..<stamp.endIndex, in: stamp)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stamp, range: range), match.range == range else {
            throw OmemoManagerError.invalidDecryptedPayload
        }
        func field(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: stamp) else { return nil }
            return String(stamp[range])
        }
        guard let year = field(1).flatMap(Int.init), year != 0, year != Int.min,
              let month = field(2).flatMap(Int.init), (1...12).contains(month),
              let day = field(3).flatMap(Int.init), (1...31).contains(day),
              let hour = field(4).flatMap(Int.init), (0...23).contains(hour),
              let minute = field(5).flatMap(Int.init), (0...59).contains(minute),
              let second = field(6).flatMap(Int.init), (0...59).contains(second), let zone = field(8) else {
            throw OmemoManagerError.invalidDecryptedPayload
        }
        var offset = 0
        if zone != "Z" {
            let parts = zone.dropFirst().split(separator: ":")
            guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
                  hours <= 14, minutes <= 59, hours != 14 || minutes == 0 else {
                throw OmemoManagerError.invalidDecryptedPayload
            }
            offset = (hours * 3600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(era: year > 0 ? 1 : 0, year: abs(year), month: month, day: day,
                                        hour: hour, minute: minute, second: second)
        guard let base = calendar.date(from: components) else { throw OmemoManagerError.invalidDecryptedPayload }
        let actual = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: base)
        guard actual.era == components.era, actual.year == components.year,
              actual.month == month, actual.day == day, actual.hour == hour,
              actual.minute == minute, actual.second == second else { throw OmemoManagerError.invalidDecryptedPayload }
        let fraction = field(7).flatMap { Double("0." + $0) } ?? 0
        let date = base.addingTimeInterval(fraction - Double(offset))
        guard date.timeIntervalSince1970.isFinite else { throw OmemoManagerError.invalidDecryptedPayload }
        return date
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

    static func open(_ payload: Data?, keyAndMAC: Data, expectedFrom: String?, expectedTo: String?, requireTo: Bool = false, originalSendingTime: OMEMOOriginalSendingTime? = nil) throws -> DDXMLElement? {
        try openVerified(payload, keyAndMAC: keyAndMAC, expectedFrom: expectedFrom, expectedTo: expectedTo, requireTo: requireTo, originalSendingTime: originalSendingTime)?.envelope
    }

    static func openVerified(_ payload: Data?, keyAndMAC: Data, expectedFrom: String?, expectedTo: String?, requireTo: Bool = false, originalSendingTime: OMEMOOriginalSendingTime? = nil) throws -> OpenedPayload? {
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
        guard let xml = String(data: plaintext, encoding: .utf8) else {
            throw OmemoManagerError.invalidDecryptedPayload
        }
        let root = try parseEnvelope(xml)
        let elements = root.children?.compactMap { $0 as? DDXMLElement } ?? []
        func children(_ name: String) -> [DDXMLElement] { elements.filter { $0.localName == name && $0.uri == "urn:xmpp:sce:1" } }
        guard children("content").count == 1, children("rpad").count == 1,
              !hasElementChildren(children("rpad")[0]) else { throw OmemoManagerError.invalidDecryptedPayload }
        if requireTo && children("to").count != 1 { throw OmemoManagerError.invalidDecryptedPayload }
        for (name, expected) in [("from", expectedFrom), ("to", expectedTo)] {
            let affixes = children(name)
            guard affixes.count <= 1 else { throw OmemoManagerError.invalidDecryptedPayload }
            if let affix = affixes.first {
                guard isEmptyAffix(affix), let value = unqualifiedAttribute("jid", in: affix),
                      let jid = XMPPJID(string: value), jid.bare == value,
                      let expected, let expectedJID = XMPPJID(string: expected), jid.bare == expectedJID.bare else {
                    throw OmemoManagerError.invalidDecryptedPayload
                }
            }
        }
        let times = children("time")
        guard times.count <= 1 else { throw OmemoManagerError.invalidDecryptedPayload }
        let timeValidation: SCETimeValidation
        if let time = times.first {
            guard isEmptyAffix(time), let stamp = unqualifiedAttribute("stamp", in: time) else {
                throw OmemoManagerError.invalidDecryptedPayload
            }
            let protectedTime = try timestamp(stamp)
            if let originalSendingTime {
                guard originalSendingTime.date.timeIntervalSince1970.isFinite,
                      abs(protectedTime.timeIntervalSince(originalSendingTime.date)) <= clockSkewAllowance else {
                    throw OmemoManagerError.invalidDecryptedPayload
                }
                timeValidation = .verified(originalSendingTime)
            } else {
                timeValidation = .unavailable
            }
        } else {
            timeValidation = .absent
        }
        let content = children("content")[0]
        for child in content.children?.compactMap({ $0 as? DDXMLElement }) ?? [] {
            if !SCEReceivePolicy.isClientContentElement(child) { child.detach() }
        }
        root.detach()
        return OpenedPayload(envelope: root, content: content, timeValidation: timeValidation)
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

    private static func parseEnvelope(_ xml: String) throws -> DDXMLElement {
        guard !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { throw OmemoManagerError.invalidDecryptedPayload }
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement(),
              SCEReceivePolicy.matches(root, name: "envelope", namespace: "urn:xmpp:sce:1") else {
            throw OmemoManagerError.invalidDecryptedPayload
        }
        root.detach()
        return root
    }

    private static func hasElementChildren(_ element: DDXMLElement) -> Bool {
        element.children?.contains { $0 is DDXMLElement } ?? false
    }

    private static func isEmptyAffix(_ element: DDXMLElement) -> Bool {
        !hasElementChildren(element) && (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func unqualifiedAttribute(_ name: String, in element: DDXMLElement) -> String? {
        let attributes = element.attributes?.filter { $0.name == name && ($0.uri ?? "").isEmpty } ?? []
        return attributes.count == 1 ? attributes[0].stringValue : nil
    }
}
