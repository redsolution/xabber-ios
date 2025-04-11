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

/// An object is responsible for
/// sizing and configuring cells for given `IndexPath`s.
open class CellSizeCalculator {

    let avatarSize: CGSize = CGSize(square: CGFloat(CommonConfigManager.shared.config.chat_avatar_size))
    let messageContainerMargin = UIEdgeInsets(top: 4, bottom: 4, left: 4, right: 4)
    let messageContainerPadding = UIEdgeInsets(top: 2, bottom: 2, left: 2, right: 2)
    let messagePadding: CGFloat = 64

    var messageLabelInsets = UIEdgeInsets(top: 0, left: 6, bottom: 2, right: 6)

    init(layout: MessagesCollectionViewFlowLayout? = nil) {
        self.layout = layout
    }


    public weak var layout: UICollectionViewFlowLayout?

    var messagesLayout: MessagesCollectionViewFlowLayout {
        guard let layout = layout as? MessagesCollectionViewFlowLayout else {
            fatalError("Layout object is missing or is not a MessagesCollectionViewFlowLayout")
        }
        return layout
    }


    open func configure(attributes: UICollectionViewLayoutAttributes) {

    }


    open func sizeForItem(at indexPath: IndexPath) -> CGSize {
        let dataSource = messagesLayout.messagesDataSource
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        return messageContainerSize(for: message)
    }

    func messageContainerSize(for message: MessageType) -> CGSize {
        return .zero
    }

    func messageContainerMaxWidth(inlineLevel: Int = 0) -> CGFloat {
        var maxWidth = messagesLayout.itemWidth - messageContainerMargin.horizontal - messageContainerPadding.horizontal - messagePadding
        if maxWidth > 420 {
            maxWidth = 420
        }
        if inlineLevel > 0 {
            maxWidth -= CGFloat(8 * inlineLevel)
        }
        return maxWidth
    }

    func labelSize(for attributedText: NSAttributedString?, considering maxWidth: CGFloat) -> CGSize {
        guard let attributedText = attributedText else { return .zero }
        let constraintBox = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        let rect = attributedText.boundingRect(
            with: constraintBox,
            options: [
                .usesLineFragmentOrigin
            ],
            context: nil
        ).standardized
        
        let size = CGSize(width: ceil(rect.size.width), height: ceil(rect.size.height))
        if size.width == 0 {
            return .zero
        }
        
        
        
        return CGSize(width: ceil(rect.size.width), height: ceil(rect.size.height))
    }
    
    func lastLineLabelSize(for attrubutedText: NSAttributedString?, for size: CGSize) -> CGSize {
        let lastLineAttributedText = attrubutedText?.splitIntoLines(for: size).last
        return labelSize(for: lastLineAttributedText, considering: size.width)
    }
}
