//
//  ChatFilesViewController+CollectionViewDelegate.swift
//  xabber
//
//  Created by Admin on 23.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension ChatFilesViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        if datasource.isEmpty {
            return CGSize(width: view.frame.width - InfoScreenFooterView.cellSpacing * 2, height: 60)
        }
        
        switch selectedType {
        case .images, .videos:
            let layout = collectionViewLayout as! UICollectionViewFlowLayout
            layout.minimumLineSpacing = InfoScreenFooterView.cellSpacing
            layout.minimumInteritemSpacing = InfoScreenFooterView.cellSpacing
            collectionView.collectionViewLayout = layout
            let widthRaw = view.frame.width / InfoScreenFooterView.numberOfCells - InfoScreenFooterView.cellSpacing * (InfoScreenFooterView.numberOfCells + 1) / InfoScreenFooterView.numberOfCells
            let width = floor(widthRaw * 100) / 100
            return CGSize(square: width)
            
        default:
            let layout = collectionViewLayout as! UICollectionViewFlowLayout
            layout.minimumLineSpacing = 0
            layout.minimumInteritemSpacing = 0
            collectionView.collectionViewLayout = layout
            return CGSize(width: view.frame.width - InfoScreenFooterView.cellSpacing * 2, height: 60)
        }
    }
}
