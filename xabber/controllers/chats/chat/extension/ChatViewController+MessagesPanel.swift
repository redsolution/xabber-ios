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
import MaterialComponents.MDCPalettes
import CocoaLumberjack

extension ChatViewController: ChatViewMessagesPanelDelegate {
    func messagesPanelOnClose() {
        self.attachedMessagesIds.accept([])
    }
    
    func messagesPanelOnIndicatorTouch() {
//        if let editMessageId = self.editMessageId.value {
//            guard let index = self.datasource.firstIndex(where: { item in
//                item.primary == editMessageId
//            }) else {
//                return
//            }
//            let indexPath = IndexPath(row: 0, section: index)
//            self.messagesCollectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
//            
//        } else {
//            let indexes = self.attachedMessagesIds.value
//                .compactMap({
//                    id in
//                    return self.datasource.firstIndex(where: {
//                        item in
//                        item.primary == id
//                    })
//                }).sorted()
//            guard let minIndex = indexes.min() else {
//                return
//            }
//            let indexPath = IndexPath(row: 0, section: minIndex)
//            self.messagesCollectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
//        }
        
    }
}
