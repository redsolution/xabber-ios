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

extension GroupchatSettingsViewController {
    class ItemCell: UITableViewCell {
        static let cellName: String = "ItemCell"
        
        open var delegate: GroupchatSettingsDelegate? = nil
        internal var itemId: String = ""
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.alignment = .center
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, left: 20, bottom: 4, right: 8)
            
            return stack
        }()
        
        internal let controlsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.alignment = .center
            stack.axis = .horizontal
            stack.distribution = .equalSpacing
            
            return stack
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel(frame: .zero)
            
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            
//            if #available(iOS 13.0, *) {
//                label.textColor = .label
//            } else {
                label.textColor = .darkText
//            }
            
            return label
        }()
        
        internal let altLabel: UILabel = {
            let label = UILabel(frame: .zero)
            
//            if #available(iOS 13.0, *) {
//                label.textColor = .secondaryLabel
//            } else {
                label.textColor = MDCPalette.grey.tint500
//            }
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        internal let stateSwitch: UISwitch = {
            let switcher = UISwitch(frame: .zero)
            
            return switcher
        }()
        
        
        @objc
        internal func onChangeState(_ sender: UISwitch) {
            CATransaction.setCompletionBlock {
                self.delegate?.onChangePermission(self.itemId, value: sender.isOn)
            }
        }
        
        internal func activateConstraints() {
            controlsStack.widthAnchor.constraint(equalToConstant: 92).isActive = true
        }
        
        internal func configure(_ itemId: String, title: String, enabled: Bool, editable: Bool, last: Bool) {
            self.itemId = itemId
            titleLabel.text = title
            stateSwitch.setOn(enabled, animated: false)
            accessoryType = editable ? .disclosureIndicator : .none
            if last {
                separatorInset = .zero
            }
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(stateSwitch)
            stateSwitch.addTarget(self, action: #selector(onChangeState), for: .valueChanged)
            activateConstraints()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
