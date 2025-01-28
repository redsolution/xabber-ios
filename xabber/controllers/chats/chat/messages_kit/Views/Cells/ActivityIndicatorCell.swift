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
import MaterialComponents.MDCPalettes

class AtivityIndicatorCell: MessageContentCell {
    /// The label used to display the message's text.
    internal let activityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        
        return view
    }()
    
    // MARK: - Methods
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        activityIndicator.frame = CGRect(square: 44)
        activityIndicator.center = self.center
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        messageContainerView.addSubview(activityIndicator)
    }
    
    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        messageContainerView.bubbleImage.isHidden = false
        messageContainerView.shadowImage.isHidden = false
        self.activityIndicator.startAnimating()
    }
    
    override func layoutAvatarView(with attributes: MessagesCollectionViewLayoutAttributes) {
        self.avatarView.frame = .zero
    }
    
    override func layoutBottomLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
        messageBottomLabel.frame = .zero
    }
    
    override func layoutMessageTopLabel(with attributes: MessagesCollectionViewLayoutAttributes) {
        messageTopLabel.frame = .zero
    }
    
    /// Used to handle the cell's contentView's tap gesture.
    /// Return false when the contentView does not need to handle the gesture.
    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        return false
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return false
    }
}
