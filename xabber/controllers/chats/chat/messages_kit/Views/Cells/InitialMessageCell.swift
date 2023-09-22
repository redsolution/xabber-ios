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
import Kingfisher
import MaterialComponents.MDCPalettes

class InitialMessageCell: MessageCollectionViewCell {

    internal let avatarView: UIImageView = {
        let view = UIImageView()
        
        view.alpha = 0.4
        
        return view
    }()
    
    internal let backplateView: UIView = {
        let view = UIView()
        
        view.backgroundColor = .clear
        view.alpha = 0.72
        
        view.layer.cornerRadius = 4
        view.layer.masksToBounds = true
        
        return view
    }()
    
    
    internal let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        
        return stack
    }()
    
    internal let iconView: UIButton = {
        let view = UIButton(frame: CGRect(square: 56))
        
        view.layer.masksToBounds = true
        
        view.backgroundColor = .blue
        view.layer.cornerRadius = 28
        
        return view
    }()
    
    internal let titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        
        return label
    }()
    
    internal let descriptionLabel: UILabel = {
        let label = UILabel()

        label.numberOfLines = 0
        label.textAlignment = .center
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        
        return label
    }()
    
    internal let aboutLabel: UILabel = {
        let label = UILabel()
        
        label.numberOfLines = 0
        label.textAlignment = .center
        
        return label
    }()
    
    internal let footerSeparator: UIView = {
        let view = UIView()
        
        view.backgroundColor = .black
        view.alpha = 0.1
        
        return view
    }()
    
    internal let footerButton: UIButton = {
        let button = UIButton()
        
        button.titleLabel?.textAlignment = .center
        button.isUserInteractionEnabled = false
        
        return button
    }()
    
    weak var delegate: MessageCellDelegate?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        setupSubviews()
    }
    
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.isHidden = false
        avatarView.image = nil
    }
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            layoutStackView(with: attributes)
        }
    }
    
    internal var extConstraints: [NSLayoutConstraint] = []
    
    internal func layoutStackView(with attributes: MessagesCollectionViewLayoutAttributes) {
        
        let containerFrame = CGRect(
            x: (self.frame.width - attributes.messageContainerSize.width) / 2,
            y: 28,
            width: attributes.messageContainerSize.width,
            height: attributes.messageContainerSize.height - 26
        )
        
        backplateView.frame = containerFrame
        
        let avatarViewFrame = CGRect(
            x: (self.frame.width - attributes.messageContainerSize.width) / 2 + 24,
            y: (self.frame.height - attributes.messageContainerSize.height) / 2 + 24,
            width: attributes.messageContainerSize.width - 48,
            height: attributes.messageContainerSize.height - 48
        )
        
        avatarView.frame = avatarViewFrame
        
        iconView.frame = CGRect(
            x: self.frame.width / 2 - 27,
            y: 0,
            width: 56,
            height: 56
        )
        
        stack.frame = CGRect(
            x: containerFrame.minX + 8,
            y: containerFrame.minY + 36,
            width: containerFrame.width - 16,
            height: containerFrame.height - 42//74
        )
        
        footerButton.frame = CGRect(
            x: containerFrame.minX + 16,
            y: containerFrame.maxY - 30,
            width: containerFrame.width - 32,
            height: 18
        )
        
        footerSeparator.frame = CGRect(
            x: containerFrame.minX,
            y: containerFrame.maxY - 36,
            width: containerFrame.width,
            height: 0.5
        )
    }
    
    func setupSubviews() {
        self.contentView.addSubview(avatarView)
        self.contentView.addSubview(backplateView)
        self.contentView.addSubview(stack)
//        self.contentView.addSubview(footerSeparator)
//        self.contentView.addSubview(footerButton)
        self.contentView.addSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(descriptionLabel)
        stack.addArrangedSubview(aboutLabel)
//        stack.setCustomSpacing(2, after: titleLabel)
//        stack.setCustomSpacing(12, after: aboutLabel)
        
    }
    
    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        
        guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate else {
            fatalError(MessageKitError.nilMessagesDisplayDelegate)
        }
        
        switch message.kind {
        case .initial(let description):
            descriptionLabel.attributedText = description
        default: break
        }
        
        delegate = messagesCollectionView.messageCellDelegate
        
        iconView.tintColor = displayDelegate.accountPalette().tint600.withAlphaComponent(0.7)
        backplateView.backgroundColor = displayDelegate.pairedAccountPalette().tint50//.withAlphaComponent(0.8)
        iconView.backgroundColor = displayDelegate.pairedAccountPalette().tint50
        iconView.setImage(displayDelegate.initialMessageIcon()?.withRenderingMode(.alwaysTemplate), for: .normal)
        titleLabel.text = displayDelegate.initialMessageTitle()
        descriptionLabel.sizeToFit()
        
        
        let footerText = NSMutableAttributedString(string: displayDelegate.initialMessageFooter() ?? "")
        let range = NSRange(location: 0, length: footerText.string.count)
        footerText.addAttribute(.font, value: UIFont.systemFont(ofSize: 13, weight: .regular), range: range)
        footerText.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
        footerText.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        footerButton.setAttributedTitle(footerText, for: .normal)
//        footerButton.attributedText = footerText
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return false
    }
    
    public final func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self)
        let modifiedLocation = CGPoint(x: touchLocation.x, y: frame.height - touchLocation.y)
        var isTapHandled: Bool = false
        switch true {
        case footerButton.frame.contains(modifiedLocation):
            self.delegate?.didTapOnInitialFooterLabel(in: self)
            isTapHandled = true
        default:
            break
        }
        if self.contentView.frame.contains(touchLocation) && !isTapHandled {
            delegate?.didTap(in: self)
        }
    }
}

