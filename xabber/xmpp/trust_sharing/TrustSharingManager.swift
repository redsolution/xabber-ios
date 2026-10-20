//
//  TrustSharingManager.swift
//  xabber
//
//  Created by Admin on 03.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import XMPPFramework
import CryptoKit
import CryptoSwift
import RealmSwift

/// RFC 7622 bare owner form: UsernameCaseMapped localpart and IDNA U-label domain.
/// Keep the resulting bytes independent of the retired Nodeprep case-folding.
private enum TrustSharingBareJID {
    // RFC 5892 exceptions are shared by IDNA and PRECIS IdentifierClass.
    private static let pvalidExceptions: Set<UInt32> = [0x00df, 0x03c2, 0x06fd, 0x06fe, 0x0f0b, 0x3007]
    private static let prohibitedScalars: Set<UInt32> = [0x0640, 0x07fa, 0x302e, 0x302f, 0x3031,
                                                       0x3032, 0x3033, 0x3034, 0x3035, 0x303b]

    private static func isOldHangulJamo(_ scalar: UInt32) -> Bool {
        (0x1100...0x11ff).contains(scalar) || (0xa960...0xa97f).contains(scalar) || (0xd7b0...0xd7ff).contains(scalar)
    }

    static func normalize(_ input: String) -> String? {
        guard !input.isEmpty, !input.contains("/"),
              input.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let parts = input.components(separatedBy: "@")
        guard parts.count <= 2, let domain = domain(parts.last ?? "") else { return nil }
        if parts.count == 1 { return domain }
        guard let user = localpart(parts[0]) else { return nil }
        return user + "@" + domain
    }

    private static func localpart(_ input: String) -> String? {
        let prepared = input.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            return ((0xff00...0xffef).contains(value) || value == 0x3000)
                ? String(scalar).precomposedStringWithCompatibilityMapping : String(scalar)
        }.joined()
        guard !prepared.isEmpty,
              prepared.rangeOfCharacter(from: CharacterSet(charactersIn: "\"&'/:<>@")) == nil else { return nil }
        // IdentifierClass preparation precedes NFC so compatibility/Jamo input
        // cannot be hidden by normalization into otherwise valid characters.
        for point in prepared.unicodeScalars {
            if pvalidExceptions.contains(point.value)
                || [0x00b7, 0x0375, 0x05f3, 0x05f4, 0x30fb, 0x200c, 0x200d].contains(point.value) { continue }
            let properties = point.properties
            guard !prohibitedScalars.contains(point.value),
                  !properties.isDefaultIgnorableCodePoint, !properties.isNoncharacterCodePoint,
                  properties.generalCategory != .control, properties.generalCategory != .unassigned,
                  !isOldHangulJamo(point.value) else { return nil }
            if (0x21...0x7e).contains(point.value) { continue }
            guard String(point).precomposedStringWithCompatibilityMapping.utf8.elementsEqual(String(point).utf8),
                  [.lowercaseLetter, .uppercaseLetter, .otherLetter, .decimalNumber,
                   .modifierLetter, .nonspacingMark, .spacingMark].contains(properties.generalCategory) else { return nil }
        }
        let mapped = prepared.lowercased().precomposedStringWithCanonicalMapping
        guard !mapped.isEmpty, mapped.utf8.count <= 1023 else { return nil }
        let points = Array(mapped.unicodeScalars)
        let arabic = points.contains { (0x0660...0x0669).contains($0.value) }
        let extended = points.contains { (0x06f0...0x06f9).contains($0.value) }
        guard !(arabic && extended) else { return nil }
        for (index, point) in points.enumerated() {
            if context(point, index: index, points: points, value: mapped) == false { return nil }
        }
        return validBidi(mapped) ? mapped : nil
    }

    private static func domain(_ input: String) -> String? {
        guard !input.isEmpty, input.utf8.count <= 1023,
              input.rangeOfCharacter(from: CharacterSet(charactersIn: "/@|\\?#%")) == nil else { return nil }
        let prepared = input.hasSuffix(".") ? String(input.dropLast()) : input
        guard let parsed = URLComponents(string: "https://" + prepared + "/"),
              parsed.user == nil, parsed.password == nil, parsed.port == nil,
              parsed.path == "/", parsed.query == nil, parsed.fragment == nil,
              let raw = parsed.host, !raw.isEmpty else { return nil }
        let normalized = raw.lowercased().precomposedStringWithCanonicalMapping
        if normalized.hasPrefix("[") {
            return normalized.hasSuffix("]") && parsed.url != nil ? normalized : nil
        }
        guard !normalized.contains(":"), normalized.utf8.count <= 1023,
              let encoded = parsed.url?.host else { return nil }
        let labels = normalized.components(separatedBy: ".")
        let asciiLabels = encoded.components(separatedBy: ".")
        guard labels.count == asciiLabels.count, !labels.contains(where: \.isEmpty),
              asciiLabels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }) else { return nil }
        for label in labels {
            let points = Array(label.unicodeScalars)
            guard let first = points.first, label.first != "-", label.last != "-",
                  ![.nonspacingMark, .spacingMark, .enclosingMark].contains(first.properties.generalCategory),
                  !(points.count >= 4 && points[2].value == 0x2d && points[3].value == 0x2d), validBidi(label) else { return nil }
            for (index, point) in points.enumerated() {
                guard !prohibitedScalars.contains(point.value), !isOldHangulJamo(point.value) else { return nil }
                if point.value == 0x2d || pvalidExceptions.contains(point.value) { continue }
                if let context = context(point, index: index, points: points, value: label) {
                    guard context else { return nil }; continue
                }
                guard [.lowercaseLetter, .uppercaseLetter, .otherLetter, .decimalNumber,
                       .modifierLetter, .nonspacingMark, .spacingMark].contains(point.properties.generalCategory),
                      !point.properties.isDefaultIgnorableCodePoint else { return nil }
            }
        }
        return normalized
    }

    private static func context(_ point: Unicode.Scalar, index: Int, points: [Unicode.Scalar], value: String) -> Bool? {
        func match(_ scalar: Unicode.Scalar?, _ pattern: String) -> Bool {
            guard let scalar else { return false }
            return regex(String(scalar), pattern) == true
        }
        let previous = index > 0 ? points[index - 1] : nil
        let next = index + 1 < points.count ? points[index + 1] : nil
        switch point.value {
        case 0x00b7: return previous?.value == 0x6c && next?.value == 0x6c
        case 0x0375: return match(next, "\\p{sc=Greek}")
        case 0x05f3, 0x05f4: return match(previous, "\\p{sc=Hebrew}")
        case 0x30fb: return regex(value.replacingOccurrences(of: "・", with: ""), "[\\p{sc=Hiragana}\\p{sc=Katakana}\\p{sc=Han}]") == true
        case 0x200c, 0x200d:
            if previous?.properties.canonicalCombiningClass.rawValue == 9 { return true }
            if point.value == 0x200d { return false }
            let before = points[..<index].reversed().first { regex(String($0), "\\p{jt=T}") != true }
            let after = points[(index + 1)...].first { regex(String($0), "\\p{jt=T}") != true }
            return match(before, "[\\p{jt=L}\\p{jt=D}]") && match(after, "[\\p{jt=R}\\p{jt=D}]")
        default: return nil
        }
    }

    private static func regex(_ value: String, _ pattern: String) -> Bool? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func validBidi(_ value: String) -> Bool {
        guard let rtl = regex(value, "[\\p{bc=R}\\p{bc=AL}\\p{bc=AN}]") else { return false }
        guard rtl else { return true }
        guard let first = value.unicodeScalars.first else { return false }
        if regex(String(first), "[\\p{bc=R}\\p{bc=AL}]") == true {
            return regex(value, "^[\\p{bc=R}\\p{bc=AL}\\p{bc=AN}\\p{bc=EN}\\p{bc=ES}\\p{bc=CS}\\p{bc=ET}\\p{bc=ON}\\p{bc=BN}\\p{bc=NSM}]*[\\p{bc=R}\\p{bc=AL}\\p{bc=EN}\\p{bc=AN}]\\p{bc=NSM}*$") == true
                && !(regex(value, "\\p{bc=EN}") == true && regex(value, "\\p{bc=AN}") == true)
        }
        return regex(String(first), "\\p{bc=L}") == true
            && regex(value, "^[\\p{bc=L}\\p{bc=EN}\\p{bc=ES}\\p{bc=CS}\\p{bc=ET}\\p{bc=ON}\\p{bc=BN}\\p{bc=NSM}]*[\\p{bc=L}\\p{bc=EN}]\\p{bc=NSM}*$") == true
    }
}

