//
//  AuthenticatedKeyExchangeManager.swift
//  xabber
//
//  Created by MacIntel on 08.02.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import SignalProtocolObjC
import XMPPFramework
import Curve25519Kit
import CryptoKit
import CryptoSwift
import RealmSwift

struct XEPTrustEnvelope {
    enum AbortReason: String {
        case cancel
        case timeout
        case fail
    }

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

    static let xmlns = "urn:xmpp:trust:0"

    let sid: String
    let timestamp: Int
    let expires: Int
    let kind: Kind

    var isExpired: Bool {
        return expires > 0 && expires <= Int(Date().timeIntervalSince1970.rounded())
    }

    static func makeTrustElement(sid: String, expires: Int, timestamp: Int = Int(Date().timeIntervalSince1970.rounded()), kind: Kind) -> DDXMLElement {
        let trust = DDXMLElement(name: "trust", xmlns: xmlns)
        trust.addAttribute(withName: "sid", stringValue: sid)
        trust.addAttribute(withName: "timestamp", stringValue: String(timestamp))
        trust.addAttribute(withName: "expires", stringValue: String(expires))

        let child = DDXMLElement(name: kind.name)
        switch kind {
        case let .request(deviceId, targetDeviceId):
            child.addAttribute(withName: "device-id", stringValue: String(deviceId))
            if let targetDeviceId {
                child.addAttribute(withName: "target-device-id", stringValue: String(targetDeviceId))
            }
        case let .accept(deviceId), let .success(deviceId):
            child.addAttribute(withName: "device-id", stringValue: String(deviceId))
        case let .challenge(deviceId, ciphertext, iv):
            child.addAttribute(withName: "device-id", stringValue: String(deviceId))
            child.addChild(DDXMLElement(name: "ciphertext", stringValue: ciphertext))
            child.addChild(DDXMLElement(name: "iv", stringValue: iv))
        case let .response(deviceId, ciphertext, iv, hmac):
            child.addAttribute(withName: "device-id", stringValue: String(deviceId))
            child.addChild(DDXMLElement(name: "ciphertext", stringValue: ciphertext))
            child.addChild(DDXMLElement(name: "iv", stringValue: iv))
            child.addChild(DDXMLElement(name: "hmac", stringValue: hmac))
        case let .verify(deviceId, hmac):
            child.addAttribute(withName: "device-id", stringValue: String(deviceId))
            child.addChild(DDXMLElement(name: "hmac", stringValue: hmac))
        case let .abort(reason):
            child.addAttribute(withName: "reason", stringValue: reason.rawValue)
        }

        trust.addChild(child)
        return trust
    }

