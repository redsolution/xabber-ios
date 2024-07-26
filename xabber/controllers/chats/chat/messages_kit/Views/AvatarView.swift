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

open class AvatarView: UIImageView {

    // MARK: - Properties
    
    open var initials: String? {
        didSet {
            setImageFrom(initials: initials)
        }
    }

    open var placeholderFont: UIFont = UIFont.preferredFont(forTextStyle: .caption1) {
        didSet {
            setImageFrom(initials: initials)
        }
    }

    open var placeholderTextColor: UIColor = .white {
        didSet {
            setImageFrom(initials: initials)
        }
    }

    open var fontMinimumScaleFactor: CGFloat = 0.5

    open var adjustsFontSizeToFitWidth = true

    private var minimumFontSize: CGFloat {
        return placeholderFont.pointSize * fontMinimumScaleFactor
    }

    private var radius: CGFloat?

    // MARK: - Overridden Properties
    open override var frame: CGRect {
        didSet {
            if AccountMasksManager.shared.load() != "square" {
                self.mask = UIImageView(image: imageLiteral( AccountMasksManager.shared.mask32pt))
            } else {
                self.mask = nil
            }
        }
    }

    open override var bounds: CGRect {
        didSet {
            if AccountMasksManager.shared.load() != "square" {
                self.mask = UIImageView(image: imageLiteral( AccountMasksManager.shared.mask32pt))
            } else {
                self.mask = nil
            }
        }
    }

    // MARK: - Initializers
    public override init(frame: CGRect) {
        super.init(frame: frame)
        prepareView()
    }

    convenience public init() {
        self.init(frame: .zero)
    }
    
    private func setImageFrom(initials: String?) {
        guard let initials = initials else { return }
        image = getImageFrom(initials: initials)
        if AccountMasksManager.shared.load() != "square" {
            mask = UIImageView(image: imageLiteral( AccountMasksManager.shared.mask32pt))
        } else {
            mask = nil
        }
    }

    private func getImageFrom(initials: String) -> UIImage {
        let width = frame.width
        let height = frame.height
        if width == 0 || height == 0 { return UIImage() }
        var font = placeholderFont

        UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), false, UIScreen.main.scale)
        defer { UIGraphicsEndImageContext() }
        let context = UIGraphicsGetCurrentContext()!

        //// Text Drawing
        let textRect = calculateTextRect(outerViewWidth: width, outerViewHeight: height)
        let initialsText = NSAttributedString(string: initials, attributes: [.font: font])
        if adjustsFontSizeToFitWidth,
            initialsText.width(considering: textRect.height) > textRect.width {
            let newFontSize = calculateFontSize(text: initials, font: font, width: textRect.width, height: textRect.height)
            font = placeholderFont.withSize(newFontSize)
        }

        let textStyle = NSMutableParagraphStyle()
        textStyle.alignment = .center
        let textFontAttributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key.font: font, NSAttributedString.Key.foregroundColor: placeholderTextColor, NSAttributedString.Key.paragraphStyle: textStyle]

        let textTextHeight: CGFloat = initials.boundingRect(with: CGSize(width: textRect.width, height: CGFloat.infinity), options: .usesLineFragmentOrigin, attributes: textFontAttributes, context: nil).height
        context.saveGState()
        context.clip(to: textRect)
        initials.draw(in: CGRect(textRect.minX, textRect.minY + (textRect.height - textTextHeight) / 2, textRect.width, textTextHeight), withAttributes: textFontAttributes)
        context.restoreGState()
        guard let renderedImage = UIGraphicsGetImageFromCurrentImageContext() else { assertionFailure("Could not create image from context"); return UIImage()}
        return renderedImage
    }

    /**
     Recursively find the biggest size to fit the text with a given width and height
     */
    private func calculateFontSize(text: String, font: UIFont, width: CGFloat, height: CGFloat) -> CGFloat {
        let attributedText = NSAttributedString(string: text, attributes: [.font: font])
        if attributedText.width(considering: height) > width {
            let newFont = font.withSize(font.pointSize - 1)
            if newFont.pointSize > minimumFontSize {
                return font.pointSize
            } else {
                return calculateFontSize(text: text, font: newFont, width: width, height: height)
            }
        }
        return font.pointSize
    }

    /**
     Calculates the inner circle's width.
     Note: Assumes corner radius cannot be more than width/2 (this creates circle).
     */
    private func calculateTextRect(outerViewWidth: CGFloat, outerViewHeight: CGFloat) -> CGRect {
        guard outerViewWidth > 0 else {
            return CGRect.zero
        }
        let shortEdge = min(outerViewHeight, outerViewWidth)
        // Converts degree to radian degree and calculate the
        // Assumes, it is a perfect circle based on the shorter part of ellipsoid
        // calculate a rectangle
        let w = shortEdge * sin(CGFloat(45).degreesToRadians) * 2
        let h = shortEdge * cos(CGFloat(45).degreesToRadians) * 2
        let startX = (outerViewWidth - w)/2
        let startY = (outerViewHeight - h)/2
        // In case the font exactly fits to the region, put 2 pixel both left and right
        return CGRect(startX+2, startY, w-4, h)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Internal methods

    internal func prepareView() {
        backgroundColor = .white
        contentMode = .scaleAspectFill
        layer.masksToBounds = true
        clipsToBounds = true
        if AccountMasksManager.shared.load() != "square" {
            mask = UIImageView(image: imageLiteral( AccountMasksManager.shared.mask48pt))
        } else {
            mask = nil
        }
//        setCorner(radius: nil)
    }

    // MARK: - Open setters
    
    open func set(avatar: Avatar) {
        if let image = avatar.image {
            self.image = image
            if AccountMasksManager.shared.load() != "square" {
                self.mask = UIImageView(image: imageLiteral( AccountMasksManager.shared.mask32pt))
            } else {
                self.mask = nil
            }
        } else {
            initials = avatar.initials
        }
    }
}

fileprivate extension FloatingPoint {
    var degreesToRadians: Self { return self * .pi / 180 }
    var radiansToDegrees: Self { return self * 180 / .pi }
}
