//
//  ChatFilesViewController+CollectionViewDataSource.swift
//  xabber
//
//  Created by Admin on 23.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension ChatFilesViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if datasource.isNotEmpty {
            return datasource.count
        } else {
            return 1
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if datasource.isEmpty {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NoFilesMediaCollectionCell.cellName, for: indexPath) as? NoFilesMediaCollectionCell else {
                return UICollectionViewCell(frame: .zero)
            }
            
            cell.setup()
            
            return cell
        }
        
        let item = datasource[indexPath.row]
        
        switch selectedType {
        case .images:
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotosMediaCollectionCell.cellName, for: indexPath) as? PhotosMediaCollectionCell else {
                return UICollectionViewCell(frame: .zero)
            }
            
            cell.setup(photoUrls: (thumb: item.thumbnail, url: item.uri))
            cell.infoScreenDelegate = self
            return cell
            
        case .videos:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VideosMediaCollectionCell.cellName, for: indexPath) as! VideosMediaCollectionCell
            cell.setup(videoCacheKey: item.videoPreviewKey,
                       videoDuration: item.video_duration ?? "")
            cell.infoScreenDelegate = self
            return cell
            
        case .voice:
//            if let voiceModel = datasource[indexPath.item].voiceModel {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VoiceMediaCollectionCell.cellName, for: indexPath) as! VoiceMediaCollectionCell
            cell.setup(url: URL(string: item.uri)!, meters: [],
                       date: item.date,
                       send_time: item.send_time ?? "",
                       senderName: item.senderName,
                       owner: owner,
                       sizeInBytes: item.sizeInBytes ?? "")
            if indexPath.item == datasource.count - 1 {
                cell.audioView.separatorLine.removeFromSuperview()
            }
            return cell
//            } else {
//                fallthrough
//            }
        default:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilesMediaCollectionCell.cellName, for: indexPath) as! FilesMediaCollectionCell
            cell.setup(mimeType: item.mimeType,
                       sender: item.senderName,
                       date: item.date,
                       time: item.send_time ?? "",
                       sizeInBytes: item.sizeInBytes ?? "",
                       filename: item.filename)
            if indexPath.item == datasource.count - 1 {
                cell.separatorLine.removeFromSuperview()
            }
            return cell
        }
    }
    
    
}
