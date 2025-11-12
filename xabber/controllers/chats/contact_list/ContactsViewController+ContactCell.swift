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

extension ContactsViewController {
    class ContactCell: UITableViewCell {
        static let cellName: String = "ContactCell"
                
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 96, right: 4)
            
            return stack
        }()
        
        internal let labelsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 4
            
            return stack
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
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            if #available(iOS 13.0, *) {
                label.textColor = .label
            } else {
                label.textColor = .darkText
            }
            
            return label
        }()
        
        internal let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = MDCPalette.grey.tint500//.systemGray
            }
            
            return label
        }()
        
        internal let bottomLineLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = MDCPalette.grey.tint500//.systemGray
            }
            
            return label
        }()
        
        let statusIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            
            view.frame = CGRect(x: 49,
                                y: 49,
                                width: 12,
                                height: 12)

            view.border(1)
            view.setStatus(status: .offline, entity: .contact)
            
            return view
        }()
        
        internal let tagScrollView: UIScrollView = {
            let scrollView = UIScrollView(frame: .zero)
            
            scrollView.showsVerticalScrollIndicator = false
            scrollView.showsHorizontalScrollIndicator = false
            
            return scrollView
        }()
        
        internal let tagsLabel: UILabel = {
            let label = UILabel()
            
            return label
        }()
                
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
                avatarView.heightAnchor.constraint(equalToConstant: 64),
                avatarView.widthAnchor.constraint(equalToConstant: 64),
                tagScrollView.heightAnchor.constraint(equalToConstant: 18),
                tagScrollView.leadingAnchor.constraint(equalTo: labelsStack.leadingAnchor),
                tagScrollView.trailingAnchor.constraint(equalTo: labelsStack.trailingAnchor)
            ])
        }
        
        open func configure(title: String, subtitle: String, bottomLine: String?, groups: [String], jid: String, owner: String, showAvatar: Bool, avatarUrl: String?, entity: RosterItemEntity, status: ResourceStatus) {
            titleLabel.text = title
            subtitleLabel.text = subtitle//JidManager.shared.prepareJid(jid: subtitle)
            bottomLineLabel.text = bottomLine
            let textInsets = UIEdgeInsets(top: 1, left: 8, bottom: 1, right: 8)
            var offset: CGFloat = 0
            for group in groups {
                let label = MessageLabel()
                label.text = group
                label.textColor = AccountColorManager.shared.palette(for: owner).tint700.withAlphaComponent(0.8)
                label.backgroundColor = MDCPalette.grey.tint100
                label.textInsets = textInsets
                label.layer.cornerRadius = 8
                label.layer.masksToBounds = true
                label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
                let size = label.sizeThatFits(CGSize(width: 300, height: 16)).margin(width: textInsets.horizontal, height: textInsets.vertical)
                let frame = CGRect(
                    origin: CGPoint(x: offset, y: 0),
                    size: size
                )
                label.frame = frame
                offset += (size.width + 8)
//                self.tagScrollView.add
                self.tagScrollView.addSubview(label)
            }
            if offset > 0 {
                self.tagScrollView.isHidden = false
                self.tagScrollView.contentSize = CGSize(width: offset, height: 18)
                self.tagScrollView.frame = CGRect(x: 0, y: 0, width: self.contentView.frame.width, height: 18)
            } else {
                self.tagScrollView.isHidden = true
            }
            
//            tagsLabel.textColor = AccountColorManager.shared.palette(for: owner).tint500
            
            if showAvatar {
                avatarView.isHidden = false
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 64) { image in
                    if let image = image {
                        self.avatarView.image = image
                    } else {
                        self.avatarView.image = UIImageView.getDefaultAvatar(for: title.capitalized, owner: owner, size: 64)
                    }
                }
            } else {
                avatarView.isHidden = true
            }
            if [.incognitoChat, .groupchat, .server, .privateChat, .issue].contains(entity) {
                statusIndicator.frame = CGRect(x: 47,
                                               y: 47,
                                               width: 16,
                                               height: 16)
                statusIndicator.border(1)
            }
            
            statusIndicator.setStatus(status: status, entity: entity)
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            self.titleLabel.text = nil
            self.avatarView.image = nil
            self.subtitleLabel.text = nil
            self.tagScrollView.frame = .zero
            self.tagScrollView.subviews.forEach({ $0.removeFromSuperview() })
            statusIndicator.frame = CGRect(x: 49,
                                           y: 49,
                                           width: 12,
                                           height: 12)
            statusIndicator.border(1)
        }
        
        func setMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
                avatarView.mask = UIImageView(image: image)
            } else {
                avatarView.mask = nil
            }
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            userImageView.frame = CGRect(x: 16, y: 10, width: 64, height: 64)
            addSubview(userImageView)
            userImageView.addSubview(avatarView)
            userImageView.addSubview(statusIndicator)
            contentView.addSubview(stack)
            stack.fillSuperview()
