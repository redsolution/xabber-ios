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

extension AccountBlockListViewController {
    class ItemCell: UITableViewCell {
        
        static let cellName = "ItemCell"
        
        public let initialAvatarSize: CGSize = CGSize(square: 48)
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 12
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 16, right: 16)
            
            return stack
        }()
        
        internal let avatarView: UIImageView = {
            let image = UIImageView(frame: CGRect(square: 48))
            
            image.contentMode = .scaleAspectFill
            image.layer.borderWidth = 0.1
            image.layer.masksToBounds = true
            image.layer.borderColor = UIColor.white.cgColor
            if AccountMasksManager.shared.load() != "square" {
                image.mask = UIImageView(image: #imageLiteral(resourceName: AccountMasksManager.shared.mask48pt))
            } else {
                image.mask = nil
            }
            image.layoutIfNeeded()
            
            return image
        }()
        
        internal let usernameLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            if #available(iOS 13.0, *) {
                label.textColor = .label
            } else {
                label.textColor = .darkText
            }
            
            return label
        }()
        
        internal let labelStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.distribution = .equalSpacing
            
            return stack
        }()
        
        internal func activateConstraints() {
            
            NSLayoutConstraint.activate([
                stack.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 1),
                avatarView.widthAnchor.constraint(equalToConstant: initialAvatarSize.width),
                avatarView.heightAnchor.constraint(equalTo: avatarView.widthAnchor, multiplier: 1)
            ])
        }
        
        open func configure(_ jid: String, owner: String, enabled: Bool) {
            usernameLabel.text = JidManager.shared.prepareJid(jid: jid)
            DefaultAvatarManager.shared.getAvatar(url: nil, jid: jid, owner: owner, size: 48) { image in
                if let image = image {
                    self.avatarView.image = image
                } else {
                    self.avatarView.image = UIImageView.getDefaultAvatar(for: jid, owner: owner, size: 48)
                }
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
            stack.fillSuperview()
            labelStack.addArrangedSubview(usernameLabel)
            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(labelStack)
            activateConstraints()
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 72, right: 0)
            selectionStyle = .none

        }
        
        required init?(coder: NSCoder) {
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
