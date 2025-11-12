//
//  ContactItemCell.swift
//  xabber
//
//  Created by Admin on 26.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

extension NotificationsSubscribtionsListViewController {
    class ContactItemCell: UITableViewCell {
        class MessageView: UIView {
            let view: UIView = {
                let view = UIView()
                
                //            let layer = CAShapeLayer()
                //            layer.strokeColor = MDCPalette.deepPurple.tint700.cgColor
                //            layer.lineWidth = 1
                //            layer.lineDashPattern = [2, 2]
                //            layer.fillColor = nil
                
                view.layer.borderColor = MDCPalette.deepPurple.tint400.cgColor
                view.layer.borderWidth = 1
                view.layer.cornerRadius = 10
                
                return view
            }()
            
            let stack: UIStackView = {
                let stack = UIStackView()
                stack.axis = .horizontal
                stack.alignment = .center
                stack.translatesAutoresizingMaskIntoConstraints = false
                
                return stack
            }()
            
            
            let label: UILabel = {
                let label = UILabel()
                label.numberOfLines = 0
                label.font = .systemFont(ofSize: 14)
                label.textColor =  MDCPalette.deepPurple.tint700
                
                return label
            }()
            
            
            let quoteOpening: UIImageView = {
                let imageView = UIImageView(image: UIImage(systemName: "quote.opening")?.withTintColor(MDCPalette.deepPurple.tint700))
                imageView.image = imageView.image?.resize(targetSize: CGSize(square: 15))
                imageView.translatesAutoresizingMaskIntoConstraints = false
                
                return imageView
            }()
            
            let quoteClosing: UIImageView = {
                let imageView = UIImageView(image: UIImage(systemName: "quote.closing")?.withTintColor(MDCPalette.deepPurple.tint700))
                imageView.image = imageView.image?.resize(targetSize: CGSize(square: 15))
                imageView.translatesAutoresizingMaskIntoConstraints = false
                
                return imageView
            }()
            
            override init(frame: CGRect) {
                super.init(frame: .zero)
                setupSubviews()
                activateConstraints()
            }
            
            required init?(coder: NSCoder) {
                super.init(coder: coder)
                setupSubviews()
                activateConstraints()
            }
            
            func setupSubviews() {
                view.addSubview(stack)
                view.addSubview(quoteOpening)
                view.addSubview(quoteClosing)
                stack.addArrangedSubview(label)
            }
            
            func configure(_ message: NSAttributedString?) {
                self.label.attributedText = message
            }
            
