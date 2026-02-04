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

class SystemMessageSizeCalculator: CellSizeCalculator {
    
//    override var messageLabelInsets = UIEdgeInsets(top: 4, left: 16, bottom: 2, right: 16)
    

//    
//    override func messageContainerMaxWidth(for message: MessageType) -> CGFloat {
////        let maxWidth = super.messageContainerMaxWidth(for: message)
////        let textInsets = messageLabelInsets(for: message)
//        return super.messageContainerMaxWidth(for: message)// - textInsets.horizontal
//    }
    
    
    
    override init(layout: MessagesCollectionViewFlowLayout? = nil) {
        super.init(layout: layout)
        messageLabelInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    }
    
    func containerSize(for message: MessageType) -> CGSize {
        let maxWidth = messageContainerMaxWidth()
        var messageContainerSize: CGSize
        let attributedText: NSAttributedString
        switch message.kind {
            case .call(let call):
                if call.incoming {
                    if call.missed {
                        attributedText = NSAttributedString(string: "Missed call", attributes: [
                            .font: UIFont.preferredFont(forTextStyle: .caption1),
                            .foregroundColor: UIColor.white,
                            ])
                    } else {
                        attributedText = NSAttributedString(string: "Incoming call", attributes: [
                            .font: UIFont.preferredFont(forTextStyle: .caption1),
                            .foregroundColor: UIColor.white,
                            ])
                    }
                } else {
                    if call.missed {
                        attributedText = NSAttributedString(string: "Outgoing call", attributes: [
                            .font: UIFont.preferredFont(forTextStyle: .caption1),
                            .foregroundColor: UIColor.white,
                            ])
                    } else {
                        attributedText = NSAttributedString(string: "Outgoing call", attributes: [
                            .font: UIFont.preferredFont(forTextStyle: .caption1),
                            .foregroundColor: UIColor.white,
                            ])
                    }
                }
            case .system(let text):
                attributedText = text
            case .date(let text):
                attributedText = text
            case .unread(let text):
                attributedText = text
        default:
            fatalError("messageContainerSize text received unhandled MessageDataType: \(message.kind)")
        }
        let messageInsets = messageLabelInsets//UIEdgeInsets(top: 4, left: 16, bottom: 2, right: 16)
        messageContainerSize = labelSize(for: attributedText, considering: maxWidth)
        messageContainerSize.width += messageInsets.horizontal
        messageContainerSize.height += messageInsets.vertical
        if messageContainerSize.width < 112.0 {
            messageContainerSize.width = 112.0
        }
        return messageContainerSize
    }
    
    override func messageContainerSize(for message: MessageType) -> CGSize {
        let size = containerSize(for: message)
        return CGSize(width: messagesLayout.itemWidth, height: size.height)
    }
    
    override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? MessagesCollectionViewLayoutAttributes else { return }
        
        let dataSource = messagesLayout.messagesDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        let size = containerSize(for: message)
        attributes.messageContainerSize = CGSize(width: messagesLayout.itemWidth, height: size.height)
        attributes.messageLabelInsets = messageLabelInsets
        attributes.textInlineViewSize = size
    }
}
