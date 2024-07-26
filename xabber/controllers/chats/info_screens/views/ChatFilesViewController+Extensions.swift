//
//  ChatFilesViewController+Extensions.swift
//  xabber
//
//  Created by Admin on 23.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import CocoaLumberjack

//extension ChatFilesViewController: TappedPhotoInMediaGallery {
//    func tappedPhoto(primary: String) {
//        chatsDelegate?.didTapPhotoFromGallery(primary: primary)
//    }
//}

extension ChatFilesViewController: CellPhotoIsMissing {
    func passCellToFooter(cell: UICollectionViewCell) {
        guard let index = collectionView.indexPath(for: cell) else { return }
        let reference = datasource[index.item]
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: reference.primary)
            try realm.write {
                instance?.isMissed = true
            }
        } catch {
            DDLogDebug("InfoScreenFooterView+Extensions: \(#function). \(error.localizedDescription)")
        }
    }
}