    static func parse(from message: XMPPMessage) -> XEPTrustEnvelope? {
        guard let trust = message.element(forName: "trust", xmlns: xmlns) ?? message.element(forName: "trust"),
              trust.xmlns() == xmlns,
              let sid = trust.attributeStringValue(forName: "sid"),
              let timestampRaw = trust.attributeStringValue(forName: "timestamp"),
              let expiresRaw = trust.attributeStringValue(forName: "expires"),
              let timestamp = Int(timestampRaw),
              let expires = Int(expiresRaw) else {
            return nil
        }

        let childNames = ["request", "accept", "challenge", "response", "verify", "success", "abort"]
        guard let child = childNames.compactMap({ trust.element(forName: $0) }).first,
              let childName = child.name else {
            return nil
        }

        switch childName {
        case "request":
            guard let deviceId = Self.deviceId(from: child) else { return nil }
            return XEPTrustEnvelope(
                sid: sid,
                timestamp: timestamp,
                expires: expires,
                kind: .request(deviceId: deviceId, targetDeviceId: Self.targetDeviceId(from: child))
            )
        case "accept":
            guard let deviceId = Self.deviceId(from: child) else { return nil }
            return XEPTrustEnvelope(sid: sid, timestamp: timestamp, expires: expires, kind: .accept(deviceId: deviceId))
        case "challenge":
            guard let deviceId = Self.deviceId(from: child),
                  let ciphertext = child.element(forName: "ciphertext")?.stringValue,
                  let iv = child.element(forName: "iv")?.stringValue else {
                return nil
            }
            return XEPTrustEnvelope(sid: sid, timestamp: timestamp, expires: expires, kind: .challenge(deviceId: deviceId, ciphertext: ciphertext, iv: iv))
        case "response":
            guard let deviceId = Self.deviceId(from: child),
                  let ciphertext = child.element(forName: "ciphertext")?.stringValue,
                  let iv = child.element(forName: "iv")?.stringValue,
                  let hmac = child.element(forName: "hmac")?.stringValue else {
                return nil
            }
            return XEPTrustEnvelope(sid: sid, timestamp: timestamp, expires: expires, kind: .response(deviceId: deviceId, ciphertext: ciphertext, iv: iv, hmac: hmac))
        case "verify":
            guard let deviceId = Self.deviceId(from: child),
                  let hmac = child.element(forName: "hmac")?.stringValue else {
                return nil
            }
            return XEPTrustEnvelope(sid: sid, timestamp: timestamp, expires: expires, kind: .verify(deviceId: deviceId, hmac: hmac))
        case "success":
            guard let deviceId = Self.deviceId(from: child) else { return nil }
            return XEPTrustEnvelope(sid: sid, timestamp: timestamp, expires: expires, kind: .success(deviceId: deviceId))
        case "abort":
            let rawReason = child.attributeStringValue(forName: "reason") ?? AbortReason.fail.rawValue
            let reason = AbortReason(rawValue: rawReason) ?? .fail
            return XEPTrustEnvelope(sid: sid, timestamp: timestamp, expires: expires, kind: .abort(reason: reason))
        default:
            return nil
        }
    }

    private static func deviceId(from element: DDXMLElement) -> Int? {
        let raw = element.attributeStringValue(forName: "device-id")
            ?? element.attributeStringValue(forName: "device_id")
            ?? element.attributeStringValue(forName: "id")
        guard let raw else { return nil }
        return Int(raw)
    }

