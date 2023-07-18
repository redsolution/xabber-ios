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

extension MessagesViewController {

    public final func addKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(MessagesViewController.handleKeyboardDidChangeState(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(MessagesViewController.handleTextViewDidBeginEditing(_:)),
            name: UITextView.textDidBeginEditingNotification, object: nil
        )
    }

    public final func removeKeyboardObservers() {
        NotificationCenter.default.removeObserver(
            self,
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UITextView.textDidBeginEditingNotification,
            object: nil
        )
    }
    
    @objc
    private final func handleTextViewDidBeginEditing(_ notification: Notification) {
        if scrollsToBottomOnKeybordBeginsEditing {
            guard let inputTextView = notification.object as? InputTextView, inputTextView === xabberInputBar.inputTextView else { return }
            messagesCollectionView.scrollToTop(animated: true)
        }
    }

    @objc
    private final func handleKeyboardDidChangeState(_ notification: Notification) {
        guard !isMessagesControllerBeingDismissed,
              let keyboardStartFrameInScreenCoords = notification.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect,
              !keyboardStartFrameInScreenCoords.isEmpty,
              let keyboardEndFrameInScreenCoords = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        
        let keyboardEndFrame = view.convert(keyboardEndFrameInScreenCoords, from: view.window)
        
        let newBottomInset = requiredScrollViewBottomInset(forKeyboardFrame: keyboardEndFrame)
        messageCollectionViewTopInset = newBottomInset
        
        if newBottomInset > messageCollectionViewLastKBPosition {
            messagesCollectionView.contentOffset.y -= newBottomInset - messageCollectionViewLastKBPosition
        }
        
        messageCollectionViewLastKBPosition = newBottomInset
    }
    
    internal final func requiredScrollViewBottomInset(forKeyboardFrame keyboardFrame: CGRect) -> CGFloat {
        let intersection = messagesCollectionView.frame.intersection(keyboardFrame)
        if intersection.isNull || intersection.maxY < messagesCollectionView.frame.maxY {
            return max(0, additionalTopInset)
        } else {
            let value = max(
                0,
                intersection.height + additionalTopInset - keyboardTransformCorrection
            )
            self.isKeyboardShowed = self.xabberInputBar.inputTextView.isFirstResponder
            if value < 56 {
                print(self.accessoryViewSearchCorrectionConstant)
                return 0 - self.accessoryViewSearchCorrectionConstant
            }
            return value
        }
    }
    
    public final func requiredInitialScrollViewBottomInset() -> CGFloat {
        let newBottomInset = max(
            messageCollectionViewLastKBPosition,
            additionalBottomInset - keyboardTransformCorrection + messageCollectionViewLastKBPosition
        )
        print(self.messageCollectionViewLastKBPosition)
        messageCollectionViewLastKBPosition = newBottomInset
        return newBottomInset
    }
    
    public final func initialBottomOffsetUpdate() {
        messageCollectionViewTopInset = 0
    }
    
    /// iOS 11's UIScrollView can automatically add safe area insets to its contentInset,
    /// which needs to be accounted for when setting the contentInset based on screen coordinates.
    ///
    /// - Returns: The distance automatically added to contentInset.bottom, if any.
    var automaticallyAddedBottomInset: CGFloat {
        return messagesCollectionView.adjustedContentInset.bottom - messagesCollectionView.contentInset.bottom - additionalSafeAreaInsets.bottom
    }
    
    var keyboardTransformCorrection: CGFloat {
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            return 51 + bottomInset
        } else {
            return 51
        }
    }
}