//            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(labelsStack)
//            stack.addArrangedSubview(statusIndicator)
            labelsStack.addArrangedSubview(titleLabel)
            labelsStack.addArrangedSubview(subtitleLabel)
            labelsStack.addArrangedSubview(bottomLineLabel)
            labelsStack.addArrangedSubview(tagScrollView)
            activateConstraints()
            
//            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 96, right: 0)
//            selectionStyle = .none
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
    
    class AddContactCell: UITableViewCell {
        static let cellName: String = "addContactCell"
                
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 96, right: 4)
            
            return stack
        }()
        
        internal let labelsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 2
            
            return stack
        }()
        
        internal let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 64))
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
            view.contentMode = .scaleAspectFill
            
            return view
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            if #available(iOS 13.0, *) {
                label.textColor = .label
            } else {
                label.textColor = .darkText
            }
            
            return label
        }()
        
        internal let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = MDCPalette.grey.tint500//.systemGray
            }
            
            return label
        }()
        
        internal let statusIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            
            view.frame = CGRect(square: 18)
            
            return view
        }()
        
        internal let buttonsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.spacing = 4
            
            return stack
        }()
        
        internal let addContactButton: UIButton = {
            var configuration = UIButton.Configuration.filled()
            configuration.cornerStyle = .capsule
            configuration.title = "Add"
            configuration.baseBackgroundColor = .tintColor
            configuration.baseForegroundColor = .white
            let button = UIButton(configuration: configuration, primaryAction: nil)
            
            return button
        }()
        
        internal let cancelButton: UIButton = {
            var configuration = UIButton.Configuration.plain()
            configuration.image = imageLiteral("xmark")
            let button = UIButton(configuration: configuration, primaryAction: nil)
            
            button.tintColor = .systemGray
            
            return button
        }()
        
                
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
                avatarView.heightAnchor.constraint(equalToConstant: 64),
                avatarView.widthAnchor.constraint(equalToConstant: 64),
                statusIndicator.heightAnchor.constraint(equalToConstant: 18),
                statusIndicator.widthAnchor.constraint(equalToConstant: 18)
            ])
        }
        
        open func configure(title: String, subtitle: String, jid: String, owner: String, showAvatar: Bool, avatarUrl: String?) {
            titleLabel.text = title
            subtitleLabel.text = subtitle//JidManager.shared.prepareJid(jid: subtitle)
            self.jid = jid
            self.owner = owner
            if showAvatar {
                avatarView.isHidden = false
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 64) { image in
                    if let image = image {
                        self.avatarView.image = image
                    } else {
                        self.avatarView.image = UIImageView.getDefaultAvatar(for: title.capitalized, owner: owner, size: 64)
                    }
                }
            } else {
                avatarView.isHidden = true
            }
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            self.titleLabel.text = nil
            self.avatarView.image = nil
            self.subtitleLabel.text = nil
        }
        
        func setMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
                avatarView.mask = UIImageView(image: image)
            } else {
                avatarView.mask = nil
            }
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            avatarView.frame = CGRect(x: 16, y: 10, width: 64, height: 64)
            addSubview(avatarView)
            contentView.addSubview(stack)
            stack.fillSuperview()
//            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(labelsStack)
            stack.addArrangedSubview(buttonsStack)
            buttonsStack.addArrangedSubview(addContactButton)
            buttonsStack.addArrangedSubview(cancelButton)
