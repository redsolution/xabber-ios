//
//  NotificationsListViewController+ItemCell.swift
//  xabber
//
//  Created by Игорь Болдин on 02.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

extension NotificationsListViewController {
    class NotificationItemCell: UITableViewCell {
        static let cellName = "NotificationItemCell"
        static let badgeSize: CGFloat = 24
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.distribution = .fill
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 0, right: 0)
            
            return stack
        }()
        
        let avatarContainer: UIView = {
            let view = UIView(frame: CGRect(square: 64))
            
            view.backgroundColor = .clear
            
            return view
        }()
        
        let userImageView: UIView = {
            let view = UIView(frame: CGRect(square: 64))
            
            view.backgroundColor = .clear//MDCPalette.grey.tint200
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image.upscale(dimension: 64))
            } else {
                view.mask = nil
            }
            
            return view
        }()
        
        let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 64))
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
            view.contentMode = .scaleAspectFill
            
            view.backgroundColor = MDCPalette.grey.tint200
            
            return view
        }()
        

        
        let titleLabel: UILabel = {
            let label = UILabel()
            
//            label.textColor = UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha:1)

            label.font = UIFont.systemFont(ofSize: 17, weight: .medium)
            label.numberOfLines = 0
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        let messageLabel: UILabel = {
            let label = UILabel()
            
    //            label.backgroundColor = .white
            
            label.lineBreakMode = .byWordWrapping
            label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            
            return label
        }()
                
        let badgeIndicator: UIImageView = {
            let view = UIImageView(frame: CGRect(x: 62.5 - NotificationItemCell.badgeSize, y: 62.5 - NotificationItemCell.badgeSize, width: NotificationItemCell.badgeSize, height: NotificationItemCell.badgeSize))
            
            view.layer.cornerRadius = NotificationItemCell.badgeSize / 2
            view.layer.masksToBounds = true
            view.backgroundColor = .systemBackground
            
            return view
        }()
        
        let badgeIcon: UIImageView = {
            let view = UIImageView(frame: CGRect(0, 0, NotificationItemCell.badgeSize, NotificationItemCell.badgeSize))
            
            view.tintColor = MDCPalette.green.tint700
            view.contentMode = .center
            
            return view
        }()
                
        var currentUrl: String? = nil
        
        public func configure(jid: String, owner: String, avatarUrl: String?, icon: String, title: NSAttributedString, date: Date) {

            if currentUrl != avatarUrl || currentUrl == nil {
                currentUrl = avatarUrl
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 56) { image in
                    if let image = image {
                        self.avatarView.image = image
                    } else {
                        self.avatarView.image = UIImageView.getDefaultAvatar(for: owner, owner: owner, size: 56)
                    }
                }
            }
            
            
            self.badgeIcon.image = imageLiteral(icon, dimension: NotificationItemCell.badgeSize + 2)
            
            let dateFormatter = DateFormatter()
            
            dateFormatter.dateFormat = "HH:mm"
                        
            accessoryType = .disclosureIndicator
            titleLabel.attributedText = title
            messageLabel.text = dateFormatter.string(from: date)
        }
        
        internal final func setMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt), AccountMasksManager.shared.load() != "square" {
                avatarView.mask = UIImageView(image: image)
                userImageView.mask = UIImageView(image: image.upscale(dimension: 60))
            } else {
                avatarView.mask = nil
                userImageView.mask = nil
            }
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()

        }
        
        private func setupSubviews() {
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 8, bottom: 8, left: 96, right: 18)
            
            backgroundColor = .systemBackground
            
            badgeIndicator.addSubview(badgeIcon)
            avatarContainer.frame = CGRect(x: 16, y: 10, width: 64, height: 64)
            avatarContainer.addSubview(userImageView)
            avatarView.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
            contentView.addSubview(avatarContainer)
            userImageView.addSubview(avatarView)
            avatarContainer.addSubview(badgeIndicator)
            avatarContainer.bringSubviewToFront(badgeIndicator)
            
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(messageLabel)
            
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 96, right: 0)
            activateConstraints()
        }
        
        private func activateConstraints() {
            NSLayoutConstraint.activate([
                stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 64)
            ])
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupSubviews()
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            self.setupSubviews()
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
            self.setupSubviews()
        }
    }
}