struct TrustSharingSignature {
    static let xmlns = "urn:xmpp:trustsharing:0"
    static let encryptionProtocol = "urn:xmpp:omemo:2"
    static let node = xmlns

    static func trustedItems(from share: DDXMLElement) -> [DDXMLElement] {
        SCEReceivePolicy.children(of: share, named: "trust-list", xmlns: xmlns)
    }

    static func canonicalString(for containers: [DDXMLElement]) -> String? {
        guard containers.isNotEmpty else { return nil }
        var owners = Set<String>()
        var lists: [(owner: String, timestamp: Int64, records: [(type: String, timestamp: Int64, value: String)])] = []
        for container in containers {
            guard SCEReceivePolicy.matches(container, name: "trust-list", namespace: xmlns),
                  let owner = canonicalOwner(for: container), owners.insert(owner).inserted,
                  timestamp(container) > 0 else { return nil }
            var keys = Set<Data>()
            var records: [(type: String, timestamp: Int64, value: String)] = []
            for entry in container.children?.compactMap({ $0 as? DDXMLElement }) ?? [] {
                guard let type = entry.localName, ["trust", "distrust"].contains(type),
                      SCEReceivePolicy.matches(entry, name: type, namespace: xmlns),
                      timestamp(entry) > 0, let value = entry.stringValue,
                      let key = Data(base64Encoded: value), key.base64EncodedString() == value,
                      keys.insert(key).inserted,
                      !(entry.children ?? []).contains(where: { $0 is DDXMLElement }) else { return nil }
                records.append((type, timestamp(entry), value))
            }
            records.sort {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                if $0.type != $1.type { return $0.type < $1.type }
                return $0.value < $1.value
            }
            lists.append((owner, timestamp(container), records))
        }
        lists.sort { $0.owner.utf8.lexicographicallyPrecedes($1.owner.utf8) }
        var parts: [String] = []
        for list in lists {
            parts += ["trust-list", list.owner, String(list.timestamp)]
            for record in list.records { parts += [record.type, String(record.timestamp), record.value] }
        }
        return parts.joined(separator: "|")
    }

    static func canonicalOwner(for container: DDXMLElement) -> String? {
        guard let raw = container.attributeStringValue(forName: "owner") else { return "" }
        guard !raw.isEmpty,
              raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let jid = TrustSharingBareJID.normalize(raw) else { return nil }
        return jid
    }

    static func hashCanonicalString(_ canonical: String) -> Data {
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }

    static func timestamp(_ element: DDXMLElement) -> Int64 {
        guard let raw = element.attributeStringValue(forName: "timestamp") else {
            return 0
        }
        return Int64(raw) ?? 0
    }
}

/// Public trust history committed with its current-identity Realm projection.
/// This lives in an existing String field; numeric retired cursors are metadata only.
private struct TrustSharingLedger: Codable {
    static let prefix = "trustsharing-v1:"

    struct Target: Hashable {
        let jid: String
        let deviceID: Int
        let fingerprint: String
        var trustedKey: String { "\(deviceID)::\(fingerprint)" }
    }

    struct Decision: Codable, Equatable {
        let deviceID: Int
        let fingerprint: String
        let state: String
        let timestamp: Int64

        var trustedKey: String { "\(deviceID)::\(fingerprint)" }
        var trustState: SignalDeviceStorageItem.TrustState {
            SignalDeviceStorageItem.TrustState(rawValue: state) ?? .unknown
        }

        func merging(_ other: Decision) -> Decision {
            if other.timestamp > timestamp { return other }
            if other.timestamp < timestamp || other.state == state { return self }
            return Decision(deviceID: deviceID, fingerprint: fingerprint,
                            state: SignalDeviceStorageItem.TrustState.unknown.rawValue, timestamp: timestamp)
        }
    }

    struct OwnerState: Codable {
        var timestamp: Int64
        var records: [String: Decision]
    }

    struct Source: Codable {
        let jid: String
        let deviceID: Int
        let identity: String
        var owners: [String: OwnerState]
    }

    let version: Int
    let encryptionProtocol: String
    let owner: String
    let localDeviceID: Int
    let localIdentity: String
    var max: Int64
    var sources: [String: Source]

    static func sourceKey(jid: String, deviceID: Int, identity: Data) -> String {
        var bytes = Data(jid.utf8)
        bytes.append(0); bytes.append(contentsOf: String(deviceID).utf8)
        bytes.append(0); bytes.append(identity)
        return bytes.base64EncodedString()
    }

    static func diagnosticMaximum(_ raw: String) -> Int64 {
        if raw.hasPrefix(prefix),
           let decoded = try? JSONDecoder().decode(TrustSharingLedger.self, from: Data(raw.dropFirst(prefix.count).utf8)),
           decoded.version == 1 { return Swift.max(0, decoded.max) }
        return Swift.max(0, Int64(raw) ?? 0)
    }

    static func load(_ raw: String, owner: String, bundle: OMEMO2LocalBundle) throws -> TrustSharingLedger {
        if raw.isEmpty || Int64(raw) != nil {
            return TrustSharingLedger(version: 1, encryptionProtocol: TrustSharingSignature.encryptionProtocol,
                owner: owner, localDeviceID: bundle.deviceID, localIdentity: bundle.identityKey.base64EncodedString(),
                max: diagnosticMaximum(raw), sources: [:])
        }
        guard raw.hasPrefix(prefix) else { throw OMEMO2StorageError.invalidState }
        let decoded = try JSONDecoder().decode(TrustSharingLedger.self, from: Data(raw.dropFirst(prefix.count).utf8))
        guard decoded.version == 1, decoded.encryptionProtocol == TrustSharingSignature.encryptionProtocol,
              decoded.owner == owner, decoded.localDeviceID == bundle.deviceID,
              decoded.localIdentity == bundle.identityKey.base64EncodedString(), decoded.max >= 0 else {
            throw OMEMO2StorageError.identityMismatch
        }
        for (key, source) in decoded.sources {
            guard source.deviceID > 0, source.deviceID <= Int(Int32.max),
                  let identity = Data(base64Encoded: source.identity), identity.count == 32,
                  identity.base64EncodedString() == source.identity,
                  key == sourceKey(jid: source.jid, deviceID: source.deviceID, identity: identity) else {
                throw OMEMO2StorageError.invalidState
            }
            for (jid, list) in source.owners {
                guard !jid.isEmpty, list.timestamp > 0 else { throw OMEMO2StorageError.invalidState }
                for (key, record) in list.records {
                    guard record.deviceID > 0, record.deviceID <= Int(Int32.max),
                          record.fingerprint.count == 64,
                          record.fingerprint.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
                          record.timestamp > 0, key == record.trustedKey,
                          ["trust", "distrust", "unknown"].contains(record.state) else {
                        throw OMEMO2StorageError.invalidState
                    }
                }
            }
        }
        return decoded
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Self.prefix + String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    func decisions() -> [Target: Decision] {
        var result: [Target: Decision] = [:]
        for source in sources.values {
            for (jid, list) in source.owners {
                for decision in list.records.values {
                    let target = Target(jid: jid, deviceID: decision.deviceID, fingerprint: decision.fingerprint)
                    result[target] = result[target].map { $0.merging(decision) } ?? decision
                }
            }
        }
        return result
    }

    func ownerTimestamp(_ jid: String) -> Int64 {
        sources.values.compactMap { $0.owners[jid]?.timestamp }.max() ?? 0
    }
}

class TrustSharingManager: AbstractXMPPManager {
    let node = TrustSharingSignature.node

