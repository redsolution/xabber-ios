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
        static let badgeSize: CGFloat = 16

        static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()

        private let avatarContainer = UIView()
        private let userImageView = UIView()
        let avatarView = UIImageView()
        let badgeIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            view.border(1)
            view.setCustomStatus(color: UIColor.red, iconName: nil)
            return view
        }()

        private let textStack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.alignment = .fill
            stack.distribution = .fill
            stack.spacing = 4
            return stack
        }()

        private let titleStack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.alignment = .firstBaseline
            stack.spacing = 8
            return stack
        }()

        let titleLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 17, weight: .medium)
            label.numberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return label
        }()

        let dateLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            label.textColor = .secondaryLabel
            label.numberOfLines = 1
            label.textAlignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            return label
        }()

        let messageLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            return label
        }()

        let dimmedView: UIView = {
            let view = UIView()
            view.backgroundColor = MDCPalette.grey.tint50
            view.isUserInteractionEnabled = false
//            view.layer.cornerRadius = 16
            view.clipsToBounds = true
            return view
        }()

        private var avatarRequestKey: String?
        private var appliedAvatarRequestKey: String?
        private var defaultAvatarImage: UIImage?

        private func makeAvatarRequestKey(owner: String, jid: String, avatarUrl: String?, size: CGFloat) -> String {
            [owner, jid, avatarUrl ?? "", String(Int(size))].joined(separator: "|")
        }

        public func configure(jid: String, owner: String, avatarUrl: String?, icon: String, title: NSAttributedString, message: NSAttributedString?, date: Date, isRead: Bool) {
            titleLabel.attributedText = title
            messageLabel.attributedText = message
            messageLabel.isHidden = message == nil
            dateLabel.text = Self.dateFormatter.string(from: date)

            dimmedView.backgroundColor = AccountColorManager.shared.palette(for: owner).tint50
            updateReadState(isRead, animated: false)
            badgeIndicator.setCustomStatus(color: AccountColorManager.shared.palette(for: owner).tint700, iconName: icon)
            badgeIndicator.layer.cornerRadius = Self.badgeSize / 2
            badgeIndicator.layer.masksToBounds = true

            let requestKey = makeAvatarRequestKey(owner: owner, jid: jid, avatarUrl: avatarUrl, size: 56)
            let defaultAvatar = UIImageView.getDefaultAvatar(for: jid, owner: owner, size: 56)
            defaultAvatarImage = defaultAvatar

            if appliedAvatarRequestKey == requestKey, let currentImage = avatarView.image {
                avatarRequestKey = requestKey
                avatarView.image = currentImage
            } else {
                avatarRequestKey = requestKey
                avatarView.image = defaultAvatar
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 56) { [weak self] image in
                    guard let self, self.avatarRequestKey == requestKey else {
                        return
                    }
                    self.appliedAvatarRequestKey = requestKey
                    self.avatarView.image = image ?? self.defaultAvatarImage ?? defaultAvatar
                }
            }
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
            avatarRequestKey = nil
            appliedAvatarRequestKey = nil
            defaultAvatarImage = nil
            titleLabel.attributedText = nil
            messageLabel.attributedText = nil
            messageLabel.isHidden = false
            dateLabel.text = nil
            avatarView.image = nil
        }

        public final func updateReadState(_ state: Bool, animated: Bool) {
            let changes = {
                self.dimmedView.alpha = state ? 0.0 : 1.0
            }

            if animated {
                UIView.animate(
                    withDuration: 0.25,
                    delay: 0.0,
                    usingSpringWithDamping: 0.8,
                    initialSpringVelocity: 0.4,
                    options: [.curveEaseInOut],
                    animations: changes,
                    completion: nil
                )
            } else {
                changes()
            }
        }

        private func setupSubviews() {
            preservesSuperviewLayoutMargins = true
            contentView.preservesSuperviewLayoutMargins = true
            directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
//            backgroundColor = .clear
//            contentView.backgroundColor = .clear

            [dimmedView, avatarContainer, textStack, userImageView, avatarView, badgeIndicator, titleStack].forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
            }

            contentView.addSubview(dimmedView)
            contentView.addSubview(avatarContainer)
            contentView.addSubview(textStack)

            avatarContainer.addSubview(userImageView)
            userImageView.addSubview(avatarView)
            avatarContainer.addSubview(badgeIndicator)

            avatarView.contentMode = .scaleAspectFill
            avatarView.backgroundColor = MDCPalette.grey.tint200
            userImageView.backgroundColor = .clear
            badgeIndicator.layer.cornerRadius = Self.badgeSize / 2
            badgeIndicator.layer.masksToBounds = true

            titleStack.addArrangedSubview(titleLabel)
            titleStack.addArrangedSubview(dateLabel)
            textStack.addArrangedSubview(titleStack)
            textStack.addArrangedSubview(messageLabel)

            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 92, right: 16)

            NSLayoutConstraint.activate([
                dimmedView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 0),
                dimmedView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: 0),
                dimmedView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                dimmedView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

                avatarContainer.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
                avatarContainer.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
                avatarContainer.widthAnchor.constraint(equalToConstant: 56),
                avatarContainer.heightAnchor.constraint(equalToConstant: 56),
                avatarContainer.bottomAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.bottomAnchor),

                userImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
                userImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
                userImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
                userImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),

                avatarView.leadingAnchor.constraint(equalTo: userImageView.leadingAnchor),
                avatarView.trailingAnchor.constraint(equalTo: userImageView.trailingAnchor),
                avatarView.topAnchor.constraint(equalTo: userImageView.topAnchor),
                avatarView.bottomAnchor.constraint(equalTo: userImageView.bottomAnchor),

                badgeIndicator.widthAnchor.constraint(equalToConstant: Self.badgeSize),
                badgeIndicator.heightAnchor.constraint(equalToConstant: Self.badgeSize),
                badgeIndicator.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: -1),
                badgeIndicator.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor, constant: -1),

                textStack.leadingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: 12),
                textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
                textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
                textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            ])

            setMask()
        }

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }

        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            setupSubviews()
        }

        override func awakeFromNib() {
            super.awakeFromNib()
            setupSubviews()
        }
    }
}