    private static func targetDeviceId(from element: DDXMLElement) -> Int? {
        let raw = element.attributeStringValue(forName: "target-device-id")
            ?? element.attributeStringValue(forName: "target_device_id")
            ?? element.attributeStringValue(forName: "to-device-id")
        guard let raw else { return nil }
        return Int(raw)
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
        if let originalFrom = addresses?["ofrom"],
           let forwardedFrom = innerMessage.attributeStringValue(forName: "from"),
           !jidMatches(originalFrom, forwardedFrom) {
            return nil
        }

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
                next = getForwardedMessage(current)
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
        guard let trust = message.element(forName: "trust", xmlns: XEPTrustEnvelope.xmlns) ?? message.element(forName: "trust") else {
            return false
        }
        return trust.xmlns() == XEPTrustEnvelope.xmlns
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
            map[type] = jid
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
              let envelope = XEPTrustEnvelope.parse(from: innerMessage) else {
            return false
        }

        if let myFullJid = AccountManager.shared.find(for: owner)?.xmppStream.myJID?.full,
           innerMessage.from?.full == myFullJid {
            return true
        }

        let key = "\(innerMessage.elementID ?? "no-id")|\(innerMessage.from?.full ?? "unknown")|\(envelope.sid)|\(envelope.kind.name)|\(envelope.timestamp)"
        if processedStanzas.contains(key) {
            return true
        }
        processedStanzas.insert(key)

        if envelope.isExpired {
            closeExpiredSessionIfNeeded(sid: envelope.sid)
            return true
        }

        guard let from = innerMessage.from else {
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
        let sid = UUID().uuidString
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
            makeSystemMessage(jid: jid, body: "Outgoing verification request")
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
                  instance.state == .receivedRequest else {
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
            makeSystemMessage(jid: instance.jid, body: "You accepted the verification request")
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            sendAbort(to: toJid, sid: sid, expires: expires, reason: .fail)
            return nil
        }

        if jid != owner, let ownJid = XMPPJID(string: owner) {
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
                  instance.state == .receivedRequestAccept else {
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

    func writeTrustedDevice(jid: String, deviceId: Int) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceId)) {
                try realm.write {
                    instance.trustDate = Date()
                    instance.state = .trusted
                    instance.trustedByDeviceId = String(AccountManager.shared.find(for: owner)?.omemo.localStore.localDeviceId() ?? 0)
                }
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
    }

    func getUsersPublicKey(jid: String, deviceId: Int) -> [UInt8] {
        do {
            let realm = try WRealm.safe()
            guard let storedBundle = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: owner, jid: jid, deviceId: deviceId)),
                  var publicKey = try storedBundle.identityKey?.base64decoded() else {
                return []
            }
            if publicKey.count == 33 {
                publicKey = Array(publicKey.dropFirst())
            }
            return publicKey
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
            return []
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

    func makeSystemMessage(jid: String, body: String) {
        do {
            let realm = try WRealm.safe()

            let item = MessageStorageItem()
            item.messageId = UUID().uuidString
            item.owner = owner
            item.body = body
            item.opponent = jid
            item.outgoing = true
            item.isRead = true
            item.displayAs = .system
            item.conversationType = .omemo
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

    func showNotification(title: String, owner: String, body: String, sid: String, timestamp: TimeInterval) {
        DispatchQueue.main.async {
            NotifyManager.shared.update(withVerificationMessage: body, owner: owner, displayName: title, sid: sid, timestamp: timestamp)
            NotifyManager.shared.showNotify(forType: .verification)
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

            if let remoteDevice = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: peerBare, deviceId: remoteDeviceId)),
               remoteDevice.state == .trusted {
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
            makeSystemMessage(jid: peerBare, body: "Incoming verification request")
            showNotification(title: peerBare, owner: owner, body: "Incoming verification request", sid: envelope.sid, timestamp: TimeInterval(envelope.timestamp))
        }
    }

    private func processAccept(_ envelope: XEPTrustEnvelope, from: XMPPJID, remoteDeviceId: Int) {
        guard from.bare == owner else {
            return
        }

        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: envelope.sid)),
                  instance.jid != owner,
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
            writeTrustedDevice(jid: instance.jid, deviceId: remoteDeviceId)
            try realm.write {
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

            writeTrustedDevice(jid: instance.jid, deviceId: remoteDeviceId)
            try realm.write {
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
                makeSystemMessage(jid: from.bare, body: "Verification rejected")
            case .timeout:
                makeSystemMessage(jid: from.bare, body: "Verification timed out")
            case .fail:
                makeSystemMessage(jid: from.bare, body: "Verification failed")
            }
        }

        postOnMain(AuthenticatedKeyExchangeManager.closeViewNotification, userInfo: ["owner": owner, "sid": envelope.sid])
        postOnMain(AuthenticatedKeyExchangeManager.verificationConfirmationVCRejected, userInfo: ["owner": owner, "sid": envelope.sid])
        postOnMain(AuthenticatedKeyExchangeManager.authenticationCodeInputVCShow, userInfo: ["owner": owner, "sid": envelope.sid])
    }

    private func onVerificationTrusted(jid: String, deviceId: Int, sid: String) {
        if jid != owner {
            makeSystemMessage(jid: jid, body: "Verification succeeded")
        }

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
        guard let keyPair = AccountManager.shared.find(for: owner)?.omemo.localStore.getIdentityKeyPair() else {
            return nil
        }
        let keyPairCurve25519 = Curve25519.load(fromPublicKey: keyPair.publicKey, andPrivateKey: keyPair.privateKey)
        let opponentPublicKey = getUsersPublicKey(jid: jid, deviceId: deviceId)
        guard !opponentPublicKey.isEmpty else {
            return nil
        }
        return Array(Curve25519.generateSharedSecret(fromPublicKey: Data(opponentPublicKey), andKeyPair: keyPairCurve25519))
    }

    private func calculateEncryptionKey(sharedKey: [UInt8], code: String, sid: String) -> [UInt8] {
        let material = Data(sharedKey + Array(code.utf8) + Array(sid.utf8))
        return Array(SHA256.hash(data: material))
    }

    private func makeHMAC(
        label: String,
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
        let payload = Data(Array(label.utf8) + trustedKey + firstNonce + secondNonce)
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
}
