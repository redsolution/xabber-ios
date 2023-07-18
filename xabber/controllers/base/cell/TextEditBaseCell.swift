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

class TextEditBaseCell: UITableViewCell {
    static let cellName: String = "TextEditBaseCell"
    
    internal var targetField: String = ""
    
    internal let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
        
        return stack
    }()
    
    internal let textField: UITextField = {
        let field = UITextField()
        
        field.returnKeyType = .done
        
        return field
    }()
    
    open var textFieldDidChangeValueCallback: ((String, String?) -> Void)? = nil
    
    internal func activateConstraints() {
        NSLayoutConstraint.activate([
            
        ])
    }
    
    open func configure(_ target: String, value: String?, placeholder: String) {
        self.targetField = target
        textField.restorationIdentifier = target
        textField.placeholder = placeholder
        textField.text = value
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(stack)
        stack.fillSuperview()
        stack.addArrangedSubview(textField)
        textField.addTarget(self, action: #selector(textFieldDidChangeValue), for: .editingChanged)
        selectionStyle = .none
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc
    internal func textFieldDidChangeValue(_ sender: UITextField) {
        textFieldDidChangeValueCallback?(targetField, sender.text)
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
}
