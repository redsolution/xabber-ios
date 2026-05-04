//
//  VerififcationSessionStorageItem.swift
//  xabber
//
//  Created by Admin on 06.03.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import RealmSwift

class VerificationSessionStorageItem: Object {
    enum VerififcationState: String {
        case none = "none"
        case sentRequest = "sent_request"
        case receivedRequest = "received_request"
        case acceptedRequest = "accepted_request"
        case receivedRequestAccept = "received_request_accept"
        case hashSentToOpponent = "hash_sent_to_opponent"
        case hashSentToInitiator = "hash_sent_to_initiator"
        case challengeSent = "challenge_sent"
        case challengeReceived = "challenge_received"
        case responseSent = "response_sent"
        case responseReceived = "response_received"
        case verifySent = "verify_sent"
        case verifyReceived = "verify_received"
        case trusted = "trusted"
        case rejected = "rejected"
        case failed = "failed"
        case cancelled = "cancelled"
        case timeout = "timeout"
    }

    enum VerificationRole: String {
        case none = "none"
        case initiator = "initiator"
        case responder = "responder"
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var ownerJid: String = ""
    @objc dynamic var myDeviceId: Int = 0
    @objc dynamic var localDeviceId: Int = 0
    @objc dynamic var jid: String = ""
    @objc dynamic var peerBareJid: String = ""
    @objc dynamic var fullJID: String = ""
    @objc dynamic var peerFullJid: String = ""
    @objc dynamic var opponentDeviceId: Int = 0
    @objc dynamic var remoteDeviceId: Int = 0
    @objc dynamic var byteSequence: String = ""
    @objc dynamic var localNonce: String = ""
    @objc dynamic var opponentByteSequence: String = ""
    @objc dynamic var remoteNonce: String = ""
    @objc dynamic var code: String = ""
    @objc dynamic var state_: String = VerififcationState.none.rawValue
    @objc dynamic var role_: String = VerificationRole.none.rawValue
    @objc dynamic var sid: String = ""
    @objc dynamic var opponentByteSequenceEncrypted: String = ""
    @objc dynamic var encryptedChallengeNonce: String = ""
    @objc dynamic var opponentByteSequenceIv: String = ""
    @objc dynamic var encryptedChallengeIV: String = ""
    @objc dynamic var timestamp: String = ""
    @objc dynamic var updatedTimestamp: String = ""
    @objc dynamic var ttl: String = "300"
    @objc dynamic var expires: Double = 0
    @objc dynamic var createdAt: Date = Date()
    @objc dynamic var updatedAt: Date = Date()
    
    var state: VerififcationState {
        get {
            return VerififcationState(rawValue: self.state_) ?? .none
        } set {
            self.state_ = newValue.rawValue
            self.updatedAt = Date()
            self.updatedTimestamp = String(Int(Date().timeIntervalSince1970.rounded()))
        }
    }

    var role: VerificationRole {
        get {
            return VerificationRole(rawValue: self.role_) ?? .none
        } set {
            self.role_ = newValue.rawValue
            self.updatedAt = Date()
            self.updatedTimestamp = String(Int(Date().timeIntervalSince1970.rounded()))
        }
    }
    
    static func genPrimary(owner: String, sid: String) -> String {
        return [owner, sid].prp()
    }
}