    private static let maximumPendingShareBytes = 256 * 1024
    private static let maximumPendingShares = 32
    private static let pendingLifetime: TimeInterval = 120
    private struct PendingShare {
        let xml: String
        let publisher: String
        let deviceID: Int
        let identity: Data
        let requestChain: Bool
        let resolution: PendingResolution
        let expires: Date
        let generation: UInt64
    }
    private struct PendingBundleRequest: Hashable {
        let shareKey: String
        let target: TrustSharingLedger.Target
    }
    private let pendingLock = NSLock()
    private var pendingGeneration: UInt64 = 0
    private var pendingShares: [String: PendingShare] = [:]
    private var requestedBundles: [PendingBundleRequest: Date] = [:]

    override func clearSession() {
        pendingLock.lock()
        pendingGeneration &+= 1
        pendingShares.removeAll(); requestedBundles.removeAll()
        pendingLock.unlock()
        super.clearSession()
    }

    private func currentPendingGeneration() -> UInt64 {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingGeneration
    }

    private func isCurrentPendingGeneration(_ value: UInt64) -> Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingGeneration == value
    }

    private func rememberPending(_ share: DDXMLElement, publisher: String, deviceID: Int, identity: Data,
                                 shouldRequestTrustedDevices: Bool, resolution: PendingResolution, deadline: Date?, generation: UInt64) {
        let now = Date()
        let expiry = deadline ?? now.addingTimeInterval(Self.pendingLifetime)
        guard expiry > now else { return }
        let xml = share.xmlString
        guard let canonical = TrustSharingSignature.canonicalString(for: TrustSharingSignature.trustedItems(from: share)),
              let signatureText = SCEReceivePolicy.children(of: share, named: "signature", xmlns: getPrimaryNamespace()).first?.stringValue,
              let signature = Data(base64Encoded: signatureText) else { return }
        var input = Data((publisher + "\u{0}" + String(deviceID) + "\u{0}").utf8)
        input.append(identity)
        input.append(TrustSharingSignature.hashCanonicalString(canonical))
        input.append(signature)
        let key = Data(SHA256.hash(data: input)).base64EncodedString()
        pendingLock.lock()
        guard pendingGeneration == generation else { pendingLock.unlock(); return }
        pendingShares = pendingShares.filter { $0.value.expires > now }
        requestedBundles = requestedBundles.filter { $0.value > now }
        if pendingShares[key] == nil && pendingShares.count >= Self.maximumPendingShares {
            pendingLock.unlock(); return
        }
        pendingShares[key] = PendingShare(xml: xml, publisher: publisher, deviceID: deviceID, identity: identity,
            requestChain: shouldRequestTrustedDevices, resolution: resolution, expires: expiry, generation: generation)
        let requests = resolution.targets.sorted { ($0.jid, $0.deviceID, $0.fingerprint) < ($1.jid, $1.deviceID, $1.fingerprint) }
            .filter { requestedBundles[PendingBundleRequest(shareKey: key, target: $0)] == nil }.prefix(16)
        for target in requests { requestedBundles[PendingBundleRequest(shareKey: key, target: target)] = expiry }
        pendingLock.unlock()
        guard !requests.isEmpty else { return }
        AccountManager.shared.find(for: owner)?.action { user, stream in
            guard self.isCurrentPendingGeneration(generation) else { return }
            do {
                let realm = try WRealm.safe()
                guard let storage = user.omemo.omemo2Storage else { return }
                let (_, bundle) = try self.localAnchor(in: realm, storage: storage)
                guard bundle.deviceID == resolution.localDeviceID, bundle.identityKey == resolution.localIdentity,
                      let publisherRow = self.device(in: realm, jid: publisher, deviceID: deviceID), publisherRow.state == .trusted,
                      realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: publisherRow.primary)?.identityKey == identity.base64EncodedString() else { return }
                for target in requests {
                    guard self.isCurrentPendingGeneration(generation) else { return }
                    user.omemo.getContactBundle(stream, jid: target.jid, deviceId: target.deviceID, force: true)
                }
            } catch { return }
        }
    }

    /// Invoked only after the normal bundle codec and Realm transaction commit.
    /// Every retry repeats signature, exact current signer, local anchor and owner clocks.
    func retryPendingShares(jid: String, deviceID: Int) {
        guard let jid = TrustSharingBareJID.normalize(jid) else { return }
        let now = Date()
        pendingLock.lock()
        // A valid reply with a different current key does not authorize an
        // immediate refetch loop for the same immutable signed input/full key.
        let retry = pendingShares.filter {
            $0.value.expires > now && $0.value.resolution.targets.contains { $0.jid == jid && $0.deviceID == deviceID }
        }
        pendingShares = pendingShares.filter { $0.value.expires > now && retry[$0.key] == nil }
        pendingLock.unlock()
        for entry in retry.values {
            guard isCurrentPendingGeneration(entry.generation), let account = AccountManager.shared.find(for: owner),
                  let current = try? account.omemo.omemo2Storage?.localBundle(),
                  current.deviceID == entry.resolution.localDeviceID,
                  current.identityKey == entry.resolution.localIdentity,
                  let share = try? DDXMLElement(xmlString: entry.xml) else { continue }
            _ = applyShare(share, publisherBareJid: entry.publisher, forcedPublisherDeviceId: entry.deviceID,
                shouldRequestTrustedDevices: entry.requestChain, pendingDeadline: entry.expires, requiredGeneration: entry.generation, requiredPublisherIdentity: entry.identity)
        }
    }

    static let receivedTrustedDevicesAfterVerification = NSNotification.Name("com.xabber.ios.ake.receivedTrustedDevicesAfterVerification")

    /// A new explicit local decision must outrank the previous decision even
    /// when both actions happen within one Unix second or the clock moves back.
    static func nextLocalDecisionTimestamp(previous: Int64, at date: Date = Date()) -> Int64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 1, seconds < Double(Int64.max),
              previous < Int64.max else { return nil }
        return max(Int64(seconds.rounded(.down)), max(previous, 0) + 1)
    }

    override func namespaces() -> [String] {
        return [
            TrustSharingSignature.xmlns,
            "\(TrustSharingSignature.node)+notify"
        ]
    }

    override func getPrimaryNamespace() -> String {
        return TrustSharingSignature.xmlns
    }

    func didReceivedListOfContactsDevices(message: XMPPMessage, encryption: MessageEncryptionProvenance = .plaintext) -> Bool {
        receiveListOfContactsDevices(message: message, encryption: encryption,
            decryptMessage: { forwardedMessage in
                let originalTime = try self.originalSendingTime(for: message)
                return try AccountManager.shared.find(for: self.owner)?.omemo.decryptMessage(
                    forwardedMessage, originalSendingTime: originalTime)
            },
            applyShare: { share, publisher in
                self.applyShare(share, publisherBareJid: publisher, shouldRequestTrustedDevices: true)
            })
    }

    /// Reuses a prepared payload without advancing the ratchet a second time.
    /// Opaque XEN payloads retain the existing decrypt and signature checks.
    func receiveListOfContactsDevices(
        message: XMPPMessage,
        encryption: MessageEncryptionProvenance,
        decryptMessage: (XMPPMessage) throws -> DDXMLElement?,
        applyShare: (DDXMLElement, String) -> Bool
    ) -> Bool {
        guard let forwardedMessage = forwardedPayloadMessage(from: message) else {
            return false
        }

        if encryption.isAuthenticated {
            let shares = SCEReceivePolicy.children(of: forwardedMessage, named: "share", xmlns: getPrimaryNamespace())
            guard shares.count == 1, let author = forwardedMessage.from?.bare else { return false }
            return applyShare(shares[0], author)
        }
        guard !encryption.isEncrypted else { return false }

        let decrypted: DDXMLElement
        do {
            guard let messageContainer = try decryptMessage(forwardedMessage) else {
                return false
            }
            decrypted = messageContainer
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return true
        }

        let author = decrypted.element(forName: "from")?.attributeStringValue(forName: "jid")
            ?? forwardedMessage.from?.bare
            ?? message.from?.bare
            ?? owner
        let share = decrypted.element(forName: "content")?.element(forName: "share", xmlns: getPrimaryNamespace())
            ?? decrypted.element(forName: "content")?.element(forName: "share")
            ?? decrypted.element(forName: "share", xmlns: getPrimaryNamespace())
            ?? decrypted.element(forName: "share")

        guard let share else {
            return false
        }

        return applyShare(share, author)
    }

    func didReceivedTrustedSharingEvent(message: XMPPMessage) -> Bool {
        guard let jid = message.from,
              let event = message.element(forName: "event"),
              let pubsubItems = event.element(forName: "items"),
              pubsubItems.attributeStringValue(forName: "node") == node else {
            return false
        }

        getUserTrustedDevices(jid: jid.bare)
        return true
    }

    override func read(withIQ iq: XMPPIQ) -> Bool {
        guard let jid = iq.from,
              let pubsub = iq.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"),
              let items = pubsub.element(forName: "items"),
              items.attributeStringValue(forName: "node") == node else {
            return false
        }

        var applied = false
        for item in items.elements(forName: "item") {
            guard let rawID = item.attributeStringValue(forName: "id"), let deviceID = Int(rawID),
                  deviceID > 0, deviceID <= Int(Int32.max), String(deviceID) == rawID,
                  let share = item.element(forName: "share", xmlns: getPrimaryNamespace()) else {
                continue
            }
            applied = applyShare(share, publisherBareJid: jid.bare, forcedPublisherDeviceId: deviceID) || applied
        }

        if applied {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: TrustSharingManager.receivedTrustedDevicesAfterVerification, object: self, userInfo: ["owner": self.owner, "jid": jid.bare])
            }
        }
        return true
    }

    func checkItemSignature(jid: String, deviceId: Int, signature: Data, itemsList: [DDXMLElement]) -> Bool {
        guard let canonical = TrustSharingSignature.canonicalString(for: itemsList) else {
            return false
        }
        return verifySignature(signature, canonicalString: canonical, publisherBareJid: jid, publisherDeviceId: deviceId)
    }

    func sendUpdateOfContactsDevices(jid: String, updatedDevicesIds: [Int]) {
        let items = buildContactTrustedItems(filterJid: jid, filterDeviceIds: Set(updatedDevicesIds))
        guard items.isNotEmpty else {
            return
        }
        sendContactShare(items)
    }

    func sendListOfContactsDevices() {
        let items = buildContactTrustedItems()
        guard items.isNotEmpty else {
            return
        }
        sendContactShare(items)
    }

    func publishOwnTrustedDevices(publisherDeviceId: String) {
        guard let publisherDeviceIdInt = Int(publisherDeviceId),
              let share = buildOwnTrustedDevicesShare(publisherDeviceId: publisherDeviceIdInt) else {
            return
        }

        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "id", stringValue: publisherDeviceId)
        item.addChild(share)

        let publish = DDXMLElement(name: "publish")
        publish.addAttribute(withName: "node", stringValue: node)
        publish.addChild(item)

        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        pubsub.addChild(publish)

        let iq = XMPPIQ(iqType: .set, child: pubsub)
        AccountManager.shared.find(for: owner)?.action { _, stream in
            stream.send(iq)
        }
    }

    func publicOwnTrustedDevices(publisherDeviceId: String) {
        publishOwnTrustedDevices(publisherDeviceId: publisherDeviceId)
    }

    func getUserTrustedDevices(jid: String, deviceId: String? = nil) {
        guard let jid = XMPPJID(string: jid) else {
            return
        }

        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: node)
        if let deviceId {
            let item = DDXMLElement(name: "item")
            item.addAttribute(withName: "id", stringValue: deviceId)
            items.addChild(item)
        }

        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        pubsub.addChild(items)

        let iq = XMPPIQ(iqType: .get, to: jid, child: pubsub)
        if let id = iq.elementID {
            queryIds.append(id)
        }

        AccountManager.shared.find(for: owner)?.action { _, stream in
            stream.send(iq)
        }
    }

    /// Keep the original forwarding timestamp when the opaque XEN adapter
    /// extracts a leaf. XEN notification/outer archive time is not its time.
    internal func originalSendingTime(for message: XMPPMessage) throws -> OMEMOOriginalSendingTime? {
        let bareMessage = recursivelyUnwrapped(message)
        if SCEReceivePolicy.hasOMEMO2(bareMessage) ||
            !SCEReceivePolicy.children(of: bareMessage, named: "share", xmlns: getPrimaryNamespace()).isEmpty {
            return try OmemoManager.originalSendingTime(for: message, owner: owner)
        }
        let notifications = SCEReceivePolicy.children(of: bareMessage, named: "notification", xmlns: XMPPNotificationsManager.xmlns)
        let nested = SCEReceivePolicy.children(of: bareMessage, named: "notify", xmlns: XMPPNotificationsManager.xmlns)
            .flatMap { SCEReceivePolicy.children(of: $0, named: "notification", xmlns: XMPPNotificationsManager.xmlns) }
        guard notifications.count + nested.count <= 1 else { throw OmemoManagerError.invalidEncryptedPayload }
        guard let notification = (notifications + nested).first else { return nil }
        let forwarded = SCEReceivePolicy.children(of: notification, named: "forwarded", xmlns: "urn:xmpp:forward:0")
        guard forwarded.count <= 1 else { throw OmemoManagerError.invalidEncryptedPayload }
        guard let forwarded = forwarded.first else { return nil }
        let container = XMPPMessage(from: DDXMLElement(name: "message", xmlns: "jabber:client"))
        container.addChild(SCEReceivePolicy.canonicalElementCopy(forwarded))
        return try OmemoManager.originalSendingTime(for: container, owner: owner)
    }

    private func forwardedPayloadMessage(from message: XMPPMessage) -> XMPPMessage? {
        if message.element(forName: "encrypted", xmlns: "urn:xmpp:omemo:2") != nil || message.element(forName: "share", xmlns: getPrimaryNamespace()) != nil {
            return message
        }

        let bareMessage = recursivelyUnwrapped(message)
        if bareMessage.element(forName: "encrypted", xmlns: "urn:xmpp:omemo:2") != nil || bareMessage.element(forName: "share", xmlns: getPrimaryNamespace()) != nil {
            return bareMessage
        }

        guard let notification = bareMessage.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns)
                ?? bareMessage.element(forName: "notification")
                ?? bareMessage.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns)?.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns)
                ?? bareMessage.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns)?.element(forName: "notification"),
              SCEReceivePolicy.matches(notification, name: "notification", namespace: XMPPNotificationsManager.xmlns) else {
            return nil
        }
        let forwarded = SCEReceivePolicy.children(of: notification, named: "forwarded", xmlns: "urn:xmpp:forward:0")
        guard forwarded.count == 1 else { return nil }
        let messages = SCEReceivePolicy.children(of: forwarded[0], named: "message", xmlns: "jabber:client")
        guard messages.count == 1 else { return nil }
        let inner = messages[0]

        let innerMessage = XMPPMessage(from: inner)
        if let originalFrom = originalFromAddress(in: bareMessage),
           let forwardedFrom = innerMessage.attributeStringValue(forName: "from"),
           !jidMatches(originalFrom, forwardedFrom) {
            return nil
        }
        return innerMessage
    }

    private func recursivelyUnwrapped(_ message: XMPPMessage) -> XMPPMessage {
        var current = message
        var depth = 0
        while depth < 4 {
            let next: XMPPMessage?
            if isArchivedMessage(current) {
                next = getArchivedMessageContainer(current)
            } else if isPriorityMessage(current) {
                next = getPriorityMessageContainer(current)
            } else if isCarbonCopy(current) {
                next = getCarbonCopyMessageContainer(current)
            } else if isCarbonForwarded(current) {
                next = getCarbonForwardedMessageContainer(current)
            } else {
                next = getForwardedMessage(current)
            }
            guard let next else {
                break
            }
            current = next
            depth += 1
        }
        return current
    }

    private func originalFromAddress(in message: XMPPMessage) -> String? {
        let addresses = message.element(forName: "addresses", xmlns: "http://jabber.org/protocol/address")
            ?? message.element(forName: "addresses")
            ?? message.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns)?.element(forName: "addresses", xmlns: "http://jabber.org/protocol/address")
            ?? message.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns)?.element(forName: "addresses")
        return addresses?.elements(forName: "address").first(where: { $0.attributeStringValue(forName: "type") == "ofrom" })?.attributeStringValue(forName: "jid")
    }

    private func jidMatches(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs {
            return true
        }
        guard let left = XMPPJID(string: lhs), let right = XMPPJID(string: rhs) else {
            return false
        }
        if left.resource != nil && right.resource != nil {
            return left.full == right.full
        }
        return left.bare == right.bare
    }

    private func applyShare(_ rawShare: DDXMLElement, publisherBareJid: String, forcedPublisherDeviceId: Int? = nil,
                            shouldRequestTrustedDevices: Bool = true, producedLocally: Bool = false, pendingDeadline: Date? = nil,
                            requiredGeneration: UInt64? = nil, requiredPublisherIdentity: Data? = nil) -> Bool {
        let generation = requiredGeneration ?? currentPendingGeneration()
        guard isCurrentPendingGeneration(generation), let publisherBareJid = TrustSharingBareJID.normalize(publisherBareJid) else { return false }
        // A mutable XML node must not change between signature validation and commit.
        guard let share = rawShare.copy() as? DDXMLElement,
              share.xmlString.utf8.count <= Self.maximumPendingShareBytes else { return false }
        let identities = SCEReceivePolicy.children(of: share, named: "identity", xmlns: getPrimaryNamespace())
        let signatures = SCEReceivePolicy.children(of: share, named: "signature", xmlns: getPrimaryNamespace())
        let containers = TrustSharingSignature.trustedItems(from: share)
        guard SCEReceivePolicy.matches(share, name: "share", namespace: getPrimaryNamespace()),
              share.attributeStringValue(forName: "protocol") == TrustSharingSignature.encryptionProtocol,
              TrustSharingSignature.timestamp(share) > 0,
              identities.count == 1, signatures.count == 1, containers.isNotEmpty,
              share.children?.compactMap({ $0 as? DDXMLElement }).count == containers.count + 2,
              let identity = identities.first,
              !(identity.children ?? []).contains(where: { $0 is DDXMLElement }),
              !(signatures.first?.children ?? []).contains(where: { $0 is DDXMLElement }),
              let identityDeviceIdRaw = identity.attributeStringValue(forName: "id"),
              let identityDeviceId = Int(identityDeviceIdRaw), identityDeviceId > 0,
              identityDeviceId <= Int(Int32.max), String(identityDeviceId) == identityDeviceIdRaw,
              forcedPublisherDeviceId == nil || forcedPublisherDeviceId == identityDeviceId,
              let identityFingerprint = identity.stringValue?.replacingOccurrences(of: " ", with: "").lowercased(),
              let signatureRaw = signatures.first?.stringValue else { return false }
        let publisherDeviceId = forcedPublisherDeviceId ?? identityDeviceId
        guard let wireIdentity = publisherIdentity(jid: publisherBareJid, deviceID: publisherDeviceId),
              wireIdentity.count == 32,
              requiredPublisherIdentity == nil || wireIdentity == requiredPublisherIdentity,
              (try? Self.canonicalRawFingerprint(wireIdentity)) == identityFingerprint,
              let signature = Data(base64Encoded: signatureRaw),
              let canonical = TrustSharingSignature.canonicalString(for: containers),
              Omemo2IdentityRepresentation.verify(signature, data: TrustSharingSignature.hashCanonicalString(canonical), storedIdentity: wireIdentity) else {
            return false
        }
        var unresolved: PendingResolution?
        let accepted = applyTrustedItems(containers, fallbackOwner: publisherBareJid, publisherDeviceId: publisherDeviceId,
            shouldRequestTrustedDevices: shouldRequestTrustedDevices, publisherIdentity: wireIdentity,
            pending: &unresolved, producedLocally: producedLocally, generation: generation)
        if let unresolved, !producedLocally {
            rememberPending(share, publisher: publisherBareJid, deviceID: publisherDeviceId, identity: wireIdentity,
                shouldRequestTrustedDevices: shouldRequestTrustedDevices, resolution: unresolved, deadline: pendingDeadline, generation: generation)
        }
        return accepted
    }

    private func verifySignature(_ signature: Data, canonicalString: String, publisherBareJid: String, publisherDeviceId: Int) -> Bool {
        guard let wireIdentity = publisherIdentity(jid: publisherBareJid, deviceID: publisherDeviceId) else {
            return false
        }
        let signedHash = TrustSharingSignature.hashCanonicalString(canonicalString)
        return Omemo2IdentityRepresentation.verify(signature, data: signedHash, storedIdentity: wireIdentity)
    }

    private struct TrustedItem {
        let jid: String
        let deviceID: Int
        let fingerprint: String
        let state: SignalDeviceStorageItem.TrustState
        let timestamp: Int64
        var target: TrustSharingLedger.Target { .init(jid: jid, deviceID: deviceID, fingerprint: fingerprint) }
        var decision: TrustSharingLedger.Decision {
            .init(deviceID: deviceID, fingerprint: fingerprint, state: state.rawValue, timestamp: timestamp)
        }
    }

    private struct TrustedList {
        let jid: String
        let timestamp: Int64
        let items: [TrustedItem]
    }

    private struct PendingResolution {
        let targets: Set<TrustSharingLedger.Target>
        let localDeviceID: Int
        let localIdentity: Data
    }

    private func trustedItems(_ containers: [DDXMLElement], fallbackOwner: String) -> [TrustedList]? {
        var lists: [TrustedList] = []
        var keys: [String: Set<String>] = [:]
        for container in containers {
            guard TrustSharingSignature.timestamp(container) > 0,
                  let canonicalOwner = TrustSharingSignature.canonicalOwner(for: container) else { return nil }
            let jid = canonicalOwner.isEmpty ? fallbackOwner : canonicalOwner
            var items: [TrustedItem] = []
            for entry in container.children?.compactMap({ $0 as? DDXMLElement }) ?? [] {
                guard let state = state(from: entry.localName), let value = entry.stringValue,
                      let bytes = Data(base64Encoded: value), bytes.base64EncodedString() == value,
                      let key = String(data: bytes, encoding: .utf8) else { return nil }
                let parts = key.components(separatedBy: "::")
                guard parts.count == 2, let deviceID = Int(parts[0]), deviceID > 0,
                      deviceID <= Int(Int32.max), String(deviceID) == parts[0], parts[1].utf8.count == 64,
                      parts[1].unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
                      TrustSharingSignature.timestamp(entry) > 0 else { return nil }
                let fingerprint = parts[1].lowercased()
                let canonicalKey = "\(deviceID)::\(fingerprint)"
                guard keys[jid, default: []].insert(canonicalKey).inserted else { return nil }
                items.append(TrustedItem(jid: jid, deviceID: deviceID, fingerprint: fingerprint,
                    state: state, timestamp: TrustSharingSignature.timestamp(entry)))
            }
            lists.append(TrustedList(jid: jid, timestamp: TrustSharingSignature.timestamp(container), items: items))
        }
        return lists
    }

    private static func canonicalRawFingerprint(_ identity: Data) throws -> String {
        try Omemo2IdentityRepresentation.fingerprint(for: identity).replacingOccurrences(of: " ", with: "").lowercased()
    }

    private func device(in realm: Realm, jid: String, deviceID: Int) -> SignalDeviceStorageItem? {
        guard let canonical = TrustSharingBareJID.normalize(jid) else { return nil }
        if let exact = realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceID)) { return exact }
        // Storage addresses are not rewritten. Equivalent A/U-label spellings
        // resolve to the same signed canonical owner for authority decisions.
        return realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND deviceId == %@", owner, deviceID)
            .first { TrustSharingBareJID.normalize($0.jid) == canonical }
    }

    private func publisherIdentity(jid: String, deviceID: Int) -> Data? {
        guard let realm = try? WRealm.safe(), let row = device(in: realm, jid: jid, deviceID: deviceID),
              let encoded = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: row.primary)?.identityKey,
              let identity = Data(base64Encoded: encoded), identity.count == 32 else { return nil }
        return identity
    }

    /// Exact-target floor for a normal local decision in its existing write.
    /// A diagnostic scalar or another fingerprint never supplies authority.
    func acceptedDecisionTimestamp(in realm: Realm, jid: String, deviceID: Int, fingerprint: String) throws -> Int64 {
        guard let jid = TrustSharingBareJID.normalize(jid), fingerprint.count == 64,
              fingerprint.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
              let row = device(in: realm, jid: jid, deviceID: deviceID),
              row.fingerprint.replacingOccurrences(of: " ", with: "").lowercased() == fingerprint,
              let storage = AccountManager.shared.find(for: owner)?.omemo.omemo2Storage else { throw OMEMO2StorageError.identityMismatch }
        let (anchor, bundle) = try localAnchor(in: realm, storage: storage)
        let ledger = try TrustSharingLedger.load(anchor.lastTrustedItemsUpdateTimestamp, owner: owner, bundle: bundle)
        return ledger.decisions()[.init(jid: jid, deviceID: deviceID, fingerprint: fingerprint)]?.timestamp ?? 0
    }

    /// The normal bundle callback also materializes retained negative/history
    /// decisions whose exact public identity was previously unavailable.
    func didCommitContactBundle(jid: String, deviceID: Int) {
        reconcileAcceptedDecision(jid: jid, deviceID: deviceID)
        retryPendingShares(jid: jid, deviceID: deviceID)
    }

    private func reconcileAcceptedDecision(jid: String, deviceID: Int) {
        guard let jid = TrustSharingBareJID.normalize(jid),
              let storage = AccountManager.shared.find(for: owner)?.omemo.omemo2Storage else { return }
        var change: (TrustedItem, Bool)?
        do {
            let realm = try WRealm.safe()
            try realm.write {
                let (anchor, bundle) = try localAnchor(in: realm, storage: storage)
                let ledger = try TrustSharingLedger.load(anchor.lastTrustedItemsUpdateTimestamp, owner: owner, bundle: bundle)
                guard let row = device(in: realm, jid: jid, deviceID: deviceID) else { return }
                let target = TrustSharingLedger.Target(jid: jid, deviceID: deviceID,
                    fingerprint: row.fingerprint.replacingOccurrences(of: " ", with: "").lowercased())
                guard currentTargetHasIdentity(target, in: realm), let decision = ledger.decisions()[target] else { return }
                let sourceID = ledger.sources.sorted(by: { $0.key < $1.key }).first {
                    $0.value.owners[jid]?.records[target.trustedKey]?.timestamp == decision.timestamp
                }?.value.deviceID ?? bundle.deviceID
                change = project(decision, target: target, in: realm, publisherDeviceID: sourceID)
            }
        } catch { return }
        if let change, change.1 { getUserTrustedDevices(jid: change.0.jid) }
    }

    private func project(_ decision: TrustSharingLedger.Decision, target: TrustSharingLedger.Target,
                         in realm: Realm, publisherDeviceID: Int) -> (TrustedItem, Bool)? {
        guard let row = device(in: realm, jid: target.jid, deviceID: target.deviceID),
              row.fingerprint.replacingOccurrences(of: " ", with: "").lowercased() == target.fingerprint else { return nil }
        if decision.trustState == .trusted && !currentTargetHasIdentity(target, in: realm) { return nil }
        let floor = row.state == .fingerprintChanged ? 0 : row.lastTrustSharingTimestamp
        var next = decision
        if decision.timestamp < floor { return nil }
        if decision.timestamp == floor {
            if row.state == .unknown || (row.state == .trusted && decision.trustState != .trusted)
                || ([.distrusted, .revoked].contains(row.state) && decision.trustState != .distrusted) {
                next = .init(deviceID: target.deviceID, fingerprint: target.fingerprint,
                    state: SignalDeviceStorageItem.TrustState.unknown.rawValue, timestamp: floor)
            } else { return nil }
        }
        let wasTrusted = row.state == .trusted
        apply(next.trustState, timestamp: next.timestamp, publisherDeviceId: publisherDeviceID, to: row)
        return (TrustedItem(jid: target.jid, deviceID: target.deviceID, fingerprint: target.fingerprint,
            state: next.trustState, timestamp: next.timestamp), !wasTrusted && next.trustState == .trusted)
    }

    static func publisherDiagnosticTimestamp(_ device: SignalDeviceStorageItem) -> Int64 {
        TrustSharingLedger.diagnosticMaximum(device.lastTrustedItemsUpdateTimestamp)
    }

    private func localAnchor(in realm: Realm, storage: XabberOMEMO2Storage) throws -> (SignalDeviceStorageItem, OMEMO2LocalBundle) {
        let bundle = try storage.localBundle()
        guard bundle.identityKey.count == 32,
              let device = realm.object(ofType: SignalDeviceStorageItem.self,
                forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: owner, deviceId: bundle.deviceID)),
              let identity = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: device.primary)?.identityKey,
              Data(base64Encoded: identity) == bundle.identityKey,
              device.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
                == (try Self.canonicalRawFingerprint(bundle.identityKey)) else {
            throw OMEMO2StorageError.identityMismatch
        }
        return (device, bundle)
    }

    private func currentTargetHasIdentity(_ target: TrustSharingLedger.Target, in realm: Realm) -> Bool {
        guard let device = device(in: realm, jid: target.jid, deviceID: target.deviceID),
              device.fingerprint.replacingOccurrences(of: " ", with: "").lowercased() == target.fingerprint,
              let encoded = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: device.primary)?.identityKey,
              let key = Data(base64Encoded: encoded), key.count == 32 else { return false }
        return (try? Self.canonicalRawFingerprint(key)) == target.fingerprint
    }

    private func applyTrustedItems(_ containers: [DDXMLElement], fallbackOwner: String, publisherDeviceId: Int,
                                   shouldRequestTrustedDevices: Bool, publisherIdentity: Data,
                                   pending: inout PendingResolution?, producedLocally: Bool = false, generation: UInt64) -> Bool {
        guard publisherIdentity.count == 32,
              let lists = trustedItems(containers, fallbackOwner: fallbackOwner),
              let account = AccountManager.shared.find(for: owner), let storage = account.omemo.omemo2Storage else { return false }
        let latestTimestamp = lists.map(\.timestamp).max() ?? 0
        var applied: [(TrustedItem, Bool)] = []
        var accepted = false
        do {
            let realm = try WRealm.safe()
            try realm.write {
                let (anchor, bundle) = try localAnchor(in: realm, storage: storage)
                guard isCurrentPendingGeneration(generation), AccountManager.shared.find(for: owner) === account, account.omemo.omemo2Storage === storage,
                      let publisher = device(in: realm, jid: fallbackOwner, deviceID: publisherDeviceId),
                      let stored = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: publisher.primary)?.identityKey,
                      Data(base64Encoded: stored) == publisherIdentity,
                      publisher.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
                        == (try Self.canonicalRawFingerprint(publisherIdentity)) else { return }
                let exactLocal = fallbackOwner == TrustSharingBareJID.normalize(owner) && publisherDeviceId == bundle.deviceID && publisherIdentity == bundle.identityKey
                guard publisher.state == .trusted || exactLocal else { return }
                var ledger = try TrustSharingLedger.load(anchor.lastTrustedItemsUpdateTimestamp, owner: owner, bundle: bundle)
                let sourceKey = TrustSharingLedger.sourceKey(jid: fallbackOwner, deviceID: publisherDeviceId, identity: publisherIdentity)
                var source = ledger.sources[sourceKey] ?? .init(jid: fallbackOwner, deviceID: publisherDeviceId,
                    identity: publisherIdentity.base64EncodedString(), owners: [:])
                let eligible = lists.filter { $0.timestamp >= (source.owners[$0.jid]?.timestamp ?? 0) }
                let oldDecisions = ledger.decisions()
                var missing: Set<TrustSharingLedger.Target> = []
                for list in eligible {
                    for item in list.items where item.state == .trusted {
                        if !currentTargetHasIdentity(item.target, in: realm), oldDecisions[item.target] == nil {
                            missing.insert(item.target)
                        }
                    }
                }
                guard missing.isEmpty else {
                    pending = .init(targets: missing, localDeviceID: bundle.deviceID, localIdentity: bundle.identityKey)
                    return
                }
                var touched: Set<TrustSharingLedger.Target> = []
                for list in eligible {
                    var ownerState = source.owners[list.jid] ?? .init(timestamp: 0, records: [:])
                    ownerState.timestamp = Swift.max(ownerState.timestamp, list.timestamp)
                    for item in list.items {
                        ownerState.records[item.decision.trustedKey] = ownerState.records[item.decision.trustedKey]
                            .map { $0.merging(item.decision) } ?? item.decision
                        touched.insert(item.target)
                    }
                    source.owners[list.jid] = ownerState
                }
                if !eligible.isEmpty { ledger.sources[sourceKey] = source }
                let decisions = ledger.decisions()
                for target in touched {
                    if let decision = decisions[target], let change = project(decision, target: target, in: realm, publisherDeviceID: publisherDeviceId) {
                        applied.append(change)
                    }
                }
                let diagnostic = Swift.max(Self.publisherDiagnosticTimestamp(publisher), latestTimestamp)
                if publisher.primary == anchor.primary { ledger.max = Swift.max(ledger.max, diagnostic) }
                else if !eligible.isEmpty { publisher.lastTrustedItemsUpdateTimestamp = String(diagnostic) }
                if !eligible.isEmpty {
                    let encoded = try ledger.encoded()
                    if anchor.lastTrustedItemsUpdateTimestamp != encoded { anchor.lastTrustedItemsUpdateTimestamp = encoded }
                }
                accepted = true
            }
        } catch {
            DDLogDebug("TrustSharingManager: signed trust state could not be committed")
            return false
        }
        guard !producedLocally else { return accepted }
        for (item, newlyTrusted) in applied {
            if newlyTrusted && shouldRequestTrustedDevices { getUserTrustedDevices(jid: item.jid) }
            if item.jid == TrustSharingBareJID.normalize(owner), let localDeviceID = AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() {
                publishOwnTrustedDevices(publisherDeviceId: String(localDeviceID))
            }
        }
        return accepted
    }

    private func apply(_ state: SignalDeviceStorageItem.TrustState, timestamp: Int64, publisherDeviceId: Int, to instance: SignalDeviceStorageItem) {
        instance.state = state
        instance.lastTrustSharingTimestamp = timestamp
        switch state {
        case .trusted:
            instance.trustDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
            instance.trustedByDeviceId = String(publisherDeviceId)
        case .distrusted, .unknown:
            instance.trustDate = Date(timeIntervalSince1970: -1)
            instance.trustedByDeviceId = nil
        case .revoked:
            instance.trustDate = Date(timeIntervalSince1970: -1)
            instance.trustedByDeviceId = nil
            instance.freshlyUpdated = true
        default:
            break
        }
    }

    private func state(from elementName: String?) -> SignalDeviceStorageItem.TrustState? {
        switch elementName {
        case "trust":
            return .trusted
        case "distrust":
            return .distrusted
        default:
            return nil
        }
    }

    private func elementName(for state: SignalDeviceStorageItem.TrustState) -> String? {
        switch state {
        case .trusted:
            return "trust"
        case .distrusted:
            return "distrust"
        case .revoked:
            return "distrust"
        default:
            return nil
        }
    }

    private func sendContactShare(_ items: [DDXMLElement]) {
        guard let account = AccountManager.shared.find(for: owner) else {
            return
        }

        let localDeviceId = account.omemo.localStore.localDeviceId()
        guard let share = buildShare(items: items, identityDeviceId: localDeviceId, identityJid: owner) else {
            return
        }

        guard let omemoEnvelope = account.omemo.prepareStanzaContent(message: "", date: Date(), jid: owner, additionalContent: [share], ignoreTimeSignature: true) else {
            return
        }

        let encrypted: DDXMLElement
        do {
            guard let encryptedRaw = try account.omemo.encryptMessage(message: omemoEnvelope, to: owner) else {
                return
            }
            encrypted = encryptedRaw
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return
        }

        let omemoMessage = XMPPMessage(messageType: .chat, to: XMPPJID(string: owner), elementID: UUID().uuidString, child: encrypted)
        omemoMessage.addBody("Message was encrypted by OMEMO".localizeString(id: "message_omemo_encryption", arguments: []))
        OmemoManager.synchronizeOutgoingEncryptionMetadata(omemoMessage)
        omemoMessage.addOriginId(UUID().uuidString)
        if let myFullJid = account.xmppStream.myJID?.full {
            omemoMessage.addAttribute(withName: "from", stringValue: myFullJid)
        }

        guard let toJid = XMPPJID(string: owner) else {
            return
        }
        account.action { user, stream in
            let packet = user.akeManager.getSignalMessagePacket(message: XMPPMessage(from: omemoMessage), to: toJid, ttl: 300)
            stream.send(packet)
        }
    }

    private func buildShare(items: [DDXMLElement], identityDeviceId: Int, identityJid: String) -> DDXMLElement? {
        guard let identityFingerprint = fingerprint(jid: identityJid, deviceId: identityDeviceId),
              let canonical = TrustSharingSignature.canonicalString(for: items),
              let signature = signCanonicalString(canonical) else {
            return nil
        }

        let share = DDXMLElement(name: "share", xmlns: getPrimaryNamespace())
        share.addAttribute(withName: "protocol", stringValue: TrustSharingSignature.encryptionProtocol)
        share.addAttribute(withName: "timestamp", stringValue: String(items.map { TrustSharingSignature.timestamp($0) }.max() ?? 0))
        for item in items {
            if let copy = item.copy() as? DDXMLElement {
                share.addChild(copy)
            }
        }

        let identity = DDXMLElement(name: "identity", xmlns: getPrimaryNamespace())
        identity.stringValue = identityFingerprint
        identity.addAttribute(withName: "id", stringValue: String(identityDeviceId))
        share.addChild(identity)

        let signatureElement = DDXMLElement(name: "signature", xmlns: getPrimaryNamespace())
        signatureElement.stringValue = signature.base64EncodedString()
        share.addChild(signatureElement)
        // Retain this newly signed local decision history under the same exact
        // local identity anchor before its current-device projection can rotate.
        guard applyShare(share, publisherBareJid: identityJid, forcedPublisherDeviceId: identityDeviceId,
            shouldRequestTrustedDevices: false, producedLocally: true) else { return nil }
        return share
    }

    private func buildContactTrustedItems(filterJid: String? = nil, filterDeviceIds: Set<Int>? = nil) -> [DDXMLElement] {
        publicationLists(ownDevices: false, filterJid: filterJid, filterDeviceIds: filterDeviceIds)
    }

    private func buildOwnTrustedDevicesShare(publisherDeviceId: Int) -> DDXMLElement? {
        let items = publicationLists(ownDevices: true)
        guard items.isNotEmpty else { return nil }
        return buildShare(items: items, identityDeviceId: publisherDeviceId, identityJid: owner)
    }

    /// Accepted full-key decisions outlive the signer row and the current SID
    /// occupant. A local explicit decision participates with its saved clock.
    private func publicationLists(ownDevices: Bool, filterJid: String? = nil, filterDeviceIds: Set<Int>? = nil) -> [DDXMLElement] {
        do {
            guard let storage = AccountManager.shared.find(for: owner)?.omemo.omemo2Storage else { return [] }
            let realm = try WRealm.safe()
            let (anchor, bundle) = try localAnchor(in: realm, storage: storage)
            let ledger = try TrustSharingLedger.load(anchor.lastTrustedItemsUpdateTimestamp, owner: owner, bundle: bundle)
            var decisions = ledger.decisions()
            for device in realm.objects(SignalDeviceStorageItem.self).filter("owner == %@", owner) {
                guard device.state != .fingerprintChanged, device.state != .ignore,
                      device.deviceId > 0, device.deviceId <= Int(Int32.max) else { continue }
                let fingerprint = device.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
                guard fingerprint.utf8.count == 64,
                      fingerprint.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else { continue }
                guard let jid = TrustSharingBareJID.normalize(device.jid) else { continue }
                let target = TrustSharingLedger.Target(jid: jid, deviceID: device.deviceId, fingerprint: fingerprint)
                if device.state == .trusted && !currentTargetHasIdentity(target, in: realm) { continue }
                let localTime = device.trustDate.timeIntervalSince1970.rounded(.down)
                let fallback = localTime.isFinite && localTime > 0 && localTime < Double(Int64.max) ? Int64(localTime) : 0
                let timestamp = device.lastTrustSharingTimestamp > 0 ? device.lastTrustSharingTimestamp : fallback
                guard timestamp > 0 else { continue }
                let state = device.state == .revoked ? SignalDeviceStorageItem.TrustState.distrusted : device.state
                guard [.trusted, .distrusted, .unknown].contains(state) else { continue }
                let candidate = TrustSharingLedger.Decision(deviceID: device.deviceId, fingerprint: fingerprint,
                    state: state.rawValue, timestamp: timestamp)
                decisions[target] = decisions[target].map { $0.merging(candidate) } ?? candidate
            }
            var owners = Set(ledger.sources.values.flatMap { $0.owners.keys })
            owners.formUnion(decisions.keys.map(\.jid))
            return owners.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.compactMap { jid in
                guard (jid == TrustSharingBareJID.normalize(owner)) == ownDevices,
                      filterJid == nil || TrustSharingBareJID.normalize(filterJid!) == jid else { return nil }
                let selected = decisions.filter { target, _ in
                    target.jid == jid && (filterDeviceIds == nil || filterDeviceIds!.contains(target.deviceID))
                }.values.filter { $0.trustState == .trusted || $0.trustState == .distrusted }
                let timestamp = Swift.max(ledger.ownerTimestamp(jid), selected.map(\.timestamp).max() ?? 0)
                guard timestamp > 0 else { return nil }
                let items = DDXMLElement(name: "trust-list", xmlns: getPrimaryNamespace())
                items.addAttribute(withName: "timestamp", stringValue: String(timestamp))
                if !ownDevices { items.addAttribute(withName: "owner", stringValue: jid) }
                for decision in selected.sorted(by: { $0.trustedKey < $1.trustedKey }) {
                    guard let type = elementName(for: decision.trustState) else { continue }
                    let entry = DDXMLElement(name: type, xmlns: getPrimaryNamespace())
                    entry.stringValue = Data(decision.trustedKey.utf8).base64EncodedString()
                    entry.addAttribute(withName: "timestamp", stringValue: String(decision.timestamp))
                    items.addChild(entry)
                }
                return items
            }
        } catch {
            DDLogDebug("TrustSharingManager: accepted trust history is unavailable for publication")
            return []
        }
    }

    private func fingerprint(jid: String, deviceId: Int) -> String? {
        do {
            let realm = try WRealm.safe()
            return realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceId))?
                .fingerprint
                .replacingOccurrences(of: " ", with: "")
                .lowercased()
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    private func signCanonicalString(_ canonical: String) -> Data? {
        guard let privateKey = try? Omemo2IdentityRepresentation.localIdentityPrivateKey(owner: owner) else {
            return nil
        }
        return try? Omemo2IdentityRepresentation.sign(TrustSharingSignature.hashCanonicalString(canonical), privateKey: privateKey)
    }

    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@", owner)
            if commitTransaction {
                try realm.write {
                    realm.delete(collection)
                }
            } else {
                realm.delete(collection)
            }
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
        }
    }
}
