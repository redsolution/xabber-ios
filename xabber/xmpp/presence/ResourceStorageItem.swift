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
import CocoaLumberjack

enum ResourceStatus: String {
    case offline = "offline"
    case xa = "xa"
    case away = "away"
    case dnd = "dnd"
    case online = "online"
    case chat = "chat"
}

enum RosterItemEntity: String {
    case contact = "contact"
    case groupchat = "groupchat"
    case bot = "bot"
    case server = "server"
    case incognitoChat = "incognito"
    case privateChat = "private"
    case encryptedChat = "encrypted"
    case issue = "issue"
}

class ResourceStorageItem: Object {
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    
    
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var resource: String = ""
    
    @objc dynamic var client: String = ""
    @objc dynamic var priority: Int = 0
    
    @objc dynamic var type_: Int = 0
    
    @objc dynamic var timestamp: Date = Date()
    
    @objc dynamic var status_: String = ResourceStatus.offline.rawValue
    @objc dynamic var statusExt: String = RosterItemEntity.contact.rawValue
    
    @objc dynamic var isTemporary: Bool = false
    
    @objc dynamic var statusMessage: String = ""
    
    @objc dynamic var isCurrentResourceForAccount: Bool = false
    
    @objc dynamic var deviceId: String? = nil
    
    override static func indexedProperties() -> [String] {
        return ["owner", "jid", "resource", "timestamp", "priority"]
    }
    
    enum ClientType: Int {
        case unknown = 0
        case bot
        case console
        case game
        case handheld
        case pc
        case phone
        case sms
        case web
        case groupchat
    }
    
    var type: ClientType {
        get {
            switch type_ {
            case ClientType.bot.rawValue: return .bot
            case ClientType.console.rawValue: return .console
            case ClientType.game.rawValue: return .game
            case ClientType.handheld.rawValue: return .handheld
            case ClientType.pc.rawValue: return .pc
            case ClientType.phone.rawValue: return .phone
            case ClientType.sms.rawValue: return .sms
            case ClientType.web.rawValue: return .web
            case ClientType.groupchat.rawValue: return .groupchat
            default: return .unknown
            }
        } set {
            type_ = newValue.rawValue
        }
    }
    
    var status: ResourceStatus {
        get {
            return ResourceStatus(rawValue: self.status_) ?? .offline
        } set {
            self.status_ = newValue.rawValue
        }
    }
    
    var entity: RosterItemEntity {
        get {
            if self.jid.contains("redmine_issue") {
                return .issue
            }
            return RosterItemEntity(rawValue: self.statusExt) ?? .contact
        } set {
            if self.jid.contains("redmine_issue") {
                self.statusExt = RosterItemEntity.issue.rawValue
            } else {
                self.statusExt = newValue.rawValue
            }
        }
    }
        
    static public func genPrimary(jid: String, owner: String, resource: String) -> String {
        return [jid, resource, owner].prp()
    }
    
    var displayedStatus: String {
        get {
            if status == .offline {
                return entity == .contact ? "Offline" : (statusMessage.isEmpty ? "Offline" : statusMessage)
            } else if statusMessage.isNotEmpty {
                return statusMessage
            } else {
                switch status {
                case .offline:
                    return "Offline".localizeString(id: "groupchat_status_offline", arguments: [])
                case .xa:
                    return "Away for long time".localizeString(id: "groupchat_status_away_long", arguments: [])
                case .away:
                    return "Away".localizeString(id: "groupchat_status_away", arguments: [])
                case .dnd:
                    return "Busy".localizeString(id: "groupchat_status_busy", arguments: [])
                case .online:
                    return "Online".localizeString(id: "groupchat_status_online", arguments: [])
                case .chat:
                    return "Ready to chat".localizeString(id: "groupchat_status_ready_to_chat", arguments: [])
                }
            }
        }
    }
    
    public final func getDevice() -> DeviceStorageItem? {
        guard let id = deviceId,
              jid == owner else {
            return nil
        }
        do {
            let realm = try WRealm.safe()
            return realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: DeviceStorageItem.genPrimary(uid: id, owner: owner))
        } catch {
            DDLogDebug("ResourceStorageItem: \(#function). \(error.localizedDescription)")
        }
        return nil
    }
}

