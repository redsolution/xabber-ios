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

extension CreateNewGroupViewController {
    
    class DescriptionCell: UITableViewCell, UITextViewDelegate {
        
        public static let cellName: String = "DescriptionCell"
        
        var stack: UIStackView = {
            let stack = UIStackView()
            stack.spacing = 4
            stack.axis = .horizontal
            stack.alignment = .center
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 16, right: 16)
            return stack
        }()
        
        var textArea: UITextView = {
            let view = UITextView()
            view.isEditable = true
            view.textContainerInset = UIEdgeInsets(top: 16, bottom: 16, left: 16, right: 16)
            view.font = .preferredFont(forTextStyle: .body)
            view.textColor = MDCPalette.grey.tint600
            return view
        }()
        
        var delegate: CreateNewGroupViewControllerDelegate? = nil
        
        private func activateConstraints() {
            
        }
        
        func configure(for notes: String) {
            self.textArea.text = notes
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.selectionStyle = .none
//            self.addSubview(stack)
//            stack.fillSuperview()
//            stack.addArrangedSubview(textArea)
            contentView.addSubview(textArea)
            textArea.fillSuperview()
            textArea.delegate = self
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 0)
            self.activateConstraints()
            selectionStyle = .none
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
        
        func textViewDidChange(_ textView: UITextView) {
            self.delegate?.onChangeDescription(textView.text)
        }
        
        func textViewShouldEndEditing(_ textView: UITextView) -> Bool {
            self.delegate?.onChangeDescription(textView.text)
            return true
        }
    }
}
