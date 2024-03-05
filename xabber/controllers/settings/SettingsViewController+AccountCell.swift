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
import RxSwift
import RxCocoa

extension SettingsViewController {
    class AccountCell: UITableViewCell {
        static let cellName: String = "AccountCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 10
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 8, right: 8)
            
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
            
            view.frame = CGRect(square: 14)
            
            return view
        }()
        
        internal var bag: DisposeBag = DisposeBag()
        
        internal func updateAvatar(_ jid: String, enabled: Bool) {
            if enabled {
                DefaultAvatarManager.shared.getAvatar(url: nil, jid: jid, owner: jid, size: 48) { image in
                    if let image = image {
                        self.avatarView.image = image
                    } else {
                        self.avatarView.image = UIImageView.getDefaultAvatar(for: jid, owner: jid, size: 48)
                    }
                }
            } else {
                DefaultAvatarManager.shared.getAvatar(url: nil, jid: jid, owner: jid, size: 48, callback: { image in
                    if let image = image {
                        self.avatarView.image = image.grayscale
                    } else {
                        self.avatarView.image = UIImageView.getDefaultAvatar(for: jid, owner: jid, size: 48)?.grayscale
                        self.avatarView.image = self.avatarView.image?.grayscale
                    }
                })
            }
        }
        
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
                avatarView.heightAnchor.constraint(equalToConstant: 48),
                avatarView.widthAnchor.constraint(equalToConstant: 48),
                statusIndicator.heightAnchor.constraint(equalToConstant: 14),
                statusIndicator.widthAnchor.constraint(equalToConstant: 14)
            ])
        }
        
        open func configure(jid: String, username: String, status: ResourceStatus, statusText: String, enabled: Bool) {
            usernameLabel.text = username
            statusLabel.text = jid
            statusIndicator.border(0.1)
            statusIndicator.setStatus(status: status, entity: .contact)
            updateAvatar(jid, enabled: enabled)
            bag = DisposeBag()
        }
        
        func setMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt), AccountMasksManager.shared.load() != "square" {
                avatarView.mask = UIImageView(image: image)
            } else {
                avatarView.mask = nil
            }
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            bag = DisposeBag()
            avatarView.image = nil
            if #available(iOS 13.0, *) {
                usernameLabel.textColor = .label
            } else {
                usernameLabel.textColor = .darkText
            }
            usernameLabel.text = nil
            statusLabel.text = nil
            statusIndicator.setStatus(status: .offline, entity: .contact)
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(labelsStack)
            stack.addArrangedSubview(statusIndicator)
            labelsStack.addArrangedSubview(usernameLabel)
            labelsStack.addArrangedSubview(statusLabel)
            activateConstraints()
            accessoryType = .disclosureIndicator
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 72, right: 0)
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        deinit {
            bag = DisposeBag()
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
}
