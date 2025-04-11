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

/// A protocol used by the `MessagesCollectionViewFlowLayout` object to determine
/// the size and layout of a `MessageCollectionViewCell` and its contents.
protocol MessagesLayoutDelegate: AnyObject {

    /// Specifies the size to use for a header view.
    ///
    /// - Parameters:
    ///   - section: The section number of the header.
    ///   - messagesCollectionView: The `MessagesCollectionView` in which this header will be displayed.
    ///
    /// - Note:
    ///   The default value returned by this method is a size of `GGSize.zero`.
    func headerViewSize(for section: Int, in messagesCollectionView: MessagesCollectionView) -> CGSize

    /// Specifies the size to use for a footer view.
    ///
    /// - Parameters:
    ///   - section: The section number of the footer.
    ///   - messagesCollectionView: The `MessagesCollectionView` in which this footer will be displayed.
    ///
    /// - Note:
    ///   The default value returned by this method is a size of `GGSize.zero`.
    func footerViewSize(for section: Int, in messagesCollectionView: MessagesCollectionView) -> CGSize

    /// Specifies the height for the `MessageContentCell`'s top label.
    ///
    /// - Parameters:
    ///   - message: The `MessageType` that will be displayed for this cell.
    ///   - indexPath: The `IndexPath` of the cell.
    ///   - messagesCollectionView: The `MessagesCollectionView` in which this cell will be displayed.
    ///
    /// - Note:
    ///   The default value returned by this method is zero.
    func cellTopLabelHeight(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> CGFloat
    
    /// Specifies the height for the message bubble's top label.
    ///
    /// - Parameters:
    ///   - message: The `MessageType` that will be displayed for this cell.
    ///   - indexPath: The `IndexPath` of the cell.
    ///   - messagesCollectionView: The `MessagesCollectionView` in which this cell will be displayed.
    ///
    /// - Note:
    ///   The default value returned by this method is zero.
    func messageTopLabelHeight(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> CGFloat

    /// Specifies the height for the `MessageContentCell`'s bottom label.
    ///
    /// - Parameters:
    ///   - message: The `MessageType` that will be displayed for this cell.
    ///   - indexPath: The `IndexPath` of the cell.
    ///   - messagesCollectionView: The `MessagesCollectionView` in which this cell will be displayed.
    ///
    /// - Note:
    ///   The default value returned by this method is zero.
    func messageBottomLabelHeight(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> CGFloat

    
    func messageCornerStyle() -> String
    
    func messageAvatarVerticalPosition() -> String
    
    func messageCornerRadius() -> String
}

extension MessagesLayoutDelegate {

    func headerViewSize(for section: Int, in messagesCollectionView: MessagesCollectionView) -> CGSize {
        return .zero
    }

    func footerViewSize(for section: Int, in messagesCollectionView: MessagesCollectionView) -> CGSize {
        return .zero
    }

    func cellTopLabelHeight(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> CGFloat {
        return 0
    }
    
    func messageTopLabelHeight(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> CGFloat {
        return 0
    }

    func messageBottomLabelHeight(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> CGFloat {
        return 0
    }
    
    func messageCornerStyle() -> String {
        return "no_tail"
    }
    
    func messageAvatarVerticalPosition() -> String {
        return "bottom"
    }
    
    func messageCornerRadius() -> String {
        return "16"
    }
}
