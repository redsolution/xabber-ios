//
//  ContactChatMetadata.swift
//  xabber_test_xmpp
//
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
import MaterialComponents.MDCPalettes
import RealmSwift
import CocoaLumberjack

class ContactChatMetadataManager {
    
    open class var shared: ContactChatMetadataManager {
        struct SettingsManagerSingleton {
            static let instance = ContactChatMetadataManager()
        }
        return SettingsManagerSingleton.instance
    }
    
    var lastColorId: Int = -1
    
    let colors = [
        MDCPalette.red,
        MDCPalette.pink,
        MDCPalette.purple,
        MDCPalette.deepPurple,
        MDCPalette.indigo,
        MDCPalette.blue,
        MDCPalette.lightBlue,
        MDCPalette.cyan,
        MDCPalette.teal,
        MDCPalette.green,
        MDCPalette.orange,
        MDCPalette.deepOrange,
        MDCPalette.brown
    ]
    
    var contacts: Set<ContactChatMetadataItem> = Set<ContactChatMetadataItem>()
    
    init() {
        self.contacts = []
    }
    
    private final func add(_ jid: String, for owner: String, badge: String, role: String) -> ContactChatMetadataItem {
        let instance: ContactChatMetadataItem = ContactChatMetadataItem(jid, for: owner, badge: badge, role: role == "member" ? nil : role, color: getRandomColor())
        self.contacts.insert(instance)
        return instance
    }
    
    public final func get(_ jid: String, for owner: String, badge: String, role: String) -> ContactChatMetadataItem {
        if let instance = self.contacts.first(where: { $0.jid == jid && $0.owner == owner }) {
            return instance
        } else {
            return self.add(jid, for: owner, badge: badge, role: role)
        }
    }
    public final func remove(_ jid: String) {
        self.contacts.filter({$0.jid == jid}).forEach { item in
            self.contacts.remove(item)
        }
    }
    
    private final func getRandomColor() -> MDCPalette {
        var Id: Int = 0
        while true {
            Id = Int.random(in: 0...(self.colors.count - 1))
            if Id != self.lastColorId {
                break
            }
        }
        if Id <= 0 && Id > self.colors.count {
            DDLogDebug("ContactChatMetadataManager.getRandomColor: invalid color id")
            Id = 0
        }
        self.lastColorId = Id
        return self.colors[Id]
    }
    
}

class ContactChatMetadataItem: NSObject {
    
    static func == (lhs: ContactChatMetadataItem, rhs: ContactChatMetadataItem) -> Bool {
        return lhs.jid == rhs.jid && lhs.owner == rhs.owner
    }
    
    var owner: String
    var jid: String
    var nickname: String
    var badge: String
    var role: String?
    var color: MDCPalette
    private var attributedNickname: NSAttributedString? = nil
    
    init(_ jid: String, for owner: String, badge: String, role: String?, color: MDCPalette) {
        self.owner = owner
        self.jid = jid
        self.nickname = self.jid
        self.badge = badge
        self.role = role
        self.color = color
        
        if let account = AccountManager.shared.users.first(where: {$0.jid == jid}) {
            self.nickname = account.username
            self.color = AccountColorManager.shared.palette(for: owner)
        } else {
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: "\(self.jid)_\(self.owner)") {
                    self.nickname = instance.displayName
                }
            } catch {
                DDLogDebug("cant find stored username for contact \(jid)")
            }
        }
    }
    
    public final func getAttributedNickname(_ attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        if let string = attributedNickname {
            return string
        } else {
            let string = NSMutableAttributedString(attributedString: NSAttributedString(string: nickname, attributes: attributes))
            string.addAttribute(.foregroundColor, value: color.tint600, range: NSRange(location: 0, length: NSString(string: nickname).length))
            string.append(NSAttributedString(string: " "))
            let locationBadge = NSString(string: string.string).length
            string.append(NSAttributedString(string: badge, attributes: attributes))
            string.addAttribute(.foregroundColor, value: MDCPalette.grey.tint600, range: NSRange(location: locationBadge, length: NSString(string: badge).length))
            let locationRole = NSString(string: string.string).length
            string.append(NSAttributedString(string: role ?? "", attributes: attributes))
            string.addAttribute(.foregroundColor, value: MDCPalette.grey.tint600, range: NSRange(location: locationRole, length: NSString(string: role ?? "").length))
            attributedNickname = string
            return string
        }
    }
    
}
