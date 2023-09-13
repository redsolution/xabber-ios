//
//  CloudStorageDeleteViewController+UICollectionViewDelegateFlowLayout.swift
//  xabber
//
//  Created by MacIntel on 13.09.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension CloudStorageDeleteViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        if indexPath.section == 0 {
            return CGSize(width: 0, height: 0)
        }
        
        if indexPath.section == datasource.count {
            return CGSize(width: view.frame.width - InfoScreenFooterView.cellSpacing * 2, height: 44)
        }
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .image, .video:
            let layout = collectionViewLayout as! UICollectionViewFlowLayout
            layout.minimumLineSpacing = InfoScreenFooterView.cellSpacing
            layout.minimumInteritemSpacing = InfoScreenFooterView.cellSpacing
            collectionView.collectionViewLayout = layout
            let width = view.frame.width / InfoScreenFooterView.numberOfCells - InfoScreenFooterView.cellSpacing * (InfoScreenFooterView.numberOfCells + 1) / InfoScreenFooterView.numberOfCells
            return CGSize(square: width)
        default:
            let layout = collectionViewLayout as! UICollectionViewFlowLayout
            layout.minimumLineSpacing = 0
            layout.minimumInteritemSpacing = 0
            collectionView.collectionViewLayout = layout
            return CGSize(width: view.frame.width - InfoScreenFooterView.cellSpacing * 2, height: 60)
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        if section == 0 {
            return CGSize(width: collectionView.frame.width, height: 140)
        }
        if section == datasource.count { return CGSize() }
        return CGSize(width: collectionView.frame.width, height: 35)
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if indexPath.section == datasource.count {
            ActionSheetPresenter()
                .present(in: self,
                         title: "Delete files",
                         message: "Please confirm deleting files from a cloud storage. This action can not be undone.",
                         cancel: "Cancel",
                         values: [ActionSheetPresenter.Item(destructive: true, title: "Delete", value: "delete")],
                         animated: true) { _ in
                    guard let account = AccountManager.shared.find(for: self.owner),
                          let uploader = account.getDefaultUploader() as? UploadManagerExtendedProtocol else { return }
                    uploader.deleteMediaForSelectedPeriod(earlierThanDate: self.dateOfLastFile!) {
                        self.navigationController?.popViewController(animated: true)
                    }
                }
            return
        }
    }
}
