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

extension ShareDialogController {
    class ItemCell: UITableViewCell {
        static let cellName = "ItemCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .fill
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 8, right: 20)
            
            return stack
        }()
        
        let creditionalsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 6, left: 0, right: 0)
            
            return stack
        }()
        
        let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 48))
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
            
            return view
        }()
        
        let usernameLabel: UILabel = {
            let label = UILabel(frame: .zero)
            
            label.textColor = .black
            label.font = UIFont.preferredFont(forTextStyle: .body)
            
            return label
        }()
        
        let lastMessageLabel: UILabel = {
            let label = UILabel(frame: .zero)
            
            label.textColor = MDCPalette.grey.tint500
            label.font = UIFont.preferredFont(forTextStyle: .caption2)
            
            return label
        }()
        
        internal func activateConstraints() {
            avatarView.widthAnchor.constraint(equalToConstant: 48).isActive = true
            avatarView.heightAnchor.constraint(equalToConstant: 48).isActive = true
        }
        
        func configure(jid: String, owner: String, nickname: String, lastMessage: String?) {
            usernameLabel.text = nickname
            if let lastMessage = lastMessage {
                lastMessageLabel.text = lastMessage
            } else {
                lastMessageLabel.text = JidManager.shared.prepareJid(jid: jid)
            }
            DefaultAvatarManager.shared.getAvatar(url: nil, jid: jid, owner: owner, size: 48) { image in
                if let image = image {
                    self.avatarView.image = image
                } else {
                    self.avatarView.setDefaultAvatar(for: jid, owner: owner)
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
            
            
            creditionalsStack.addArrangedSubview(usernameLabel)
            creditionalsStack.addArrangedSubview(lastMessageLabel)
            
            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(creditionalsStack)
            
            addSubview(stack)
            stack.fillSuperview()
            activateConstraints()
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 64, right: 0)
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
