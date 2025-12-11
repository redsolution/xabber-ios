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

class GroupchatInvitedUsersStorageItem: Object {
        
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var groupchatId: String = ""
    @objc dynamic var owner: String = ""
    
    @objc dynamic var jid: String = ""
    @objc dynamic var nickname: String = ""
    @objc dynamic var lastSeen: Date? = nil
    
    @objc dynamic var updatedTS: Double = 0
    @objc dynamic var oldschoolAvatarKey: String? = nil
    @objc dynamic var avatarMaxUrl: String? = nil
    @objc dynamic var avatarMinUrl: String? = nil
    @objc dynamic var avatarUpdatedTS: Double = -1
    
    public var avatarUrl: String? {
        return avatarMaxUrl ?? avatarMinUrl ?? oldschoolAvatarKey
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
    
    public static func genPrimary(jid: String, groupchat: String, owner: String) -> String {
        return [jid, groupchat, owner].prp()
    }
}
