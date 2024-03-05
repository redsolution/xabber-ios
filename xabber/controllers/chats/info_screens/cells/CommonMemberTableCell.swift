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
import Kingfisher

class CommonMemberTableCell: UITableViewCell {
    static let cellName: String = "CommonMemberTableCell"
            
    internal let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 8
        
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 16, right: 18)
        
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
    
    internal let avatarGroupView: UIView = {
        let view = UIView(frame: CGRect(square: 48))
        
        return view
    }()
    
    internal let avatarView: UIImageView = {
        let view = UIImageView(frame: CGRect(square: 48))
        if let image = UIImage(named: AccountMasksManager.shared.mask48pt), AccountMasksManager.shared.load() != "square" {
            view.mask = UIImageView(image: image)
        } else {
            view.mask = nil
        }
        view.contentMode = .scaleAspectFill
        
        return view
    }()
    
    internal let titleStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.spacing = 4
        
        return stack
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
    
    internal let badgeLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.textColor = MDCPalette.grey.tint600
        
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
        
        view.frame = CGRect(x: 34, y: 34, width: 12, height: 12)
        
        return view
    }()
    
    internal let roleIndicator: UIImageView = {
        let view = UIImageView(frame: CGRect(square: 24))
        
        if #available(iOS 13.0, *) {
            view.tintColor = .secondaryLabel
        } else {
            view.tintColor = .gray
        }
        
        return view
    }()
    
    internal func activateConstraints() {
        NSLayoutConstraint.activate([
            avatarGroupView.heightAnchor.constraint(equalToConstant: 48),
            avatarGroupView.widthAnchor.constraint(equalToConstant: 48),
            roleIndicator.heightAnchor.constraint(equalToConstant: 18),
            roleIndicator.widthAnchor.constraint(equalToConstant: 18)
        ])
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        if #available(iOS 13.0, *) {
            subtitleLabel.textColor = .secondaryLabel
        } else {
            subtitleLabel.textColor = MDCPalette.grey.tint500//.systemGray
        }
//            self.avatarView.image = nil
//            self.s
    }
    
    open func configure(jid: String, owner: String, userId: String?, title: String, badge: String, isMe: Bool, subtitle: String, status: ResourceStatus, entity: RosterItemEntity, role: GroupchatUserStorageItem.Role) {
        titleLabel.text = title
        if let userId = userId {
            DefaultAvatarManager.shared.getGroupAvatar(user: userId, jid: jid, owner: owner, size: 48) { image in
                self.avatarView.image = image
            }
        } else {
            DefaultAvatarManager.shared.getAvatar(url: nil, jid: jid, owner: owner, size: 48) { image in
                if let image = image {
                    self.avatarView.image = image
                } else {
                    self.avatarView.image = UIImageView.getDefaultAvatar(for: jid, owner: owner, size: 48)
                }
            }
        }
        
        let attributedBadge = NSMutableAttributedString(string: badge, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .caption1),
            .foregroundColor: MDCPalette.grey.tint600
        ])
        attributedBadge.addAttribute(NSAttributedString.Key.baselineOffset, value: -0.5, range: NSRange(0..<attributedBadge.string.count))
        badgeLabel.attributedText = attributedBadge
//            subtitleLabel.text = subtitle
        
        if isMe {
            subtitleLabel.textColor = .systemRed
            subtitleLabel.text = "This is you".localizeString(id: "this_is_you", arguments: [])
        } else if status == .online {
            subtitleLabel.textColor = MDCPalette.green.tint700
            subtitleLabel.text = subtitle
        } else {
            subtitleLabel.text = subtitle
        }
        switch entity {
        case .groupchat, .incognitoChat, .bot, .server, .issue:
            statusIndicator.border(1)
            statusIndicator.setStatus(status: status, entity: entity)
        default:
            statusIndicator.border(1)
            statusIndicator.setStatus(status: status, entity: entity)
        }
                
        switch role {
        case .owner:
            roleIndicator.image = #imageLiteral(resourceName: "star").withRenderingMode(.alwaysTemplate)
        case .admin:
            roleIndicator.image = #imageLiteral(resourceName: "star-outline").withRenderingMode(.alwaysTemplate)
        case .member:
            roleIndicator.image = nil
        }
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(stack)
        stack.fillSuperview()
        avatarGroupView.addSubview(avatarView)
        avatarGroupView.addSubview(statusIndicator)
        stack.addArrangedSubview(avatarGroupView)
        stack.addArrangedSubview(labelsStack)
        stack.addArrangedSubview(roleIndicator)
        labelsStack.addArrangedSubview(titleStack)
        labelsStack.addArrangedSubview(subtitleLabel)
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(badgeLabel)
        activateConstraints()
        separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 66, right: 0)
        selectionStyle = .none
    }
    
    func setMask() {
        if let image = UIImage(named: AccountMasksManager.shared.mask48pt), AccountMasksManager.shared.load() != "square" {
            avatarView.mask = UIImageView(image: image)
        } else {
            avatarView.mask = nil
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
