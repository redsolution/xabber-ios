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

extension SettingsItemDetailViewController {
    class SwitchCell: UITableViewCell {
        
        static let cellName = "SwitchCell"
        
        var key: String = ""
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
            
            return stack
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            return label
        }()
        
        internal let valueSwitch: UISwitch = {
            let view = UISwitch(frame: .zero)
            
            return view
        }()
        
        open var switchCallback: ((String, Bool)->Void)? = nil
        
        @objc
        private func switchValueDidChange(_ sender: UISwitch) {
//            CATransaction.setCompletionBlock {
                //... animation just finished
                self.switchCallback?(self.key, sender.isOn)
//            }
        }
        
        internal func activateConstraints() {
            //            stack.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 1).isActive = true
        }
        
        open func configure(_ key: String, for title: String, active: Bool) {
            self.key = key
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(valueSwitch)
            titleLabel.text = title
            valueSwitch.isOn = active
            valueSwitch.addTarget(self, action: #selector(switchValueDidChange), for: .valueChanged)
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
