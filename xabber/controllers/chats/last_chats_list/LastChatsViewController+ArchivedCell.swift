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

extension LastChatsViewController {
    class ArchivedCell: CellWithBadge {
        static let cellName = "ArchivedCell"
        
        let infoStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.distribution = .fill
            stack.spacing = 0
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 6, bottom: 6, left: 4, right: 4)
            
            return stack
        }()
        
        let iconButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 56))

            button.setImage(imageLiteral( "archive-filled")?.withRenderingMode(.alwaysTemplate), for: .normal)
            button.layer.cornerRadius = 27
            button.layer.masksToBounds = true
            
            if #available(iOS 13.0, *) {
                button.tintColor = .systemBackground
            } else {
                button.tintColor = .white
            }
            button.backgroundColor = MDCPalette.grey.tint400
            
            return button
        }()
        
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            if #available(iOS 13.0, *) {
                label.textColor = .label
            } else {
                label.textColor = UIColor(red:0.13, green:0.13, blue:0.13, alpha:1)
            }
            label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        let bottomStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .top
            stack.spacing = 8
//            stack.distribution = .fill
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 32)

            return stack
        }()
        
        let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.lineBreakMode = .byWordWrapping
            label.numberOfLines = 0
            
            return label
        }()
        
        let unreadLabel: UILabel = {
            let label = UILabel()
            
            label.backgroundColor = UIColor(red:0.11, green:0.37, blue:0.13, alpha:1)
            
            return label
        }()
        
        private func activateConstraints() {
            NSLayoutConstraint.activate([
                bottomStack.heightAnchor.constraint(equalToConstant: 36)
            ])
            
        }
        
        public final func configure(title: String, text: NSAttributedString, count: Int) {
            titleLabel.text = title
            subtitleLabel.attributedText = text
            subtitleLabel.numberOfLines = 0
            if count > 0 {
                badgeColor = MDCPalette.grey.tint500
                badgeString = "\(count)"
            } else {
                badgeString = ""
            }
            
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            titleLabel.text = nil
            titleLabel.attributedText = nil
            subtitleLabel.attributedText = nil
            subtitleLabel.text = nil
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(infoStack)
//            UIEdgeInsets(top: 6, bottom: 8, left: 72, right: 0)
            infoStack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 72, right: 0)
            if #available(iOS 13.0, *) {
                backgroundColor = .systemBackground
            } else {
                backgroundColor = .white
            }
            
            iconButton.frame = CGRect(x: 10, y: 10, width: 56, height: 56)
            addSubview(iconButton)
            
            infoStack.addArrangedSubview(titleLabel)
            infoStack.addArrangedSubview(bottomStack)
            bottomStack.addArrangedSubview(subtitleLabel)
            
            
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 74, right: 0)
            
            contentView.backgroundColor = MDCPalette.grey.tint100
            
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
