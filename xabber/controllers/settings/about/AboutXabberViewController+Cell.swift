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

extension AboutXabberViewController {
    class Cell: UITableViewCell {
        
        static let cellName = "Cell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 10, right: 10)
            
            return stack
        }()
        
        internal let cellLabel: UILabel = {
            let label = UILabel()
            
//            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.textColor = MDCPalette.grey.tint900
            label.numberOfLines = 0
            label.textAlignment = NSTextAlignment.justified
            
//            label.
//            label.inset
            return label
        }()
        
        open func configure(_ text: String) {
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(cellLabel)
            
            let attr = try! NSAttributedString(data: text.data(using: .unicode)!, options: [NSAttributedString.DocumentReadingOptionKey.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
            let textString = NSMutableAttributedString(attributedString: attr)
            
//            let textString = NSMutableAttributedString(string: text, attributes: [ NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .body)])
            let textRange = NSRange(location: 0, length: textString.length)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 1.43
            paragraphStyle.firstLineHeadIndent = 0
            paragraphStyle.alignment = .justified
            textString.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
            textString.addAttribute(NSAttributedString.Key.kern, value: -0.22, range: textRange)
            textString.addAttribute(.font, value: UIFont.systemFont(ofSize: 15, weight: .light), range: textRange)
            cellLabel.attributedText = textString
            accessoryType = .none
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
}
