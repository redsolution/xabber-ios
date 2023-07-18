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

extension SubforwardsViewController: MessagesDisplayDelegate {
    
    
    func messageStyle(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageStyle {
        let item = self.subforwards[indexPath.section]
        let corner: MessageStyle.TailCorner = isFromCurrentSender(message: message) ? .bottomRight : .bottomLeft
        if item.kind != .text { return .bubble(corner) }
        if indexPath.section > 0 {
            if self.subforwards[indexPath.section - 1].isOutgoing == item.isOutgoing {
                return .bubble(corner)
            }
        }
        return .bubbleTail(corner)
    }
    
    func detectorAttributes(for detector: DetectorType, and message: MessageType, at indexPath: IndexPath) -> [NSAttributedString.Key : Any] {
        switch detector {
        case .address, .date, .phoneNumber, .transitInformation:
            return MessageLabel.defaultAttributes
        case .url:
            return MessageLabel.defaultURLAttributes
        }
    }
    
    func enabledDetectors(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> [DetectorType] {
        return [.url, .address, .phoneNumber, .date]
    }
    
    func backgroundColor(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> UIColor {
        let item = self.subforwards[indexPath.section]
        return item.isOutgoing ? UIColor.white : accountPallete.tint50
    }
    
    func deliveryState(at indexPath: IndexPath) -> MessageStorageItem.MessageSendingState {
        return .none
    }
    
    func inlineAccountColor() -> UIColor {
        return accountPallete.tint100
    }
    
}
