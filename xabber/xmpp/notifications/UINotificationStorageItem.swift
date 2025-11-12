//
//  UINotificationStorageItem.swift
//  xabber
//
//  Created by Игорь Болдин on 19.08.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import RealmSwift
import CocoaLumberjack

class UINotificationStorageItem: Object {
    enum Kind: String {
        case none = ""
        case invite = "invite"
        case contactRequest = "contact_request"
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    
    @objc dynamic var kind_: String = Kind.none.rawValue
    
    @objc dynamic var date: Date = Date()
    @objc dynamic var readAt: Date? = nil
    @objc dynamic var isRead: Bool = false
    @objc dynamic var updateAt: Date = Date()
    
    static func genPrimary(owner: String, jid: String) -> String {
        return [owner, jid].prp()
    }
    
    var kind: Kind {
        get {
            return Kind(rawValue: self.kind_) ?? .none
        } set {
            self.kind_ = newValue.rawValue
        }
    }
}
