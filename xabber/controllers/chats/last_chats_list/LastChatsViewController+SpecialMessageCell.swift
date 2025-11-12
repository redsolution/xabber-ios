////
////
////
////  This program is free software; you can redistribute it and/or
////  modify it under the terms of the GNU General Public License as
////  published by the Free Software Foundation; either version 3 of the
////  License.
////
////  This program is distributed in the hope that it will be useful,
////  but WITHOUT ANY WARRANTY; without even the implied warranty of
////  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
////  General Public License for more details.
////
////  You should have received a copy of the GNU General Public License along
////  with this program; if not, write to the Free Software Foundation, Inc.,
////  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
////
////
////
//
//import Foundation
//
//extension LastChatsViewController: AddContactDelegate {
//    func didAddContact(owner: String, jid: String, entity: RosterItemEntity, conversationType: ClientSynchronizationManager.ConversationType) {
//        getAppTabBar()?.displayChat(
//            owner: owner,
//            jid: jid,
//            entity: entity,
//            conversationType: conversationType
//        )
//    }
//}

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

class SpecialMessageTableViewCell: UITableViewCell {
    static let cellName: String = "SpecialMessageTableViewCell"
    
    let contentStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
//        stack.distribution = .fill
        stack.alignment = .center
        stack.spacing = 8
        
