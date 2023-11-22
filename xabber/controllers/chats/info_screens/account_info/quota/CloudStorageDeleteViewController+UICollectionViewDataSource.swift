//
//  CloudStorageDeleteViewController+UICollectionViewDataSource.swift
//  xabber
//
//  Created by MacIntel on 13.09.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension CloudStorageDeleteViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return datasource.count + 1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if section == datasource.count {
            return 1 // button
        }
        return datasource[section].count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if indexPath.section == datasource.count { // Сell with delete button
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "deleteButton", for: indexPath)
            let textView = UILabel()
            textView.text = "Delete"
            textView.textColor = .systemRed
            textView.textAlignment = .center
            cell.addSubview(textView)
            textView.fillSuperview()
            cell.backgroundColor = .systemBackground
            cell.layer.cornerRadius = 10
            cell.selectedBackgroundView = UIView()
            cell.selectedBackgroundView?.fillSuperview()
            cell.selectedBackgroundView?.layer.cornerRadius = 10
            cell.selectedBackgroundView?.backgroundColor = .systemGray3
            return cell
        } else if indexPath.section == 0 { // cell for specification
            let cell = UICollectionViewCell()
            return cell
        }
        
        let item = datasource[indexPath.section][indexPath.row]
        
        switch item.kind {
        case .image:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotosMediaCollectionCell.cellName, for: indexPath) as! PhotosMediaCollectionCell
            cell.setup(photoUrls: (thumb: nil, url: item.uri!))
            return cell
        case .video:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VideosMediaCollectionCell.cellName, for: indexPath) as! VideosMediaCollectionCell
            cell.setup(videoCacheKey: item.videoPreviewKey, videoDuration: item.videoDuration ?? "")
            return cell
        case .file:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilesMediaCollectionCell.cellName, for: indexPath) as! FilesMediaCollectionCell
            cell.setup(mimeType: item.mimeType!, sender: item.senderName ?? "", date: item.date ?? "", time: item.time ?? "", sizeInBytes: String(item.size!), filename: item.fileName!)
            cell.senderNameLabel.text = cell.fileNameLabel.text
            cell.fileNameLabel.isHidden = true
            cell.fileSizeLabel.text = item.size
            if indexPath.row == datasource[indexPath.section].count - 1 {
                cell.separatorLine.isHidden = true
            }
            return cell
        case .voice:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VoiceMediaCollectionCell.cellName, for: indexPath) as! VoiceMediaCollectionCell
            cell.setup(withReference: item.voiceModel, date: item.date!, send_time: item.time!, sizeInBytes: item.size!, url: item.uri)
            if item.meters == nil {
                cell.audioView.configure(.paused, meters: [0.0, 0.0], loading: false, duration: item.audioDuration ?? "", senderName: item.fileName ?? "Audio message", date: item.date!, send_time: item.time!, sizeInBytes: item.size ?? "? КБ")
            }
            cell.audioView.durationLabel.text = cell.sizeInBytes
            if indexPath.row == datasource[indexPath.section].count - 1 {
                cell.audioView.separatorLine.isHidden = true
            }
            return cell
        default:
            let cell = UICollectionViewCell()
            return cell
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "headerView", for: indexPath)
        headerView.prepareForReuse()
        if headerView.subviews.count != 0 {
            headerView.subviews.first?.removeFromSuperview()
        }
        
        if indexPath.section == 0 {
            let label = UILabel()
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.text = "Please review the list of files that are about to be deleted from your cloud storage to free up space.\n\nFiles will remain on this device, but will be inaccessible on your other devices."
            label.numberOfLines = 0
            headerView.addSubview(label)
            label.fillSuperviewWithOffset(top: 0, bottom: 0, left: 10, right: 10)
            
            return headerView
        }
        
        if indexPath.section == datasource.count {
            return headerView
        }
        
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .title3).bold()
        switch datasource[indexPath.section][indexPath.row].kind {
        case .image:
            label.text = "Images"
        case .video:
            label.text = "Videos"
        case .file:
            label.text = "Files"
        case .voice:
            label.text = "Voice messages"
        default:
            label.text = "Undefined"
        }
        headerView.addSubview(label)
        label.fillSuperviewWithOffset(top: 13, bottom: 0, left: 25, right: 0)
        return headerView
    }
}
