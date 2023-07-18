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

extension SearchResultsViewController {
    class ContactCell: CellWithBadge {
        static let cellName = "ContactCell"
        
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 8
            stack.distribution = .fill
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0.5, right: 0)
            
            return stack
        }()
        
        let infoStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.distribution = .fill
            stack.spacing = 2
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 12, bottom: 12, left: 4, right: 8)
            
            return stack
        }()
        
        let userImageView: UIView = {
            let view = UIView(frame: CGRect(square: 48))
            
            view.backgroundColor = .clear
            
            return view
        }()
        
        let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 48))
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
            view.contentMode = .scaleAspectFill
            
            return view
        }()
        
        let statusIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            
            view.frame = CGRect(square: 12)
            view.setStatus(status: .offline, entity: .contact)
            
            return view
        }()
        
        let usernameLabel: UILabel = {
            let label = UILabel()
            label.textColor = UIColor(red:0.13, green:0.13, blue:0.13, alpha:1)
            
            label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
            
            return label
        }()
        
        let jidLabel: UILabel = {
            let label = UILabel()
            
//            label.backgroundColor = .white
//            if #available(iOS 13.0, *) {
//                label.textColor = .label
//            } else {
                label.textColor = UIColor(red:0.56, green:0.56, blue:0.58, alpha:1)
//            }
            
            label.font = UIFont.systemFont(ofSize: 14)
            
            return label
        }()
        
        let accountIndicator: UIView = {
            let view = UIView()
            
            view.backgroundColor = .clear
            
            return view
        }()
        
        private func activateConstraints() {
            let constraints: [NSLayoutConstraint] = [
                userImageView.widthAnchor.constraint(equalToConstant: 48),
                userImageView.heightAnchor.constraint(equalToConstant: 48),
                accountIndicator.widthAnchor.constraint(equalToConstant: 2),
                accountIndicator.heightAnchor.constraint(equalTo: stack.heightAnchor, multiplier: 1)]
            NSLayoutConstraint.activate(constraints)
            
        }
        
        func configure(jid: String, owner: String, username: String, isGroupchat: Bool, status: ResourceStatus, indicator color: UIColor) {
            //            let start = CFAbsoluteTimeGetCurrent()
            
            
            DefaultAvatarManager.shared.getAvatar(jid: jid, owner: owner, size: 48, callback: { image in
                self.avatarView.image = image
            })
            
            usernameLabel.text = username
            jidLabel.text = jid
            
            accountIndicator.backgroundColor = color
            
            if isGroupchat {
                statusIndicator.isHidden = true
            } else {
                statusIndicator.isHidden = false
                statusIndicator.setStatus(status: status, entity: .contact)
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
            backgroundColor = .white
            
            stack.addArrangedSubview(accountIndicator)
            stack.addArrangedSubview(userImageView)
            stack.addArrangedSubview(infoStack)
            
            infoStack.addArrangedSubview(usernameLabel)
            infoStack.addArrangedSubview(jidLabel)
            
            statusIndicator.frame = CGRect(x: 34,
                                           y: 34,
                                           width: 14,
                                           height: 14)
            userImageView.addSubview(avatarView)
            userImageView.addSubview(statusIndicator)
            statusIndicator.border(2)
            statusIndicator.setStatus(status: .offline, entity: .contact)
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 74, right: 0)
            
            activateConstraints()
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

