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

extension NewCallViewController {
    class ItemCell: UITableViewCell {
        static let cellName = "ItemCell"
        
        internal var jid: String = ""
        internal var owner: String = ""
        
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 8
            stack.distribution = .fill
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 12)
            
            return stack
        }()
        
        let middleStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.distribution = .fill
//            stack.spacing = 4
            
            return stack
        }()
        
        let infoStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
//            stack.distribution = .
            stack.spacing = 6
            
            return stack
        }()
        
        
        let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 48))
            if let image = UIImage(named: AccountMasksManager.shared.mask176pt), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
            view.contentMode = .scaleAspectFill
            
            return view
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            
            return label
        }()
        
        let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = MDCPalette.grey.tint500//.systemGray
            }
            
            return label
        }()
                
        let stateIndicator: UIImageView = {
            let view = UIImageView()
            
            view.isHidden = true
            
            
            return view
        }()
        
        let accountIndicator: UIView = {
            let view = UIView()
            
            view.backgroundColor = .clear
            
            return view
        }()
        
        let callButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 36))
            
            button.backgroundColor = MDCPalette.grey.tint100
            button.setImage(#imageLiteral(resourceName: "call").withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = MDCPalette.grey.tint500
            button.layer.cornerRadius = button.frame.width / 2
            button.layer.masksToBounds = true
            button.imageEdgeInsets = UIEdgeInsets(square: 6)
            
            return button
        }()
        
        internal var onCallButtonPress: ((String, String) -> Void)? = nil
        
        func configureAvatar(_ jid: String, avatarUrl: String?) {
            DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 48) { image in
                if let image = image {
                    self.avatarView.image = image
                } else {
                    self.avatarView.setDefaultAvatar(for: jid, owner: self.owner)
                }
            }
        }
        
        private func activateConstraints() {
            let constraints: [NSLayoutConstraint] = [
                avatarView.widthAnchor.constraint(equalToConstant: 48),
                avatarView.heightAnchor.constraint(equalToConstant: 48),
                titleLabel.heightAnchor.constraint(equalToConstant: 20),
                infoStack.heightAnchor.constraint(equalToConstant: 20),
                callButton.widthAnchor.constraint(equalToConstant: 36),
                callButton.heightAnchor.constraint(equalToConstant: 36),
                stateIndicator.widthAnchor.constraint(equalToConstant: 18),
                stateIndicator.heightAnchor.constraint(equalToConstant: 18),
                accountIndicator.widthAnchor.constraint(equalToConstant: 2),
                accountIndicator.heightAnchor.constraint(equalTo: stack.heightAnchor, multiplier: 1)
            ]
            NSLayoutConstraint.activate(constraints)
            
        }
        
        func configure(owner: String, jid: String, title: String, avatarUrl: String?) {
            self.jid = jid
            self.owner = owner
            self.configureAvatar(jid, avatarUrl: avatarUrl)
            titleLabel.text = title
            subtitleLabel.text = jid
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
            stack.addArrangedSubview(accountIndicator)
            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(middleStack)
            stack.addArrangedSubview(callButton)
            
            middleStack.addArrangedSubview(titleLabel)
            middleStack.addArrangedSubview(infoStack)
            
            infoStack.addArrangedSubview(stateIndicator)
            infoStack.addArrangedSubview(subtitleLabel)
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 66, right: 0)
            callButton.addTarget(self, action: #selector(onButtonPress), for: .touchUpInside)
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
        
        @objc
        internal func onButtonPress(_ sender: UIButton) {
            onCallButtonPress?(jid, owner)
        }
    }
}
