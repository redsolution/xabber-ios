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
import RealmSwift


class MessageStanzaStorageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var messageId: String = ""
    @objc dynamic var stanza: String = ""
    @objc dynamic var timestamp: Date = Date()
    
    func set(_ Id: String, for owner: String, with stanza: String, at date: Date, primary: String) {
        self.primary = [primary, "_stanza"].joined()
        self.owner = owner
        self.messageId = Id
        self.stanza = stanza
        self.timestamp = date
    }
}

class OutgoingMessageQueueItem: Object {
    enum State: String {
        case queued
        case awaitingReceipt
        case terminalFailed
    }

    override static func primaryKey() -> String? {
        return "primary"
    }

    override static func indexedProperties() -> [String] {
        return ["owner", "conversationJid", "conversationType_", "messagePrimary", "originId", "state_"]
    }

    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var conversationJid: String = ""
    @objc dynamic var conversationType_: String = ClientSynchronizationManager.ConversationType.regular.rawValue
    @objc dynamic var messagePrimary: String = ""
    @objc dynamic var originId: String = ""
    @objc dynamic var stanzaXML: String = ""
    @objc dynamic var createdAt: Date = Date()
    @objc dynamic var createdOrder: Double = 0
    @objc dynamic var attemptCount: Int = 0
    @objc dynamic var awaitingReceipt: Bool = false
    @objc dynamic var replayRequired: Bool = false
    @objc dynamic var lastError: String? = nil
    @objc dynamic var lastAttemptAt: Date? = nil
    @objc dynamic var state_: String = State.queued.rawValue

    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            ClientSynchronizationManager.ConversationType(rawValue: conversationType_) ?? .regular
        } set {
            conversationType_ = newValue.rawValue
        }
    }

    var state: State {
        get {
            State(rawValue: state_) ?? .queued
        } set {
            state_ = newValue.rawValue
            awaitingReceipt = newValue == .awaitingReceipt
        }
    }

    static func genPrimary(
        owner: String,
        conversationJid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        messagePrimary: String
    ) -> String {
        [owner, conversationJid, conversationType.rawValue, messagePrimary].prp()
    }

    func configure(
        owner: String,
        conversationJid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        messagePrimary: String,
        originId: String,
        stanzaXML: String,
        createdAt: Date,
        replayRequired: Bool
    ) {
        self.primary = OutgoingMessageQueueItem.genPrimary(
            owner: owner,
            conversationJid: conversationJid,
            conversationType: conversationType,
            messagePrimary: messagePrimary
        )
        self.owner = owner
        self.conversationJid = conversationJid
        self.conversationType = conversationType
        self.messagePrimary = messagePrimary
        self.originId = originId
        self.stanzaXML = stanzaXML
        self.createdAt = createdAt
        self.createdOrder = createdAt.timeIntervalSince1970
        self.replayRequired = replayRequired
        self.state = .queued
    }
}
