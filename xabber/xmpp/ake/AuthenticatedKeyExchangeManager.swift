//
//  AuthenticatedKeyExchangeManager.swift
//  xabber
//
//  Created by MacIntel on 08.02.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import XMPPFramework
import CryptoKit
import CryptoSwift
import RealmSwift

struct XEPTrustEnvelope {
    enum AbortReason: String { case cancel, timeout, fail }
    enum Kind {
        case request(deviceId: Int, targetDeviceId: Int?)
        case accept(deviceId: Int)
        case challenge(deviceId: Int, ciphertext: String, iv: String)
        case response(deviceId: Int, ciphertext: String, iv: String, hmac: String)
        case verify(deviceId: Int, hmac: String)
        case success(deviceId: Int)
        case abort(reason: AbortReason)
        var name: String {
            switch self {
            case .request: return "request"
            case .accept: return "accept"
            case .challenge: return "challenge"
            case .response: return "response"
            case .verify: return "verify"
            case .success: return "success"
            case .abort: return "abort"
            }
        }
    }
    static let xmlns = "urn:xabber:trust"
    static let protocolNamespace = "urn:xmpp:omemo:2"
    let sid: String
    // Local session bookkeeping; these values are not message dates or wire fields.
    let timestamp: Int
    let expires: Int
    let kind: Kind
    var isExpired: Bool { expires > 0 && expires <= Int(Date().timeIntervalSince1970) }

    static func makeTrustElement(sid: String, expires: Int, timestamp: Int = Int(Date().timeIntervalSince1970), kind: Kind) -> DDXMLElement {
        let element = DDXMLElement(name: kind.name, xmlns: xmlns)
        element.addAttribute(withName: "session-id", stringValue: sid)
        switch kind {
        case let .request(deviceId, targetDeviceId):
            element.addAttribute(withName: "protocol", stringValue: protocolNamespace)
            element.addAttribute(withName: "device-id", stringValue: String(deviceId))
            element.addAttribute(withName: "expires", stringValue: String(expires))
            if let targetDeviceId { element.addAttribute(withName: "target", stringValue: String(targetDeviceId)) }
        case let .accept(deviceId):
            element.addAttribute(withName: "device-id", stringValue: String(deviceId))
        case let .challenge(deviceId, ciphertext, iv):
            element.addAttribute(withName: "device-id", stringValue: String(deviceId))
            addNonce(to: element, ciphertext: ciphertext, iv: iv)
        case let .response(_, ciphertext, iv, hmac):
            addNonce(to: element, ciphertext: ciphertext, iv: iv)
            let mac = DDXMLElement(name: "key-mac", xmlns: xmlns)
            mac.stringValue = hmac
            element.addChild(mac)
        case let .verify(_, hmac):
            let mac = DDXMLElement(name: "key-mac", xmlns: xmlns)
            mac.stringValue = hmac
            element.addChild(mac)
        case .success: break
        case let .abort(reason): element.addAttribute(withName: "reason", stringValue: reason.rawValue)
        }
        return element
    }
    private static func addNonce(to element: DDXMLElement, ciphertext: String, iv: String) {
        let nonce = DDXMLElement(name: "nonce", xmlns: xmlns)
        nonce.stringValue = ciphertext
        nonce.addAttribute(withName: "iv", stringValue: iv)
        element.addChild(nonce)
    }
    private static func binary(_ value: String?, size: Int) -> String? {
        guard let value, let data = Data(base64Encoded: value), data.count == size,
              data.base64EncodedString() == value else { return nil }
        return value
    }
    private static func deviceID(_ value: String?) -> Int? {
        guard let value, let id = Int(value), id > 0, id <= Int(Int32.max), String(id) == value else { return nil }
        return id
    }
    static func parse(from message: XMPPMessage) -> XEPTrustEnvelope? {
        let names = Set(["request", "accept", "challenge", "response", "verify", "success", "abort"])
        let payloads = (message.children ?? []).compactMap { $0 as? DDXMLElement }
            .filter { names.contains($0.localName ?? "") && $0.uri == xmlns }
        guard payloads.count == 1, let element = payloads.first,
              let sid = binary(element.attributeStringValue(forName: "session-id"), size: 16) else { return nil }
        let children = (element.children ?? []).compactMap { $0 as? DDXMLElement }
        func child(_ name: String) -> DDXMLElement? {
            let matches = children.filter { $0.localName == name && $0.uri == xmlns }
            return matches.count == 1 ? matches.first : nil
        }
        func nonce() -> (String, String)? {
            guard let nonce = child("nonce"),
                  let ciphertext = binary(nonce.stringValue, size: 48),
                  let iv = binary(nonce.attributeStringValue(forName: "iv"), size: 16) else { return nil }
            return (ciphertext, iv)
        }
        let kind: Kind
        var expires = 0
        switch element.localName {
        case "request":
            guard children.isEmpty, element.attributeStringValue(forName: "protocol") == protocolNamespace,
                  let id = deviceID(element.attributeStringValue(forName: "device-id")),
                  let expiration = element.attributeStringValue(forName: "expires"),
                  let parsed = Int(expiration), parsed > 0, String(parsed) == expiration else { return nil }
            let rawTarget = element.attributeStringValue(forName: "target")
            let target = deviceID(rawTarget)
            guard rawTarget == nil || target != nil else { return nil }
            expires = parsed; kind = .request(deviceId: id, targetDeviceId: target)
        case "accept":
            guard children.isEmpty, let id = deviceID(element.attributeStringValue(forName: "device-id")) else { return nil }
            kind = .accept(deviceId: id)
        case "challenge":
            guard children.count == 1, let id = deviceID(element.attributeStringValue(forName: "device-id")), let (ciphertext, iv) = nonce() else { return nil }
            kind = .challenge(deviceId: id, ciphertext: ciphertext, iv: iv)
        case "response":
            guard children.count == 2, let (ciphertext, iv) = nonce(), let mac = binary(child("key-mac")?.stringValue, size: 32) else { return nil }
            kind = .response(deviceId: 0, ciphertext: ciphertext, iv: iv, hmac: mac)
        case "verify":
            guard children.count == 1, let mac = binary(child("key-mac")?.stringValue, size: 32) else { return nil }
            kind = .verify(deviceId: 0, hmac: mac)
        case "success":
            guard children.isEmpty else { return nil }
            kind = .success(deviceId: 0)
        case "abort":
            guard children.isEmpty, let raw = element.attributeStringValue(forName: "reason"), let reason = AbortReason(rawValue: raw) else { return nil }
            kind = .abort(reason: reason)
        default: return nil
        }
        return XEPTrustEnvelope(sid: sid, timestamp: Int(Date().timeIntervalSince1970), expires: expires, kind: kind)
    }
}

