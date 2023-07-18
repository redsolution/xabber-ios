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

import UIKit

public enum MessageStyle {

    public enum TailCorner: String {

        case topLeft
        case bottomLeft
        case topRight
        case bottomRight

        internal var imageOrientation: UIImage.Orientation {
            switch self {
            case .bottomRight: return .up
            case .bottomLeft: return .upMirrored
            case .topLeft: return .down
            case .topRight: return .downMirrored
            }
        }
    }

    case bubble(TailCorner)
    case bubbleTail(TailCorner)
    
    public var shadowImage: UIImage? {
        guard let imageCacheKey = imageShadowCacheKey, let imageName = imageShadowName else { return nil }

        let cache = MessageStyle.bubbleImageCache

        if let cachedImage = cache.object(forKey: imageCacheKey as NSString) {
            return cachedImage
        }
        var image = #imageLiteral(resourceName: imageName)
        
        switch self {
        case .bubbleTail(let corner), .bubble(let corner):
            guard let cgImage = image.cgImage else { return nil }
            image = UIImage(cgImage: cgImage, scale: image.scale, orientation: corner.imageOrientation)
        }
        
        let stretchedImage = stretch(shadow: image)
        cache.setObject(stretchedImage, forKey: imageCacheKey as NSString)
        return stretchedImage
    }
    
    public var image: UIImage? {
        
        guard let imageCacheKey = imageCacheKey, let imageName = imageName else { return nil }

        let cache = MessageStyle.bubbleImageCache

        if let cachedImage = cache.object(forKey: imageCacheKey as NSString) {
            return cachedImage
        }
        var image = #imageLiteral(resourceName: imageName)
        
        switch self {
        case .bubbleTail(let corner), .bubble(let corner):
            guard let cgImage = image.cgImage else { return nil }
            image = UIImage(cgImage: cgImage, scale: image.scale, orientation: corner.imageOrientation)
        }
        
        let stretchedImage = stretch(image)
        cache.setObject(stretchedImage, forKey: imageCacheKey as NSString)
        return stretchedImage
    }

    // MARK: - Internal
    
    internal static let bubbleImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.name = "com.xabber.chat.bubbles"
        return cache
    }()
    
    // MARK: - Private
    
    private var imageCacheKey: String? {
        guard let imageName = imageName else { return nil }
        
        switch self {
        case .bubbleTail(let corner), .bubble(let corner):
            return [imageName, corner.rawValue].prp()
        }
    }

    private var imageShadowCacheKey: String? {
        guard let imageName = imageShadowName else { return nil }
        switch self {
        case .bubbleTail(let corner), .bubble(let corner):
            return [imageName, corner.rawValue].prp()
        }
    }
    
    private var imageName: String? {
        switch self {
        case .bubble(_): return "message_bubble"
        case .bubbleTail(_): return "message_bubble_tail"
        }
    }

    private var imageShadowName: String? {
        switch self {
        case .bubble(_): return "message_bubble_shadow"
        case .bubbleTail(_): return "message_bubble_tail_shadow"
        }
    }
    
    private func stretch(_ image: UIImage) -> UIImage {
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: 6,
                                                                bottom: 10,
                                                                left: 5,
                                                                right: 13),
                                    resizingMode: .stretch)
    }
    
    private func stretch(shadow image: UIImage) -> UIImage { // TODO: fix insets
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: 8,
                                                                bottom: 12,
                                                                left: 7,
                                                                right: 15),
                                    resizingMode: .stretch)
    }
}
