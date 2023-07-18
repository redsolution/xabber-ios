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
    class InfoCell: UITableViewCell {
        
        enum Style {
            case info
            case button
            case danger
        }
        
        public static let cellName: String = "InfoCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 16
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 16, right: 8)
            
            return stack
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            label.textColor = .darkText
            
            return label
        }()
        
        internal let valueLabel: UILabel = {
            let label = UILabel()
            
            label.textColor = MDCPalette.grey.tint600
            
            return label
        }()
        
        internal let statusIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            
            view.frame = CGRect(square: 18)
            view.isHidden = true
            
            return view
        }()
        
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
                statusIndicator.heightAnchor.constraint(equalToConstant: 18),
                statusIndicator.widthAnchor.constraint(equalToConstant: 18)
            ])
        }
        
        open func configure(_ style: Style, title: String, value: String, checked: Bool) {
            titleLabel.text = title
            valueLabel.text = value
            switch style {
            case .info:
//                if #available(iOS 13.0, *) {
//                    titleLabel.textColor = .label
//                } else {
                    titleLabel.textColor = .darkText
//                }
            case .button:
                titleLabel.textColor = MDCPalette.blue.tint500//.systemBlue
            case .danger:
                titleLabel.textColor = MDCPalette.red.tint500//.systemRed
            }
            if checked {
                accessoryType = .checkmark
            } else {
                accessoryType = .none
            }
        }
        
        public final func configureForStatus(value: String?, entity: RosterItemEntity) {
            let status = ResourceStatus(rawValue: value == "active" ? "online" : (value ?? "none")) ?? .offline
            statusIndicator.isHidden = false
            statusIndicator.border(1)
            statusIndicator.setStatus(status: status, entity: entity)
            activateConstraints()
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(statusIndicator)
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(valueLabel)
            selectionStyle = .none
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
