//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit
import RealmSwift
import CocoaLumberjack

extension InfoScreenFooterView: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if datasource.isNotEmpty {
            return datasource.count
        } else {
            return 1
        }
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if datasource.isNotEmpty {
            DispatchQueue.global(qos: .background).async {
                if indexPath.item == (collectionView.numberOfItems(inSection: 0) - 1) {
                    do {
                        let realm = try WRealm.safe()
                        let lastChatsMsgCount = realm
                            .objects(LastChatsStorageItem.self)
                            .filter("jid == %@ AND owner == %@ AND isSynced == true", self.jid, self.owner)
                            .first?
                            .messagesCount
                        let messageStorageItemCount = realm
                            .objects(MessageStorageItem.self)
                            .count

                        if (lastChatsMsgCount ?? 0) > messageStorageItemCount {
                            DispatchQueue.main.async(flags: [.detached]) {
                                self.archiveRequestWithFilter()
                            }
                        }
                    } catch {
                        DDLogDebug("InfoScreenFooterView: \(#function). \(error.localizedDescription)")
                    }
                }
            }
            let data = datasource[indexPath.item]
            
            switch selectedKind {
            case .images:
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotosMediaCollectionCell.cellName, for: indexPath) as! PhotosMediaCollectionCell
                cell.setup(photoUrls: (thumb: data.thumbnail, url: data.uri))
                cell.infoScreenDelegate = self
                return cell
                
            case .videos:
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VideosMediaCollectionCell.cellName, for: indexPath) as! VideosMediaCollectionCell
                cell.setup(videoCacheKey: data.videoPreviewKey,
                           videoDuration: data.video_duration ?? "")
                cell.infoScreenDelegate = self
                return cell
                
            case .files:
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilesMediaCollectionCell.cellName, for: indexPath) as! FilesMediaCollectionCell
                cell.setup(mimeType: data.mimeType,
                           sender: data.senderName,
                           date: data.date,
                           time: data.send_time ?? "",
                           sizeInBytes: data.sizeInBytes ?? "",
                           filename: data.filename)
                return cell
                
            case .voice:
                if let voiceModel = datasource[indexPath.item].voiceModel {
                    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VoiceMediaCollectionCell.cellName, for: indexPath) as! VoiceMediaCollectionCell
                    cell.setup(withReference: voiceModel,
                               date: data.date,
                               send_time: data.send_time ?? "",
                               senderName: data.senderName,
                               owner: owner,
                               sizeInBytes: data.sizeInBytes ?? "")
                    
                    return cell
                } else {
                    fallthrough
                }
                
            default:
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NoFilesMediaCollectionCell.cellName, for: indexPath) as! NoFilesMediaCollectionCell
                cell.setup()
                return cell
            }
            
        } else {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NoFilesMediaCollectionCell.cellName, for: indexPath) as! NoFilesMediaCollectionCell
            if isFirstTimeOpened {
                isFirstTimeOpened = false
                needsCollectionUpdate = true
            } else {
                cell.setup()
            }
            return cell
        }
    }
}
