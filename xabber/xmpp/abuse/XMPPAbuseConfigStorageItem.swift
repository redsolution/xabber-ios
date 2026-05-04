//
//  XMPPAbuseConfigStorageItem.swift
//  xabber
//
//  Created by Игорь Болдин on 13.02.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation
import RealmSwift
import CocoaLumberjack

class XMPPAbuseConfigStorageItem: Object {
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var abuseAddress: String = ""
    @objc dynamic var group: Bool = false
    
    @objc dynamic var updateAt: Date = Date()
    
    static func genPrimary(owner: String) -> String {
        return owner
    }
}

class XMPPAbuseReportStorageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var conversationType_: String = ""
    @objc dynamic var abuseAddress: String = ""
    
    @objc dynamic var messageId: String = ""
    @objc dynamic var reportId: String = ""
    @objc dynamic var createdAt: Date? = nil
    @objc dynamic var targetType: String = ""
    @objc dynamic var reason: String = ""
    @objc dynamic var comment: String? = nil
    @objc dynamic var state: String? = nil
    @objc dynamic var includeMessageExcerpt: Bool = false
    @objc dynamic var messageExcerpt: String? = nil
    @objc dynamic var payload: String? = nil
    
    
    @objc dynamic var updateAt: Date = Date()
    
    static func genPrimary(owner: String, jid: String, messageId: String) -> String {
        return [owner, jid, messageId].prp()
    }
    
    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            return ClientSynchronizationManager.ConversationType(rawValue: self.conversationType_) ?? ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        } set {
            self.conversationType_ = newValue.rawValue
        }
    }
}
