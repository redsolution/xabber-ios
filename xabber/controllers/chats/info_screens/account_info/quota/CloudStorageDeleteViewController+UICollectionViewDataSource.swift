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
            let textView = cell.contentView.viewWithTag(101) as? UILabel ?? UILabel()
            textView.tag = 101
            textView.text = isDeleting ? "Deleting…" : "Delete"
            textView.textColor = .systemRed
            textView.textAlignment = .center
            if textView.superview == nil {
                cell.contentView.addSubview(textView)
                textView.fillSuperview()
            }
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
        case .image, .avatar:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotosMediaCollectionCell.cellName, for: indexPath) as! PhotosMediaCollectionCell
            if let uri = item.uri {
                cell.setup(photoUrls: (thumb: nil, url: uri))
            }
            return cell
        case .video:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VideosMediaCollectionCell.cellName, for: indexPath) as! VideosMediaCollectionCell
            cell.setup(videoCacheKey: item.videoPreviewKey, videoDuration: item.videoDuration ?? "")
            return cell
        case .file:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilesMediaCollectionCell.cellName, for: indexPath) as! FilesMediaCollectionCell
            cell.setup(
                mimeType: item.mimeType ?? "file",
                sender: item.senderName ?? "",
                date: item.date ?? "",
                time: item.time ?? "",
                sizeInBytes: item.size ?? "0 KiB",
                filename: item.fileName ?? "File"
            )
            cell.senderNameLabel.text = cell.fileNameLabel.text
            cell.fileNameLabel.isHidden = true
            cell.fileSizeLabel.text = item.size
            if indexPath.row == datasource[indexPath.section].count - 1 {
                cell.separatorLine.isHidden = true
            }
            return cell
        case .voice:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VoiceMediaCollectionCell.cellName, for: indexPath) as! VoiceMediaCollectionCell
            let meters = item.meters?
                .split(separator: " ")
                .compactMap { Float($0) }
            cell.audioView.configure(
                .paused,
                meters: (meters?.isEmpty == false ? meters : nil) ?? [0.0, 0.0],
                loading: false,
                duration: item.audioDuration ?? "",
                senderName: item.fileName ?? "Audio message",
                date: item.date ?? "",
                send_time: item.time ?? "",
                sizeInBytes: item.size ?? "0 KiB"
            )
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
            label.text = "Please review the advisory list of files selected to reach \(plan.percent)% free space. The server validates the cleanup again on confirmation. Avatars are excluded."
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
        case .avatar:
            label.text = "Avatars"
        default:
            label.text = "Undefined"
        }
        headerView.addSubview(label)
        label.fillSuperviewWithOffset(top: 13, bottom: 0, left: 25, right: 0)
        return headerView
    }
}
