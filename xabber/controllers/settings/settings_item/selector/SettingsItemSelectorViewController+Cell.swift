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

extension SettingsItemSelectorViewController {
    
    class Cell: UITableViewCell {
        
        static let cellName = "SelectionCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
            
            return stack
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            return label
        }()
        
        internal func activateConstraints() {
            //            stack.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 1).isActive = true
        }
        
        open func configure(for title: String, active: Bool) {
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(titleLabel)
            titleLabel.text = title.split(separator: "_").joined(separator: " ").capitalized
            if active {
                accessoryType = .checkmark
            } else {
                accessoryType = .none
            }
            selectionStyle = .none
            activateConstraints()
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
        
    }
    
}
