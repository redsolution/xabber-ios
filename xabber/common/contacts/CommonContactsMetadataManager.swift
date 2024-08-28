//
//  CommonContactsMetadataManager.swift
//  xabber
//
//  Created by Игорь Болдин on 23.08.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation

class CommonContactsMetadataManager: NSObject {
    open class var shared: CommonContactsMetadataManager {
        struct CommonContactsMetadataManagerSingleton {
            static let instance = CommonContactsMetadataManager()
        }
        return CommonContactsMetadataManagerSingleton.instance
    }
    
    struct Metadata {
        let jid: String
        let owner: String
        let username: String?
        let avatarUrl: String?
    }
    
    let key: String = "contacts_metadata"
    
    public func clear(for owner: String) {
        guard let userDefaults = UserDefaults.init(suiteName: "group.com.xabber") else {
            fatalError()
        }
        userDefaults.dictionaryRepresentation().keys.forEach {
            if $0.contains([key, owner].prp()) {
                userDefaults.removeObject(forKey: $0)
            }
        }
    }
    
    public func update(owner: String, jid: String, username: String?, avatarUrl: String?) {
        guard let userDefaults = UserDefaults.init(suiteName: "group.com.xabber") else {
            fatalError()
        }
        var metadata: [String: Any] = userDefaults.dictionary(forKey: [key, owner, jid].prp()) ?? ["username": username ?? "test", "avatarUrl": avatarUrl ?? ""]
        if let username = username {
            metadata["username"] = username
        }
        if let avatarUrl = avatarUrl {
            metadata["avatarUrl"] = avatarUrl
        }
        userDefaults.setValue(metadata, forKey: [key, owner, jid].prp())
    }
    
    public func getItem(owner: String, jid: String) -> Metadata {
        guard let userDefaults = UserDefaults.init(suiteName: "group.com.xabber") else {
            fatalError()
        }
        if let metadata: [String: Any] = userDefaults.dictionary(forKey: [key, owner, jid].prp()) {
            return Metadata(
                jid: jid,
                owner: owner,
                username: metadata["username"] as? String,
                avatarUrl: metadata["avatarUrl"] as? String
            )
        }
        return Metadata(jid: jid, owner: owner, username: nil, avatarUrl: nil)
    }
}
