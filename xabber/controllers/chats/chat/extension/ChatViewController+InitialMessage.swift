//
//  ChatViewController+InitialMessage.swift
//  xabber
//
//  Created by Игорь Болдин on 17.06.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents

extension ChatViewController {
    class InitialMessageOverlayView: UIView {
        internal let containerView: UIView = {
            let view = UIView(frame: .zero)
            
            view.backgroundColor = .clear
            
            return view
        }()
        
        internal let containerStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.spacing = 8
            stack.alignment = .center
            stack.distribution = .fill
            
            return stack
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel(frame: .zero)
            label.numberOfLines = 1
            label.lineBreakMode = .byWordWrapping
            label.textAlignment = .center
            label.textColor = .label
            label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
            return label
        }()
        
        internal let descriptionLabel: UILabel = {
            let label = UILabel(frame: .zero)
            
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.textAlignment = .center
            label.textColor = .label
            label.font = UIFont.systemFont(ofSize: 16, weight: .regular)
            
            return label
        }()
        
        internal let iconButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 64))
            
            button.backgroundColor = .white
            
            return button
        }()
        
        internal let learnmoreButton: UIButton = {
            let button = UIButton(frame: .zero)
            
            button.setTitle("learn more", for: .normal)
            button.setTitleColor(.tintColor, for: .normal)
            
            return button
        }()
        
        let blurredEffectView: UIVisualEffectView = {
            let blurEffect = UIBlurEffect(style: .systemMaterial)
            let blurredEffectView = UIVisualEffectView(effect: blurEffect)
            
            return blurredEffectView
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            self.setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setup()
        }
        
        private func setup() {
            self.addSubview(self.containerView)
            self.containerView.addSubview(blurredEffectView)
            self.containerView.addSubview(self.containerStack)
            self.containerStack.fillSuperviewWithOffset(top: 40, bottom: 8, left: 8, right: 8)
            
            self.containerStack.addArrangedSubview(self.titleLabel)
            self.containerStack.addArrangedSubview(self.descriptionLabel)
            self.containerStack.addArrangedSubview(self.learnmoreButton)
            self.addSubview(self.iconButton)
        }
        
        public func update(frame: CGRect, conversationType: ClientSynchronizationManager.ConversationType, privacy: GroupChatStorageItem.Privacy? = nil, peerToPeer: Bool? = nil) {
            self.frame = frame
            self.containerView.layer.cornerRadius = 8
            self.containerView.layer.masksToBounds = true
            let width: CGFloat = 320
            let height: CGFloat = 232
            self.containerView.frame = CGRect(
                origin: CGPoint(x: (frame.width - width) / 2, y: (frame.height - height) / 2),
                size: CGSize(width: width, height: height)
            )
            let iconButtonSize: CGFloat = 64
            self.iconButton.frame = CGRect(
                origin: CGPoint(x: (frame.width - iconButtonSize) / 2, y: (frame.height - height) / 2 - (iconButtonSize / 2)),
                size: CGSize(square: iconButtonSize)
            )
            self.iconButton.layer.cornerRadius = iconButtonSize / 2
            self.iconButton.layer.masksToBounds = true
            
            self.blurredEffectView.frame = self.containerView.bounds
            
            NSLayoutConstraint.activate([
                titleLabel.heightAnchor.constraint(equalToConstant: 24),
                learnmoreButton.heightAnchor.constraint(equalToConstant: 24)
            ])
            switch conversationType {
                case .regular:
                    self.iconButton.setImage(imageLiteral("person.fill", dimension: 28), for: .normal)
                    self.titleLabel.text = "Regular chat".localizeString(id: "intro_regular_chat", arguments: [])
                    self.descriptionLabel.text = "Messages in this chat are not encrypted. Servers often store transient messages in an archive. This allows easy device synchronization and server-side history search, but adds privacy risks.".localizeString(id: "intro_regular_chat_text", arguments: [])
                    let string = NSAttributedString(string: "Learn more about messaging".localizeString(id: "intro_regular_chat_learn", arguments: []), attributes: [
                        .foregroundColor: UIColor.tintColor,
                        .font: UIFont.systemFont(ofSize: 14, weight: .regular)
                    ])
                    self.learnmoreButton.setAttributedTitle(string, for: .normal)
//                    self.learnmoreButton.setTitle(string.string, for: .normal)
                case .group:
                    if let privacy = privacy, let peerToPeer = peerToPeer {
                        if peerToPeer {
                            self.iconButton.setImage(imageLiteral("person.line.dotted.person", dimension: 28), for: .normal)
                            self.titleLabel.text = "Private chat".localizeString(id: "intro_private_chat", arguments: [])
                            self.descriptionLabel.text = "Private chat with incognito user. Messages are routed through group server and your identities are kept secret from each other. Be vigilant, do not disclose yourself by being careless.".localizeString(id: "intro_private_chat_text", arguments: [])
                            self.learnmoreButton.setAttributedTitle(NSAttributedString(string: "Learn more about private chats".localizeString(id: "intro_private_chat_learn", arguments: []), attributes: [
                                .foregroundColor: UIColor.tintColor,
                                .font: UIFont.systemFont(ofSize: 14, weight: .regular)
                            ]), for: .normal)
                        } else {
                            switch privacy {
                                case .incognito:
                                    self.iconButton.setImage(imageLiteral("person.2", dimension: 28), for: .normal)
                                    self.titleLabel.text = "Incognito group".localizeString(id: "intro_incognito_group", arguments: [])
                                    self.descriptionLabel.text = "Identities of users in this group are kept hidden from each other, only group admins can access your real XMPP ID. Be vigilant, do not disclose yourself by being careless.".localizeString(id: "intro_incognito_group_text", arguments: [])
                                    self.learnmoreButton.setAttributedTitle(NSAttributedString(string: "Learn more about incognito groups".localizeString(id: "intro_incognito_group_learn", arguments: []), attributes: [
                                        .foregroundColor: UIColor.tintColor,
                                        .font: UIFont.systemFont(ofSize: 14, weight: .regular)
                                    ]), for: .normal)
                                case .publicChat, .none:
                                    self.iconButton.setImage(imageLiteral("person.2.fill", dimension: 28), for: .normal)
                                    self.titleLabel.text = "Public group".localizeString(id: "intro_public_group", arguments: [])
                                    self.descriptionLabel.text = "Identities of users in this group are public, so any member can contact you using your real XMPP ID.".localizeString(id: "intro_public_group_text", arguments: [])
                                    self.learnmoreButton.setAttributedTitle(NSAttributedString(string: "Learn more about public groups".localizeString(id: "intro_public_group_learn", arguments: []), attributes: [
                                        .foregroundColor: UIColor.tintColor,
                                        .font: UIFont.systemFont(ofSize: 14, weight: .regular)
                                    ]), for: .normal)
                            }
                        }
                    } else {
                        self.iconButton.setImage(imageLiteral("person.2.fill", dimension: 28), for: .normal)
                        self.titleLabel.text = "Public group".localizeString(id: "intro_public_group", arguments: [])
                        self.descriptionLabel.text = "Identities of users in this group are public, so any member can contact you using your real XMPP ID.".localizeString(id: "intro_public_group_text", arguments: [])
                        self.learnmoreButton.setAttributedTitle(NSAttributedString(string: "Learn more about public groups".localizeString(id: "intro_public_group_learn", arguments: []), attributes: [
                            .foregroundColor: UIColor.tintColor,
                            .font: UIFont.systemFont(ofSize: 14, weight: .regular)
                        ]), for: .normal)
                    }
                case .channel:
                    break
                case .omemo, .omemo1, .axolotl:
                    self.iconButton.setImage(imageLiteral("person.badge.shield.checkmark.fill", dimension: 28), for: .normal)
                    self.titleLabel.text = "Encrypted chat".localizeString(id: "intro_encrypted_chat", arguments: [])
                    self.descriptionLabel.text = "Messages in this chat are encrypted with end-to-end encryption. You must always confirm the identity of your contact by verifying encryption keys fingerprints.".localizeString(id: "intro_encrypted_chat_text", arguments: [])
                    self.learnmoreButton.setAttributedTitle(NSAttributedString(string: "Learn more about encrypted chats".localizeString(id: "intro_encrypted_chat_learn", arguments: []), attributes: [
                        .foregroundColor: UIColor.tintColor,
                        .font: UIFont.systemFont(ofSize: 14, weight: .regular)
                    ]), for: .normal)
                case .notifications:
                    break
                case .saved:
                    break
            }
        }
    }
}
