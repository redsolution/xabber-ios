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

extension ContactsViewController {
    class ContactCell: UITableViewCell {
        class var cellName: String { "ContactCell" }

        internal let avatarContainer: UIView = {
            let view = UIView()
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }()

        let avatarView: UIImageView = {
            let view = UIImageView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.contentMode = .scaleAspectFill
            view.backgroundColor = MDCPalette.grey.tint200
            return view
        }()

        let statusIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.border(1)
            view.setStatus(status: .offline, entity: .contact)
            return view
        }()

        internal let contentStack: UIStackView = {
            let stack = UIStackView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .horizontal
            stack.alignment = .top
            stack.spacing = 12
            return stack
        }()

        internal let labelsStack: UIStackView = {
            let stack = UIStackView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .vertical
            stack.alignment = .fill
            stack.spacing = 4
            return stack
        }()

        internal let titleLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.textColor = .label
            label.numberOfLines = 0
            return label
        }()

        internal let subtitleLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            return label
        }()

        internal let bottomLineLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            return label
        }()

        internal let tagScrollView: UIScrollView = {
            let scrollView = UIScrollView()
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            return scrollView
        }()

        internal let tagsStack: UIStackView = {
            let stack = UIStackView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .horizontal
            stack.alignment = .leading
            stack.spacing = 8
            return stack
        }()

        private var statusWidthConstraint: NSLayoutConstraint?
        private var statusHeightConstraint: NSLayoutConstraint?
        private var avatarRequestKey: String?

        private func activateConstraints() {
            let statusWidthConstraint = statusIndicator.widthAnchor.constraint(equalToConstant: 12)
            let statusHeightConstraint = statusIndicator.heightAnchor.constraint(equalToConstant: 12)
            self.statusWidthConstraint = statusWidthConstraint
            self.statusHeightConstraint = statusHeightConstraint

            NSLayoutConstraint.activate([
                avatarContainer.widthAnchor.constraint(equalToConstant: 64),
                avatarContainer.heightAnchor.constraint(equalToConstant: 64),
                avatarView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
                avatarView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
                avatarView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
                avatarView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
                statusIndicator.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: -2),
                statusIndicator.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor, constant: -2),
                statusWidthConstraint,
                statusHeightConstraint,
                tagScrollView.heightAnchor.constraint(equalToConstant: 18),
                tagsStack.topAnchor.constraint(equalTo: tagScrollView.contentLayoutGuide.topAnchor),
                tagsStack.bottomAnchor.constraint(equalTo: tagScrollView.contentLayoutGuide.bottomAnchor),
                tagsStack.leadingAnchor.constraint(equalTo: tagScrollView.contentLayoutGuide.leadingAnchor),
                tagsStack.trailingAnchor.constraint(equalTo: tagScrollView.contentLayoutGuide.trailingAnchor),
                tagsStack.heightAnchor.constraint(equalTo: tagScrollView.frameLayoutGuide.heightAnchor),
                contentStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
                contentStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
                contentStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
                contentStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
            ])
        }

        private func updateTags(_ groups: [String], owner: String) {
            tagsStack.arrangedSubviews.forEach { subview in
                tagsStack.removeArrangedSubview(subview)
                subview.removeFromSuperview()
            }

            let uniqueGroups = Array(Set(groups)).sorted()
            guard uniqueGroups.isNotEmpty else {
                tagScrollView.isHidden = true
                return
            }

            tagScrollView.isHidden = false
            let textInsets = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
            let paletteColor = AccountColorManager.shared.palette(for: owner).tint700.withAlphaComponent(0.15)

            uniqueGroups.forEach { group in
                let label = MessageLabel()
                label.text = group
                label.textColor = .label
                label.backgroundColor = paletteColor
                label.textInsets = textInsets
                label.layer.cornerRadius = 4
                label.layer.masksToBounds = true
                label.font = UIFont.systemFont(ofSize: 12, weight: .regular)
                tagsStack.addArrangedSubview(label)
            }
        }

        private func updateStatus(entity: RosterItemEntity, status: ResourceStatus) {
            let isWideStatus = [.incognitoChat, .groupchat, .server, .privateChat, .issue].contains(entity)
            statusWidthConstraint?.constant = isWideStatus ? 16 : 12
            statusHeightConstraint?.constant = isWideStatus ? 16 : 12
            statusIndicator.border(1)
            statusIndicator.setStatus(status: status, entity: entity)
        }

        private func updateAvatarMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt)?.upscale(dimension: 64),
               AccountMasksManager.shared.load() != "square" {
                avatarView.mask = UIImageView(image: image)
            } else {
                avatarView.mask = nil
            }
        }

        open func configure(title: String, subtitle: String, bottomLine: String?, groups: [String], jid: String, owner: String, showAvatar: Bool, avatarUrl: String?, entity: RosterItemEntity, status: ResourceStatus) {
            titleLabel.text = title
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = subtitle.isEmpty
            bottomLineLabel.text = bottomLine
            bottomLineLabel.isHidden = (bottomLine?.isEmpty ?? true)

            updateTags(groups, owner: owner)
            updateStatus(entity: entity, status: status)
            updateAvatarMask()

            guard showAvatar else {
                avatarRequestKey = nil
                avatarView.isHidden = true
                avatarView.image = nil
                return
            }

            avatarView.isHidden = false
            let requestKey = [owner, jid, avatarUrl ?? ""].joined(separator: "|")
            avatarRequestKey = requestKey

            DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 64) { [weak self] image in
                guard let self = self, self.avatarRequestKey == requestKey else {
                    return
                }
                if let image = image {
                    self.avatarView.image = image
                } else {
                    self.avatarView.image = UIImageView.getDefaultAvatar(for: title.capitalized, owner: owner, size: 64)
                }
            }
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            titleLabel.text = nil
            subtitleLabel.text = nil
            bottomLineLabel.text = nil
            subtitleLabel.isHidden = false
            bottomLineLabel.isHidden = false
            avatarView.image = nil
            avatarRequestKey = nil
            updateTags([], owner: "")
            updateStatus(entity: .contact, status: .offline)
        }

        func setMask() {
            updateAvatarMask()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            separatorInset = UIEdgeInsets(top: 0, left: contentView.layoutMargins.left + 64 + 12, bottom: 0, right: 0)
        }

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)

            contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)

            contentView.addSubview(contentStack)
            contentStack.addArrangedSubview(avatarContainer)
            contentStack.addArrangedSubview(labelsStack)

            avatarContainer.addSubview(avatarView)
            avatarContainer.addSubview(statusIndicator)

            labelsStack.addArrangedSubview(titleLabel)
            labelsStack.addArrangedSubview(subtitleLabel)
            labelsStack.addArrangedSubview(bottomLineLabel)
            labelsStack.addArrangedSubview(tagScrollView)
            tagScrollView.addSubview(tagsStack)

            activateConstraints()
        }

        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}

