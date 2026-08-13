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
        } else if indexPath.section == datasource.count || indexPath.section == datasource.count + 1 {
            return CGSize(width: view.frame.width - InfoScreenFooterView.cellSpacing * 2, height: 44)
        }
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .image, .video, .avatar:
            let layout = collectionViewLayout as! UICollectionViewFlowLayout
            layout.minimumLineSpacing = CloudStorageCategoryLayoutPolicy.spacing
            layout.minimumInteritemSpacing = CloudStorageCategoryLayoutPolicy.spacing
            let width = CloudStorageCategoryLayoutPolicy.gridItemWidth(
                containerWidth: collectionView.bounds.width
            )
            return CGSize(square: width)
        default:
            let layout = collectionViewLayout as! UICollectionViewFlowLayout
            layout.minimumLineSpacing = 0
            layout.minimumInteritemSpacing = 0
            collectionView.collectionViewLayout = layout
            return CGSize(
                width: CloudStorageCategoryLayoutPolicy.listItemWidth(
                    containerWidth: collectionView.bounds.width
                ),
                height: CloudStorageCategoryLayoutPolicy.listItemHeight
            )
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        if section == 0 {
            return CGSize(width: collectionView.frame.width, height: 140)
        }
        if section == datasource.count || section == datasource.count + 1 { return CGSize() }
        return CGSize(width: collectionView.frame.width, height: 35)
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard gallerySelectionIsCurrent() else { return }
        collectionView.deselectItem(at: indexPath, animated: true)
        if indexPath.section == datasource.count {
            ActionSheetPresenter()
                .present(in: self,
                         title: "Delete files",
                         message: "Please confirm deleting files from a cloud storage. This action can not be undone.",
                         cancel: "Cancel",
                         values: [ActionSheetPresenter.Item(destructive: true, title: "Delete", value: "delete")],
                         animated: true) { _ in
                    self.performDeletion()
                }
            return
        }
    }
}
