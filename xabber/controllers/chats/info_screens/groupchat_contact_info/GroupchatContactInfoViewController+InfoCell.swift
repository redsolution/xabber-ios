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

extension GroupchatContactInfoViewController {
    class InfoCell: UITableViewCell {
        
        enum Style {
            case list
            case info
            case button
            case danger
        }
        
        public static let cellName: String = "InfoCell"
        
        internal var itemId: String = ""
        public var delegate: GroupchatContactInfoPermissionDelegate? = nil
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 20, right: 16)
            
            return stack
        }()
        
        internal let labelsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            
            return stack
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            label.textColor = .darkText
            
            return label
        }()
        
        internal let valueLabel: UILabel = {
            let label = UILabel()
            
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = MDCPalette.grey.tint600
            }
            
            return label
        }()
        
        internal let switchItem: UISwitch = {
            let view = UISwitch()
            view.isHidden = true
            return view
        }()
        
        @objc
        internal func onSwitchChangeValue(_ sender: UISwitch) {
            CATransaction.setCompletionBlock {
                self.delegate?.onChangePermission(sender: sender, itemId: self.itemId, value: sender.isOn)
            }
        }
        
        internal func activateConstraints() {
            
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            titleLabel.text = nil
            valueLabel.text = nil
            switchItem.isOn = false
            accessoryType = .none
            switchItem.isHidden = true
        }
        
        open func configure(_ style: Style, itemId: String, title: String, value: String?, editable: Bool, last: Bool) {
            self.itemId = itemId
            titleLabel.text = title
            valueLabel.text = value
            switchItem.setOn(value != nil, animated: false)
            switch style {
            case .info:
                if #available(iOS 13.0, *) {
                    titleLabel.textColor = .label
                } else {
                    titleLabel.textColor = .darkText
                }
            case .button:
                titleLabel.textColor = MDCPalette.blue.tint500//.systemBlue
            case .danger:
                titleLabel.textColor = MDCPalette.red.tint500//.systemRed
            case .list:
                switchItem.isHidden = false
            }
            if editable {
                accessoryType = .disclosureIndicator
            } else {
                accessoryType = .none
            }
            if last {
                separatorInset = .zero
            }
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            labelsStack.addArrangedSubview(titleLabel)
            labelsStack.addArrangedSubview(valueLabel)
            stack.addArrangedSubview(labelsStack)
            stack.addArrangedSubview(switchItem)
            switchItem.addTarget(self, action: #selector(onSwitchChangeValue), for: .valueChanged)
            if #available(iOS 13.0, *) {
                self.backgroundColor = .secondarySystemGroupedBackground
            } else {
                self.backgroundColor = .white
            }
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
