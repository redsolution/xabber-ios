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
import CocoaLumberjack

extension MessagesViewController {

    // MARK: - Register / Unregister Observers

    internal func addMenuControllerObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(MessagesViewController.menuControllerWillShow(_:)), name: UIMenuController.willShowMenuNotification, object: nil)
    }

    internal func removeMenuControllerObservers() {
        NotificationCenter.default.removeObserver(self, name: UIMenuController.willShowMenuNotification, object: nil)
    }

    // MARK: - Notification Handlers

    /// Show menuController and set target rect to selected bubble
    @objc
    private func menuControllerWillShow(_ notification: Notification) {

        guard let currentMenuController = notification.object as? UIMenuController,
            let selectedIndexPath = selectedIndexPathForMenu else { return }

        NotificationCenter.default.removeObserver(self, name: UIMenuController.willShowMenuNotification, object: nil)
        defer {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(MessagesViewController.menuControllerWillShow(_:)),
                                                   name: UIMenuController.willShowMenuNotification, object: nil)
            selectedIndexPathForMenu = nil
        }

        currentMenuController.setMenuVisible(false, animated: false)
              
        let share = UIMenuItem(title: "Forward".localizeString(id: "chat_froward", arguments: []),
                               action: NSSelectorFromString("shareMessage:"))
        let reply = UIMenuItem(title: "Reply".localizeString(id: "chat_reply", arguments: []),
                               action: NSSelectorFromString("replyMessage:"))
        let delete = UIMenuItem(title: "Delete".localizeString(id: "contact_delete", arguments: []),
                                action: NSSelectorFromString("deleteMessage:"))
        let more = UIMenuItem(title: "More".localizeString(id: "chat_more_actions", arguments: []),
                              action: NSSelectorFromString("moreAction:"))
        let retry = UIMenuItem(title: "Retry".localizeString(id: "chat_retry", arguments: []),
                               action: NSSelectorFromString("retrySendingMessage:"))
        let pin = UIMenuItem(title: "Pin".localizeString(id: "message_pin", arguments: []),
                             action: NSSelectorFromString("pinMessage:"))
        let edit = UIMenuItem(title: "Edit".localizeString(id: "edit_contact", arguments: []),
                              action: NSSelectorFromString("editMessage:"))

        currentMenuController.menuItems = [reply, share, delete, more, retry, pin, edit]
        
        guard let selectedCell = messagesCollectionView.cellForItem(at: selectedIndexPath) as? MessageContentCell else { return }
        let selectedCellMessageBubbleFrame = selectedCell.convert(selectedCell.messageContainerView.frame, to: view)

        var messageInputBarFrame: CGRect = .zero
        if let messageInputBarSuperview = xabberInputBar.superview {
            messageInputBarFrame = view.convert(xabberInputBar.frame, from: messageInputBarSuperview)
        }

        var topNavigationBarFrame: CGRect = navigationBarFrame
        if navigationBarFrame != .zero, let navigationBarSuperview = navigationController?.navigationBar.superview {
            topNavigationBarFrame = view.convert(navigationController!.navigationBar.frame, from: navigationBarSuperview)
        }

//        let menuHeight = currentMenuController.menuFrame.height

        let selectedCellMessageBubblePlusMenuFrame = CGRect(selectedCellMessageBubbleFrame.origin.x,
                                                            selectedCellMessageBubbleFrame.minY,// - menuHeight,
                                                            selectedCellMessageBubbleFrame.size.width,
                                                            selectedCellMessageBubbleFrame.size.height)// + 2 * menuHeight)

        var targetRect: CGRect = selectedCellMessageBubbleFrame
        currentMenuController.arrowDirection = .default

        /// Message bubble intersects with navigationBar and keyboard
        if selectedCellMessageBubblePlusMenuFrame.intersects(topNavigationBarFrame) && selectedCellMessageBubblePlusMenuFrame.intersects(messageInputBarFrame) {
            let centerY = (selectedCellMessageBubblePlusMenuFrame.intersection(messageInputBarFrame).minY + selectedCellMessageBubblePlusMenuFrame.intersection(topNavigationBarFrame).maxY) / 2
            targetRect = CGRect(selectedCellMessageBubblePlusMenuFrame.midX, centerY, 1, 1)
        } /// Message bubble only intersects with navigationBar
        else if selectedCellMessageBubblePlusMenuFrame.intersects(topNavigationBarFrame) {
            currentMenuController.arrowDirection = .up
        }

        currentMenuController.setTargetRect(targetRect, in: view)
        
        currentMenuController.update()
        
        currentMenuController.setMenuVisible(true, animated: true)
    }

    // MARK: - Helpers

    private var navigationBarFrame: CGRect {
        guard let navigationController = navigationController, !navigationController.navigationBar.isHidden else {
            return .zero
        }
        return navigationController.navigationBar.frame
    }
    
    @objc
    internal func copyMessage(_ sender: Any) {
        DDLogDebug(#function)
    }
    
    @objc
    internal func shareMessage(_ sender: Any) {
        DDLogDebug(#function)
    }
    
    @objc
    internal func replyMessage(_ sender: Any) {
        DDLogDebug(#function)
    }
    
    @objc
    internal func deleteMessage(_ sender: Any) {
        DDLogDebug(#function)
    }
    
    @objc
    internal func editMessage(_ sender: Any) {
        DDLogDebug(#function)
    }
    
    @objc
    internal func pinMessage(_ sender: Any) {
        DDLogDebug(#function)
    }
    
    @objc
    internal func moreAction(_ sender: Any) {
        DDLogDebug(#function)
    }
    
    @objc
    internal func retrySendingMessage(_ sender: Any) {
        DDLogDebug(#function)
    }
}
