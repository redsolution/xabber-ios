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

extension ChatViewController: ImagePickerViewDelegate {
    func checkProgress(for messageId: String, total: Int, progress: Int) {
        let lastIndexPath = IndexPath(item: 0, section: self.messagesObserver!.count - 1)
        
        if self.messagesCollectionView.indexPathsForVisibleItems.contains(lastIndexPath) {
            self.messagesCollectionView.reloadItems(at: [lastIndexPath])
        }
    }
    
    func onSendMessage() {
        print("Call empty", #function)
        DispatchQueue.main.async {
            self.forwardedIds.accept(Set<String>())
            self.attachedMessagesIds.accept([])
            self.unreadMessagePositionId = nil
            self.scrollToLastOrUnreadItem()
        }
    }
    
    func onDismissPicker() {
        self.inputAccessoryView?.isHidden = false
    }
}
