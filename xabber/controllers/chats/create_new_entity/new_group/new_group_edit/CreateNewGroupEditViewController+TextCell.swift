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

extension CreateNewGroupEditViewController {
    class TextCell: UITableViewCell {
        public static let cellName = "VCardEditedItemCell"
                
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
            
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.keyboardType = .URL
            field.returnKeyType = .done
            
            return field
        }()
        
        var callback: ((UITextField) -> Void)? = nil
        
        private func activateConstraints() {
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.95).isActive = true
        }
        
        func configure(_ title: String, value: String) {
//            addSubview(stack)
//            selectionStyle = .none
//            stack.fillSuperview()
//            stack.addArrangedSubview(field)
//            backgroundColor = .white
//            activateConstraints()
            field.text = value.isEmpty ? nil : value
            field.placeholder = title
            field.clearButtonMode = .always
            field.addTarget(self, action: #selector(fieldDidChange), for: .editingChanged)
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            selectionStyle = .none
            stack.fillSuperview()
            stack.addArrangedSubview(field)
            backgroundColor = .white
            activateConstraints()
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
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
