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
        
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
                avatarView.heightAnchor.constraint(equalToConstant: 48),
                avatarView.widthAnchor.constraint(equalToConstant: 48),
                statusIndicator.heightAnchor.constraint(equalToConstant: 18),
                statusIndicator.widthAnchor.constraint(equalToConstant: 18)
            ])
        }
        
        open func configure(title: String, subtitle: String, status: ResourceStatus, entity: RosterItemEntity, jid: String, owner: String, showAvatar: Bool) {
            titleLabel.text = title
            subtitleLabel.text = JidManager.shared.prepareJid(jid: subtitle)
            
            switch entity {
            case .groupchat, .incognitoChat, .bot, .server, .issue:
                statusIndicator.border(1)
                statusIndicator.setStatus(status: status, entity: entity)
            default:
                statusIndicator.border(4)
                statusIndicator.setStatus(status: status, entity: entity)
            }
            if showAvatar {
                avatarView.isHidden = false
                DefaultAvatarManager.shared.getAvatar(jid: jid, owner: owner, size: 48) { image in
                    self.avatarView.image = image
                }
            } else {
                avatarView.isHidden = true
            }
        }
        
        func setMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt), AccountMasksManager.shared.load() != "square" {
                avatarView.mask = UIImageView(image: image)
            } else {
                avatarView.mask = nil
            }
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            self.layer.shouldRasterize = true
            self.layer.rasterizationScale = UIScreen.main.scale
            stack.fillSuperview()
            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(labelsStack)
            stack.addArrangedSubview(statusIndicator)
            labelsStack.addArrangedSubview(titleLabel)
            labelsStack.addArrangedSubview(subtitleLabel)
            activateConstraints()
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 66, right: 0)
            selectionStyle = .none
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
