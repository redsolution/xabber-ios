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
import MaterialComponents.MDCPalettes

class SkeletonMessageCell: CommonMessageCell {
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {

        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        self.messageContainerView.bubbleImage.alpha = 1.0
    }
    
    override func setupSubviews() {
        super.setupSubviews()
    }
    
    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        self.messageContainerView.alpha = 0.35
        
        UIView.animate(
            withDuration: 0.66,
            delay: 0.5,
            options: [.repeat, .curveEaseInOut, .autoreverse, .beginFromCurrentState]) {
                self.messageContainerView.alpha = 0.5
            } completion: { _ in
                
            }
    }
    
    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        return false
    }
}
