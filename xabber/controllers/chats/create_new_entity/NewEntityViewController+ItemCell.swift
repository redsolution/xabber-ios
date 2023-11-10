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

extension NewEntityViewController {
    class ItemCell: UITableViewCell {
        enum Style {
            case info
            case button
            case danger
        }
        
        public static let cellName: String = "ItemCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 12
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 20, right: 8)
            
            return stack
        }()
        
        internal let icon: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 24))
            
            return view
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            label.textColor = .darkText
            
            return label
        }()
        
        internal let separatorView: UIView = {
            let view = UIView()
            
            view.backgroundColor = UIColor.black.withAlphaComponent(0.27)
            
            return view
        }()
        
        internal func activateConstraints() {
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        
        open func configure(_ style: Style, title: String, icon: UIImage, editable: Bool, last: Bool) {
//            if
//            sel
            titleLabel.text = title
            self.icon.image = icon.withRenderingMode(.alwaysTemplate)
            switch style {
            case .info:
                titleLabel.textColor = .darkText
                self.icon.tintColor = .darkText
            case .button:
                titleLabel.textColor = MDCPalette.blue.tint500
                self.icon.tintColor = MDCPalette.blue.tint500
            case .danger:
                titleLabel.textColor = MDCPalette.red.tint500
                self.icon.tintColor = MDCPalette.red.tint500
            }
            if editable {
                accessoryType = .disclosureIndicator
            } else {
                accessoryType = .none
            }
//            if last {
//                separatorView.frame = CGRect(x: 0, y: self.frame.height - 1, width: self.frame.width, height: 0.5)
//            } else {
//                separatorView.frame = CGRect(x: 56, y: self.frame.height - 1, width: self.frame.width - 56, height: 0.5)
//            }
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 60, right: 0)
            if last {
                separatorInset = .zero
            }
            
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            addSubview(separatorView)
            stack.fillSuperview()
            stack.addArrangedSubview(icon)
            stack.addArrangedSubview(titleLabel)
            activateConstraints()
            selectionStyle = .none
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
