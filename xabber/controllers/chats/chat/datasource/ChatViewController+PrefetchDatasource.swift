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
        let diffY = contentOffsetY - self.previousContentOffsetY
        print(diffY, contentOffsetY, "DIFF")
        self.previousContentOffsetY = contentOffsetY
        
        
        
        if self.nextPinnedDateIndex != nil && self.chatScrollDirection == prevScrollDirection {
            if let itemIndex = self.nextPinnedDateIndex {
                let item = self.dateViews[itemIndex]
                print("pin", item.frame.minY, item.frame.maxY, self.pinnedDateFrame.minY, self.pinnedDateFrame.maxY)
                if self.chatScrollDirection == .up {
                    if item.frame.maxY > self.pinnedDateFrame.maxY  {
                        self.nextPinnedDateIndex = nil
                        self.dateViews[itemIndex].isPinned = true
                        self.dateViews[itemIndex].frame = self.pinnedDateFrame
                        self.pinnedDateIndex = item.naturalIndex
                    }
                } else if self.chatScrollDirection == .down {
                    if item.frame.minY < self.pinnedDateFrame.minY  {
                        self.nextPinnedDateIndex = nil
                        self.dateViews[itemIndex].isPinned = true
                        self.dateViews[itemIndex].frame = self.pinnedDateFrame
                        self.pinnedDateIndex = item.naturalIndex
                    }
                }
            }
        } else if self.nextPinnedDateIndex != nil && self.chatScrollDirection != prevScrollDirection {
            if let newScrollDirection = self.chatScrollDirection {
                switch prevScrollDirection {
                    case .up:
                        switch newScrollDirection {
                            case .up: break
                            case .down: self.nextPinnedDateIndex = self.nextPinnedDateIndex! - 1
                        }
                    case .down:
                        switch newScrollDirection {
                            case .up: self.nextPinnedDateIndex = self.nextPinnedDateIndex! + 1
                            case .down: break
                        }
                }
            }
        } else {
            self.dateViews.enumerated().forEach {
                (offset, item) in
                if item.isPinned {
                    let modifiedFrame = self.originalFrames[offset]
                    if self.chatScrollDirection == .up {
                        print(modifiedFrame.maxY, pinnedDateFrame.minY)
                        if modifiedFrame.maxY > pinnedDateFrame.maxY {
                            let newIndex = offset + 1
                            if newIndex < self.dateViews.count {
                                item.isPinned = false
                                item.frame = modifiedFrame
                                self.nextPinnedDateIndex = newIndex
                                if self.dateViews[newIndex].frame.maxY < 0 {
                                    if self.dateViews.filter({ $0.isPinned }).isEmpty {
                                        let oldFrame = self.dateViews[newIndex].frame
                                        var offsetY: CGFloat = 20
                                        if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
                                            offsetY += topInset
                                        }
                                        let newFrame = CGRect(
                                            origin: CGPoint(
                                                x: oldFrame.origin.x,
                                                y: offsetY//40
                                            ),
                                            size: oldFrame.size
                                        )
                                        self.dateViews[newIndex].frame = newFrame
                                    }
                                }
                            }
                        }
                    } else if self.chatScrollDirection == .down {
                        let prevIndex = offset - 1
                        
                        if prevIndex >= 0 {
                            let prevFrame = self.originalFrames[prevIndex]
                            if prevFrame.maxY < self.pinnedDateFrame.maxY + 38 {
                                item.isPinned = false
                                item.frame = prevFrame.offsetBy(dx: 0, dy: -38)
                                self.nextPinnedDateIndex = prevIndex
                            }
                        }
                    }
                }
            }
        }
        self.originalFrames.enumerated().forEach {
            (offset, item) in
            self.originalFrames[offset].origin.y += diffY
        }
        self.dateViews.forEach {
            item in
            var center = item.center
            center.y = center.y + diffY
            item.updateCenterIfNotAPinned(center)
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
