//
//  NSAttributedString+Extensions.swift
//  xabber
//
//  Created by Игорь Болдин on 21.03.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import CoreGraphics
import CoreText
import Foundation

extension NSAttributedString {
    
    func splitIntoLines(for size: CGSize, keepNewlines: Bool = false) -> [NSAttributedString] {
        let frameSetter: CTFramesetter = CTFramesetterCreateWithAttributedString(self as CFAttributedString)
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: size))
        
        let frame: CTFrame = CTFramesetterCreateFrame(frameSetter, CFRange(), path, nil)
        // Can't do a simple 'as' here but this cast never fails. Guard is just here to make the code pretty
        guard let lines = CTFrameGetLines(frame) as? [CTLine] else { return [] }
        return lines.map {
            let lineRange = CTLineGetStringRange($0)
            let lineString = attributedSubstring(from: NSRange(location: lineRange.location, length: lineRange.length))
            if lineString.string.last == "\n" && !keepNewlines {
                return attributedSubstring(from: NSRange(location: lineRange.location, length: lineRange.length - 1))
            }
            return lineString
        }
    }
    
    internal func width(considering height: CGFloat) -> CGFloat {

        let constraintBox = CGSize(width: .greatestFiniteMagnitude, height: height)
        let rect = self.boundingRect(with: constraintBox, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return rect.width
        
    }
}