            func activateConstraints() {
                NSLayoutConstraint.activate([
                    quoteOpening.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
                    quoteOpening.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 5),
                    
                    quoteClosing.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
                    quoteClosing.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -5),
                    
                    stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
                    stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
                    stack.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 25),
                    stack.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -25),
                ])
            }
        }
        
        static let cellName = "ContactItemCell"
        
        static let badgeSize: CGFloat = 24
        var jid: String = ""
        var owner: String = ""
        var uuid: String = ""
        var addButtonAction: ((_ jid: String, _ owner: String, _ uuid: String) -> Void)?
        var declineButtonAction: ((_ jid: String, _ owner: String, _ uuid: String) -> Void)?
        
        let stack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 6
            
            return stack
        }()
        
        let avatarContainer: UIView = {
            let view = UIView(frame: CGRect(square: 64))
            view.backgroundColor = .clear
            
            return view
        }()
        
        let userImageView: UIView = {
            let view = UIView(frame: CGRect(square: 64))
            
            view.backgroundColor = .clear
            
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
        
        let badgeIndicator: UIImageView = {
            let view = UIImageView(frame: CGRect(x: 62.5 - ContactItemCell.badgeSize, y: 62.5 - ContactItemCell.badgeSize, width: ContactItemCell.badgeSize, height: ContactItemCell.badgeSize))
            
            view.layer.cornerRadius = ContactItemCell.badgeSize / 2
            view.layer.masksToBounds = true
            view.backgroundColor = .systemBackground
            
            return view
        }()
        
        let badgeIcon: UIImageView = {
            let view = UIImageView(frame: CGRect(0, 0, ContactItemCell.badgeSize, ContactItemCell.badgeSize))
            
            view.tintColor = MDCPalette.green.tint700
            view.contentMode = .center
            
            return view
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            label.font = .systemFont(ofSize: label.font.pointSize, weight: .medium)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        let subtitleLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 14)
            label.textColor = .secondaryLabel
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        var messageView: MessageView? = nil
        
        let buttonsStack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .horizontal
//            stack.distribution = .equalSpacing
            
            return stack
        }()
        
        let addButton: UIButton = {
            let button = UIButton()
            var config = UIButton.Configuration.filled()
            config.baseBackgroundColor = .tintColor
            button.configuration = config
            
            return button
        }()
        
        let declineButton: UIButton = {
            let button = UIButton()
            var config = UIButton.Configuration.plain()
            config.baseForegroundColor = .tintColor
            
            button.configuration = config
            
            return button
        }()
        
        let dimmedView: UIView = {
            let view = UIView(frame: .zero)
            
            view.backgroundColor = MDCPalette.grey.tint50
            
            return view
        }()
        
        func setupSubviews() {
            badgeIndicator.addSubview(badgeIcon)
            contentView.addSubview(dimmedView)
            dimmedView.fillSuperview()
            contentView.addSubview(avatarContainer)
            avatarContainer.frame = CGRect(x: 16, y: 10, width: 64, height: 64)
            avatarContainer.addSubview(userImageView)
            
            userImageView.addSubview(avatarView)
            avatarContainer.addSubview(badgeIndicator)
            avatarContainer.bringSubviewToFront(badgeIndicator)
            
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 10, bottom: 10, left: 96, right: 0)
            
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(subtitleLabel)
            if messageView != nil {
                stack.addArrangedSubview(messageView!)
            }
            stack.addArrangedSubview(buttonsStack)
            
            buttonsStack.addArrangedSubview(addButton)
            buttonsStack.addArrangedSubview(declineButton)
            buttonsStack.addArrangedSubview(UIStackView())
            
            addButton.addTarget(self, action: #selector(addButtonPressed), for: .touchUpInside)
            declineButton.addTarget(self, action: #selector(declineButtonPressed), for: .touchUpInside)
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 96, right: 0)
        }
        
        func configure(owner: String, username: NSAttributedString, jid: String, message: NSAttributedString? = nil, icon: String, avatarUrl: String? = nil, uuid: String, isRead: Bool) {
            DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 64) { image in
                if let image = image {
                    self.avatarView.image = image
                } else {
                    self.avatarView.image = UIImageView.getDefaultAvatar(for: username.string, owner: owner, size: 64)
                }
            }
            dimmedView.backgroundColor = AccountColorManager.shared.palette(for: owner).tint50
            updateReadState(isRead, animated: false)
            titleLabel.attributedText = username
            subtitleLabel.text = jid
            if let message = message {
                messageView = MessageView(frame: .zero)
                messageView?.configure(message)
            }
            
            addButton.setTitle("Add contact", for: .normal)
            declineButton.setTitle("Decline", for: .normal)
            badgeIcon.image = imageLiteral(icon, dimension: ContactItemCell.badgeSize + 2)
            self.jid = jid
            self.owner = owner
            self.uuid = uuid
        }
        
        public final func updateReadState(_ state: Bool, animated: Bool) {
            func transaction(_ block: @escaping (() -> Void)) {
                if animated {
                    UIView.animate(
                        withDuration: 0.3,
                        delay: 0.0,
                        usingSpringWithDamping: 0.7,
                        initialSpringVelocity: 0.4,
                        options: [.curveLinear],
                        animations: block,
                        completion: nil)
                } else {
                    block()
                }
            }
            transaction {
                if state {
                    self.dimmedView.alpha = 0.0
                } else {
                    self.dimmedView.alpha = 1.0
                }
            }
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
        }
        
        @objc
        private func addButtonPressed() {
            addButtonAction?(self.jid, self.owner, self.uuid)
        }
        
        @objc
        private func declineButtonPressed() {
            declineButtonAction?(self.jid, self.owner, self.uuid)
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
