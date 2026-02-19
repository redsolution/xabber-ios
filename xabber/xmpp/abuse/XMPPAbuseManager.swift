//
//  XMPPAbuseManager.swift
//  xabber
//
//  Created by Игорь Болдин on 13.02.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation
import XMPPFramework
import RealmSwift
import CocoaLumberjack

class XMPPAbuseManager: AbstractXMPPManager {
    enum ManagerErrorType: Error {
        case notAvailable
    }
    
    static let xmlns: String = "urn:xabber:favorites:0"
    
    open var node: String? = nil
    
    var defaultAdress: String = CommonConfigManager.shared.config.default_report_address
    
    override func namespaces() -> [String] {
        return [
            XMPPAbuseManager.xmlns
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return XMPPFavoritesManager.xmlns
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        loadLocal()
    }
    
    private func loadLocal() {
        
    }
    
    public func register(address: String, for owner: String, isGroup: Bool) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: XMPPAbuseConfigStorageItem.self, forPrimaryKey: XMPPAbuseConfigStorageItem.genPrimary(owner: owner)) {
                try realm.write {
                    instance.updateAt = Date()
                }
            } else {
                let instance = XMPPAbuseConfigStorageItem()
                instance.owner = owner
                instance.abuseAddress = address
                instance.group = isGroup
                instance.primary = XMPPAbuseConfigStorageItem.genPrimary(owner: owner)
                instance.updateAt = Date()
                try realm.write {
                    realm.add(instance)
                }
            }
        } catch {
            DDLogDebug("XMPPAbuseManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public func report(_ xmppStream: XMPPStream, message primary: String, reason: String) {
        do {
            let realm = try WRealm.safe()
            if let messageInstance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                let isGroup = messageInstance.conversationType == .group
                let abuseJid = realm.object(ofType: XMPPAbuseConfigStorageItem.self, forPrimaryKey: isGroup ? messageInstance.opponent : messageInstance.owner)?.abuseAddress
                _ = AccountManager
                    .shared
                    .find(for: self.owner)?
                    .messages
                    .sendSimpleMessage("report: \(reason)", to: abuseJid ?? self.defaultAdress, forwarded: [primary], conversationType: .regular, isReport: true)
            }
        } catch {
            DDLogDebug("XMPPAbuseManager: \(#function). \(error.localizedDescription)")
        }
    }
}