//            stack.addArrangedSubview(statusIndicator)
            labelsStack.addArrangedSubview(titleLabel)
            labelsStack.addArrangedSubview(subtitleLabel)
            activateConstraints()
            addContactButton.addTarget(self, action: #selector(onAddContactButtonTouchUpInside), for: .touchUpInside)
            cancelButton.addTarget(self, action: #selector(onCancelButtonTouchUpInside), for: .touchUpInside)
//            backgroundColor = .secondarySystemBackground
//            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 96, right: 0)
//            selectionStyle = .none
        }
        
        open var cellDelegate: ContactCellSubscribtionActionsDelegate? = nil
        
        var owner: String? = nil
        var jid: String? = nil
        
        @objc
        internal func onAddContactButtonTouchUpInside(_ sender: UIButton) {
            guard let owner = owner, let jid = jid else { return }
            self.cellDelegate?.acceptSubscribtionRequest(jid: jid, owner: owner)
        }
        
        @objc
        internal func onCancelButtonTouchUpInside(_ sender: UIButton) {
            guard let owner = owner, let jid = jid else { return }
            self.cellDelegate?.cancelSubscribtionRequest(jid: jid, owner: owner)
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
    
    class RequestContactCell: UITableViewCell {
        static let cellName: String = "requestContactCell"
                
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            
//            stack.isLayoutMarginsRelativeArrangement = true
//            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 96, right: 4)
            
            return stack
        }()
        
        internal let labelsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 2
            
            return stack
        }()
        
        internal let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 64))
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
            view.contentMode = .scaleAspectFill
            
            return view
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            if #available(iOS 13.0, *) {
                label.textColor = .label
            } else {
                label.textColor = .darkText
            }
            
            return label
        }()
        
        internal let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = MDCPalette.grey.tint500//.systemGray
            }
            
            return label
        }()
        
        internal let statusIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            
            view.frame = CGRect(square: 18)
            
            return view
        }()
        
        internal let buttonsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.spacing = 4
            
            return stack
        }()
               
        internal let cancelButton: UIButton = {
            var configuration = UIButton.Configuration.plain()
            configuration.image = imageLiteral("xmark")
            let button = UIButton(configuration: configuration, primaryAction: nil)
            
            button.tintColor = .systemGray
            
            return button
        }()
        
                
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
                avatarView.heightAnchor.constraint(equalToConstant: 64),
                avatarView.widthAnchor.constraint(equalToConstant: 64),
                statusIndicator.heightAnchor.constraint(equalToConstant: 18),
                statusIndicator.widthAnchor.constraint(equalToConstant: 18)
            ])
        }
        
        open func configure(title: String, subtitle: String, jid: String, owner: String, showAvatar: Bool, avatarUrl: String?) {
            titleLabel.text = title
            subtitleLabel.text = subtitle//JidManager.shared.prepareJid(jid: subtitle)
            self.owner = owner
            self.jid = jid
            if showAvatar {
                avatarView.isHidden = false
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 64) { image in
                    if let image = image {
                        self.avatarView.image = image
                    } else {
                        self.avatarView.image = UIImageView.getDefaultAvatar(for: title.capitalized, owner: owner, size: 64)
                    }
                }
            } else {
                avatarView.isHidden = true
            }
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            self.titleLabel.text = nil
            self.avatarView.image = nil
            self.subtitleLabel.text = nil
        }
        
        func setMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
                avatarView.mask = UIImageView(image: image)
            } else {
                avatarView.mask = nil
            }
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            avatarView.frame = CGRect(x: 16, y: 10, width: 64, height: 64)
            addSubview(avatarView)
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 8, bottom: 8, left: 96, right: 4)
//            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(labelsStack)
            stack.addArrangedSubview(buttonsStack)
            buttonsStack.addArrangedSubview(cancelButton)
