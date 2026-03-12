//
//  SubsriptionInfoRealmStorage.swift
//  xabber
//
//  Created by Игорь Болдин on 11.03.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation
import RealmSwift

class SubsriptionInfoRealmStorage: Object {

    override static func primaryKey() -> String? {
        return "transactionId"
    }

    @objc dynamic var transactionId: String = ""
    @objc dynamic var productId: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var accountUUID: String = ""
    @objc dynamic var expires: Date = Date()
    @objc dynamic var purchaseDate: Date = Date()
}
