//
//  ChatViewController+DateView.swift
//  xabber
//
//  Created by Игорь Болдин on 27.12.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension ChatViewController {
    class FloatDateView: UIView {
        var primary: String = ""
        var text: NSAttributedString = NSAttributedString()
        var naturalIndex: Int = 0
        var isPinned: Bool = false
        var hiddenDate: Bool? = nil
        let messageLabelInsets = UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        let contentView: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            
            return stack
        }()
        
        let messageLabel: MessageLabel = {
            let label = MessageLabel()
            
            return label
        }()
        
        func updateContent() {
            self.messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.2)
            self.messageLabel.textInsets = messageLabelInsets
            self.messageLabel.attributedText = self.text
            self.messageLabel.textAlignment = .center
            let constraintBox = CGSize(width: UIScreen.main.bounds.width, height: .greatestFiniteMagnitude)
            let dateRect = text.boundingRect(with: constraintBox, options: [
                .usesLineFragmentOrigin,
                .usesFontLeading
            ], context: nil).integral
            
            let frame = CGRect(
                x: 0,
                y: 4,
                width: dateRect.width + self.messageLabelInsets.horizontal,
                height: dateRect.height + self.messageLabelInsets.vertical
            )
            self.messageLabel.frame = frame
            self.messageLabel.center.x = self.center.x
            self.messageLabel.layer.cornerRadius = frame.height / 2
            self.messageLabel.layer.masksToBounds = true
            self.layoutSubviews()
        }
        
        func configure(_ text: NSAttributedString) {
            if text != self.text {
                self.text = text
                self.updateContent()
            }
        }
        
        func setupSubviews() {
            addSubview(messageLabel)
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func updateCenterIfNotAPinned(_ center: CGPoint) {
            if self.isPinned {
                return
            }
            self.center = center
            self.layoutIfNeeded()
        }
        
        func updateFrameIfNotAPinned(_ frame: CGRect) {
            if self.isPinned {
                return
            }
            self.frame = frame
            self.messageLabel.center.x = self.center.x
            self.layoutSubviews()
//            self.updateContent()
        }
        
        func show() {
            if let hiddenDate = hiddenDate,
               hiddenDate == false {
                return
            }
            self.hiddenDate = false
            UIView.animate(withDuration: 0.6, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.1, options: [.curveEaseIn]) {
                self.alpha = 1.0
            } completion: { _ in
            }
        }
        
        func hide(fast: Bool = false, withoutAnimation: Bool = false) {
            if let hiddenDate = hiddenDate,
               hiddenDate == true {
                return
            }
            self.hiddenDate = true
            if withoutAnimation {
                UIView.performWithoutAnimation {
                    self.alpha = 0.0
                }
            } else {
                UIView.animate(withDuration: fast ? 0.1 : 1.0, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.1, options: [.curveEaseIn]) {
                    self.alpha = 0.0
                } completion: { _ in
                    
                }
            }
        }
    }

    class UnreadMentionsNavigatorView: UIView {
        var onBadgeTap: (() -> Void)?

        private(set) var preferredSize = CGSize(width: 44, height: 44)
        private(set) var mode: ChatUnreadMentionNavigatorMode = .hidden
        internal private(set) var currentUnreadCountText: String? = nil

        private let badgeButton = UIButton(type: .system)
        private let surfaceColor = UIColor.systemBackground.withAlphaComponent(0.98)
        private let countBadgeLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
            label.textAlignment = .center
            label.textColor = .white
            label.backgroundColor = .systemBlue
            label.layer.cornerRadius = 10
            label.layer.masksToBounds = true
            label.isHidden = true
            return label
        }()

        var showsDirectionalButtons: Bool {
            false
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.setupSubviews()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupSubviews() {
            self.clipsToBounds = false

            self.badgeButton.translatesAutoresizingMaskIntoConstraints = false
            self.badgeButton.setTitle("@", for: .normal)
            self.badgeButton.backgroundColor = self.surfaceColor
            self.badgeButton.layer.cornerRadius = 22
            self.badgeButton.layer.masksToBounds = false
            self.badgeButton.tintColor = .systemBlue
            self.badgeButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .bold)
            self.badgeButton.layer.shadowColor = UIColor.black.withAlphaComponent(0.16).cgColor
            self.badgeButton.layer.shadowOffset = CGSize(width: 0, height: 5)
            self.badgeButton.layer.shadowRadius = 12
            self.badgeButton.layer.shadowOpacity = 1
            self.badgeButton.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            self.badgeButton.accessibilityLabel = "Unread mentions"
            self.badgeButton.accessibilityIdentifier = "chat-unread-mentions-button"

            self.addSubview(self.badgeButton)
            self.badgeButton.addSubview(self.countBadgeLabel)

            self.countBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
            self.countBadgeLabel.accessibilityIdentifier = "chat-unread-mentions-count"
            self.countBadgeLabel.layer.borderWidth = 2

            NSLayoutConstraint.activate([
                self.badgeButton.topAnchor.constraint(equalTo: self.topAnchor),
                self.badgeButton.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                self.badgeButton.trailingAnchor.constraint(equalTo: self.trailingAnchor),
                self.badgeButton.bottomAnchor.constraint(equalTo: self.bottomAnchor),
                self.countBadgeLabel.heightAnchor.constraint(equalToConstant: 20),
                self.countBadgeLabel.centerXAnchor.constraint(equalTo: self.badgeButton.trailingAnchor, constant: -7),
                self.countBadgeLabel.centerYAnchor.constraint(equalTo: self.badgeButton.topAnchor, constant: 7),
                self.countBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
            ])
        }

        @objc
        private func buttonTapped(_ sender: UIButton) {
            if sender === self.badgeButton {
                self.onBadgeTap?()
            }
        }

        func update(
            mode: ChatUnreadMentionNavigatorMode,
            unreadCount: Int,
            accentColor: UIColor
        ) {
            self.mode = mode
            self.badgeButton.tintColor = accentColor
            self.countBadgeLabel.backgroundColor = accentColor
            self.badgeButton.backgroundColor = self.surfaceColor
            self.countBadgeLabel.layer.borderColor = self.surfaceColor.cgColor

            let unreadText = unreadCount > 99 ? "99+" : "\(unreadCount)"
            self.currentUnreadCountText = unreadCount > 0 ? unreadText : nil
            self.countBadgeLabel.text = unreadText
            self.countBadgeLabel.isHidden = unreadCount <= 0
            self.badgeButton.accessibilityValue = unreadCount > 0 ? unreadText : nil
            self.preferredSize = CGSize(width: 44, height: 44)
        }
    }
}
