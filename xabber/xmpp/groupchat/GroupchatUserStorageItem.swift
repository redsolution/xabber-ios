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

class GroupchatUserStorageItem: Object {
    
    enum Role: String {
        case owner = "owner"
        case admin = "admin"
        case member = "member"
        
        var localized: String {
            get {
                switch self {
                case .owner:
                    return "Owner".localizeString(id: "groupchat_personal_status_owner", arguments: [])
                case .admin:
                    return "Administrator".localizeString(id: "groupchat_personal_status_administrator", arguments: [])
                case .member:
                    return "Member".localizeString(id: "groupchat_personal_status_member", arguments: [])
                }
            }
        }
    }
    
    enum IntegerRole: Int {
        case owner = 1
        case admin = 2
        case member = 20
    }
    
    enum Subscribtion: String {
        case none = "none"
        case both = "both"
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var groupchatId: String = ""
    @objc dynamic var userId: String = ""
    @objc dynamic var owner: String = ""
    
    @objc dynamic var jid: String = ""
    @objc dynamic var role_: String = Role.member.rawValue
    @objc dynamic var nickname: String = ""
    @objc dynamic var badge: String = ""
    @objc dynamic var avatarURI: String = ""
    @objc dynamic var temporaryAvatarHash: String = ""
    @objc dynamic var avatarHash: String = ""
    @objc dynamic var isOnline: Bool = false
    @objc dynamic var lastSeen: Date? = nil
    @objc dynamic var isBlocked: Bool = false
    @objc dynamic var isKicked: Bool = false
    
    @objc dynamic var isTemporary: Bool = false
    
    var permissons_: List<String> = List<String>()
    var restrictions_: List<String> = List<String>()
    
    @objc dynamic var subscribtion_: String = Subscribtion.both.rawValue
    
    @objc dynamic var isMe: Bool = false
    @objc dynamic var sortedRole: Int = IntegerRole.member.rawValue
    
    @objc dynamic var updateTimestamp: Date = Date(timeIntervalSinceReferenceDate: 0)
    @objc dynamic var updatedTS: Double = 0
    
    override static func indexedProperties() -> [String] {
        return ["owner", "groupchatId"]
    }
    
    var subscribtion: Subscribtion {
        get {
            switch subscribtion_ {
            case Subscribtion.both.rawValue: return .both
            case Subscribtion.none.rawValue: return .none
            default: return .both
            }
        } set {
            subscribtion_ = newValue.rawValue
        }
    }
    
    var role: Role {
        get {
            switch role_ {
            case Role.member.rawValue: return .member
            case Role.admin.rawValue: return .admin
            case Role.owner.rawValue: return .owner
            default: return .member
            }
        } set {
            role_ = newValue.rawValue
        }
    }
    
    var avatarURL: URL? {
        get {
            return URL(string: avatarURI)
        } set {
            avatarURI = newValue?.absoluteString ?? ""
        }
    }
    
    var avatarKey: URL {
        get {
            return URL(string: [userId, groupchatId].prp())!
        }
    }
    
    var permissions: [[String: String]] {
        get {
            var out: [[String: String]] = []
            permissons_.forEach {
                if let data = $0.data(using: .utf8) {
                    do {
                        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
                            out.append(json)
                        }
                    } catch {
                        DDLogDebug("GroupchatUserStorageItem: \(#function). \(error.localizedDescription)")
                    }
                }
            }
            return out
        } set {
            var out: [String] = []
            newValue.forEach {
                do {
                    let data = try JSONSerialization.data(withJSONObject: $0, options: [])
                    if let string = String(data: data, encoding: .utf8) {
                        out.append(string)
                    }
                } catch {
                    DDLogDebug("GroupchatUserStorageItem: \(#function). \(error.localizedDescription)")
                }
            }
            permissons_.removeAll()
            permissons_.append(objectsIn: out)
        }
    }
    
    var restrictions: [[String: String]] {
        get {
            var out: [[String: String]] = []
            restrictions_.forEach {
                if let data = $0.data(using: .utf8) {
                    do {
                        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
                            out.append(json)
                        }
                    } catch {
                        DDLogDebug("GroupchatUserStorageItem: \(#function). \(error.localizedDescription)")
                    }
                }
            }
            return out
        } set {
            var out: [String] = []
            newValue.forEach {
                do {
                    let data = try JSONSerialization.data(withJSONObject: $0, options: [])
                    if let string = String(data: data, encoding: .utf8) {
                        out.append(string)
                    }
                } catch {
                    DDLogDebug("GroupchatUserStorageItem: \(#function). \(error.localizedDescription)")
                }
            }
            restrictions_.removeAll()
            restrictions_.append(objectsIn: out)
        }
    }
    
    var dateString: String? {
        get {
            let lastSeenDateFormatter: DateFormatter = DateFormatter()
            if let date = self.lastSeen {
                let today = Date()
                if abs(today.timeIntervalSince(date)) < 60 {
                    lastSeenDateFormatter.dateFormat = "'last seen just now'"
                        .localizeString(id: "chat_seen_just_now", arguments: [])
                } else if abs(today.timeIntervalSince(date)) < 60 * 60 {
                    lastSeenDateFormatter.dateFormat = "'last seen \(Int(abs(today.timeIntervalSince(date)) / 60)) minutes ago'"
                        .localizeString(id: "chat_seen_minutes_ago",
                                        arguments: ["\(Int(abs(today.timeIntervalSince(date)) / 60))"])
                } else if abs(today.timeIntervalSince(date)) < 2 * 60 * 60 {
                    lastSeenDateFormatter.dateFormat = "'last seen an hour ago '"
                        .localizeString(id: "chat_seen_hour_ago", arguments: [])
                } else if abs(today.timeIntervalSince(date)) < 12 * 60 * 60 {
                    lastSeenDateFormatter.dateFormat = "'last seen at 'HH:mm"
                        .localizeString(id: "chat_seen_at", arguments: [])
                } else if abs(today.timeIntervalSince(date)) < 24 * 60 * 60 {
                    lastSeenDateFormatter.dateFormat = "'last seen yesterday at 'HH:mm"
                        .localizeString(id: "chat_seen_yesterday", arguments: [])
                }  else if (NSCalendar.current.dateComponents([.day], from: date, to: today).day ?? 0) <= 7 {
                    lastSeenDateFormatter.dateFormat = "'last seen on 'E' at 'HH:mm"
                        .localizeString(id: "chat_seen_date_time", arguments: [])
                } else if (NSCalendar.current.dateComponents([.year], from: date, to: today).year ?? 0) < 1 {
                    lastSeenDateFormatter.dateFormat = "'last seen 'dd MMM"
                        .localizeString(id: "chat_seen_date", arguments: [])
                } else {
                    lastSeenDateFormatter.dateFormat = "'last seen 'd MMM yyyy"
                        .localizeString(id: "chat_seen_date_year", arguments: [])
                }
                return lastSeenDateFormatter.string(from: date)
            }
            return nil
        }
    }
    
    
    func compareHash(_ hash: String) -> Bool {
        return avatarHash == hash
    }
    
    public static func genPrimary(id: String, groupchat: String, owner: String) -> String {
        return [id, groupchat, owner].prp()
    }
}
