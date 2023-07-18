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
import Accelerate

extension UIImage {
    convenience init(view: UIView) {
        UIGraphicsBeginImageContext(view.frame.size)
        view.layer.render(in:UIGraphicsGetCurrentContext()!)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        self.init(cgImage: image!.cgImage!)
    }
}

extension CIImage {
    var image: UIImage? {
        let image = UIImage(ciImage: self)
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: image.size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}

extension UIImage {
    func applying(saturation value: NSNumber) -> UIImage? {
        return CIImage(image: self)?
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: value])
            .image
    }
    var grayscale: UIImage? {
        return applying(saturation: 0)
    }
}

extension UIImage {
    func rotate(radians: CGFloat) -> UIImage {
        let rotatedSize = CGRect(origin: .zero, size: size)
            .applying(CGAffineTransform(rotationAngle: CGFloat(radians)))
            .integral.size
        UIGraphicsBeginImageContext(rotatedSize)
        if let context = UIGraphicsGetCurrentContext() {
            let origin = CGPoint(x: rotatedSize.width / 2.0,
                                 y: rotatedSize.height / 2.0)
            context.translateBy(x: origin.x, y: origin.y)
            context.rotate(by: radians)
            switch radians {
            case .pi / 2, .pi / -2:
                draw(in: CGRect(x: -origin.y, y: -origin.x,
                                width: rotatedSize.width, height: rotatedSize.height))
            default:
                draw(in: CGRect(x: -origin.x, y: -origin.y,
                                width: rotatedSize.width, height: rotatedSize.height))
            }
//            draw(in: CGRect(x: -origin.x, y: -origin.y,
//                            width: rotatedSize.width, height: rotatedSize.height))
            let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            

            return rotatedImage ?? self
        }

        return self
    }
}
//
//public extension CGImage
//{
//    public func horizontallyFlipped() -> CGImage?
//    {
//        return self.rotated(radians: 0.0, flipOverHorizontalAxis: true, flipOverVerticalAxis: false)
//    }
//
//    public func verticallyFlipped() -> CGImage?
//    {
//        return self.rotated(radians: 0.0, flipOverHorizontalAxis: false, flipOverVerticalAxis: true)
//    }
//
//    public func rotated(radians: CGFloat) -> CGImage?
//    {
//        return self.rotated(radians: radians, flipOverHorizontalAxis: false, flipOverVerticalAxis: false)
//    }
//
////    public func rotated(degrees: CGFloat) -> CGImage?
////    {
////        return self.rotated(radians: degreesToRadians(degrees), flipOverHorizontalAxis: false, flipOverVerticalAxis: false)
////    }
//
////    public func rotated(degrees: CGFloat, flipOverHorizontalAxis: Bool, flipOverVerticalAxis: Bool) -> CGImage?
////    {
////        return self.rotated(radians: degreesToRadians(degrees), flipOverHorizontalAxis: flipOverHorizontalAxis, flipOverVerticalAxis: flipOverVerticalAxis)
////    }
//
//    public func rotated(radians: CGFloat, flipOverHorizontalAxis: Bool, flipOverVerticalAxis: Bool) -> CGImage?
//    {
//        // Create an ARGB bitmap context
//        let width = self.width
//        let height = self.height
//
//        let rotatedRect = CGRect(x: 0, y: 0, width: width, height: height).applying(CGAffineTransform(rotationAngle: radians))
//
//        guard let bmContext = CGContext.ARGBBitmapContext(width: Int(rotatedRect.size.width), height: Int(rotatedRect.size.height), withAlpha: true) else
//        {
//            return nil
//        }
//
//        // Image quality
//        bmContext.setShouldAntialias(true)
//        bmContext.setAllowsAntialiasing(true)
//        bmContext.interpolationQuality = .high
//
//        // Rotation happen here (around the center)
//        bmContext.scaleBy(x: +(rotatedRect.size.width / 2.0), y: +(rotatedRect.size.height / 2.0))
//        bmContext.rotate(by: radians)
//
//        // Do flips
//        bmContext.scaleBy(x: (flipOverHorizontalAxis ? -1.0 : 1.0), y: (flipOverVerticalAxis ? -1.0 : 1.0))
//
//        // Draw the image in the bitmap context
//        bmContext.draw(self, in: CGRect(-(CGFloat(width) / 2.0), -(CGFloat(height) / 2.0), CGFloat(width), CGFloat(height)))
//
//        // Create an image object from the context
//        return bmContext.makeImage()
//    }
//
////    public func pixelsRotated(degrees: Float) -> CGImage?
////    {
////        return self.pixelsRotated(radians: degreesToRadians(degrees))
////    }
//
////    public func pixelsRotated(radians: Float) -> CGImage?
////    {
////        // Create an ARGB bitmap context
////        let width = self.width
////        let height = self.height
////        let bytesPerRow = width * numberOfComponentsPerARBGPixel
////        guard let bmContext = CGContext.ARGBBitmapContext(width: width, height: height, withAlpha: true) else
////        {
////            return nil
////        }
////
////        // Draw the image in the bitmap context
////        bmContext.draw(self, in: CGRect(0, 0, width, height))
////
////        // Grab the image raw data
////        guard let data = bmContext.data else
////        {
////            return nil
////        }
////
////        var src = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
////        var dst = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
////        let bgColor: [UInt8] = [0, 0, 0, 0]
////        vImageRotate_ARGB8888(&src, &dst, nil, radians, bgColor, vImage_Flags(kvImageBackgroundColorFill))
////
////        return bmContext.makeImage()
////    }
////
////    public func reflected(height: Int = 0, fromAlpha: CGFloat = 1.0, toAlpha: CGFloat = 0.0) -> CGImage?
////    {
////        var h = height
////        let width = self.width
////        if h <= 0
////        {
////            h = self.height
////            return nil
////        }
////
////        UIGraphicsBeginImageContextWithOptions(CGSize(width, height), false, 0.0)
////        guard let mainViewContentContext = UIGraphicsGetCurrentContext() else
////        {
////            return nil
////        }
////
////        guard let gradientMaskImage = CGImage.makeGrayGradient(width: 1, height: h, fromAlpha: fromAlpha, toAlpha: toAlpha) else
////        {
////            return nil
////        }
////
////        mainViewContentContext.clip(to: CGRect(0, 0, width, h), mask: gradientMaskImage)
////        mainViewContentContext.draw(self, in: CGRect(0, 0, width, self.height))
////
////        let theImage = mainViewContentContext.makeImage()
////
////        UIGraphicsEndImageContext()
////
////        return theImage
////    }
//}
