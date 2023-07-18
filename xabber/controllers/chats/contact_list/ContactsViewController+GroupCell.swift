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

extension ContactsViewController {
    class GroupCell: UITableViewCell {
        static let cellName: String = "GroupCell"
                
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 16, right: 16)
            
            return stack
        }()
//
//        internal let collapsedButton: UIButton = {
//            let button = UIButton(type: .)
//
//            return button
//        }()
//
        internal let collapsedIcon: UIImageView = {
            let view = UIImageView()
            
            view.tintColor = MDCPalette.grey.tint400
            
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
        
        internal var subtitleButton: UIButton = {
            let button = UIButton()
            
            button.setImage(#imageLiteral(resourceName: "group-incognito"), for: .normal)
            if #available(iOS 13.0, *) {
                button.tintColor = .secondaryLabel
                button.setTitleColor(.secondaryLabel, for: .normal)
            } else {
                button.tintColor = .gray
                button.setTitleColor(.gray, for: .normal)
            }
            
            return button
        }()
        
        internal var subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
//            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = .gray
            }
            
            return label
        }()
        
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
                collapsedIcon.widthAnchor.constraint(equalToConstant: 24),
                collapsedIcon.heightAnchor.constraint(equalToConstant: 24)
            ])
        }
        
        open func configure(title: String, subtitle: String?, collapsed: Bool) {
            titleLabel.text = title
            subtitleLabel.text = subtitle
            if collapsed {
                collapsedIcon.image = #imageLiteral(resourceName: "menu-up").withRenderingMode(.alwaysTemplate)
            } else {
                collapsedIcon.image = #imageLiteral(resourceName: "menu-down").withRenderingMode(.alwaysTemplate)
            }
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(subtitleLabel)
            stack.addArrangedSubview(collapsedIcon)
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
