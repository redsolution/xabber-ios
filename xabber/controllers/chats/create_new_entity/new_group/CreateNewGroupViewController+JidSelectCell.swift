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

extension CreateNewGroupViewController {
    class JidSelectCell: UITableViewCell {
        public static let cellName: String = "JidSelectCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 4
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 8)
            
            return stack
        }()
        
        internal let textField: UITextField = {
            let field = UITextField()
            
            field.placeholder = "Localpart".localizeString(id: "localpart", arguments: [])
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.keyboardType = .asciiCapable
            
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
//            field.
            
            return field
        }()
        
        internal let label: UILabel = {
            let label = UILabel()
            
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            
            return label
        }()
        
        internal var itemId: String = ""
        var delegate: CreateNewGroupViewControllerDelegate? = nil
        
        @objc
        func onValueChanged(_ sender: UITextField) {
            delegate?.willUpdateTextField(itemId, value: sender.text)
        }
        
        internal func activateConstraints() {
            textField.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        
        open func configure(_ itemId: String, localpart: String?, placeholder: String, server: String) {
            self.itemId = itemId
            textField.placeholder = placeholder
            textField.text = localpart
            label.text = server
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(textField)
            stack.addArrangedSubview(label)
            accessoryType = .disclosureIndicator
            selectionStyle = .none
            textField.addTarget(self, action: #selector(onValueChanged), for: .editingChanged)
            activateConstraints()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
    }
}