//            stack.addArrangedSubview(statusIndicator)
            labelsStack.addArrangedSubview(titleLabel)
            labelsStack.addArrangedSubview(subtitleLabel)
            cancelButton.addTarget(self, action: #selector(onCancelButtonTouchUpInside), for: .touchUpInside)
            activateConstraints()
//            backgroundColor = .secondarySystemBackground
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        open var cellDelegate: ContactCellSubscribtionActionsDelegate? = nil
        
        var owner: String? = nil
        var jid: String? = nil
        
        @objc
        internal func onCancelButtonTouchUpInside(_ sender: UIButton) {
            guard let owner = owner, let jid = jid else { return }
            self.cellDelegate?.cancelSubscribtionRequest(jid: jid, owner: owner)
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
    
    class ButtonTableCell: UITableViewCell {
        static let cellName: String = "buttonTableViewCell"

        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            label.textColor = .secondaryLabel
            
            return label
        }()
        
        internal let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.textColor = .secondaryLabel
            label.textAlignment = .right
//            label.font =
            
            return label
        }()
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            
            return stack
        }()
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.accessoryType = .disclosureIndicator
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 2, bottom: 2, left: 16, right: 20)
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(subtitleLabel)
//            self.backgroundColor = .secondarySystemBackground
//            backgroundColor = .secondarySystemBackground
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
        
        func configure(title: String, subtitle: String) {
            self.titleLabel.text = title
            self.subtitleLabel.text = subtitle
        }
    }
    
    class GroupInviteCell: UITableViewCell {
        static let cellName: String = "groupInviteCell"
                
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .top
            stack.distribution = .fill
            stack.spacing = 8
            
//            stack.isLayoutMarginsRelativeArrangement = true
//            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 96, right: 4)
            
            return stack
        }()
        
        internal let labelsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 2
            
            stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            return stack
        }()
        
        internal let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 64))
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
            view.contentMode = .scaleAspectFill
            
            return view
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            if #available(iOS 13.0, *) {
                label.textColor = .label
            } else {
                label.textColor = .darkText
            }
            
            return label
        }()
        
        internal let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = MDCPalette.grey.tint500//.systemGray
            }
            
            return label
        }()
        
        let statusIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            
            view.frame = CGRect(x: 49,
                                y: 49,
                                width: 12,
                                height: 12)

            view.border(1)
            view.setStatus(status: .offline, entity: .contact)
            
            return view
        }()
        
        internal let buttonsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.spacing = 4
            
            return stack
        }()
        
        internal let acceptInviteButton: UIButton = {
            var configuration = UIButton.Configuration.filled()
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .mini 
            configuration.title = "Join"
            configuration.baseBackgroundColor = .tintColor
            configuration.baseForegroundColor = .white
            
            let button = UIButton(configuration: configuration, primaryAction: nil)
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            
            return button
        }()
        
        internal let cancelButton: UIButton = {
            var configuration = UIButton.Configuration.plain()
            configuration.image = imageLiteral("xmark")
            let button = UIButton(configuration: configuration, primaryAction: nil)
            
            button.tintColor = .systemGray
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            
            return button
        }()
        
        class InviteReasonLabel: MessageLabel {
            override init(frame: CGRect) {
                super.init(frame: frame)
                self.setup()
            }
            
            required init?(coder: NSCoder) {
                super.init(coder: coder)
                self.setup()
            }
            
            internal let quoteLine: UIView = {
                let view = UIView()
                
                return view
            }()
            
            func setup() {
                addSubview(quoteLine)
            }
            
            func configure(text: String, owner: String) {
                self.textInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
                
                self.text = text//"lorem reason dolor ssssLLFKNG WFL;J NG WERIGNEWRIG NIEGN ∑OI GNW;VF DN VF;ON"// text
//                if self.text.isEmpty {
//                    self.isHidden = true
//                } else {
//                    self.isHidden = false
//                }
                self.numberOfLines = 0
                self.lineBreakMode = .byWordWrapping
                self.quoteLine.backgroundColor = AccountColorManager.shared.palette(for: owner).tint500
                self.sizeToFit()
            }
            
            override func draw(_ rect: CGRect) {
                super.draw(rect)
                quoteLine.frame = CGRect(origin: CGPoint(x: 1, y: 0), size: CGSize(width: 2, height: rect.height))
            }
        }
        
        internal let reason = InviteReasonLabel(frame: .zero)
        internal let descrLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            label.textColor = .secondaryLabel
            
            return label
        }()
                
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
                avatarView.heightAnchor.constraint(equalToConstant: 64),
                avatarView.widthAnchor.constraint(equalToConstant: 64),
                statusIndicator.heightAnchor.constraint(equalToConstant: 18),
                statusIndicator.widthAnchor.constraint(equalToConstant: 18),
                acceptInviteButton.widthAnchor.constraint(lessThanOrEqualToConstant: 60),
                cancelButton.widthAnchor.constraint(lessThanOrEqualToConstant: 44),
                avatarsStack.heightAnchor.constraint(equalToConstant: 32)
            ])
        }
        
        internal let avatarsStack: UIView = {
            let view = UIView()
            
            return view
        }()
        
        
        open func configure(primary: String, title: String, invitedBy: String, subtitle: String, descr: String?, jid: String, owner: String, showAvatar: Bool, avatarUrl: String?, members: [GroupDisplayMember], bottomLine: String) {
            self.primary = primary
            titleLabel.text = title
            let attributedStr = NSMutableAttributedString()
            attributedStr.append(NSAttributedString(string: "Invited by ", attributes: [
                .foregroundColor: UIColor.secondaryLabel,
                .font: UIFont.systemFont(ofSize: 14, weight: .regular)
            ]))
            attributedStr.append(NSAttributedString(string: invitedBy, attributes: [
                .foregroundColor: AccountColorManager.shared.palette(for: owner).tint500,
                .font: UIFont.systemFont(ofSize: 14, weight: .regular)
            ]))
            subtitleLabel.attributedText = attributedStr//JidManager.shared.prepareJid(jid: subtitle)
            if let descr = descr, descr.isNotEmpty {
                self.descrLabel.isHidden = false
            } else {
                self.descrLabel.isHidden = true
            }
            descrLabel.text = descr
            reason.configure(text: subtitle, owner: owner)
            
            var offset: CGFloat = 0
            var membersAvatars: [UIView] = []
            members.forEach {
                member in
                
                let memberAvatarContainer = UIView(frame: CGRect(
                        origin: CGPoint(x: offset, y: 0),
                        size: CGSize(square: 32)
                    )
                )
                memberAvatarContainer.backgroundColor = .white
                if let image = UIImage(named: AccountMasksManager.shared.mask32pt)?.resize(targetSize: CGSize(square: 32)), AccountMasksManager.shared.load() != "square" {
                    memberAvatarContainer.mask = UIImageView(image: image)
                } else {
                    memberAvatarContainer.mask = nil
                }
                
                let memberAvatar: UIImageView = {
                    let view = UIImageView(frame: CGRect(
                            origin: CGPoint(x: 1, y: 1),
                            size: CGSize(square: 30)
                        )
                    )
                    offset += 26
                    if let image = UIImage(named: AccountMasksManager.shared.mask32pt)?.resize(targetSize: CGSize(square: 30)), AccountMasksManager.shared.load() != "square" {
                        view.mask = UIImageView(image: image)
                    } else {
                        view.mask = nil
                    }
                    view.contentMode = .scaleAspectFill
                    
                    return view
                }()
                memberAvatarContainer.addSubview(memberAvatar)
                DefaultAvatarManager.shared.getGroupAvatar(url: member.avatarUrl, userId: member.uuid, jid: member.jid ?? "", owner: owner, size: 30) { image in
                    if let image = image {
                        memberAvatar.image = image
                    } else {
                        memberAvatar.image = UIImageView.getDefaultAvatar(for: member.name, owner: owner, size: 30)
                    }
                }
                
                avatarsStack.addSubview(memberAvatarContainer)
                membersAvatars.append(memberAvatarContainer)
                membersAvatars.reversed().forEach { avatarsStack.bringSubviewToFront($0) }
            }
            
            let bottomLineLabel: UILabel = {
                let label = UILabel()
                
                label.font = UIFont.preferredFont(forTextStyle: .caption1)
                if #available(iOS 13.0, *) {
                    label.textColor = .secondaryLabel
                } else {
                    label.textColor = MDCPalette.grey.tint500//.systemGray
                }
                
                return label
            }()
            bottomLineLabel.text = bottomLine
            let size = bottomLineLabel.sizeThatFits(CGSize(width: 100, height: 32))
            bottomLineLabel.frame = CGRect(
                origin: CGPoint(x: offset + 12, y: (32 - size.height) / 2),
                size: size
            )
            offset += size.width + 12
            
            avatarsStack.addSubview(bottomLineLabel)
            
            if membersAvatars.isEmpty {
                avatarsStack.isHidden = true
            } else {
                avatarsStack.isHidden = false
                avatarsStack.frame = CGRect(
                    origin: CGPoint(x: 0, y: 0),
                    size: CGSize(width: offset + 26, height: 32)
                )
            }
            
            if showAvatar {
                avatarView.isHidden = false
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 64) { image in
                    if let image = image {
                        self.avatarView.image = image
                    } else {
                        self.avatarView.image = UIImageView.getDefaultAvatar(for: title.capitalized, owner: owner, size: 64)
                    }
                }
            } else {
                avatarView.isHidden = true
            }
            statusIndicator.frame = CGRect(x: 47,
                                           y: 47,
                                           width: 16,
                                           height: 16)
            statusIndicator.border(1)
            statusIndicator.setCustomStatus(color: AccountColorManager.shared.palette(for: owner).tint700, iconName: "badge-circle-big-group-invite")
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            self.titleLabel.text = nil
            self.avatarView.image = nil
            self.subtitleLabel.text = nil
            
            self.avatarsStack.subviews.forEach { $0.removeFromSuperview() }
        }
        
        func setMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
                avatarView.mask = UIImageView(image: image)
            } else {
                avatarView.mask = nil
            }
        }
        
        let userImageView: UIView = {
            let view = UIView(frame: CGRect(square: 64))
            
            view.backgroundColor = .clear
            
            return view
        }()
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
//            avatarView.frame = CGRect(x: 16, y: 14, width: 64, height: 64)
//            contentView.addSubview(avatarView)
            userImageView.frame = CGRect(x: 16, y: 10, width: 64, height: 64)
            addSubview(userImageView)
            userImageView.addSubview(avatarView)
            userImageView.addSubview(statusIndicator)
            contentView.addSubview(stack)
