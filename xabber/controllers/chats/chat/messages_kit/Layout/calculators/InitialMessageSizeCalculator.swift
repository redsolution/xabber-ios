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

class InitialMessageSizeCalculator: CellSizeCalculator {
    
    
    
    override func messageContainerSize(for message: MessageType) -> CGSize {
        let maxWidth = messageContainerMaxWidth()
        var messageContainerSize: CGSize
        var height: CGFloat = 104//136//112
        switch message.kind {
        case .initial(let description):
            height += labelSize(for: description, considering: maxWidth).height
        default:
            fatalError("messageContainerSize text received unhandled MessageDataType: \(message.kind)")
        }
        messageContainerSize = CGSize(width: maxWidth, height: height)
        return messageContainerSize
    }
    
    override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? MessagesCollectionViewLayoutAttributes else { return }
        
        let dataSource = messagesLayout.messagesDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        
        attributes.messageLabelInsets = UIEdgeInsets(top: 10, left: 24, bottom: 10, right: 24)
    }
}
