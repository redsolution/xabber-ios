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
        private enum Metrics {
            static let size: CGFloat = NativeGlassBarStyle.buttonSize
            static let countBadgeSize: CGFloat = 20
            static let countBadgeBorderWidth: CGFloat = 2
            static let countBadgeBorderColor = UIColor.systemBackground.withAlphaComponent(0.88)
        }

        var onBadgeTap: (() -> Void)?

        private(set) var preferredSize = CGSize(square: Metrics.size)
        private(set) var mode: ChatUnreadMentionNavigatorMode = .hidden
        internal private(set) var currentUnreadCountText: String? = nil

        private let badgeButton = UIButton(type: .system)
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
            let initialFrame = frame.size == .zero
                ? CGRect(origin: frame.origin, size: CGSize(square: Metrics.size))
                : frame
            super.init(frame: initialFrame)
            self.setupSubviews()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupSubviews() {
            self.clipsToBounds = false

            self.badgeButton.translatesAutoresizingMaskIntoConstraints = false
            self.badgeButton.setTitle(nil, for: .normal)
            self.badgeButton.setImage(imageLiteral("at", dimension: NativeGlassBarStyle.iconSize), for: .normal)
            self.badgeButton.tintColor = .systemBlue
            NativeGlassBarStyle.applyDetachedIconButtonStyle(
                to: self.badgeButton,
                tintColor: .systemBlue,
                image: imageLiteral("at", dimension: NativeGlassBarStyle.iconSize)
            )
            self.badgeButton.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            self.badgeButton.accessibilityLabel = "Unread mentions"
            self.badgeButton.accessibilityIdentifier = "chat-unread-mentions-button"

            self.addSubview(self.badgeButton)
            self.badgeButton.addSubview(self.countBadgeLabel)

            self.countBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
            self.countBadgeLabel.accessibilityIdentifier = "chat-unread-mentions-count"
            self.countBadgeLabel.layer.borderWidth = Metrics.countBadgeBorderWidth
            self.countBadgeLabel.layer.borderColor = Metrics.countBadgeBorderColor.cgColor

            NSLayoutConstraint.activate([
                self.badgeButton.topAnchor.constraint(equalTo: self.topAnchor),
                self.badgeButton.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                self.badgeButton.trailingAnchor.constraint(equalTo: self.trailingAnchor),
                self.badgeButton.bottomAnchor.constraint(equalTo: self.bottomAnchor),
                self.countBadgeLabel.topAnchor.constraint(equalTo: self.badgeButton.topAnchor),
                self.countBadgeLabel.trailingAnchor.constraint(equalTo: self.badgeButton.trailingAnchor),
                self.countBadgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: self.badgeButton.leadingAnchor),
                self.countBadgeLabel.heightAnchor.constraint(equalToConstant: Metrics.countBadgeSize),
                self.countBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.countBadgeSize)
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
            NativeGlassBarStyle.applyDetachedIconButtonStyle(
                to: self.badgeButton,
                tintColor: accentColor,
                image: imageLiteral("at", dimension: NativeGlassBarStyle.iconSize)
            )
            self.countBadgeLabel.backgroundColor = accentColor
            self.countBadgeLabel.layer.borderColor = Metrics.countBadgeBorderColor.cgColor

            let unreadText = unreadCount > 99 ? "99+" : "\(unreadCount)"
            self.currentUnreadCountText = unreadCount > 0 ? unreadText : nil
            self.countBadgeLabel.text = unreadText
            self.countBadgeLabel.isHidden = unreadCount <= 0
            self.badgeButton.accessibilityValue = unreadCount > 0 ? unreadText : nil
            self.preferredSize = CGSize(square: Metrics.size)
        }
    }
}
