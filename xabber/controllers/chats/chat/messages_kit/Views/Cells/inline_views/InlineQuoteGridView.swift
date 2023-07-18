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

class InlineQuoteGridView: InlineMediaBaseView {
    
    class QuoteView: UIView {
        
        internal let quoteMarkView: UIView = {
            let view = UIView()
            
            return view
        }()
        
        internal let textLabel: UILabel = {
            let label = UILabel()
            
            label.lineBreakMode = .byWordWrapping
            label.numberOfLines = 0
            
            return label
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func setup() {
            addSubview(quoteMarkView)
            addSubview(textLabel)
            quoteMarkView.frame = CGRect(x: 1,
                                         y: 0,
                                         width: 2,
                                         height: frame.height)
            textLabel.frame = self.bounds
        }
        
        func configure(_ text: NSAttributedString, isQuote: Bool, color: UIColor) {
            if isQuote {
                textLabel.frame = CGRect(x: 12,
                                         y: 0,
                                         width: frame.width - 12,
                                         height: frame.height)
            } else {
                quoteMarkView.isHidden = true
            }
            textLabel.attributedText = text
            quoteMarkView.backgroundColor = color.withAlphaComponent(0.7)
        }
    }
    
    internal func prepareGrid(_ quoteItems: [MessageStorageItem.QuoteBodyItem]) -> [CGRect] {
        let frame = self.frame
        let padding: CGFloat = 4
        var offset: CGFloat = 0
        return quoteItems
            .compactMap { item in
                let constraintBox = CGSize(width: frame.width - (item.isQuote ? 12 : 0), height: .greatestFiniteMagnitude)
                let boundingRect = item.body.boundingRect(with: constraintBox, options: [
                    .usesLineFragmentOrigin,
                    .usesFontLeading
                ], context: nil).integral
                
                let rect = CGRect(x: 0,
                                  y: offset,
                                  width: boundingRect.width + (item.isQuote ? 12 : 0),
                                  height: boundingRect.height)
                offset += boundingRect.height + padding
                return rect
            }
    }
    
    func configure(_ quoteItems: [MessageStorageItem.QuoteBodyItem], messageId: String?, indexPath: IndexPath, color: UIColor) {
        self.messageId = messageId
        subviews.forEach { $0.removeFromSuperview() }
        grid.removeAll()
        prepareGrid(quoteItems).enumerated().forEach {
            index, cell in
            let view = QuoteView(frame: cell)
            view.configure(quoteItems[index].body, isQuote: quoteItems[index].isQuote, color: color)
            addSubview(view)
        }
    }
    
    override func handleTouch(at point: CGPoint, callback: ((String?, Int, Bool) -> Void)?) {

    }
    
}
