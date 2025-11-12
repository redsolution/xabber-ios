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
import XMPPFramework.XMPPPresence
import XMPPFramework.XMPPJID

class RosterStorageItem: Object {
    enum Subsccribtion: String {
        case to = "to"
        case from = "from"
        case both = "both"
        case none = "none"
        case undefined = "undefined"
    }
    
    enum Ask: String {
        case none = "none"
        case `in` = "in"
        case out = "out"
        case both = "both"
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var username: String = ""
    @objc dynamic var customUsername: String = ""
    @objc dynamic var removed: Bool = false
    
    @objc dynamic var subscription_: String = ""
    @objc dynamic var ask_: String = ""
    @objc dynamic var askMessage: String = ""
    @objc dynamic var approved: Bool = false
    
    @objc dynamic var isHidden: Bool = false
    
    @objc dynamic var notes: String? = nil
    
    @objc dynamic var isSupportOmemo: Bool = true
    @objc dynamic var isOmemoDevicesListReceived: Bool = false
    
    @objc dynamic var oldschoolAvatarKey: String? = nil
    @objc dynamic var avatarMaxUrl: String? = nil
    @objc dynamic var avatarMinUrl: String? = nil
    @objc dynamic var avatarUpdatedTS: Double = -1
    @objc dynamic var updatedTS: Double = -1
    @objc dynamic var encryptionUpdatedTS: Double = -1
    
    @objc dynamic var isContact: Bool = true
    
    
    var groups: List<String> = List<String>()
    
    var associatedLastChat: LastChatsStorageItem? = nil
    
    public var avatarUrl: String? {
        return avatarMaxUrl ?? avatarMinUrl ?? oldschoolAvatarKey
    }
    
    public final func isThereSubscriptionRequest() -> Bool {
        if (XMPPJID(string: self.jid)?.isServer ?? true) {
            return false
        }
        switch self.ask {
        case .in, .both:
            return true
        default:
            return false
        }
    }
    
    override static func indexedProperties() -> [String] {
        return ["owner", "jid"]
    }
    
    public final var displayName: String {
        get {
            if customUsername.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty { return customUsername.trimmingCharacters(in: .whitespacesAndNewlines) }
            if username.isNotEmpty { return username }
            return JidManager.shared.prepareJid(jid: jid)
        }
    }

    public var subscribtion: Subsccribtion {
        get {
            return Subsccribtion(rawValue: subscription_) ?? Subsccribtion.undefined
        } set {
            subscription_ = newValue.rawValue
        }
    }
    
    public var ask: Ask {
        get {
            return Ask(rawValue: ask_) ?? Ask.none
        } set {
            ask_ = newValue.rawValue
        }
    }
    
    public static func genPrimary(jid: String, owner: String) -> String {
        return [jid, owner].prp()
    }
    
    public final func getPrimaryResource() -> ResourceStorageItem? {
        do {
            let realm = try WRealm.safe()
            if let resource = realm
                .objects(ResourceStorageItem.self)
                .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                .sorted(by: [
                    SortDescriptor(keyPath: "timestamp", ascending: false),
                    SortDescriptor(keyPath: "priority", ascending: false)
                ]).first {
                    return resource
                }
        } catch {
            DDLogDebug("cant get status for roster item")
        }
        return nil
    }
}
