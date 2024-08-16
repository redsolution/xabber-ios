//
//  XMPPFavoritesManagerStorageItem.swift
//  xabber
//
//  Created by Admin on 14.08.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import RealmSwift

class XMPPFavoritesManagerStorageItem: Object {
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    static let imageName: String = "bookmark.fill"
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var node: String = ""
    
    static func genPrimary(owner: String) -> String {
        return [owner].prp()
    }
}
