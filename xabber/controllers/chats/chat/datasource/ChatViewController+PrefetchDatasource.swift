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
    
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {

        if self.currentPage.isUnlocked {
            if let direction = self.chatScrollDirection {
                if indexPath.section == 0 {
                    self.onTouchStartPage(direction: direction)
                } else if indexPath.section == self.datasource.count - 1 {
                    self.onTouchEndPage(direction: direction)
                }
            }
        }
    }
    
    func updateDateViews(contentOffsetY: CGFloat, prevScrollDirection: ChatDirection) {
        self.previousContentOffsetY = contentOffsetY
        
        let newOriginalFrames = self.originalFrames.compactMap {
            return $0.offsetBy(dx: 0, dy: contentOffsetY)
        }
        let newFrames = self.realDateFrames.compactMap {
            return $0.offsetBy(dx: 0, dy: contentOffsetY)
        }
        
        if let index = self.pinnedDateIndex {
            let frame = self.dateViews[index].frame
            let modifiedFrame = newOriginalFrames[index]
            if self.chatScrollDirection == .up {
                if modifiedFrame.maxY > frame.maxY {
                    self.dateViews[index].isPinned = false
                    self.pinnedDateIndex = nil
                }
            } else if self.chatScrollDirection == .down {
                let prevIndex = index - 1
                if prevIndex >= 0 {
                    let prevFrame = newOriginalFrames[index]
                    if frame.maxY < (prevFrame.minY - 8) {
                        self.dateViews[index].isPinned = false
                        self.pinnedDateIndex = nil
                    }
                }
            }
        } else {
            if self.chatScrollDirection == .up {
                
            } else if self.chatScrollDirection == .down {
                
            }
        }
        self.dateViews.enumerated().forEach {
            (offset, item) in
            item.updateFrameIfNotAPinned(newFrames[offset])
        }
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if self.currentPage.isUnlocked {
            let contentOffsetY = scrollView.contentOffset.y
            let prevScrollDirection: ChatDirection = self.chatScrollDirection ?? .up
            if contentOffsetY > self.previousContentOffsetY {
                self.chatScrollDirection = .up
            } else {
                self.chatScrollDirection = .down
            }
            self.updateDateViews(contentOffsetY: contentOffsetY, prevScrollDirection: prevScrollDirection)
            self.contentOffsetObserver.accept(contentOffsetY)
        }
    }
}