struct XEPTrustForwardedExtractor {
    static func trustMessage(from message: XMPPMessage) -> XMPPMessage? {
        let bareMessage = recursivelyUnwrapped(message)
        if containsTrust(in: bareMessage) {
            return bareMessage
        }

        guard let notification = bareMessage.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns)
                ?? bareMessage.element(forName: "notification")
                ?? bareMessage.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns)?.element(forName: "notification", xmlns: XMPPNotificationsManager.xmlns)
                ?? bareMessage.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns)?.element(forName: "notification"),
              notification.xmlns() == XMPPNotificationsManager.xmlns,
              let forwardedElement = notification.element(forName: "forwarded", xmlns: "urn:xmpp:forward:0")
                ?? notification.element(forName: "forwarded"),
              let innerElement = forwardedElement.element(forName: "message") else {
            return nil
        }

        let innerMessage = XMPPMessage(from: innerElement)
        guard containsTrust(in: innerMessage) else {
            return nil
        }

        let addresses = addressMap(from: bareMessage) ?? addressMap(from: bareMessage.element(forName: "notify", xmlns: XMPPNotificationsManager.xmlns))
        guard let originalFrom = addresses?["ofrom"],
              let forwardedFrom = innerMessage.from,
              let claimedSender = XMPPJID(string: originalFrom),
              claimedSender.full == forwardedFrom.full else { return nil }

        return innerMessage
    }

    private static func recursivelyUnwrapped(_ message: XMPPMessage) -> XMPPMessage {
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
                // A quoted forwarded message cannot claim a different sender.
                next = nil
            }

            guard let unwrapped = next else {
                break
            }
            current = unwrapped
            depth += 1
        }
        return current
    }

    private static func containsTrust(in message: XMPPMessage) -> Bool {
        return XEPTrustEnvelope.parse(from: message) != nil
    }

    private static func addressMap(from element: DDXMLElement?) -> [String: String]? {
        guard let element,
              let addresses = element.element(forName: "addresses", xmlns: "http://jabber.org/protocol/address")
                ?? element.element(forName: "addresses") else {
            return nil
        }

        var map: [String: String] = [:]
        for address in addresses.elements(forName: "address") {
            guard let type = address.attributeStringValue(forName: "type"),
                  let jid = address.attributeStringValue(forName: "jid") else {
                continue
            }
            guard map[type] == nil, let parsed = XMPPJID(string: jid), parsed.user != nil else { return nil }
            map[type] = parsed.full
        }
        return map
    }

    private static func jidMatches(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs {
            return true
        }
        guard let left = XMPPJID(string: lhs),
              let right = XMPPJID(string: rhs) else {
            return false
        }
        if left.resource != nil && right.resource != nil {
            return left.full == right.full
        }
        return left.bare == right.bare
    }
}

private struct VerificationSessionTimeoutSnapshot {
    let owner: String
    let sid: String
    let primary: String
    let peerRaw: String
    let expires: Int
    let shouldNotifyPeer: Bool

    init(_ session: VerificationSessionStorageItem) {
        owner = session.owner
        sid = session.sid
        primary = VerificationSessionStorageItem.genPrimary(owner: session.owner, sid: session.sid)
        peerRaw = session.peerFullJid.isEmpty ? (session.fullJID.isEmpty ? session.jid : session.fullJID) : session.peerFullJid
        expires = Int(session.expires)
        shouldNotifyPeer = session.role == .initiator || session.state == .sentRequest
    }

    var peer: XMPPJID? {
        return XMPPJID(string: peerRaw)
    }
}

class AuthenticatedKeyExchangeManager: AbstractXMPPManager {
    static let showConfirmationViewNotification = NSNotification.Name("com.xabber.ios.ake.showConfirmationViewNotification")
    static let showSuccessViewNotification = NSNotification.Name("com.xabber.ios.ake.showSuccessViewNotification")
    static let showCodeInputViewNotification = NSNotification.Name("com.xabber.ios.ake.showCodeInputViewNotification")
    static let showCodeOutputViewNotification = NSNotification.Name("com.xabber.ios.ake.showCodeOutputViewNotification")

    static let closeViewNotification = NSNotification.Name(rawValue: "com.xabber.ios.ake.closeView")
    static let verificationConfirmationVCRejected = NSNotification.Name(rawValue: "com.xabber.ios.ake.rejected_VerificationConfirmationViewController")
    static let authenticationCodeInputVCShow = NSNotification.Name(rawValue: "com.xabber.ios.ake.AuthenticationCodeInputViewController")

    enum State {
        case none
        case sentRequest
        case receivedRequest
        case acceptedRequest
        case hashSentToOpponent
        case hashSentToInitiator
        case trusted
    }

    private enum HMACLabel {
        static let a1 = "trustedKey_A1"
        static let b1 = "trustedKey_B1"
    }

    private struct VerificationKeyBinding {
        let peer: String
        let deviceID: Int
        let peerIdentity: Data
        let ownIdentity: Data
    }
    // Active code exchanges fail closed after restart or an identity change.
    // No stored session or old trust row is converted into new verification proof.
    private var verificationKeyBindings: [String: VerificationKeyBinding] = [:]
    private let verificationKeyBindingsLock = NSRecursiveLock()

    private func keyBinding(for sid: String) -> VerificationKeyBinding? {
        verificationKeyBindingsLock.lock()
        defer { verificationKeyBindingsLock.unlock() }
        return verificationKeyBindings[sid]
    }

    private func bindVerificationKeys(_ session: VerificationSessionStorageItem) -> Bool {
        verificationKeyBindingsLock.lock()
        defer { verificationKeyBindingsLock.unlock() }
        guard let peerIdentity = getUsersIdentityKey(jid: session.jid, deviceId: session.opponentDeviceId),
              peerIdentity.count == 32,
              let bundle = try? AccountManager.shared.find(for: owner)?.omemo.omemo2Storage?.localBundle(),
              bundle.deviceID == session.myDeviceId else { return false }
        if let existing = verificationKeyBindings[session.sid] {
            return existing.peer == session.jid && existing.deviceID == session.opponentDeviceId
                && existing.peerIdentity == peerIdentity && existing.ownIdentity == bundle.identityKey
        }
        verificationKeyBindings[session.sid] = .init(peer: session.jid, deviceID: session.opponentDeviceId,
            peerIdentity: peerIdentity, ownIdentity: bundle.identityKey)
        return true
    }

    private func verificationKeysUnchanged(_ session: VerificationSessionStorageItem) -> Bool {
        guard keyBinding(for: session.sid) != nil else { return false }
        return bindVerificationKeys(session)
    }

