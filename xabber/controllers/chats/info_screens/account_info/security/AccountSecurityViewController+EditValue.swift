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

extension AccountSecurityViewController {
    class EditValue: UITableViewCell {
        
        static let cellName = "EditValueCell"
        
        enum Kind {
            case regular
            case password
        }
        
        internal var key: String = ""
        
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
            
            return stack
        }()
        
        var field: UITextField = {
            let field = UITextField()
            
            return field
        }()
        
        var callback: ((UITextField) -> Bool)? = nil
        
        private func activateConstraints() {
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.95).isActive = true
        }
        
        func configure(_ kind: Kind, for title: String, value: String, key: String) {
            self.key = key
            addSubview(stack)
            selectionStyle = .none
            stack.fillSuperview()
            stack.addArrangedSubview(field)
            backgroundColor = .white
            field.text = value.isEmpty ? nil : value
            field.placeholder = title
            field.autocorrectionType = .no
            field.returnKeyType = .done
            field.clearButtonMode = .always
            field.keyboardType = .default
            field.restorationIdentifier = key
            field.addTarget(self, action: #selector(fieldDidChange), for: .editingChanged)
            switch kind {
            case .regular:
                break
            case .password:
                field.isSecureTextEntry = true
                field.clearsOnBeginEditing = true
                field.clearsOnInsertion = true
            }
            activateConstraints()
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
        
        @objc
        internal func fieldDidChange(_ sender: UITextField) {
            callback?(sender)
        }
    }
}
