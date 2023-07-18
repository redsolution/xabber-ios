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

enum UILabelStyleType {
    case chatsCell
    case contactsCell
}

extension UILabel {
    
    func setLineHeight(lineHeight: CGFloat) {
        let text = self.text
        if let text = text {
            let attributeString = NSMutableAttributedString(string: text)
            let style = NSMutableParagraphStyle()
            
            style.lineSpacing = lineHeight
            attributeString.addAttribute(NSAttributedString.Key.paragraphStyle, value: style, range: NSMakeRange(0, text.count))
            self.attributedText = attributeString
        }
    }
    
    func styleForCellText(_ cell: UILabelStyleType) {
        switch cell {
        case .chatsCell:
            let text = self.text
            if let text = text {
                self.lineBreakMode = .byWordWrapping
                self.numberOfLines = 0
                self.textColor = UIColor(red:0.56, green:0.56, blue:0.58, alpha:1)
                let textString = NSMutableAttributedString(string: text, attributes: [ NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)])
                let textRange = NSRange(location: 0, length: textString.length)
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.lineSpacing = 1.43
                textString.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
                textString.addAttribute(NSAttributedString.Key.kern, value: -0.22, range: textRange)
                self.attributedText = textString
//                print("\(text) with width \(self.frame.width) height \(self.frame.height)")
//                self.sizeToFit()
//                print("width \(self.frame.width) height \(self.frame.height)")
//                self.frame.
                
            }
        case .contactsCell:
            break
        }
    }
}
