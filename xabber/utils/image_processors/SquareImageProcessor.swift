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
import Kingfisher

struct SquareImageProcessor: ImageProcessor {
    
    /// Identifier of the processor.
    /// - Note: See documentation of `ImageProcessor` protocol for more.
    
    public let identifier: String
    
    public let targetContentMode: ContentMode
    
    public let minimumSize: CGSize
    
    public let anchor: CGPoint
    public init(greaterThan minimumSize: CGSize, mode: ContentMode = .none) {
        self.targetContentMode = mode
        self.minimumSize = minimumSize
        self.anchor = CGPoint(x: 0.5, y: 0.5)
        if mode == .none {
            self.identifier = "com.xabber.SquareImageProcessor(\(minimumSize.width), \(minimumSize.height))"
        } else {
            self.identifier = "com.xabber.SquareImageProcessor(\(minimumSize.width), \(minimumSize.height), \(mode))"
        }
    }
    
    public func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        switch item {
        case .image(let image):
            let referenceSize: CGSize = CGSize(square: min(image.size.width, image.size.height))
            print(referenceSize)
            if image.size == referenceSize { return image }
            if referenceSize.width < minimumSize.width {
                return image.kf.scaled(to: options.scaleFactor)
                            .kf.resize(to: minimumSize, for: targetContentMode)
                            .kf.crop(to: referenceSize, anchorOn: anchor)
            } else if referenceSize.height < minimumSize.height {
                return image.kf.scaled(to: options.scaleFactor)
                            .kf.resize(to: minimumSize, for: targetContentMode)
                            .kf.crop(to: referenceSize, anchorOn: anchor)
            } else {
                return image.kf.scaled(to: options.scaleFactor)
                            .kf.crop(to: referenceSize, anchorOn: anchor)
            }
            
        case .data:
            return (DefaultImageProcessor.default |> self).process(item: item, options: options)
        }
    }
}
