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
    
//    func showFloatingDate() {
//        let visibleItems = self.messagesCollectionView.indexPathsForVisibleItems
//        let layout = self.messagesCollectionView.collectionViewLayout as! MessagesCollectionViewFlowLayout
//        let visibleDateFrames: [CGRect] = visibleItems.compactMap {
//            path in
//            switch self.datasource[path.section].kind {
//                case .date, .unread:
//                    let attrib = layout.layoutAttributesForItem(at: path)
//                    guard let frame = attrib?.frame else { return nil }
//                    var convertedPoint = self.messagesCollectionView.convert(frame.origin, to: self.view)
//                    convertedPoint.y = convertedPoint.y - frame.height
//                    let newFrame = CGRect(origin: convertedPoint, size: frame.size)
//                    print(newFrame)
//                    return newFrame
//                default:
//                    return nil
//            }
//        }.filter({
//            $0.minY < 150
//        })
//        if visibleDateFrames.isEmpty && ((visibleItems.compactMap({ $0.section }).max() ?? 0) != self.datasource.count - 1) {
//            self.showFloatingDateObserver.accept(true)
//            self.hideFloatingDateObserver.accept(false)
//            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
//                self.hideFloatingDateObserver.accept(true)
//            }
//        } else {
//            self.showFloatingDateObserver.accept(false)
//            self.hideFloatingDateObserver.accept(false)
//        }
//    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
//        self.showFloatingDate()
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
//        self.showFloatingDate()
        
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
        self.updateFloatingDate()
    }
    
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        self.updateFloatingDate()
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let contentOffsetY = scrollView.contentOffset.y
        let diffY = contentOffsetY - self.previousContentOffsetY
        print(contentOffsetY)
        
        
        
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
//        self.showFloatingDate()
        self.showFloatingDateObserver.accept(true)
//        if contentOffsetY > 250 {
//            if !self.shouldShowScrollDownButton.value {
//                if !self.inSearchMode.value {
//                    self.shouldShowScrollDownButton.accept(true)
//                }
//            }
//        } else {
//            if self.shouldShowScrollDownButton.value {
//                self.shouldShowScrollDownButton.accept(false)
//            }
//        }
    }
    
    
}
