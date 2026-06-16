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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import RealmSwift

class XMPPMessageScheduleStorageItem: Object {
    enum Status: String {
        case pending
        case failed
    }

    override static func primaryKey() -> String? {
        return "primary"
    }

    override static func indexedProperties() -> [String] {
        return ["owner", "conversation", "conversationType_", "deliverAt", "status_"]
    }

    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var scheduledId: String = ""
    @objc dynamic var conversation: String = ""
    @objc dynamic var conversationType_: String = ClientSynchronizationManager.ConversationType.regular.rawValue
    @objc dynamic var deliverAt: Date = Date(timeIntervalSince1970: 0)
    @objc dynamic var status_: String = Status.pending.rawValue
    @objc dynamic var messageXML: String = ""
    @objc dynamic var createdAt: Date = Date()
    @objc dynamic var updatedAt: Date = Date()

    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            ClientSynchronizationManager.ConversationType(rawValue: conversationType_) ?? .regular
        } set {
            conversationType_ = newValue.rawValue
        }
    }

    var status: Status {
        get {
            Status(rawValue: status_) ?? .pending
        } set {
            status_ = newValue.rawValue
        }
    }

    static func genPrimary(owner: String, scheduledId: String) -> String {
        return [owner, scheduledId].prp()
    }

    func configure(
        owner: String,
        scheduledId: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        deliverAt: Date,
        status: Status,
        messageXML: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let primary = Self.genPrimary(owner: owner, scheduledId: scheduledId)
        if realm == nil {
            self.primary = primary
            self.createdAt = createdAt
        }
        self.owner = owner
        self.scheduledId = scheduledId
        self.conversation = conversation
        self.conversationType = conversationType
        self.deliverAt = deliverAt
        self.status = status
        self.messageXML = messageXML
        self.updatedAt = updatedAt
    }
}
