//
//  SharedRosterUtils.swift
//  xabber
//
//  Created by Игорь Болдин on 11.02.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation

class SharedRosterUtils {
    
    static func setUsername(jid: String, owner: String, username: String) {
        guard let userDefaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
            fatalError()
        }
        userDefaults.set(username, forKey: [jid, owner].prp())
    }
    
    static func getUsername(jid: String, owner: String) -> String? {
        guard let userDefaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
            fatalError()
        }
        return userDefaults.value(forKey: [jid, owner].prp()) as? String
    }
}
