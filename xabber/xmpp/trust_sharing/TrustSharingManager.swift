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
import Curve25519Kit
import CryptoSwift
import RealmSwift

struct TrustSharingSignature {
    static let xmlns = "urn:xmpp:trustsharing:0"
    static let usage = "urn:xmpp:omemo:2"
    static let node = "urn:xmpp:trustsharing:0:items"

    static func trustedItems(from share: DDXMLElement) -> [DDXMLElement] {
        let modern = share.elements(forName: "trusted-items")
        if modern.isNotEmpty {
            return modern
        }
        return share.elements(forName: "items")
    }

    static func canonicalString(for containers: [DDXMLElement]) -> String? {
        var canonical = ""
        let sortedContainers = containers.sorted { lhs, rhs in
            timestamp(lhs) > timestamp(rhs)
        }

        for container in sortedContainers {
            let containerTimestamp = timestamp(container)
            guard containerTimestamp > 0 else {
                return nil
            }
            canonical += String(containerTimestamp)

            let entries = (container.elements(forName: "trust")
                + container.elements(forName: "distrust")
                + container.elements(forName: "revoked"))
                .sorted { lhs, rhs in
                    let lhsTimestamp = timestamp(lhs)
                    let rhsTimestamp = timestamp(rhs)
                    if lhsTimestamp == rhsTimestamp {
                        return (lhs.name ?? "") < (rhs.name ?? "")
                    }
                    return lhsTimestamp > rhsTimestamp
                }

            for entry in entries {
                guard let name = entry.name,
                      let value = entry.stringValue,
                      timestamp(entry) > 0 else {
                    return nil
                }
                canonical += "<\(name):\(timestamp(entry))/\(value)"
            }
        }

        return canonical
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

    override func namespaces() -> [String] {
        return [
            TrustSharingSignature.xmlns,
            "\(TrustSharingSignature.node)+notify"
        ]
    }

    override func getPrimaryNamespace() -> String {
        return TrustSharingSignature.xmlns
    }

    func didReceivedListOfContactsDevices(message: XMPPMessage) -> Bool {
        guard let forwardedMessage = forwardedPayloadMessage(from: message),
              let omemoManager = AccountManager.shared.find(for: owner)?.omemo else {
            return false
        }

        let decrypted: DDXMLElement
        do {
            guard let messageContainer = try omemoManager.decryptMessage(forwardedMessage) else {
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

        return applyShare(share, publisherBareJid: author, shouldRequestTrustedDevices: true)
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
            guard let share = item.element(forName: "share", xmlns: getPrimaryNamespace()) ?? item.element(forName: "share") else {
                continue
            }
            applied = applyShare(share, publisherBareJid: jid.bare, forcedPublisherDeviceId: Int(item.attributeStringValue(forName: "id") ?? "")) || applied
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
              notification.xmlns() == XMPPNotificationsManager.xmlns,
              let forwarded = notification.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0")
                ?? notification.element(forName: "forwarded"),
              let inner = forwarded.element(forName: "message") else {
            return nil
        }

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
        guard share.xmlns() == getPrimaryNamespace(),
              share.attributeStringValue(forName: "usage", withDefaultValue: TrustSharingSignature.usage) == TrustSharingSignature.usage,
              let identity = share.element(forName: "identity"),
              let identityDeviceIdRaw = identity.attributeStringValue(forName: "id"),
              let identityDeviceId = Int(identityDeviceIdRaw),
              forcedPublisherDeviceId == nil || forcedPublisherDeviceId == identityDeviceId,
              let identityFingerprint = identity.stringValue?.replacingOccurrences(of: " ", with: "").lowercased(),
              let signatureRaw = share.element(forName: "signature", xmlns: getPrimaryNamespace())?.stringValue ?? share.element(forName: "signature")?.stringValue else {
            return false
        }

        let publisherDeviceId = forcedPublisherDeviceId ?? identityDeviceId
        guard fingerprintMatches(jid: publisherBareJid, deviceId: publisherDeviceId, fingerprint: identityFingerprint),
              let signature = try? signatureRaw.base64decoded() else {
            return false
        }

        let containers = TrustSharingSignature.trustedItems(from: share)
        guard containers.isNotEmpty,
              checkPublisherTimestamp(publisherBareJid: publisherBareJid, publisherDeviceId: publisherDeviceId, containers: containers),
              let canonical = TrustSharingSignature.canonicalString(for: containers),
              verifySignature(Data(signature), canonicalString: canonical, publisherBareJid: publisherBareJid, publisherDeviceId: publisherDeviceId) else {
            return false
        }

        return applyTrustedItems(containers, fallbackOwner: publisherBareJid, publisherDeviceId: publisherDeviceId, shouldRequestTrustedDevices: shouldRequestTrustedDevices)
    }

    private func verifySignature(_ signature: Data, canonicalString: String, publisherBareJid: String, publisherDeviceId: Int) -> Bool {
        let publicKey = AccountManager.shared.find(for: owner)?.akeManager.getUsersPublicKey(jid: publisherBareJid, deviceId: publisherDeviceId) ?? []
        guard publicKey.isNotEmpty else {
            return false
        }
        let signedHash = TrustSharingSignature.hashCanonicalString(canonicalString)
        return Ed25519.verifySignature(signature, publicKey: Data(publicKey), data: signedHash)
    }

    private func fingerprintMatches(jid: String, deviceId: Int, fingerprint: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            guard let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceId)) else {
                return false
            }
            let stored = device.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
            return stored == fingerprint
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    private func checkPublisherTimestamp(publisherBareJid: String, publisherDeviceId: Int, containers: [DDXMLElement]) -> Bool {
        let latestTimestamp = containers.map { TrustSharingSignature.timestamp($0) }.max() ?? 0
        guard latestTimestamp > 0 else {
            return false
        }

        do {
            let realm = try WRealm.safe()
            guard let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: publisherBareJid, deviceId: publisherDeviceId)) else {
                return false
            }
            if latestTimestamp <= device.lastTrustSharingTimestamp {
                return false
            }
            try realm.write {
                device.lastTrustSharingTimestamp = latestTimestamp
                device.lastTrustedItemsUpdateTimestamp = String(latestTimestamp)
            }
            return true
        } catch {
            DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    private func applyTrustedItems(_ containers: [DDXMLElement], fallbackOwner: String?, publisherDeviceId: Int, shouldRequestTrustedDevices: Bool) -> Bool {
        var applied = false

        for container in containers {
            let itemOwner = container.attributeStringValue(forName: "owner") ?? fallbackOwner
            guard let jid = itemOwner else {
                continue
            }

            let entries = container.elements(forName: "trust")
                + container.elements(forName: "distrust")
                + container.elements(forName: "revoked")

            for entry in entries {
                guard let state = state(from: entry.name),
                      let value = entry.stringValue,
                      let trustKeyBytes = try? value.base64decoded(),
                      let trustKey = String(bytes: trustKeyBytes, encoding: .utf8),
                      let deviceIdRaw = trustKey.components(separatedBy: "::").first,
                      let deviceId = Int(deviceIdRaw) else {
                    continue
                }

                let entryTimestamp = TrustSharingSignature.timestamp(entry)
                guard entryTimestamp > 0 else {
                    continue
                }

                do {
                    let realm = try WRealm.safe()
                    let primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceId)
                    if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary) {
                        if entryTimestamp <= instance.lastTrustSharingTimestamp {
                            continue
                        }
                        try realm.write {
                            apply(state, timestamp: entryTimestamp, publisherDeviceId: publisherDeviceId, to: instance)
                        }
                        applied = true
                    } else if state == .revoked {
                        let instance = SignalDeviceStorageItem()
                        instance.owner = owner
                        instance.jid = jid
                        instance.primary = primary
                        instance.deviceId = deviceId
                        instance.state = .revoked
                        instance.freshlyUpdated = true
                        instance.lastTrustSharingTimestamp = entryTimestamp
                        try realm.write {
                            realm.add(instance)
                        }
                        applied = true
                    }
                } catch {
                    DDLogDebug("TrustSharingManager: \(#function). \(error.localizedDescription)")
                }

                if state == .trusted && shouldRequestTrustedDevices {
                    getUserTrustedDevices(jid: jid)
                }
                if jid == owner, let localDeviceId = AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() {
                    publishOwnTrustedDevices(publisherDeviceId: String(localDeviceId))
                }
            }
        }

        return applied
    }

