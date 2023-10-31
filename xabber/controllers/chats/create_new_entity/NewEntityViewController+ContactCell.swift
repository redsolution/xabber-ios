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

extension NewEntityViewController {
    class ContactCell: UITableViewCell {
        static let cellName: String = "ContactCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 8, right: 8)
            
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
//            if #available(iOS 13.0, *) {
//                label.textColor = .secondaryLabel
//            } else {
                label.textColor = MDCPalette.grey.tint500//.systemGray
//            }
            
            return label
        }()
        
        internal let statusIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            
            view.frame = CGRect(square: 18)
            
            return view
        }()
        
        internal let accountIndicator: UIView = {
            let view = UIView()
            
            return view
        }()
        
        internal let separatorView: UIView = {
            let view = UIView()
            
            view.backgroundColor = UIColor.black.withAlphaComponent(0.27)
            
            return view
        }()
        
        internal func updateAvatar(_ avatarKey: String) {
            avatarView.kf.setImage(with: KF.ImageResource(downloadURL: URL(string: avatarKey)!, cacheKey: avatarKey),
                                   placeholder: nil,
                                   options: [.alsoPrefetchToMemory, .onlyFromCache],
                                   progressBlock: nil) { (result) in
                
            }
        }
        
        internal func activateConstraints() {
            avatarView.heightAnchor.constraint(equalToConstant: 48).isActive = true
            avatarView.widthAnchor.constraint(equalToConstant: 48).isActive = true
            statusIndicator.heightAnchor.constraint(equalToConstant: 18).isActive = true
            statusIndicator.widthAnchor.constraint(equalToConstant: 18).isActive = true
        }
        
        open func configure(_ jid: String, username: String, indicatorColor: UIColor, status: ResourceStatus, entity: RosterItemEntity, avatarKey: String) {
            usernameLabel.text = username
            statusLabel.text = jid
            accountIndicator.backgroundColor = indicatorColor.withAlphaComponent(0.7)
            
//            if last {
//                separatorView.frame = CGRect(x: 0, y: self.frame.height - 1, width: self.frame.width, height: 0.5)
//            } else {
                separatorView.frame = CGRect(x: 64, y: self.frame.height - 1, width: self.frame.width - 64, height: 0.5)
//            }
            
            switch entity {
            case .groupchat, .incognitoChat, .bot, .server, .issue:
                statusIndicator.border(1)
                statusIndicator.setStatus(status: status, entity: entity)
            default:
                statusIndicator.border(4)
                statusIndicator.setStatus(status: status, entity: entity)
            }
            updateAvatar(avatarKey)
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
            addSubview(separatorView)
            stack.fillSuperview()
            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(labelsStack)
            stack.addArrangedSubview(statusIndicator)
            labelsStack.addArrangedSubview(usernameLabel)
            labelsStack.addArrangedSubview(statusLabel)
            accountIndicator.frame = CGRect(x: 0, y: 1, width: 2, height: 62)
            addSubview(accountIndicator)
            accountIndicator.backgroundColor = .clear
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