protocol ContactCellSubscribtionActionsDelegate: AnyObject {
    func acceptSubscribtionRequest(jid: String, owner: String)
    func cancelSubscribtionRequest(jid: String, owner: String)
}

protocol GroupListActionsCellDelegate: AnyObject {
    func acceptInvite(invitePrimary primary: String)
    func cancelInvite(invitePrimary primary: String)
}

extension ContactsViewController {
    class ButtonTableCell: UITableViewCell {
        static let cellName: String = "ContactsButtonTableCell"

        private let titleLabel = UILabel()
        private let subtitleLabel = UILabel()
        private let stack = UIStackView()

        func configure(title: String, subtitle: String) {
            titleLabel.text = title
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = subtitle.isEmpty
        }

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            titleLabel.font = .preferredFont(forTextStyle: .body)
            subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
            subtitleLabel.textColor = .secondaryLabel
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.spacing = 12
            contentView.addSubview(stack)
            contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
                stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
            ])
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(UIView())
            stack.addArrangedSubview(subtitleLabel)
            accessoryType = .disclosureIndicator
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    class AddContactCell: ContactCell {
        override class var cellName: String { "AddContactCell" }

        weak var cellDelegate: ContactCellSubscribtionActionsDelegate?

        private let actionsStack = UIStackView()
        private let acceptButton = UIButton(type: .system)
        private let declineButton = UIButton(type: .system)

        private var jid: String = ""
        private var owner: String = ""

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            actionsStack.axis = .horizontal
            actionsStack.spacing = 12
            actionsStack.distribution = .fillEqually
            acceptButton.setTitle("Accept", for: .normal)
            declineButton.setTitle("Decline", for: .normal)
            acceptButton.addTarget(self, action: #selector(onAccept), for: .touchUpInside)
            declineButton.addTarget(self, action: #selector(onDecline), for: .touchUpInside)
            actionsStack.addArrangedSubview(acceptButton)
            actionsStack.addArrangedSubview(declineButton)
            labelsStack.addArrangedSubview(actionsStack)
        }

        func configure(title: String, subtitle: String, jid: String, owner: String, showAvatar: Bool, avatarUrl: String?) {
            self.jid = jid
            self.owner = owner
            super.configure(title: title, subtitle: subtitle, bottomLine: nil, groups: [], jid: jid, owner: owner, showAvatar: showAvatar, avatarUrl: avatarUrl, entity: .contact, status: .offline)
        }

        @objc private func onAccept() {
            cellDelegate?.acceptSubscribtionRequest(jid: jid, owner: owner)
        }

        @objc private func onDecline() {
            cellDelegate?.cancelSubscribtionRequest(jid: jid, owner: owner)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    class RequestContactCell: ContactCell {
        override class var cellName: String { "RequestContactCell" }

        weak var cellDelegate: ContactCellSubscribtionActionsDelegate?

        private let cancelButton = UIButton(type: .system)
        private var jid: String = ""
        private var owner: String = ""

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            cancelButton.setTitle("Cancel request", for: .normal)
            cancelButton.contentHorizontalAlignment = .leading
            cancelButton.addTarget(self, action: #selector(onCancel), for: .touchUpInside)
            labelsStack.addArrangedSubview(cancelButton)
        }

        func configure(title: String, subtitle: String, jid: String, owner: String, showAvatar: Bool, avatarUrl: String?) {
            self.jid = jid
            self.owner = owner
            super.configure(title: title, subtitle: subtitle, bottomLine: nil, groups: [], jid: jid, owner: owner, showAvatar: showAvatar, avatarUrl: avatarUrl, entity: .contact, status: .offline)
        }

        @objc private func onCancel() {
            cellDelegate?.cancelSubscribtionRequest(jid: jid, owner: owner)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    class GroupInviteCell: ContactCell {
        override class var cellName: String { "GroupInviteCell" }

        weak var cellDelegate: GroupListActionsCellDelegate?

        private let detailsLabel = UILabel()
        private let actionsStack = UIStackView()
        private let acceptButton = UIButton(type: .system)
        private let declineButton = UIButton(type: .system)

        private var primary: String = ""

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            detailsLabel.font = .preferredFont(forTextStyle: .caption1)
            detailsLabel.textColor = .secondaryLabel
            detailsLabel.numberOfLines = 0
            labelsStack.insertArrangedSubview(detailsLabel, at: 2)

            actionsStack.axis = .horizontal
            actionsStack.spacing = 12
            actionsStack.distribution = .fillEqually
            acceptButton.setTitle("Accept", for: .normal)
            declineButton.setTitle("Decline", for: .normal)
            acceptButton.addTarget(self, action: #selector(onAccept), for: .touchUpInside)
            declineButton.addTarget(self, action: #selector(onDecline), for: .touchUpInside)
            actionsStack.addArrangedSubview(acceptButton)
            actionsStack.addArrangedSubview(declineButton)
            labelsStack.addArrangedSubview(actionsStack)
        }

        func configure(primary: String, title: String, invitedBy: String, subtitle: String, descr: String?, jid: String, owner: String, showAvatar: Bool, avatarUrl: String?, members: [ContactsViewController.GroupDisplayMember], bottomLine: String) {
            self.primary = primary
            detailsLabel.text = invitedBy.isEmpty ? descr : invitedBy
            super.configure(title: title, subtitle: subtitle, bottomLine: bottomLine, groups: [], jid: jid, owner: owner, showAvatar: showAvatar, avatarUrl: avatarUrl, entity: .groupchat, status: .away)
        }

        @objc private func onAccept() {
            cellDelegate?.acceptInvite(invitePrimary: primary)
        }

        @objc private func onDecline() {
            cellDelegate?.cancelInvite(invitePrimary: primary)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