//            UIEdgeInsets(top: 8, bottom: 8, left: 96, right: 4)
            stack.fillSuperviewWithOffset(top: 8, bottom: 8, left: 96, right: 4)
//            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(labelsStack)
            stack.addArrangedSubview(buttonsStack)
            buttonsStack.addArrangedSubview(acceptInviteButton)
            buttonsStack.addArrangedSubview(cancelButton)
//            stack.addArrangedSubview(statusIndicator)
            labelsStack.addArrangedSubview(titleLabel)
            labelsStack.addArrangedSubview(subtitleLabel)
            labelsStack.addArrangedSubview(reason)
            labelsStack.addArrangedSubview(descrLabel)
            labelsStack.addArrangedSubview(avatarsStack)
            labelsStack.setCustomSpacing(8, after: descrLabel)
//            labelsStack.
            activateConstraints()
            acceptInviteButton.addTarget(self, action: #selector(onAcceptInviteButtonTouchUpInside), for: .touchUpInside)
            cancelButton.addTarget(self, action: #selector(onCancelInviteButtonTouchUpInside), for: .touchUpInside)
//            self.backgroundColor = .secondarySystemBackground
//            backgroundColor = .secondarySystemBackground
//            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 96, right: 0)
//            selectionStyle = .none
        }
        
        open var cellDelegate: GroupListActionsCellDelegate? = nil
        
        var primary: String? = nil
        
        @objc
        internal func onAcceptInviteButtonTouchUpInside(_ sender: UIButton) {
            if let primary = primary {
                self.cellDelegate?.acceptInvite(invitePrimary: primary)
            }
        }
        
        @objc
        internal func onCancelInviteButtonTouchUpInside(_ sender: UIButton) {
            if let primary = primary {
                self.cellDelegate?.cancelInvite(invitePrimary: primary)
            }
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
}

protocol GroupListActionsCellDelegate {
    func acceptInvite(invitePrimary primary: String)
    func cancelInvite(invitePrimary primary: String)
}

protocol ContactCellSubscribtionActionsDelegate {
    func acceptSubscribtionRequest(jid: String, owner: String)
    func cancelSubscribtionRequest(jid: String, owner: String)
}
