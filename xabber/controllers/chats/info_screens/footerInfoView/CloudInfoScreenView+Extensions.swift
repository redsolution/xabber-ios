//
//  CloudInfoScreenView+Extensions.swift
//  xabber
//
//  Created by MacIntel on 09.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import CocoaLumberjack

protocol TappedPhotoInCloudGallery {
    func tappedPhotoInGallery(primary: String)
}

extension CloudInfoScreenView: TappedPhotoInCloudGallery {
    func tappedPhotoInGallery(primary: String) {
        do {
            let realm = try WRealm.safe()
            let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary)
            let chatViewController = ChatViewController()
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return
        }
    }
}

