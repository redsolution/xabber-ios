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
        
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {

    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {

    }
    
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
//        if self.canLoadDatasource {
//            if (self.messagesCollectionView.contentSize.height - self.messagesCollectionView.contentOffset.y) < self.view.bounds.height {
//                self.canLoadDatasource = false
//                self.onTouchEndPage(direction: .up)
//            }
//        }
//        if self.canLoadDatasource {
//            if self.currentPage.minIndex > 0 {
//                if let datasourcePrimary = self.datasource.first?.primary,
//                   let observerPrimary = self.messagesObserver.first?.primary,
//                   datasourcePrimary != observerPrimary {
//                    if self.messagesCollectionView.contentOffset.y < 0 {
//                        self.canLoadDatasource = false
//                        self.onTouchStartPage(direction: .down)
//                    }
//                }
//            }
//        }
        
        self.willUpdateFloatingDate()
        if !self.datasource[indexPath.section].isRead {
            var value = self.messagesToReadObserver.value
            value.insert(self.datasource[indexPath.section].primary)
            self.messagesToReadObserver.accept(value)
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        self.willUpdateFloatingDate()
        if self.datasource.count > indexPath.section {
            if !self.datasource[indexPath.section].isRead {
                var value = self.messagesToReadObserver.value
                value.insert(self.datasource[indexPath.section].primary)
                self.messagesToReadObserver.accept(value)
            }
        }
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let contentOffsetY = scrollView.contentOffset.y

        if self.currentPage.isUnlocked {
            let contentOffsetY = scrollView.contentOffset.y
            if contentOffsetY > self.previousContentOffsetY {
                self.chatScrollDirection = .down
            } else {
                self.chatScrollDirection = .up
            }
            self.contentOffsetObserver.accept(contentOffsetY)
        }
        if !self.preventHidingDate {
            self.pinnedDateView.hide()
        }
        self.previousContentOffsetY = contentOffsetY
        self.showFloatingDateObserver.accept(true)
        
        self.messagesCollectionView.indexPathsForVisibleItems.forEach {
            indexPath in
            if !self.datasource[indexPath.section].isRead {
                var value = self.messagesToReadObserver.value
                value.insert(self.datasource[indexPath.section].primary)
                self.messagesToReadObserver.accept(value)
            }
        }
    }
    
    
}
