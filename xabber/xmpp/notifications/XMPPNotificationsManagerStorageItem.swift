//
//  XMPPNotificationsManagerStorage.swift
//  xabber
//
//  Created by Игорь Болдин on 18.03.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import RealmSwift
import CocoaLumberjack

class XMPPNotificationsManagerStorageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    
    @objc dynamic var lastItemId: String? = nil
    @objc dynamic var unread: Int = 0
    
    @objc dynamic var node: String? = nil
    
    static func genPrimary(owner: String) -> String {
        return [owner].prp()
    }
}


class NotificationStorageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var uniqueId: String = ""
    
    @objc dynamic var category_: String = ""
    @objc dynamic var isRead: Bool = true
    @objc dynamic var associatedJid: String? = nil
    @objc dynamic var displayedNick: String? = nil
    @objc dynamic var text: String? = nil
    @objc dynamic var metadata_: String? = nil
    @objc dynamic var date: Date = Date()
    
    @objc dynamic var shouldShow: Bool = false
    
    static func genPrimary(owner: String, jid: String, uniqueId: String) -> String {
        return [owner, jid, uniqueId].prp()
    }
    
    var category: XMPPNotificationsManager.Category {
        get {
            return XMPPNotificationsManager.Category(rawValue: self.category_) ?? .device
        } set {
            self.category_ = newValue.rawValue
        }
    }
    
    var metadata: [String: Any]? {
        get {
            if let metadata = self.metadata_,
                let data = metadata.data(using: .utf8) {
                do {
                    return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                } catch {
                    DDLogDebug("NotificationStorageItem: \(#function). \(error.localizedDescription)")
                }
            }
            return nil
        } set {
            if let value = newValue {
                do {
                    let data = try JSONSerialization.data(withJSONObject: value, options: [])
                    self.metadata_ = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    DDLogDebug("NotificationStorageItem: \(#function). \(error.localizedDescription)")
                }
            } else {
                self.metadata_ = nil
            }
        }
    }
    
}