    private func apply(_ state: SignalDeviceStorageItem.TrustState, timestamp: Int64, publisherDeviceId: Int, to instance: SignalDeviceStorageItem) {
        instance.state = state
        instance.lastTrustSharingTimestamp = timestamp
        instance.lastTrustedItemsUpdateTimestamp = String(timestamp)
        switch state {
        case .trusted:
            instance.trustDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
            instance.trustedByDeviceId = String(publisherDeviceId)
        case .distrusted:
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
        case "revoked":
            return .revoked
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
            return "revoked"
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
        let encryptionElement = DDXMLElement(name: "encryption", xmlns: "urn:xmpp:eme:0")
        encryptionElement.addAttribute(withName: "namespace", stringValue: "urn:xmpp:omemo:2")
        omemoMessage.addChild(encryptionElement)
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
        share.addAttribute(withName: "usage", stringValue: TrustSharingSignature.usage)
        for item in items {
            if let copy = item.copy() as? DDXMLElement {
                share.addChild(copy)
            }
        }

        let identity = DDXMLElement(name: "identity", stringValue: identityFingerprint)
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
            let devices = Array(realm.objects(SignalDeviceStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND state_ == %@", owner, owner, SignalDeviceStorageItem.TrustState.trusted.rawValue)
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
        let filteredDevices = devices.filter { elementName(for: $0.state) != nil }
        guard filteredDevices.isNotEmpty else {
            return nil
        }

        let timestamp = Int(Date().timeIntervalSince1970.rounded())
        let items = DDXMLElement(name: "trusted-items", xmlns: getPrimaryNamespace())
        items.addAttribute(withName: "timestamp", stringValue: String(timestamp))
        if let itemOwner {
            items.addAttribute(withName: "owner", stringValue: itemOwner)
        }

        for device in filteredDevices {
            guard let name = elementName(for: device.state) else {
                continue
            }
            let key = "\(device.deviceId)::\(device.fingerprint.replacingOccurrences(of: " ", with: "").lowercased())"
            let entry = DDXMLElement(name: name, stringValue: key.toBase64())
            let entryTimestamp = max(Int(device.trustDate.timeIntervalSince1970.rounded()), timestamp)
            entry.addAttribute(withName: "timestamp", stringValue: String(entryTimestamp))
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
        guard let keyPair = AccountManager.shared.find(for: owner)?.omemo.localStore.getIdentityKeyPair() else {
            return nil
        }
        let curveKeyPair = Curve25519.load(fromPublicKey: keyPair.publicKey, andPrivateKey: keyPair.privateKey)
        return Ed25519.sign(TrustSharingSignature.hashCanonicalString(canonical), with: curveKeyPair)
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
