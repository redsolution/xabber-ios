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
        case trusted = "trusted"
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var myDeviceId: Int = 0
    @objc dynamic var jid: String = ""
    @objc dynamic var fullJID: String = ""
    @objc dynamic var opponentDeviceId: Int = 0
    @objc dynamic var byteSequence: String = ""
    @objc dynamic var opponentByteSequence: String = ""
    @objc dynamic var code: String = ""
    @objc dynamic var state_: String = VerififcationState.none.rawValue
    @objc dynamic var sid: String = ""
    @objc dynamic var opponentByteSequenceEncrypted: String = ""
    @objc dynamic var opponentByteSequenceIv: String = ""
    
    var state: VerififcationState {
        get {
            return VerififcationState(rawValue: self.state_) ?? .none
        } set {
            self.state_ = newValue.rawValue
        }
    }
    
    static func genPrimary(owner: String, jid: String, sid: String) -> String {
        return [owner, jid, sid].prp()
    }
}
