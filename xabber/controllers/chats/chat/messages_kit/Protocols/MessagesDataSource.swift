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

import UIKit

protocol MessagesDataSource: AnyObject {

    func currentSender() -> Sender

    func isFromCurrentSender(message: MessageType) -> Bool
    
    func messageBottomPadding(at indexPath: IndexPath) -> CGFloat
    
    func showTopLabel(for message: MessageType) -> Bool
    
    
    func messageForItem(at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageType

    func numberOfSections(in messagesCollectionView: MessagesCollectionView) -> Int

    func numberOfItems(inSection section: Int, in messagesCollectionView: MessagesCollectionView) -> Int

    func cellTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString?
    
    func messageTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString?

    func messageBottomLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString?
    
    func showAvatar() -> Bool
    
    func audioMessageState(at indexPath: IndexPath, messageId: String?, index: Int?) -> InlineAudioGridView.AudioCellPlayingState
    
    func audioMessageDurationString(at indexPath: IndexPath, messageId: String?, index: Int?) -> String?
    
    func audioMessageCurrentGradientPercentage(at indexPath: IndexPath, messageId: String?, index: Int?) -> Float?
    
    func audioMessageDuration(at indexPath: IndexPath, messageId: String?, index: Int?) -> TimeInterval
    
    func audioMessageCurrentDuration(at indexPath: IndexPath, messageId: String?, index: Int?) -> TimeInterval
    
    func showDeliveryIndicator() -> Bool
    
    func canPerformAction() -> Bool
}
