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
    enum InitialMessageOverlayLayoutPolicy {
        private static let preferredSize = CGSize(width: 340, height: 340)
        private static let horizontalMargin: CGFloat = 16
        private static let verticalMargin: CGFloat = 12

        static func frame(
            viewBounds: CGRect,
            safeAreaInsets: UIEdgeInsets,
            inputTopY: CGFloat
        ) -> CGRect {
            guard viewBounds.width > 0, viewBounds.height > 0 else {
                return .zero
            }

            let availableTop = viewBounds.minY + max(0, safeAreaInsets.top) + verticalMargin
            let safeBottom = viewBounds.maxY - max(0, safeAreaInsets.bottom)
            let inputLimit = inputTopY.isFinite ? inputTopY : safeBottom
            let availableBottom = min(safeBottom, inputLimit) - verticalMargin
            let availableWidth = max(0, viewBounds.width - horizontalMargin * 2)
            let availableHeight = max(0, availableBottom - availableTop)

            guard availableWidth > 0, availableHeight > 0 else {
                return CGRect(x: viewBounds.midX, y: availableTop, width: 0, height: 0)
            }

            let width = min(preferredSize.width, availableWidth)
            let height = min(preferredSize.height, availableHeight)
            return CGRect(
                x: viewBounds.midX - width / 2,
                y: availableTop + (availableHeight - height) / 2,
                width: width,
                height: height
            )
        }
    }

    internal func updateInitialMessageOverlayFrame() {
        guard self.shouldShowInitialMessage.value,
              self.initialMessageOverlayView.superview != nil,
              self.view.bounds.width > 0,
              self.view.bounds.height > 0 else {
            return
        }

        let inputTopY = currentInputTopYForInitialMessageOverlay()
        let frame = InitialMessageOverlayLayoutPolicy.frame(
            viewBounds: self.view.bounds,
            safeAreaInsets: self.view.safeAreaInsets,
            inputTopY: inputTopY
        )
        let groupSnapshot = self.activeGroupSnapshotForInitialMessage()
        self.initialMessageOverlayView.update(
            frame: frame,
            conversationType: self.conversationType,
            privacy: groupSnapshot?.privacy,
            peerToPeer: groupSnapshot.map { $0.parentJID != nil }
        )
        self.keepInteractiveChatControlsAboveInitialMessage()
    }

    private func activeGroupSnapshotForInitialMessage() -> GroupSnapshot? {
        guard self.conversationType == .group,
              let realm = try? WRealm.safe(),
              let projection = try? GroupRepository(realm: realm).projection(
                owner: self.owner,
                groupJID: self.jid
              ),
              projection.state.isActive else {
            return nil
        }
        return projection.state.snapshot
    }

    private func currentInputTopYForInitialMessageOverlay() -> CGFloat {
        guard let inputView = self.xabberInputView,
              inputView.superview != nil,
              inputView.frame.height > 0,
              inputView.frame.minY.isFinite else {
            return self.view.bounds.maxY
        }

        return inputView.frame.minY
    }

    private func keepInteractiveChatControlsAboveInitialMessage() {
        self.view.bringSubviewToFront(self.scrollDownButton)
        if let inputView = self.xabberInputView {
            self.view.bringSubviewToFront(inputView)
            if inputView.mentionPanel.superview === self.view {
                self.view.bringSubviewToFront(inputView.mentionPanel)
            }
        }
        self.view.bringSubviewToFront(self.unreadMentionsNavigatorView)
    }

    class InitialMessageOverlayView: UIView {
        private enum Layout {
            static let horizontalInset: CGFloat = 8
            static let topInset: CGFloat = 40
            static let bottomInset: CGFloat = 8
            static let titleHeight: CGFloat = 24
            static let learnMoreHeight: CGFloat = 24
            static let preferredContainerWidth: CGFloat = 320
            static let preferredContainerHeight: CGFloat = 232
            static let preferredIconSize: CGFloat = 64
        }

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
        
        private lazy var titleHeightConstraint = titleLabel.heightAnchor.constraint(equalToConstant: Layout.titleHeight)
        private lazy var learnMoreHeightConstraint = learnmoreButton.heightAnchor.constraint(equalToConstant: Layout.learnMoreHeight)
        private var learnMoreURL: URL?

        internal var onOpenURL: (URL) -> Void = { url in
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }

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
            
            self.containerStack.addArrangedSubview(self.titleLabel)
            self.containerStack.addArrangedSubview(self.descriptionLabel)
            self.containerStack.addArrangedSubview(self.learnmoreButton)
            self.addSubview(self.iconButton)
            self.learnmoreButton.addTarget(
                self,
                action: #selector(openLearnMoreURL),
                for: .touchUpInside
            )

            NSLayoutConstraint.activate([
                titleHeightConstraint,
                learnMoreHeightConstraint
            ])
        }
        
        public func update(
            frame: CGRect,
            conversationType: ClientSynchronizationManager.ConversationType,
            privacy: GroupPrivacy? = nil,
            peerToPeer: Bool? = nil
        ) {
            self.frame = frame
            self.learnMoreURL = nil
            self.learnmoreButton.accessibilityIdentifier = nil
            self.containerView.layer.cornerRadius = 8
            self.containerView.layer.masksToBounds = true

            let iconButtonSize = self.iconButtonSize(for: self.bounds)
            let iconOverlap = iconButtonSize / 2
            let width = min(Layout.preferredContainerWidth, max(0, self.bounds.width - 20))
            let height = min(Layout.preferredContainerHeight, max(0, self.bounds.height - iconOverlap))
            let contentHeight = height + iconOverlap
            let contentOriginY = max(0, (self.bounds.height - contentHeight) / 2)

            self.containerView.frame = CGRect(
                origin: CGPoint(x: (self.bounds.width - width) / 2, y: contentOriginY + iconOverlap),
                size: CGSize(width: width, height: height)
            )
            self.iconButton.frame = CGRect(
                origin: CGPoint(x: (self.bounds.width - iconButtonSize) / 2, y: contentOriginY),
                size: CGSize(square: iconButtonSize)
            )
            self.iconButton.layer.cornerRadius = iconButtonSize / 2
            self.iconButton.layer.masksToBounds = true
            
            self.blurredEffectView.frame = self.containerView.bounds
            layoutOverlayContents()
            
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
                    if peerToPeer == true {
                        self.iconButton.setImage(imageLiteral("person.line.dotted.person", dimension: 28), for: .normal)
                        self.titleLabel.text = "Private chat".localizeString(id: "intro_private_chat", arguments: [])
                        self.descriptionLabel.text = "Private chat with incognito user. Messages are routed through group server and your identities are kept secret from each other. Be vigilant, do not disclose yourself by being careless.".localizeString(id: "intro_private_chat_text", arguments: [])
                        self.learnmoreButton.setAttributedTitle(NSAttributedString(string: "Learn more about private chats".localizeString(id: "intro_private_chat_learn", arguments: []), attributes: [
                            .foregroundColor: UIColor.tintColor,
                            .font: UIFont.systemFont(ofSize: 14, weight: .regular)
                        ]), for: .normal)
                    } else {
                        switch privacy ?? .publicGroup {
                            case .incognito:
                                self.iconButton.setImage(imageLiteral("person.2", dimension: 28), for: .normal)
                                self.titleLabel.text = "Incognito group".localizeString(id: "intro_incognito_group", arguments: [])
                                self.descriptionLabel.text = "Identities of users in this group are kept hidden from each other, only group admins can access your real XMPP ID. Be vigilant, do not disclose yourself by being careless.".localizeString(id: "intro_incognito_group_text", arguments: [])
                                self.learnmoreButton.setAttributedTitle(NSAttributedString(string: "Learn more about incognito groups".localizeString(id: "intro_incognito_group_learn", arguments: []), attributes: [
                                    .foregroundColor: UIColor.tintColor,
                                    .font: UIFont.systemFont(ofSize: 14, weight: .regular)
                                ]), for: .normal)
                            case .publicGroup:
                                self.iconButton.setImage(imageLiteral("person.2.fill", dimension: 28), for: .normal)
                                self.titleLabel.text = "Public group".localizeString(id: "intro_public_group", arguments: [])
                                self.descriptionLabel.text = "Identities of users in this group are public, so any member can contact you using your real XMPP ID.".localizeString(id: "intro_public_group_text", arguments: [])
                                self.learnmoreButton.setAttributedTitle(NSAttributedString(string: "Learn more about public groups".localizeString(id: "intro_public_group_learn", arguments: []), attributes: [
                                    .foregroundColor: UIColor.tintColor,
                                    .font: UIFont.systemFont(ofSize: 14, weight: .regular)
                                ]), for: .normal)
                        }
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
                    self.iconButton.setImage(
                        imageLiteral("bookmark.fill", dimension: 28),
                        for: .normal
                    )
                    self.titleLabel.text = "Saved messages".localizeString(
                        id: "saved_messages__header",
                        arguments: []
                    )
                    self.descriptionLabel.text = "Save notes, links, files, and forwarded messages here. Your saved messages are synchronized across your devices.".localizeString(
                        id: "intro_saved_messages_text",
                        arguments: []
                    )
                    let title = "Learn more about Saved Messages".localizeString(
                        id: "intro_saved_messages_learn",
                        arguments: []
                    )
                    self.learnmoreButton.setAttributedTitle(
                        NSAttributedString(
                            string: title,
                            attributes: [
                                .foregroundColor: UIColor.tintColor,
                                .font: UIFont.systemFont(
                                    ofSize: 14,
                                    weight: .regular
                                )
                            ]
                        ),
                        for: .normal
                    )
                    self.learnmoreButton.accessibilityLabel = title
                    self.learnmoreButton.accessibilityIdentifier =
                        "chat.initial_message.saved.learn_more"
                    self.learnMoreURL = URL(
                        string: "https://www.xabber.com/learn/saved/".localizeString(
                            id: "intro_saved_messages_link",
                            arguments: []
                        )
                    )
            }
        }

        @objc private func openLearnMoreURL() {
            guard let learnMoreURL else {
                return
            }
            onOpenURL(learnMoreURL)
        }

        private func iconButtonSize(for bounds: CGRect) -> CGFloat {
            guard bounds.width > 0, bounds.height > 0 else {
                return 0
            }

            return min(Layout.preferredIconSize, bounds.width, bounds.height / 3)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutOverlayContents()
        }

        private func layoutOverlayContents() {
            blurredEffectView.frame = containerView.bounds
            let topInset = min(Layout.topInset, max(0, containerView.bounds.height * 0.25))
            let width = max(0, containerView.bounds.width - (Layout.horizontalInset * 2))
            let height = max(0, containerView.bounds.height - topInset - Layout.bottomInset)
            containerStack.frame = CGRect(
                x: Layout.horizontalInset,
                y: topInset,
                width: width,
                height: height
            )
        }
    }
}
