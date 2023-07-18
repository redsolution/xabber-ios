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

extension GroupchatDefaultRightsViewController {
    
        
    class ListItemEditCell: UITableViewCell {
        
        public static let cellName: String = "ListItemEditCell"
        
        internal var itemId: String = ""
        public var delegate: GroupchatDefaultRightsDelegate? = nil
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 20, right: 16)
            
            return stack
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
//            if #available(iOS 13.0, *) {
//                label.textColor = .label
//            } else {
                label.textColor = .darkText
//            }
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        internal let valueLabel: UILabel = {
            let label = UILabel()
            
//            if #available(iOS 13.0, *) {
//                label.textColor = .secondaryLabel
//            } else {
                label.textColor = MDCPalette.grey.tint600
//            }
            
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            
            return label
        }()
        
        internal let switchItem: UISwitch = {
            let view = UISwitch()
            
            return view
        }()
        
        @objc
        internal func onSwitchChangeValue(_ sender: UISwitch) {
            CATransaction.setCompletionBlock {
                self.delegate?.onChangeState(self.itemId, sender: sender)
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
        }
        
        open func configure(itemId: String, title: String, value: String?) {
            self.itemId = itemId
            titleLabel.text = title
            valueLabel.text = value
            switchItem.isOn = value != nil
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(valueLabel)
            stack.addArrangedSubview(switchItem)
            switchItem.addTarget(self, action: #selector(onSwitchChangeValue), for: .valueChanged)
//            if #available(iOS 13.0, *) {
//                self.backgroundColor = .secondarySystemGroupedBackground
//            } else {
                self.backgroundColor = .white
//            }
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
    }
    
}