        return stack
    }()
    
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .label
        
        return label
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        
        return label
    }()
    
    internal let cancelButton: UIButton = {
//        var configuration = UIButton.Configuration.plain()
//        
//        configuration.buttonSize = .mini
//        configuration.image = imageLiteral("xmark")
//        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
//        configuration.imagePadding = 12
//        configuration.imagePlacement = NSDirectionalRectEdge.all
//        
//        let button = UIButton(configuration: configuration, primaryAction: nil)
//
//        button.tintColor = .systemGray
//        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
//        button.setContentHuggingPriority(.defaultHigh, for: .vertical)
//        
//        return button
        let button = UIButton(frame: CGRect(square: 24))
        
        button.setImage(imageLiteral("xmark"), for: .normal)
        button.contentMode = .scaleAspectFit
        button.tintColor = .systemGray
        button.imageEdgeInsets = UIEdgeInsets(top: 12, bottom: 12, left: 12, right: 12)
        
        return button
    }()
    
    let avatarStack: UIView = {
        let view = UIView()
        
        return view
    }()
    
    let avatarStackContainer: UIView = {
        let stack = UIView()
        
        return stack
    }()
    
    override func prepareForReuse() {
        super.prepareForReuse()
        self.titleLabel.text = nil
        self.subtitleLabel.text = nil
        self.avatarStack.subviews.forEach { $0.removeFromSuperview() }
    }
    
    open var closeCallback: ((String) -> Void)? = nil
    
    var key: String = ""
    
    @objc
    private final func onCancelButtonTouchUpInside(_ sender: UIButton) {
        self.closeCallback?(self.key)
    }
    
    func configure(title: String, subtitle: String, avatars: [AvatarStructItem], owner: String, showTopLine: Bool, key: String) {
        self.key = key
        self.titleLabel.text = title
        self.subtitleLabel.text  = subtitle
        var offset: CGFloat = 0
        var avatarsViews: [UIView] = []
        let offsetConst: CGFloat = 12
        if showTopLine {
            self.topLine.isHidden = false
        } else {
            self.topLine.isHidden = true
        }
        self.contentView.backgroundColor = AccountColorManager.shared.palette(for: owner).tint50.withAlphaComponent(0.5)
//        backgroundColorView.backgroundColor = AccountColorManager.shared.palette(for: owner).tint50.withAlphaComponent(0.5)
        avatars.forEach {
            avatar in
            
            let avatarContainer = UIView(frame: CGRect(
                    origin: CGPoint(x: offset, y: 0),
                    size: CGSize(square: 32)
                )
            )
            avatarContainer.backgroundColor = .white
            if let image = UIImage(named: AccountMasksManager.shared.mask32pt)?.resize(targetSize: CGSize(square: 32)), AccountMasksManager.shared.load() != "square" {
                avatarContainer.mask = UIImageView(image: image)
            } else {
                avatarContainer.mask = nil
            }
            
            let avatarView: UIImageView = {
                let view = UIImageView(frame: CGRect(
                        origin: CGPoint(x: 1, y: 1),
                        size: CGSize(square: 30)
                    )
                )
                offset += offsetConst
                if let image = UIImage(named: AccountMasksManager.shared.mask32pt)?.resize(targetSize: CGSize(square: 30)), AccountMasksManager.shared.load() != "square" {
                    view.mask = UIImageView(image: image)
                } else {
                    view.mask = nil
                }
                view.contentMode = .scaleAspectFill
                
                return view
            }()
            avatarContainer.addSubview(avatarView)
            if avatar.isGroup {
                DefaultAvatarManager.shared.getGroupAvatar(url: avatar.url, userId: avatar.uuid, jid: avatar.jid, owner: avatar.owner, size: 30) { image in
                    if let image = image {
                        avatarView.image = image
                    } else {
                        avatarView.image = UIImageView.getDefaultAvatar(for: avatar.name, owner: avatar.owner, size: 30)
                    }
                }
            } else {
                DefaultAvatarManager.shared.getAvatar(url: avatar.url, jid: avatar.jid, owner: avatar.owner, size: 30) { image in
                    if let image = image {
                        avatarView.image = image
                    } else {
                        avatarView.image = UIImageView.getDefaultAvatar(for: avatar.name, owner: avatar.owner, size: 30)
                    }
                }
            }
            
            
            avatarStack.addSubview(avatarContainer)
            avatarsViews.append(avatarContainer)
            avatarsViews.reversed().forEach { avatarStack.bringSubviewToFront($0) }
            
            if avatarsViews.isEmpty {
                avatarStack.isHidden = true
            } else {
                avatarStack.isHidden = false
                let width: CGFloat = offset + (32 - offsetConst)
                avatarStack.frame = CGRect(
                    origin: CGPoint(x: (64 - width) / 2, y: 6),
                    size: CGSize(width: width, height: 32)
                )
            }
        }
    }
    
    let backgroundColorView: UIView = {
        let view = UIView()
        
        view.layer.cornerRadius = 16
        view.layer.masksToBounds = true
        
        return view
    }()
    
    let topLine: UIView = {
        let view = UIView()
        
        view.backgroundColor = UIColor.black.withAlphaComponent(0.21)
        
        return view
    }()
    
    func setupSubviews() {
        self.contentView.backgroundColor = .clear
        self.contentView.layer.cornerRadius = 8
        self.contentView.layer.masksToBounds = true
//        self.contentView.addSubview(backgroundColorView)
        self.contentView.addSubview(self.contentStack)
//        backgroundColorView.fillSuperviewWithOffset(top: 2, bottom: 2, left: 16, right: 16)
        self.avatarStackContainer.frame = CGRect(origin: CGPoint(x: 16, y: 2), size: CGSize(width: 64, height: 44))
        self.contentView.addSubview(avatarStackContainer)
        self.avatarStackContainer.addSubview(avatarStack)
//        self.contentView.addSubview(self.avatarStack)
        self.selectionStyle = .none
        self.contentStack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 96, right: 4)
//        self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 96, right: 20)
        self.contentStack.addArrangedSubview(self.stack)
        self.contentStack.addArrangedSubview(self.cancelButton)
        self.stack.addArrangedSubview(self.titleLabel)
        self.stack.addArrangedSubview(self.subtitleLabel)
        separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 0)
        self.contentView.addSubview(self.topLine)
        self.topLine.frame = CGRect(origin: CGPoint.zero, size: CGSize(width: UIScreen.main.bounds.width, height: 1.0 / UIScreen.main.scale))
//        self.accessoryType = .disclosureIndicator
        NSLayoutConstraint.activate([
            self.cancelButton.widthAnchor.constraint(equalToConstant: 36),
            self.cancelButton.heightAnchor.constraint(equalToConstant: 36)
        ])
        self.cancelButton.addTarget(self, action: #selector(onCancelButtonTouchUpInside), for: .touchUpInside)
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.setupSubviews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupSubviews()
    }
    
}


