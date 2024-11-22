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
//        guard let maxVisibleItem = self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ $0.section }).min(),
//        let minVisibleItem = self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ $0.section }).max() else {
//            return
//        }
//        let currentVelocityY =  collectionView.panGestureRecognizer.velocity(in: collectionView.superview).y
//        let currentVelocityYSign = Int(currentVelocityY).signum()
//        if currentVelocityYSign != lastVelocityYSign && currentVelocityYSign != 0 {
//            lastVelocityYSign = currentVelocityYSign
//        }
//        if lastVelocityYSign == 0 {
//            if minVisibleItem == 0 {
//                self.addDatasourceToStart()
//            } else if maxVisibleItem >= datasource.count - (collectionView.indexPathsForVisibleItems.count + 1) {
//                self.addDatasourceToEnd()
//            }
//        } else if lastVelocityYSign < 0 {
//            if minVisibleItem == 0 {
//                self.addDatasourceToStart()
//            }
//        } else if lastVelocityYSign > 0 && datasource.count > 30 {
//            if maxVisibleItem >= datasource.count - 20 {
//                self.addDatasourceToEnd()
//            }
//        }
    }
    
    
//    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
//        
//    }
    
    
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        
    }
    
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
//        print("DID SCROLL")
        guard let maxVisibleItem = self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ $0.section }).max(),
        let minVisibleItem = self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ $0.section }).min() else {
            return
        }
        let currentVelocityY =  scrollView.panGestureRecognizer.velocity(in: scrollView.superview).y
        let currentVelocityYSign = Int(currentVelocityY).signum()
        if currentVelocityYSign != lastVelocityYSign && currentVelocityYSign != 0 {
            lastVelocityYSign = currentVelocityYSign
        }
//        print("LAST VELOCITY", lastVelocityYSign, maxVisibleItem, minVisibleItem)
//        if lastVelocityYSign == 0 {
//            if minVisibleItem == 0 {
//                self.addDatasourceToStart()
//            } else if maxVisibleItem >= datasource.count - (messagesCollectionView.indexPathsForVisibleItems.count + 1) {
//                self.addDatasourceToEnd()
//            }
//        }
        if self.scrollToMessageArchivedId == nil {
            if lastVelocityYSign < 0 {
                if minVisibleItem == 0 {
                    self.addDatasourceToStart()
                }
            } else if lastVelocityYSign > 0 && datasource.count > 30 {
                if maxVisibleItem >= datasource.count - 20 {
                    self.addDatasourceToEnd()
                }
            }
        }
        
//        let messageId = self.datasource[maxVisibleItem].primary
//        self.bottomVisibleMessageId.accept(messageId)
    }
    
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        
    }
    
}
