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
import RxSwift
import RxCocoa
import RxRealm
import CocoaLumberjack

extension ChatViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        print("PREFETCH", indexPaths.compactMap{ $0.section }.sorted())
        print("VISIBLE", collectionView.indexPathsForVisibleItems.compactMap{ $0.section }.sorted())
    }
    
    
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        print("END DRAGGING", velocity, targetContentOffset.pointee)
        guard let maxVisibleItem = self.messagesCollectionView.indexPathsForVisibleItems.compactMap { $0.section }.max(),
        let minVisibleItem = self.messagesCollectionView.indexPathsForVisibleItems.compactMap { $0.section }.min() else {
            return
        }
        let currentVelocityY =  scrollView.panGestureRecognizer.velocity(in: scrollView.superview).y 
        let currentVelocityYSign = Int(currentVelocityY).signum() 
        if currentVelocityYSign != lastVelocityYSign && currentVelocityYSign != 0 {
            lastVelocityYSign = currentVelocityYSign
        }
        if lastVelocityYSign < 0 {
            if minVisibleItem == 0 {
                self.addDatasourceToStart()
            }
        } else if lastVelocityYSign > 0 && datasource.count > 30 {
            if maxVisibleItem >= datasource.count - 10 {
                self.addDatasourceToEnd()
            }
        }
    }
    
    
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if self.showSkeletonObserver.value { return }
        if !canUpdateDataset { return }
        guard let section = messagesCollectionView
                  .indexPathsForVisibleItems
                  .compactMap({ return $0.section })
                  .max(),
              let sectionMin = messagesCollectionView
                  .indexPathsForVisibleItems
                  .compactMap({ return $0.section })
                  .min() else {
            return
        }
        if (section == datasource.count - 1) && ((messagesObserver?.count ?? 0) > datasource.count){
            messagesCount += ChatViewController.datasourcePageSize
            DispatchQueue.main.async {
                self.runDatasetUpdateTask()
            }
            self.shouldChangeOffsetOnUpdate = false
        } else if (section == datasource.count - 1) && ((messagesObserver?.count ?? 0) == datasource.count) {
            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { stream, session in
                session.mam?.getNextHistory(stream, for: self.jid, conversationType: self.conversationType) {
                    DispatchQueue.main.async {
                        self.runDatasetUpdateTask()
                    }
                }
            }) {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.mam.getNextHistory(stream, for: self.jid, conversationType: self.conversationType) {
                        DispatchQueue.main.async {
                            self.runDatasetUpdateTask()
                        }
                    }
                })
            }
        } else {
            self.shouldChangeOffsetOnUpdate = sectionMin > 0
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
//        if self.showSkeletonObserver.value { return }
////        if NotifyManager.shared.currentDialog == nil { return }
//        if let path = scrollItemIndexPath,
//        indexPath.section == path.section {
//            scrollItemIndexPath = nil
//            (cell as? MessageContentCell)?.hilghlightCell(color: UIColor.blue.withAlphaComponent(0.1), duration: 1.6)
//        }
//        DispatchQueue.main.async {
//            if indexPath.section > collectionView.indexPathsForVisibleItems.count + 2 {
//                self.toolsButtonStateObserver.accept(.scrollToBottom)
//            } else {
//                self.toolsButtonStateObserver.accept(.hidden)
//            }
//        }
//        guard (messagesObserver?.count ?? 0) > indexPath.section,
//              let primary = messagesObserver?[indexPath.section].primary else {
//            self.updateQueue.asyncAfter(deadline: .now() + 0.3) {
//                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                    user.messages.readLastMessage(jid: self.jid, conversationType: self.conversationType)
//                })
//            }
//            return
//        }
//        if !(messagesObserver?[indexPath.section].isRead ?? true) {
//            self.updateQueue.asyncAfter(deadline: .now() + 0.3) {
//                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                    user.messages.readMessage(primary,
//                                              last: false)
//                })
//            }
//        }
//        if (messagesObserver?.count ?? 0) < indexPath.section { return }
//        
//        DispatchQueue.global(qos: .background).async {
//            MessageReferenceStorageItem.prepareVoice(message: primary)
//            MessageReferenceStorageItem.prepareVideo(message: primary)
//        }
        
    }
    
}
