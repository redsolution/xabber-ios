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

class GroupChatStorageItem: Object {
    
    enum Membership: String {
        case none = "none"
        case open = "open"
        case memberOnly = "member-only"
        
        var localized: String? {
            get {
                switch self {
                case .none:
                    return nil
                case .open:
                    return "Open".localizeString(id: "groupchat_status_open", arguments: [])
                case .memberOnly:
                    return "Member only".localizeString(id: "groupchat_status_member_only", arguments: [])
                }
            }
        }
    }
    
    enum Privacy: String {
        case none = "none"
        case incognito = "incognito"
        case publicChat = "public"
        
        var localized: String? {
            get {
                switch self {
                case .none:
                    return nil
                case .incognito:
                    return "Incognito".localizeString(id: "groupchat_status_incognito", arguments: [])
                case .publicChat:
                    return "Public".localizeString(id: "groupchat_status_public", arguments: [])
                }
            }
        }
    }
    
    enum Index: String {
        case none = "none"
        case local = "local"
        case global = "global"
        
        var localized: String? {
            get {
                switch self {
                case .none:
                    return "No".localizeString(id: "groupchat_status_none", arguments: [])
                case .local:
                    return "Local".localizeString(id: "groupchat_status_local", arguments: [])
                case .global:
                    return "Global".localizeString(id: "groupchat_status_global", arguments: [])
                }
            }
        }
    }
    
    enum MuteState: Int {
        case enabled
        case disabled
        case disabledForTime
        case onlyMentions
    }
    
    public static func genPrimary(jid: String, owner: String) -> String {
        return [jid, owner].prp()
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var name: String = ""
    @objc dynamic var privacy_: String = Privacy.none.rawValue
    @objc dynamic var index_: String = Index.none.rawValue
    @objc dynamic var membership_: String = Membership.none.rawValue
    @objc dynamic var descr: String = ""
    @objc dynamic var pinnedMessage: String = ""
    var contacts: List<String> = List<String>()
    var domains: List<String> = List<String>()
    @objc dynamic var members: Int = 0
    @objc dynamic var present: Int = 0
//    @objc dynamic var collectj: Bool = true
    @objc dynamic var peerToPeer: Bool = false
    @objc dynamic var usersListVersion: String? = nil
    var invited: List<String> = List<String>()
    @objc dynamic var canInvite: Bool = true
    @objc dynamic var canChangeSettings: Bool = false
    @objc dynamic var canChangeUsersSettings: Bool = false
    @objc dynamic var canChangeNicknames: Bool = false
    @objc dynamic var canChangeBadge: Bool = false
    @objc dynamic var canBlockUsers: Bool = false
    @objc dynamic var canChangeAvatars: Bool = false
    @Persisted var canDeleteMessages: Bool = false
    
    var defaultRestrictions: List<String> = List<String>()
    
    @objc dynamic var status: String = ""
    
    @objc dynamic var muteState_: Int = MuteState.enabled.rawValue
    
    @objc dynamic var isDeleted: Bool = false
    
    override static func indexedProperties() -> [String] {
        return ["owner", ]
    }
    
    @objc dynamic var defaultPermissions_: String = ""
    
    var defaultPermissions: [GroupchatPermission] {
            get { decodePermissions(from: defaultPermissions_) }
            set { defaultPermissions_ = encodePermissions(newValue) }
        }

        // MARK: – Helpers
    private func encodePermissions(_ perms: [GroupchatPermission]) -> String {
        guard let data = try? JSONEncoder().encode(perms),
              let json = String(data: data, encoding: .utf8) else {
            return ""                     // fallback – empty array
        }
        return json
    }

    private func decodePermissions(from json: String) -> [GroupchatPermission] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let perms = try? JSONDecoder().decode([GroupchatPermission].self, from: data) else {
            return []                     // fallback – empty array
        }
        return perms
    }
    
    var muteState: MuteState {
        get {
            switch muteState_ {
            case MuteState.enabled.rawValue: return .enabled
            case MuteState.disabled.rawValue: return .disabled
            case MuteState.disabledForTime.rawValue: return .disabledForTime
            case MuteState.onlyMentions.rawValue: return .onlyMentions
            default: return .enabled
            }
        } set {
            muteState_ = newValue.rawValue
        }
    }
    
    var membership: Membership {
        get {
            switch membership_ {
            case Membership.none.rawValue: return .none
            case Membership.open.rawValue: return .open
            case Membership.memberOnly.rawValue: return .memberOnly
            default: return .none
            }
        } set {
            membership_ = newValue.rawValue
        }
    }
    
    var privacy: Privacy {
        get {
            switch privacy_ {
            case Privacy.none.rawValue: return .none
            case Privacy.publicChat.rawValue: return .publicChat
            case Privacy.incognito.rawValue: return .incognito
            default: return .none
            }
        } set {
            privacy_ = newValue.rawValue
        }
    }
    
    var index: Index {
        get {
            switch index_ {
            case Index.none.rawValue: return .none
            case Index.local.rawValue: return .local
            case Index.global.rawValue: return .global
            default: return .none
            }
        } set {
            index_ = newValue.rawValue
        }
    }
    
    var statusVerbose: String {
        get {
            switch self.status {
            case "Inactive": return "Inactive".localizeString(id: "groupchat_status_inactive", arguments: [])
            case "xa":       return "Away for long time".localizeString(id: "groupchat_status_away_long", arguments: [])
            case "away":     return "Away".localizeString(id: "groupchat_status_away", arguments: [])
            case "dnd":      return "Busy".localizeString(id: "groupchat_status_busy", arguments: [])
            case "online":   return "Online".localizeString(id: "groupchat_status_online", arguments: [])
            case "chat":     return "Ready to chat".localizeString(id: "groupchat_status_ready_to_chat", arguments: [])
            case "active":   return "Online".localizeString(id: "groupchat_status_online", arguments: [])
            default:         return "Offline".localizeString(id: "groupchat_status_offline", arguments: [])
            }
        }
    }
    
    var statusDisplayed: ResourceStatus {
        get {
            switch self.status {
            case "Inactive": return .offline
            case "xa":       return .xa
            case "away":     return .away
            case "dnd":      return .dnd
            case "online":   return .online
            case "chat":     return .chat
            case "active":   return .online
            default:         return .offline
            }
        }
    }
    
    func configure(_ jid: String, owner: String) {
        self.jid = jid
        self.owner = owner
        self.primary = [jid, owner].prp()
    }
    
    public var statusString: String {
        get {
            if present == 0 {
                return "\(members) \(members == 1 ? "member" : "members")"
            } else {
                return "\(members) members, \(present) online".localizeString(id: "number_of_members_and_online", arguments: ["\(members)", "\(present)"])
            }
        }
    }
}
