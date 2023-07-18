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

extension GroupchatInviteViewController {
    class GroupCell: UITableViewCell {
        static public let cellName: String = "GroupCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 8)
            
            return stack
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            return label
        }()
        
        internal let collapseButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 36))
            
            button.tintColor = MDCPalette.grey.tint700
            
            return button
        }()
        
        internal func activateConstraints() {
            
        }
        
        open func configure(title: String, collapsed: Bool) {
            titleLabel.text = title
            if collapsed {
                
            } else {
                
            }
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(collapseButton)
            stack.addArrangedSubview(titleLabel)
            activateConstraints()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}

