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
        guard !raw.isEmpty, !raw.contains("|"),
              raw.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let jid = XMPPJID(string: raw), jid.resource == nil else { return nil }
        return jid.bare
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

class TrustSharingManager: AbstractXMPPManager {
    let node = TrustSharingSignature.node

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

    func handleTrustItems(jid: String? = nil, publisherDeviceId: Int, itemsList: [DDXMLElement], shouldRequestTrustedDevices: Bool = false) {
        _ = applyTrustedItems(itemsList, fallbackOwner: jid, publisherDeviceId: publisherDeviceId, shouldRequestTrustedDevices: shouldRequestTrustedDevices)
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

    private func applyShare(_ share: DDXMLElement, publisherBareJid: String, forcedPublisherDeviceId: Int? = nil, shouldRequestTrustedDevices: Bool = false) -> Bool {
        let identities = SCEReceivePolicy.children(of: share, named: "identity", xmlns: getPrimaryNamespace())
        let signatures = SCEReceivePolicy.children(of: share, named: "signature", xmlns: getPrimaryNamespace())
        let containers = TrustSharingSignature.trustedItems(from: share)
        guard SCEReceivePolicy.matches(share, name: "share", namespace: getPrimaryNamespace()),
              share.attributeStringValue(forName: "protocol") == TrustSharingSignature.encryptionProtocol,
              TrustSharingSignature.timestamp(share) > 0,
              identities.count == 1, signatures.count == 1, containers.isNotEmpty,
              share.children?.compactMap({ $0 as? DDXMLElement }).count == containers.count + 2,
              let identity = identities.first,
              let identityDeviceIdRaw = identity.attributeStringValue(forName: "id"),
              let identityDeviceId = Int(identityDeviceIdRaw), identityDeviceId > 0,
              identityDeviceId <= Int(Int32.max), String(identityDeviceId) == identityDeviceIdRaw,
              forcedPublisherDeviceId == nil || forcedPublisherDeviceId == identityDeviceId,
              let identityFingerprint = identity.stringValue?.replacingOccurrences(of: " ", with: "").lowercased(),
              let signatureRaw = signatures.first?.stringValue else {
            return false
        }

        let publisherDeviceId = forcedPublisherDeviceId ?? identityDeviceId
        guard let wireIdentity = AccountManager.shared.find(for: owner)?.akeManager.getUsersIdentityKey(jid: publisherBareJid, deviceId: publisherDeviceId),
              (try? Omemo2IdentityRepresentation.fingerprint(for: wireIdentity).replacingOccurrences(of: " ", with: "").lowercased()) == identityFingerprint,
              let signature = try? signatureRaw.base64decoded() else {
            return false
        }

        guard containers.isNotEmpty,
              let canonical = TrustSharingSignature.canonicalString(for: containers),
              Omemo2IdentityRepresentation.verify(Data(signature), data: TrustSharingSignature.hashCanonicalString(canonical), storedIdentity: wireIdentity) else {
            return false
        }

        return applyTrustedItems(containers, fallbackOwner: publisherBareJid, publisherDeviceId: publisherDeviceId,
                                 shouldRequestTrustedDevices: shouldRequestTrustedDevices,
                                 publisherIdentity: wireIdentity)
    }

    private func verifySignature(_ signature: Data, canonicalString: String, publisherBareJid: String, publisherDeviceId: Int) -> Bool {
        guard let wireIdentity = AccountManager.shared.find(for: owner)?.akeManager.getUsersIdentityKey(jid: publisherBareJid, deviceId: publisherDeviceId) else {
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
    }

    private func trustedItems(_ containers: [DDXMLElement], fallbackOwner: String?) -> [TrustedItem]? {
        var items: [TrustedItem] = []
        var addresses = Set<OMEMO2PeerAddress>()
        for container in containers {
            guard TrustSharingSignature.timestamp(container) > 0,
                  let canonicalOwner = TrustSharingSignature.canonicalOwner(for: container),
                  let jid = canonicalOwner.isEmpty ? fallbackOwner : canonicalOwner else { return nil }
            let entries = container.elements(forName: "trust")
                + container.elements(forName: "distrust")
            for entry in entries {
                guard let state = state(from: entry.name),
                      let value = entry.stringValue,
                      let bytes = try? value.base64decoded(),
                      let key = String(bytes: bytes, encoding: .utf8) else { return nil }
                let parts = key.components(separatedBy: "::")
                guard parts.count == 2, let deviceID = Int(parts[0]),
                      deviceID > 0, deviceID <= Int(Int32.max), String(deviceID) == parts[0],
                      parts[1].utf8.count == 64,
                      parts[1].unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
                      addresses.insert(OMEMO2PeerAddress(jid: jid, deviceID: deviceID)).inserted,
                      TrustSharingSignature.timestamp(entry) > 0 else { return nil }
                items.append(TrustedItem(jid: jid, deviceID: deviceID, fingerprint: parts[1].lowercased(),
                                         state: state, timestamp: TrustSharingSignature.timestamp(entry)))
            }
        }
        return items
    }

    private func applyTrustedItems(_ containers: [DDXMLElement], fallbackOwner: String?, publisherDeviceId: Int,
                                   shouldRequestTrustedDevices: Bool, publisherIdentity: Data? = nil) -> Bool {
        guard let items = trustedItems(containers, fallbackOwner: fallbackOwner) else { return false }
        let latestTimestamp = containers.map { TrustSharingSignature.timestamp($0) }.max() ?? 0
        let localBundle = try? AccountManager.shared.find(for: owner)?.omemo.omemo2Storage?.localBundle()
        var applied: [TrustedItem] = []
        var accepted = false
        do {
            let realm = try WRealm.safe()
            // Signature verification precedes mutation. Recheck current authority,
            // recipient identities and replay state in the same write transaction.
            try realm.write {
                var publisher: SignalDeviceStorageItem?
                if let publisherIdentity {
                    guard let publisherJID = fallbackOwner,
                          let device = realm.object(ofType: SignalDeviceStorageItem.self,
                            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: publisherJID, deviceId: publisherDeviceId)),
                          let storedKey = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: device.primary)?.identityKey,
                          Data(base64Encoded: storedKey) == publisherIdentity,
                          let fingerprint = try? Omemo2IdentityRepresentation.fingerprint(for: publisherIdentity),
                          device.fingerprint.replacingOccurrences(of: " ", with: "").lowercased() == fingerprint.replacingOccurrences(of: " ", with: "").lowercased(),
                          latestTimestamp >= (Int64(device.lastTrustedItemsUpdateTimestamp) ?? 0) else { return }
                    let isExactLocalIdentity = publisherJID == owner && localBundle?.deviceID == publisherDeviceId
                        && localBundle?.identityKey == publisherIdentity
                    guard device.state == .trusted || isExactLocalIdentity else { return }
                    publisher = device
                }

                var changes: [(TrustedItem, SignalDeviceStorageItem?)] = []
                for item in items {
                    let primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: item.jid, deviceId: item.deviceID)
                    if let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary) {
                        guard device.fingerprint.replacingOccurrences(of: " ", with: "").lowercased() == item.fingerprint else { return }
                        // A display fingerprint alone cannot authorize a new
                        // cryptographic identity under a reused device ID.
                        if item.state == .trusted {
                            guard let encodedKey = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary)?.identityKey,
                                  let key = Data(base64Encoded: encodedKey), key.count == 32,
                                  (try? Omemo2IdentityRepresentation.fingerprint(for: key).replacingOccurrences(of: " ", with: "").lowercased()) == item.fingerprint else { return }
                        }
                        if item.timestamp > device.lastTrustSharingTimestamp {
                            changes.append((item, device))
                        } else if item.timestamp == device.lastTrustSharingTimestamp,
                                  [.trusted, .distrusted].contains(device.state), device.state != item.state {
                            // Conflicting equal-time decisions have no authority
                            // to send or delegate trust. Keep the decision floor.
                            let ambiguous = TrustedItem(jid: item.jid, deviceID: item.deviceID, fingerprint: item.fingerprint,
                                                        state: .unknown, timestamp: item.timestamp)
                            changes.append((ambiguous, device))
                        }
                    } else if item.state == .distrusted {
                        changes.append((item, nil))
                    } else { return }
                }