    private func admittedEnvelope(_ envelope: XEPTrustEnvelope, from: XMPPJID) -> XEPTrustEnvelope? {
        guard from.user != nil else { return nil }
        do {
            let realm = try WRealm.safe()
            let session = realm.object(ofType: VerificationSessionStorageItem.self,
                forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: envelope.sid))
            if case .request = envelope.kind {
                // A replay must never reset another exchange, its nonce, or its peer binding.
                return session == nil ? envelope : nil
            }
            guard let session, !isTerminal(session.state) else { return nil }
            if case .accept = envelope.kind {
                guard from.bare == owner, session.role == .responder, session.state == .receivedRequest else { return nil }
                guard session.expires > Date().timeIntervalSince1970 else {
                    closeExpiredSessionIfNeeded(sid: session.sid)
                    return nil
                }
                return envelope
            }
            guard from.bare == session.jid else { return nil }
            let pinned = session.peerFullJid.isEmpty ? session.fullJID : session.peerFullJid
            guard pinned.isEmpty || pinned == from.full else { return nil }
            guard session.expires > Date().timeIntervalSince1970 else {
                closeExpiredSessionIfNeeded(sid: session.sid)
                return nil
            }
            let kind: XEPTrustEnvelope.Kind
            switch envelope.kind {
            case let .challenge(deviceID, ciphertext, iv):
                guard session.role == .initiator, session.state == .sentRequest,
                      session.opponentDeviceId == 0 || session.opponentDeviceId == deviceID else { return nil }
                kind = .challenge(deviceId: deviceID, ciphertext: ciphertext, iv: iv)
            case let .response(_, ciphertext, iv, hmac):
                guard session.role == .responder, session.state == .acceptedRequest,
                      verificationKeysUnchanged(session) else { return nil }
                kind = .response(deviceId: session.opponentDeviceId, ciphertext: ciphertext, iv: iv, hmac: hmac)
            case let .verify(_, hmac):
                guard session.role == .initiator, session.state == .responseSent,
                      verificationKeysUnchanged(session) else { return nil }
                kind = .verify(deviceId: session.opponentDeviceId, hmac: hmac)
            case .success:
                guard session.role == .responder, session.state == .verifySent,
                      verificationKeysUnchanged(session) else { return nil }
                kind = .success(deviceId: session.opponentDeviceId)
            case let .abort(reason): kind = .abort(reason: reason)
            case .request, .accept: return nil
            }
            return XEPTrustEnvelope(sid: envelope.sid, timestamp: envelope.timestamp,
                expires: Int(session.expires), kind: kind)
        } catch { return nil }
    }

    private func validatedTrustTarget(realm: Realm, jid: String, deviceId: Int,
                                      expectedIdentity: Data? = nil) -> SignalDeviceStorageItem? {
        guard let identity = getUsersIdentityKey(jid: jid, deviceId: deviceId), identity.count == 32,
              expectedIdentity == nil || identity == expectedIdentity,
              let fingerprint = try? Omemo2IdentityRepresentation.fingerprint(for: identity),
              let device = realm.object(ofType: SignalDeviceStorageItem.self,
                  forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceId)),
              device.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
                == fingerprint.replacingOccurrences(of: " ", with: "").lowercased() else { return nil }
        return device
    }

    private func applyLocalTrust(_ device: SignalDeviceStorageItem) throws {
        let now = Date()
        guard let timestamp = TrustSharingManager.nextLocalDecisionTimestamp(
            previous: device.lastTrustSharingTimestamp, at: now) else {
            throw AuthenticatedKeyExchangeManagerError.invalidDecisionTimestamp
        }
        device.trustDate = now
        device.lastTrustSharingTimestamp = timestamp
        device.state = .trusted
        device.trustedByDeviceId = String(AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() ?? 0)
    }

    private var processedStanzas: Set<String> = []

    override init(withOwner owner: String) {
        super.init(withOwner: owner)
    }

    override func namespaces() -> [String] {
        return [XEPTrustEnvelope.xmlns]
    }

    override func getPrimaryNamespace() -> String {
        return XEPTrustEnvelope.xmlns
    }

    @discardableResult
    func didReceivedVerificationMessage(message: XMPPMessage) -> Bool {
        guard let innerMessage = XEPTrustForwardedExtractor.trustMessage(from: message),
              let received = XEPTrustEnvelope.parse(from: innerMessage),
              let from = innerMessage.from,
              let envelope = admittedEnvelope(received, from: from) else {
            return false
        }

        if let myFullJid = AccountManager.shared.find(for: owner)?.xmppStream.myJID?.full,
           innerMessage.from?.full == myFullJid {
            return true
        }

        let key = "\(innerMessage.elementID ?? "no-id")|\(innerMessage.from?.full ?? "unknown")|\(envelope.sid)|\(envelope.kind.name)"
        if processedStanzas.contains(key) {
            return true
        }
        processedStanzas.insert(key)

        if envelope.isExpired {
            closeExpiredSessionIfNeeded(sid: envelope.sid)
            return true
        }

        switch envelope.kind {
        case let .request(deviceId, targetDeviceId):
            processRequest(envelope, from: from, remoteDeviceId: deviceId, targetDeviceId: targetDeviceId)
        case let .accept(deviceId):
            processAccept(envelope, from: from, remoteDeviceId: deviceId)
        case let .challenge(deviceId, ciphertext, iv):
            processChallenge(envelope, from: from, remoteDeviceId: deviceId, ciphertext: ciphertext, iv: iv)
        case let .response(deviceId, ciphertext, iv, hmac):
            processResponse(envelope, from: from, remoteDeviceId: deviceId, ciphertext: ciphertext, iv: iv, hmac: hmac)
        case let .verify(deviceId, hmac):
            processVerify(envelope, from: from, remoteDeviceId: deviceId, hmac: hmac)
        case let .success(deviceId):
            processSuccess(envelope, from: from, remoteDeviceId: deviceId)
        case let .abort(reason):
            processAbort(envelope, from: from, reason: reason)
        }

        return true
    }

    func sendVerificationRequest(jid: String, deviceId: String? = nil) {
        guard let account = AccountManager.shared.find(for: owner),
              let toJid = XMPPJID(string: jid) else {
            return
        }

        let localDeviceId = account.omemo.localStore.localDeviceId()
        guard let sidBytes = try? generateByteSequence() else { return }
        let sid = Data(sidBytes.prefix(16)).base64EncodedString()
        let ttl = jid == owner ? 300 : 86400
        let now = Int(Date().timeIntervalSince1970.rounded())
        let expires = now + ttl
        let targetDeviceId = deviceId.flatMap { Int($0) }

        do {
            let realm = try WRealm.safe()
            let oldInstances = realm.objects(VerificationSessionStorageItem.self)
                .filter("owner == %@ AND myDeviceId == %@ AND jid == %@ AND NOT (state_ IN %@)",
                        owner,
                        localDeviceId,
                        jid,
                        terminalStateRawValues())
            let instance = VerificationSessionStorageItem()
            fillNewSession(instance, sid: sid, owner: owner, jid: jid, localDeviceId: localDeviceId, remoteDeviceId: targetDeviceId ?? 0, role: .initiator, state: .sentRequest, timestamp: now, expires: expires)
            try realm.write {
                realm.delete(oldInstances)
                realm.add(instance, update: .modified)
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return
        }

        if jid != owner {
            account.omemo.initChat(jid: jid)
            makeSystemMessage(jid: jid, event: .outgoingVerificationRequest)
        }

        let trust = XEPTrustEnvelope.makeTrustElement(sid: sid, expires: expires, timestamp: now, kind: .request(deviceId: localDeviceId, targetDeviceId: targetDeviceId))
        sendTrustElement(trust, to: toJid, ttl: ttl)
    }

    @discardableResult
    func acceptVerificationRequest(jid: String, sid: String) -> String? {
        guard let account = AccountManager.shared.find(for: owner),
              let toJid = bestKnownJid(for: sid, fallback: jid) else {
            return nil
        }

        let localDeviceId = account.omemo.localStore.localDeviceId()
        let code = generateCode()
        let localNonce: [UInt8]
        do {
            localNonce = try generateByteSequence()
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return nil
        }

        var remoteDeviceId = 0
        var expires = Int(Date().timeIntervalSince1970.rounded()) + (jid == owner ? 300 : 86400)

        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid)),
                  !isTerminal(instance.state),
                  instance.state == .receivedRequest, instance.expires > Date().timeIntervalSince1970,
                  bindVerificationKeys(instance) else {
                return nil
            }

            remoteDeviceId = instance.opponentDeviceId
            expires = Int(instance.expires)

            let encrypted = try encrypt(jid: instance.jid, sid: sid, deviceId: remoteDeviceId, code: code, data: localNonce)
            try realm.write {
                instance.code = code
                instance.byteSequence = base64(localNonce)
                instance.localNonce = base64(localNonce)
                instance.opponentByteSequenceEncrypted = base64(encrypted.encrypted)
                instance.encryptedChallengeNonce = base64(encrypted.encrypted)
                instance.opponentByteSequenceIv = base64(encrypted.iv)
                instance.encryptedChallengeIV = base64(encrypted.iv)
                instance.state = .acceptedRequest
                instance.role = .responder
            }

            let trust = XEPTrustEnvelope.makeTrustElement(
                sid: sid,
                expires: expires,
                kind: .challenge(deviceId: localDeviceId, ciphertext: base64(encrypted.encrypted), iv: base64(encrypted.iv))
            )
            sendTrustElement(trust, to: toJid, ttl: max(expires - Int(Date().timeIntervalSince1970.rounded()), 1))
            makeSystemMessage(jid: instance.jid, event: .acceptedVerificationRequest)
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            sendAbort(to: toJid, sid: sid, expires: expires, reason: .fail)
            return nil
        }

        if let ownJid = XMPPJID(string: owner) {
            let accept = XEPTrustEnvelope.makeTrustElement(sid: sid, expires: expires, kind: .accept(deviceId: localDeviceId))
            sendTrustElement(accept, to: ownJid, ttl: 300)
        }

        postOnMain(AuthenticatedKeyExchangeManager.showCodeOutputViewNotification, userInfo: ["owner": owner, "sid": sid])
        return code
    }

    func processSecretCode(code: String, sid: String) {
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid)),
                  !isTerminal(instance.state),
                  instance.state == .receivedRequestAccept,
                  instance.expires > Date().timeIntervalSince1970, bindVerificationKeys(instance) else {
                return
            }

            let encryptedChallenge = instance.opponentByteSequenceEncrypted.isEmpty ? instance.encryptedChallengeNonce : instance.opponentByteSequenceEncrypted
            let encryptedChallengeIV = instance.opponentByteSequenceIv.isEmpty ? instance.encryptedChallengeIV : instance.opponentByteSequenceIv
            let remoteNonce = try decrypt(
                jid: instance.jid,
                sid: sid,
                deviceId: instance.opponentDeviceId,
                code: code,
                ciphertext: encryptedChallenge.base64decoded(),
                iv: encryptedChallengeIV.base64decoded()
            )

            guard remoteNonce.count == 32 else { throw AuthenticatedKeyExchangeManagerError.missingKeyMaterial }
            try realm.write {
                instance.code = code
                instance.opponentByteSequence = base64(remoteNonce)
                instance.remoteNonce = base64(remoteNonce)
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            failSession(sid: sid, reason: .fail, shouldNotifyPeer: true)
            return
        }

        guard let toJid = sessionPeerJid(sid: sid) else {
            return
        }
        sendHashToOpponent(jid: toJid, sid: sid)
    }

    func sendHashToOpponent(jid: XMPPJID, sid: String) {
        do {
            let realm = try WRealm.safe()
            guard let account = AccountManager.shared.find(for: owner),
                  let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid)),
                  !isTerminal(instance.state),
                  let remoteNonce = try? (instance.remoteNonce.isEmpty ? instance.opponentByteSequence : instance.remoteNonce).base64decoded() else {
                return
            }

            let localDeviceId = account.omemo.localStore.localDeviceId()
            let localNonce = try generateByteSequence()
            let encrypted = try encrypt(jid: instance.jid, sid: sid, deviceId: instance.opponentDeviceId, code: instance.code, data: localNonce)
            guard let hmac = makeHMAC(
                label: HMACLabel.a1,
                trustedJid: owner,
                trustedDeviceId: localDeviceId,
                sharedJid: instance.jid,
                sharedDeviceId: instance.opponentDeviceId,
                firstNonce: localNonce,
                secondNonce: remoteNonce,
                code: instance.code,
                sid: sid
            ) else {
                failSession(sid: sid, reason: .fail, shouldNotifyPeer: true)
                return
            }

            try realm.write {
                instance.byteSequence = base64(localNonce)
                instance.localNonce = base64(localNonce)
                instance.state = .responseSent
            }

            let trust = XEPTrustEnvelope.makeTrustElement(
                sid: sid,
                expires: Int(instance.expires),
                kind: .response(deviceId: localDeviceId, ciphertext: base64(encrypted.encrypted), iv: base64(encrypted.iv), hmac: base64(hmac))
            )
            sendTrustElement(trust, to: jid, ttl: max(Int(instance.expires) - Int(Date().timeIntervalSince1970.rounded()), 1))
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            failSession(sid: sid, reason: .fail, shouldNotifyPeer: true)
        }
    }

    func rejectRequestToVerify(jid: String, sid: String) {
        guard let toJid = bestKnownJid(for: sid, fallback: jid) else {
            markSession(sid: sid, state: .cancelled)
            return
        }
        cancelSession(sid: sid, to: toJid)
    }

    func cancelVerificationSession(sid: String) {
        guard let toJid = sessionPeerJid(sid: sid) else {
            markSession(sid: sid, state: .cancelled)
            return
        }
        cancelSession(sid: sid, to: toJid)
    }

    func sendErrorMessage(fullJID: XMPPJID, sid: String, reason: String) {
        let normalizedReason = reason.lowercased()
        let abortReason: XEPTrustEnvelope.AbortReason
        if normalizedReason.contains("timeout") {
            abortReason = .timeout
        } else if normalizedReason.contains("cancel") || normalizedReason.contains("reject") {
            abortReason = .cancel
        } else {
            abortReason = .fail
        }

        failSession(sid: sid, reason: abortReason, shouldNotifyPeer: false)
        let expires = sessionExpires(sid: sid)
        sendAbort(to: fullJID, sid: sid, expires: expires, reason: abortReason)
    }

    @discardableResult
    func writeTrustedDevice(jid: String, deviceId: Int) -> Bool {
        do {
            let realm = try WRealm.safe()
            guard let target = validatedTrustTarget(realm: realm, jid: jid, deviceId: deviceId) else { return false }
            try realm.write { try applyLocalTrust(target) }
            return true
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    func getUsersPublicKey(jid: String, deviceId: Int) -> [UInt8] {
        guard let storedIdentity = getUsersIdentityKey(jid: jid, deviceId: deviceId),
              let curveKey = try? Omemo2IdentityRepresentation.canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: storedIdentity) else {
            return []
        }
        return Array(curveKey)
    }

    /// Returns the stored transport representation. Callers which verify an
    /// identity signature must keep Ed25519 bytes instead of using the ECDH key.
    func getUsersIdentityKey(jid: String, deviceId: Int) -> Data? {
        do {
            let realm = try WRealm.safe()
            guard let storedBundle = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: owner, jid: jid, deviceId: deviceId)),
                  let encodedIdentity = storedBundle.identityKey,
                  let identity = Data(base64Encoded: encodedIdentity) else {
                return nil
            }
            _ = try Omemo2IdentityRepresentation.canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity: identity)
            return identity
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    func encrypt(jid: String, sid: String, deviceId: Int, data: [UInt8]) throws -> (encrypted: [UInt8], iv: [UInt8]) {
        let code = sessionCode(sid: sid)
        return try encrypt(jid: jid, sid: sid, deviceId: deviceId, code: code, data: data)
    }

    func decrypt(jid: String, sid: String, deviceId: Int, ciphertext: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        let code = sessionCode(sid: sid)
        return try decrypt(jid: jid, sid: sid, deviceId: deviceId, code: code, ciphertext: ciphertext, iv: iv)
    }

    func decryptElementFromXML(jid: String, sid: String, deviceId: Int, encryptedXML: DDXMLElement) -> [UInt8]? {
        guard let ciphertextRaw = encryptedXML.element(forName: "ciphertext")?.stringValue,
              let ivRaw = encryptedXML.element(forName: "iv")?.stringValue else {
            return nil
        }
        do {
            return try decrypt(jid: jid, sid: sid, deviceId: deviceId, ciphertext: try ciphertextRaw.base64decoded(), iv: try ivRaw.base64decoded())
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    func getSignalMessagePacket(message: XMPPMessage, to: XMPPJID, ttl: Int) -> DDXMLElement {
        if let notificationManager = AccountManager.shared.find(for: owner)?.notifications {
            return notificationManager.formIQ(to: to, child: message)
        }
        return message
    }

    func makeSystemMessage(jid: String, event: AuthenticatedKeyExchangeSystemEvent) {
        do {
            let realm = try WRealm.safe()

            let item = MessageStorageItem()
            item.messageId = UUID().uuidString
            item.owner = owner
            item.body = ""
            item.opponent = jid
            item.outgoing = true
            item.isRead = true
            item.displayAs = .system
            item.conversationType = .omemo
            item.markAuthenticatedKeyExchangeSystemEvent(event)
            item.updatePrimary(system: true, auth: false)

            try realm.write {
                _ = item.save(commitTransaction: false)
            }

            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: item.opponent, owner: item.owner, conversationType: item.conversationType)
            ) {
                try realm.write {
                    instance.lastMessage = item
                    instance.messageDate = Date()
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }

    func showNotification(
        title: String,
        owner: String,
        body: String,
        senderJid: String,
        sid: String,
        timestamp: TimeInterval
    ) {
        DispatchQueue.main.async {
            NotifyManager.shared.update(
                withVerificationMessage: body,
                owner: owner,
                displayName: title,
                senderJid: senderJid,
                sid: sid,
                timestamp: timestamp
            )
        }
    }

    private func processRequest(_ envelope: XEPTrustEnvelope, from: XMPPJID, remoteDeviceId: Int, targetDeviceId: Int?) {
        guard let account = AccountManager.shared.find(for: owner) else {
            return
        }

        let localDeviceId = account.omemo.localStore.localDeviceId()
        if let targetDeviceId, targetDeviceId != localDeviceId {
            return
        }

        let peerBare = from.bare
        let now = Int(Date().timeIntervalSince1970.rounded())

        do {
            let realm = try WRealm.safe()
            if let existing = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: envelope.sid)),
               isTerminal(existing.state) || Int(existing.expires) <= now {
                return
            }

            let newerSessions = realm.objects(VerificationSessionStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND NOT (state_ IN %@)", owner, peerBare, terminalStateRawValues())
                .filter { (item) -> Bool in
                    (Int(item.timestamp) ?? 0) > envelope.timestamp && item.sid != envelope.sid
                }
            if !newerSessions.isEmpty {
                return
            }

            let existing = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: envelope.sid))
            let instance = existing ?? VerificationSessionStorageItem()

            try realm.write {
                fillNewSession(instance, sid: envelope.sid, owner: owner, jid: peerBare, localDeviceId: localDeviceId, remoteDeviceId: remoteDeviceId, role: .responder, state: .receivedRequest, timestamp: envelope.timestamp, expires: envelope.expires)
                instance.fullJID = from.full
                instance.peerFullJid = from.full
                if existing == nil {
                    realm.add(instance, update: .modified)
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return
        }

        if peerBare == owner {
            postOnMain(AuthenticatedKeyExchangeManager.showConfirmationViewNotification, userInfo: ["owner": owner, "sid": envelope.sid])
        } else {
            let event = AuthenticatedKeyExchangeSystemEvent.incomingVerificationRequest
            makeSystemMessage(jid: peerBare, event: event)
            showNotification(
                title: peerBare,
                owner: owner,
                body: event.localizedText,
                senderJid: peerBare,
                sid: envelope.sid,
                timestamp: TimeInterval(envelope.timestamp)
            )
        }
    }

    private func processAccept(_ envelope: XEPTrustEnvelope, from: XMPPJID, remoteDeviceId: Int) {
        guard from.bare == owner else {
            return
        }

        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: envelope.sid)),
                  instance.state == .receivedRequest else {
                return
            }

            try realm.write {
                instance.remoteDeviceId = remoteDeviceId
                instance.state = .cancelled
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }

        postOnMain(AuthenticatedKeyExchangeManager.closeViewNotification, userInfo: ["owner": owner, "sid": envelope.sid])
    }

    private func processChallenge(_ envelope: XEPTrustEnvelope, from: XMPPJID, remoteDeviceId: Int, ciphertext: String, iv: String) {
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: envelope.sid)),
                  !isTerminal(instance.state),
                  instance.role == .initiator,
                  instance.state == .sentRequest else {
                return
            }

            try realm.write {
                instance.jid = from.bare
                instance.peerBareJid = from.bare
                instance.fullJID = from.full
                instance.peerFullJid = from.full
                instance.opponentDeviceId = remoteDeviceId
                instance.remoteDeviceId = remoteDeviceId
                instance.opponentByteSequenceEncrypted = ciphertext
                instance.encryptedChallengeNonce = ciphertext
                instance.opponentByteSequenceIv = iv
                instance.encryptedChallengeIV = iv
                instance.state = .receivedRequestAccept
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return
        }

        postOnMain(AuthenticatedKeyExchangeManager.showCodeInputViewNotification, userInfo: ["owner": owner, "sid": envelope.sid])
    }

    private func processResponse(_ envelope: XEPTrustEnvelope, from: XMPPJID, remoteDeviceId: Int, ciphertext: String, iv: String, hmac: String) {
        do {
            let realm = try WRealm.safe()
            guard let account = AccountManager.shared.find(for: owner),
                  let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: envelope.sid)),
                  !isTerminal(instance.state),
                  instance.role == .responder,
                  instance.state == .acceptedRequest,
                  let localNonce = try? (instance.localNonce.isEmpty ? instance.byteSequence : instance.localNonce).base64decoded() else {
                return
            }

            let remoteNonce = try decrypt(jid: instance.jid, sid: envelope.sid, deviceId: remoteDeviceId, code: instance.code, ciphertext: try ciphertext.base64decoded(), iv: try iv.base64decoded())
            guard remoteNonce.count == 32 else { throw AuthenticatedKeyExchangeManagerError.missingKeyMaterial }
            guard let expected = makeHMAC(
                label: HMACLabel.a1,
                trustedJid: instance.jid,
                trustedDeviceId: remoteDeviceId,
                sharedJid: instance.jid,
                sharedDeviceId: remoteDeviceId,
                firstNonce: remoteNonce,
                secondNonce: localNonce,
                code: instance.code,
                sid: envelope.sid
            ),
                  let received = try? hmac.base64decoded(),
                  constantTimeEquals(expected, received) else {
                try realm.write {
                    instance.state = .failed
                }
                sendAbort(to: from, sid: envelope.sid, expires: Int(instance.expires), reason: .fail)
                postOnMain(AuthenticatedKeyExchangeManager.closeViewNotification, userInfo: ["owner": owner, "sid": envelope.sid])
                return
            }

            let localDeviceId = account.omemo.localStore.localDeviceId()
            guard let verifyHMAC = makeHMAC(
                label: HMACLabel.b1,
                trustedJid: owner,
                trustedDeviceId: localDeviceId,
                sharedJid: instance.jid,
                sharedDeviceId: remoteDeviceId,
                firstNonce: localNonce,
                secondNonce: remoteNonce,
                code: instance.code,
                sid: envelope.sid
            ) else {
                return
            }

            try realm.write {
                instance.fullJID = from.full
                instance.peerFullJid = from.full
                instance.opponentDeviceId = remoteDeviceId
                instance.remoteDeviceId = remoteDeviceId
                instance.opponentByteSequence = base64(remoteNonce)
                instance.remoteNonce = base64(remoteNonce)
                instance.state = .responseReceived
            }

            let trust = XEPTrustEnvelope.makeTrustElement(
                sid: envelope.sid,
                expires: Int(instance.expires),
                kind: .verify(deviceId: localDeviceId, hmac: base64(verifyHMAC))
            )
            sendTrustElement(trust, to: from, ttl: max(Int(instance.expires) - Int(Date().timeIntervalSince1970.rounded()), 1))
            try realm.write {
                instance.state = .verifySent
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            sendAbort(to: from, sid: envelope.sid, expires: envelope.expires, reason: .fail)
        }
    }

    private func processVerify(_ envelope: XEPTrustEnvelope, from: XMPPJID, remoteDeviceId: Int, hmac: String) {
        do {
            let realm = try WRealm.safe()
            guard let account = AccountManager.shared.find(for: owner),
                  let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: envelope.sid)),
                  !isTerminal(instance.state),
                  instance.role == .initiator,
                  let localNonce = try? (instance.localNonce.isEmpty ? instance.byteSequence : instance.localNonce).base64decoded(),
                  let remoteNonce = try? (instance.remoteNonce.isEmpty ? instance.opponentByteSequence : instance.remoteNonce).base64decoded() else {
                return
            }

            guard let expected = makeHMAC(
                label: HMACLabel.b1,
                trustedJid: from.bare,
                trustedDeviceId: remoteDeviceId,
                sharedJid: from.bare,
                sharedDeviceId: remoteDeviceId,
                firstNonce: remoteNonce,
                secondNonce: localNonce,
                code: instance.code,
                sid: envelope.sid
            ),
                  let received = try? hmac.base64decoded(),
                  constantTimeEquals(expected, received) else {
                try realm.write {
                    instance.state = .failed
                }
                sendAbort(to: from, sid: envelope.sid, expires: Int(instance.expires), reason: .fail)
                postOnMain(AuthenticatedKeyExchangeManager.closeViewNotification, userInfo: ["owner": owner, "sid": envelope.sid])
                return
            }

            let localDeviceId = account.omemo.localStore.localDeviceId()
            guard let binding = keyBinding(for: instance.sid),
                  let target = validatedTrustTarget(realm: realm, jid: instance.jid, deviceId: remoteDeviceId,
                      expectedIdentity: binding.peerIdentity) else { return }
            try realm.write {
                try applyLocalTrust(target)
                instance.opponentDeviceId = remoteDeviceId
                instance.remoteDeviceId = remoteDeviceId
                instance.state = .trusted
            }

            let trust = XEPTrustEnvelope.makeTrustElement(sid: envelope.sid, expires: Int(instance.expires), kind: .success(deviceId: localDeviceId))
            sendTrustElement(trust, to: from, ttl: max(Int(instance.expires) - Int(Date().timeIntervalSince1970.rounded()), 1))
            onVerificationTrusted(jid: instance.jid, deviceId: remoteDeviceId, sid: envelope.sid)
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            sendAbort(to: from, sid: envelope.sid, expires: envelope.expires, reason: .fail)
        }
    }

    private func processSuccess(_ envelope: XEPTrustEnvelope, from: XMPPJID, remoteDeviceId: Int) {
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: envelope.sid)),
                  !isTerminal(instance.state),
                  instance.role == .responder else {
                return
            }

            guard let binding = keyBinding(for: instance.sid),
                  let target = validatedTrustTarget(realm: realm, jid: instance.jid, deviceId: remoteDeviceId,
                      expectedIdentity: binding.peerIdentity) else { return }
            try realm.write {
                try applyLocalTrust(target)
                instance.fullJID = from.full
                instance.peerFullJid = from.full
                instance.opponentDeviceId = remoteDeviceId
                instance.remoteDeviceId = remoteDeviceId
                instance.state = .trusted
            }
            onVerificationTrusted(jid: instance.jid, deviceId: remoteDeviceId, sid: envelope.sid)
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }

    private func processAbort(_ envelope: XEPTrustEnvelope, from: XMPPJID, reason: XEPTrustEnvelope.AbortReason) {
        let state: VerificationSessionStorageItem.VerififcationState
        switch reason {
        case .cancel:
            state = .rejected
        case .timeout:
            state = .timeout
        case .fail:
            state = .failed
        }

        markSession(sid: envelope.sid, state: state)
        if from.bare != owner {
            switch reason {
            case .cancel:
                makeSystemMessage(jid: from.bare, event: .verificationRejected)
            case .timeout:
                makeSystemMessage(jid: from.bare, event: .verificationTimedOut)
            case .fail:
                makeSystemMessage(jid: from.bare, event: .verificationFailed)
            }
        }

        postOnMain(AuthenticatedKeyExchangeManager.closeViewNotification, userInfo: ["owner": owner, "sid": envelope.sid])
        postOnMain(AuthenticatedKeyExchangeManager.verificationConfirmationVCRejected, userInfo: ["owner": owner, "sid": envelope.sid])
        postOnMain(AuthenticatedKeyExchangeManager.authenticationCodeInputVCShow, userInfo: ["owner": owner, "sid": envelope.sid])
    }

    private func onVerificationTrusted(jid: String, deviceId: Int, sid: String) {
        if jid != owner {
            makeSystemMessage(jid: jid, event: .verificationSucceeded)
        }

        verificationKeyBindingsLock.lock()
        verificationKeyBindings.removeValue(forKey: sid)
        verificationKeyBindingsLock.unlock()
        AccountManager.shared.find(for: owner)?.trustSharingManager.sendListOfContactsDevices()
        AccountManager.shared.find(for: owner)?.trustSharingManager.publishOwnTrustedDevices(publisherDeviceId: String(AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() ?? 0))
        AccountManager.shared.find(for: owner)?.trustSharingManager.getUserTrustedDevices(jid: jid)

        postOnMain(AuthenticatedKeyExchangeManager.showSuccessViewNotification, userInfo: ["owner": owner, "jid": jid, "deviceId": String(deviceId), "sid": sid])
    }

    private func cancelSession(sid: String, to: XMPPJID) {
        let expires = sessionExpires(sid: sid)
        sendAbort(to: to, sid: sid, expires: expires, reason: .cancel)
        markSession(sid: sid, state: .cancelled)
        postOnMain(AuthenticatedKeyExchangeManager.closeViewNotification, userInfo: ["owner": owner, "sid": sid])
    }

    private func failSession(sid: String, reason: XEPTrustEnvelope.AbortReason, shouldNotifyPeer: Bool) {
        let state: VerificationSessionStorageItem.VerififcationState
        switch reason {
        case .cancel:
            state = .cancelled
        case .timeout:
            state = .timeout
        case .fail:
            state = .failed
        }

        let peer = sessionPeerJid(sid: sid)
        let expires = sessionExpires(sid: sid)
        markSession(sid: sid, state: state)
        if shouldNotifyPeer, let peer {
            sendAbort(to: peer, sid: sid, expires: expires, reason: reason)
        }
        postOnMain(AuthenticatedKeyExchangeManager.closeViewNotification, userInfo: ["owner": owner, "sid": sid])
    }

    private func closeExpiredSessionIfNeeded(sid: String) {
        do {
            let realm = try WRealm.safe()
            let primary = VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid)
            guard let existing = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: primary),
                  !existing.isInvalidated else {
                return
            }

            let now = Date().timeIntervalSince1970
            guard let markedTimeout = try markExpiredSessionTimeout(VerificationSessionTimeoutSnapshot(existing), realm: realm, now: now),
                  markedTimeout.shouldNotifyPeer,
                  let peer = markedTimeout.peer else {
                return
            }
            sendAbort(to: peer, sid: markedTimeout.sid, expires: markedTimeout.expires, reason: .timeout)
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }

    private func markSession(sid: String, state: VerificationSessionStorageItem.VerififcationState) {
        do {
            let realm = try WRealm.safe()
            let primary = VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid)
            try realm.write {
                guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: primary),
                      !instance.isInvalidated,
                      !isTerminal(instance.state) else {
                    return
                }
                instance.state = state
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }

    private func markExpiredSessionTimeout(_ snapshot: VerificationSessionTimeoutSnapshot, realm: Realm, now: TimeInterval) throws -> VerificationSessionTimeoutSnapshot? {
        var markedTimeout: VerificationSessionTimeoutSnapshot?
        try realm.write {
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: snapshot.primary),
                  !instance.isInvalidated,
                  !isTerminal(instance.state) else {
                return
            }
            guard instance.expires > 0,
                  instance.expires <= now else {
                return
            }
            markedTimeout = VerificationSessionTimeoutSnapshot(instance)
            instance.state = .timeout
        }
        return markedTimeout
    }

    private func sendAbort(to jid: XMPPJID, sid: String, expires: Int, reason: XEPTrustEnvelope.AbortReason) {
        let trust = XEPTrustEnvelope.makeTrustElement(sid: sid, expires: max(expires, Int(Date().timeIntervalSince1970.rounded())), kind: .abort(reason: reason))
        sendTrustElement(trust, to: jid, ttl: 300)
    }

    private func sendTrustElement(_ trust: DDXMLElement, to jid: XMPPJID, ttl: Int) {
        let message = XMPPMessage(messageType: .chat, to: jid, elementID: UUID().uuidString, child: trust)
        if let myFullJid = AccountManager.shared.find(for: owner)?.xmppStream.myJID?.full {
            message.addAttribute(withName: "from", stringValue: myFullJid)
        }
        let packet = getSignalMessagePacket(message: message, to: jid, ttl: ttl)
        AccountManager.shared.find(for: owner)?.action { _, stream in
            stream.send(packet)
        }
    }

    private func fillNewSession(
        _ instance: VerificationSessionStorageItem,
        sid: String,
        owner: String,
        jid: String,
        localDeviceId: Int,
        remoteDeviceId: Int,
        role: VerificationSessionStorageItem.VerificationRole,
        state: VerificationSessionStorageItem.VerififcationState,
        timestamp: Int,
        expires: Int
    ) {
        instance.owner = owner
        instance.ownerJid = owner
        instance.myDeviceId = localDeviceId
        instance.localDeviceId = localDeviceId
        instance.jid = jid
        instance.peerBareJid = jid
        instance.opponentDeviceId = remoteDeviceId
        instance.remoteDeviceId = remoteDeviceId
        instance.sid = sid
        instance.primary = VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid)
        instance.timestamp = String(timestamp)
        instance.updatedTimestamp = String(timestamp)
        instance.ttl = String(max(expires - timestamp, 0))
        instance.expires = Double(expires)
        instance.createdAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        instance.updatedAt = Date()
        instance.role = role
        instance.state = state
    }

    private func sessionPeerJid(sid: String) -> XMPPJID? {
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid)) else {
                return nil
            }
            if !instance.peerFullJid.isEmpty, let jid = XMPPJID(string: instance.peerFullJid) {
                return jid
            }
            if !instance.fullJID.isEmpty, let jid = XMPPJID(string: instance.fullJID) {
                return jid
            }
            return XMPPJID(string: instance.jid)
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    private func bestKnownJid(for sid: String, fallback: String) -> XMPPJID? {
        return sessionPeerJid(sid: sid) ?? XMPPJID(string: fallback)
    }

    private func sessionCode(sid: String) -> String {
        do {
            let realm = try WRealm.safe()
            return realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid))?.code ?? ""
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return ""
        }
    }

    private func sessionExpires(sid: String) -> Int {
        do {
            let realm = try WRealm.safe()
            if let expires = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid))?.expires,
               expires > 0 {
                return Int(expires)
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
        return Int(Date().timeIntervalSince1970.rounded()) + 300
    }

    private func encrypt(jid: String, sid: String, deviceId: Int, code: String, data: [UInt8]) throws -> (encrypted: [UInt8], iv: [UInt8]) {
        guard let sharedKey = calculateSharedKey(jid: jid, deviceId: deviceId) else {
            throw AuthenticatedKeyExchangeManagerError.missingKeyMaterial
        }
        let encryptionKey = calculateEncryptionKey(sharedKey: sharedKey, code: code, sid: sid)
        var iv = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv)
        guard status == errSecSuccess else {
            throw AuthenticatedKeyExchangeManagerError.secRandomCopyBytesFailed
        }
        let aes = try AES(key: encryptionKey, blockMode: CBC(iv: iv))
        return (try aes.encrypt(data), iv)
    }

    private func decrypt(jid: String, sid: String, deviceId: Int, code: String, ciphertext: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        guard let sharedKey = calculateSharedKey(jid: jid, deviceId: deviceId) else {
            throw AuthenticatedKeyExchangeManagerError.missingKeyMaterial
        }
        let encryptionKey = calculateEncryptionKey(sharedKey: sharedKey, code: code, sid: sid)
        let aes = try AES(key: encryptionKey, blockMode: CBC(iv: iv))
        return try aes.decrypt(ciphertext)
    }

    private func calculateSharedKey(jid: String, deviceId: Int) -> [UInt8]? {
        guard let privateKey = try? Omemo2IdentityRepresentation.localIdentityPrivateKey(owner: owner),
              let peerIdentity = getUsersIdentityKey(jid: jid, deviceId: deviceId),
              let shared = try? Omemo2IdentityRepresentation.sharedSecret(privateKey: privateKey, peerIdentity: peerIdentity) else {
            return nil
        }
        return Array(shared)
    }

    private func calculateEncryptionKey(sharedKey: [UInt8], code: String, sid: String) -> [UInt8] {
        let material = Data(sharedKey + Array(code.utf8) + Array(sid.utf8))
        return Array(SHA256.hash(data: material))
    }

    func makeHMAC(
        label _: String,
        trustedJid: String,
        trustedDeviceId: Int,
        sharedJid: String,
        sharedDeviceId: Int,
        firstNonce: [UInt8],
        secondNonce: [UInt8],
        code: String,
        sid: String
    ) -> [UInt8]? {
        guard let trustedKey = trustedKey(jid: trustedJid, deviceId: trustedDeviceId),
              let sharedKey = calculateSharedKey(jid: sharedJid, deviceId: sharedDeviceId) else {
            return nil
        }
        let key = calculateEncryptionKey(sharedKey: sharedKey, code: code, sid: sid)
        let payload = Data(trustedKey + firstNonce + secondNonce)
        let mac = CryptoKit.HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: Data(key)))
        return Array(Data(mac))
    }

    private func trustedKey(jid: String, deviceId: Int) -> [UInt8]? {
        do {
            let realm = try WRealm.safe()
            guard let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceId)) else {
                return nil
            }
            let fingerprint = device.fingerprint.replacingOccurrences(of: " ", with: "").lowercased()
            return Array("\(deviceId)::\(fingerprint)".utf8)
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    private func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        var diff: UInt8 = 0
        for index in lhs.indices {
            diff |= lhs[index] ^ rhs[index]
        }
        return diff == 0
    }

    private func generateByteSequence() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AuthenticatedKeyExchangeManagerError.secRandomCopyBytesFailed
        }
        return bytes
    }

    private func generateCode() -> String {
        return String(Int.random(in: 100000...999999))
    }

    private func base64(_ bytes: [UInt8]) -> String {
        return Data(bytes).base64EncodedString()
    }

    private func postOnMain(_ name: NSNotification.Name, userInfo: [AnyHashable: Any]) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: self, userInfo: userInfo)
        }
    }

    private func terminalStateRawValues() -> [String] {
        return [
            VerificationSessionStorageItem.VerififcationState.trusted.rawValue,
            VerificationSessionStorageItem.VerififcationState.rejected.rawValue,
            VerificationSessionStorageItem.VerififcationState.failed.rawValue,
            VerificationSessionStorageItem.VerififcationState.cancelled.rawValue,
            VerificationSessionStorageItem.VerififcationState.timeout.rawValue
        ]
    }

    private func isTerminal(_ state: VerificationSessionStorageItem.VerififcationState) -> Bool {
        switch state {
        case .trusted, .rejected, .failed, .cancelled, .timeout:
            return true
        default:
            return false
        }
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
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }

    static func prepare() {
        let timer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(checkVerificationSessionsTTL),
            userInfo: nil,
            repeats: true
        )
        RunLoop.current.add(timer, forMode: .default)

        do {
            let realm = try WRealm.safe()
            let jids = AccountManager.shared.users.compactMap { $0.jid }
            for owner in jids {
                if let ownVerification = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@ AND state_ == %@", owner, owner, VerificationSessionStorageItem.VerififcationState.receivedRequest.rawValue).first {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: AuthenticatedKeyExchangeManager.showConfirmationViewNotification, object: self, userInfo: ["owner": owner, "sid": ownVerification.sid])
                    }
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }

    @objc
    static func checkVerificationSessionsTTL() {
        do {
            let realm = try WRealm.safe()
            let now = Date().timeIntervalSince1970
            let terminal = [
                VerificationSessionStorageItem.VerififcationState.trusted.rawValue,
                VerificationSessionStorageItem.VerififcationState.rejected.rawValue,
                VerificationSessionStorageItem.VerififcationState.failed.rawValue,
                VerificationSessionStorageItem.VerififcationState.cancelled.rawValue,
                VerificationSessionStorageItem.VerififcationState.timeout.rawValue
            ]
            let expired = realm.objects(VerificationSessionStorageItem.self)
                .filter("expires > 0 AND expires <= %@ AND NOT (state_ IN %@)", NSNumber(value: now), terminal)
            let snapshots = expired.compactMap { session -> VerificationSessionTimeoutSnapshot? in
                guard !session.isInvalidated else {
                    return nil
                }
                return VerificationSessionTimeoutSnapshot(session)
            }

            for snapshot in snapshots {
                var markedTimeout: VerificationSessionTimeoutSnapshot?
                try realm.write {
                    guard let session = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: snapshot.primary),
                          !session.isInvalidated,
                          session.expires > 0,
                          session.expires <= now,
                          !terminal.contains(session.state_) else {
                        return
                    }
                    markedTimeout = VerificationSessionTimeoutSnapshot(session)
                    session.state = .timeout
                }
                if let markedTimeout,
                   markedTimeout.shouldNotifyPeer,
                   let peer = markedTimeout.peer,
                   let manager = AccountManager.shared.find(for: markedTimeout.owner)?.akeManager {
                    manager.sendAbort(to: peer, sid: markedTimeout.sid, expires: Int(now), reason: .timeout)
                    manager.postOnMain(AuthenticatedKeyExchangeManager.closeViewNotification, userInfo: ["owner": markedTimeout.owner, "sid": markedTimeout.sid])
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }
}

enum AuthenticatedKeyExchangeManagerError: Error {
    case secRandomCopyBytesFailed
    case missingKeyMaterial
    case invalidDecisionTimestamp
}
