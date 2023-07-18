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
import LetterAvatarKit
import MaterialComponents.MDCPalettes

extension GroupchatInviteListViewController {
    class ContactCell: UITableViewCell {

        static let cellName: String = "ContactCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 8, right: 16)
            
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
        
        internal let usernameLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.textColor = .darkText
            
            return label
        }()
        
        internal let statusLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = MDCPalette.grey.tint500
            
            return label
        }()
        
        internal let statusIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            
            view.frame = CGRect(square: 12)
            
            return view
        }()
        
        internal let selectedIndicator: UIView = {
            let view = UIView()
            
            return view
        }()
        
        
        
        internal func updateAvatar(_ avatarKey: String, owner: String) {
            let circleAvatarImage = LetterAvatarMaker()
                .setCircle(true)
                .setUsername(avatarKey.capitalized)
                .setBorderWidth(1.0)
                .setBackgroundColors([AccountColorManager.shared.primaryColor(for: owner)])
                .build()
            avatarView.image = circleAvatarImage
        }
        
        internal func activateConstraints() {
            avatarView.heightAnchor.constraint(equalToConstant: 48).isActive = true
            avatarView.widthAnchor.constraint(equalToConstant: 48).isActive = true
            statusIndicator.heightAnchor.constraint(equalToConstant: 12).isActive = true
            statusIndicator.widthAnchor.constraint(equalToConstant: 12).isActive = true
        }
        
        open func configure(_ jid: String, owner: String, failed: Bool) {
            usernameLabel.text = jid
//            statusLabel.text = jid
            if failed {
                usernameLabel.textColor = MDCPalette.red.tint500//.systemRed
            }
            updateAvatar(jid, owner: owner)
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            avatarView.image = nil
//            if #available(iOS 13.0, *) {
//                usernameLabel.textColor = .label
//            } else {
                usernameLabel.textColor = .darkText
//            }
            usernameLabel.text = nil
            statusLabel.text = nil
            statusIndicator.setStatus(status: .offline, entity: .contact)
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
            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(labelsStack)
            labelsStack.addArrangedSubview(usernameLabel)
//            labelsStack.addArrangedSubview(statusLabel)
            activateConstraints()
            
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 66, right: 0)
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