                guard changes.isNotEmpty || publisher != nil else { return }
                for (item, device) in changes {
                    if let device {
                        apply(item.state, timestamp: item.timestamp, publisherDeviceId: publisherDeviceId, to: device)
                    } else {
                        let instance = SignalDeviceStorageItem()
                        instance.owner = owner
                        instance.jid = item.jid
                        instance.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: item.jid, deviceId: item.deviceID)
                        instance.deviceId = item.deviceID
                        instance.fingerprint = item.fingerprint
                        instance.state = .distrusted
                        instance.freshlyUpdated = true
                        instance.lastTrustSharingTimestamp = item.timestamp
                        realm.add(instance)
                    }
                    applied.append(item)
                }
                if let publisher {
                    // Publication freshness and the device's own trust decision
                    // have independent clocks. Preserve existing rows as stored.
                    publisher.lastTrustedItemsUpdateTimestamp = String(latestTimestamp)
                }
                accepted = true
            }
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return false
        }

        for item in applied {
            if item.state == .trusted && shouldRequestTrustedDevices { getUserTrustedDevices(jid: item.jid) }
            if item.jid == owner, let localDeviceID = AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() {
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
        return share
    }

    private func buildContactTrustedItems(filterJid: String? = nil, filterDeviceIds: Set<Int>? = nil) -> [DDXMLElement] {
        do {
            let realm = try WRealm.safe()
            let allowedStates = [
                SignalDeviceStorageItem.TrustState.trusted.rawValue,
                SignalDeviceStorageItem.TrustState.distrusted.rawValue,
                SignalDeviceStorageItem.TrustState.revoked.rawValue
            ]
            var devices = Array(realm.objects(SignalDeviceStorageItem.self)
                .filter("owner == %@ AND jid != %@ AND state_ IN %@", owner, owner, allowedStates)
                .map { $0 })
            if let filterJid {
                devices = devices.filter { $0.jid == filterJid }
            }
            if let filterDeviceIds {
                devices = devices.filter { filterDeviceIds.contains($0.deviceId) }
            }

            let grouped = Dictionary(grouping: devices, by: { $0.jid })
            return grouped.compactMap { jid, devices in
                trustedItemsElement(owner: jid, devices: devices)
            }
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return []
        }
    }

    private func buildOwnTrustedDevicesShare(publisherDeviceId: Int) -> DDXMLElement? {
        do {
            let realm = try WRealm.safe()
            let allowedStates = [
                SignalDeviceStorageItem.TrustState.trusted.rawValue,
                SignalDeviceStorageItem.TrustState.distrusted.rawValue,
                SignalDeviceStorageItem.TrustState.revoked.rawValue
            ]
            let devices = Array(realm.objects(SignalDeviceStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND state_ IN %@", owner, owner, allowedStates)
                .map { $0 })
            guard let items = trustedItemsElement(owner: nil, devices: devices) else {
                return nil
            }
            return buildShare(items: [items], identityDeviceId: publisherDeviceId, identityJid: owner)
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    private func trustedItemsElement(owner itemOwner: String?, devices: [SignalDeviceStorageItem]) -> DDXMLElement? {
        let decisions: [(device: SignalDeviceStorageItem, type: String, timestamp: Int64)] = devices.compactMap { device in
            guard let type = elementName(for: device.state) else { return nil }
            let trustTime = device.trustDate.timeIntervalSince1970.rounded(.down)
            let localTimestamp = trustTime.isFinite && trustTime > 0 && trustTime < Double(Int64.max) ? Int64(trustTime) : 0
            let timestamp = device.lastTrustSharingTimestamp > 0 ? device.lastTrustSharingTimestamp : localTimestamp
            guard timestamp > 0 else { return nil }
            return (device, type, timestamp)
        }
        guard let timestamp = decisions.map({ $0.timestamp }).max() else { return nil }
        let items = DDXMLElement(name: "trust-list", xmlns: getPrimaryNamespace())
        items.addAttribute(withName: "timestamp", stringValue: String(timestamp))
        if let itemOwner {
            items.addAttribute(withName: "owner", stringValue: itemOwner)
        }

        for (device, name, decisionTimestamp) in decisions {
            let key = "\(device.deviceId)::\(device.fingerprint.replacingOccurrences(of: " ", with: "").lowercased())"
            let entry = DDXMLElement(name: name, xmlns: getPrimaryNamespace())
            entry.stringValue = key.toBase64()
            entry.addAttribute(withName: "timestamp", stringValue: String(decisionTimestamp))
            items.addChild(entry)
        }

        return items
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
