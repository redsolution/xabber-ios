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
    class LargeTextItemCell: UITableViewCell, UITextViewDelegate {
        public static let cellName: String = "LargeTextItemCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 8)
            
            return stack
        }()
        
        let textField: UITextView = {
            let field = UITextView()
            
            field.isEditable = true
            field.isUserInteractionEnabled = true
            field.font = UIFont.preferredFont(forTextStyle: .body)
            field.contentInset = UIEdgeInsets(top: 8, bottom: 8, left: 16, right: 20)
            field.textAlignment = .justified
//            field.
            
            return field
        }()
        
        internal var itemId: String = ""
        var delegate: GroupchatSettingsDelegate? = nil
        
        internal func activateConstraints() {
            
        }
        
        open func configure(_ itemId: String, placeholder: String, value: String?, enabled: Bool) {
            self.itemId = itemId
//            textField.placeholder = placeholder
            textField.text = value
//            textField.isEditable = enabled
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(textField)
            textField.fillSuperview()
            textField.delegate = self
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func textViewDidChange(_ textView: UITextView) {
            delegate?.willUpdateSingleTextField(itemId, value: textView.text)
        }
    }
}
