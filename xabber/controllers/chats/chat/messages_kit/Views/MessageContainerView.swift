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

open class MessageContainerView: UIView {

    private let shadowInsets: UIEdgeInsets = UIEdgeInsets(top: 1,
                                                          bottom: 2,
                                                          left: 1,
                                                          right: 1)
    
    
    public let shadowImage: UIImageView = {
        let view = UIImageView()
        
        return view
    }()
    
    public let bubbleImage: UIImageView = {
        let view = UIImageView()
        
        return view
    }()
    
    open var style: MessageStyle = .bubble(.bottomLeft) {
        didSet {
            applyMessageStyle()
        }
    }

    open override var frame: CGRect {
        didSet {
            shadowImage.frame = CGRect(x: -shadowInsets.left,
                                       y: -shadowInsets.top,
                                       width: self.frame.width + shadowInsets.horizontal,
                                       height: self.frame.height + shadowInsets.vertical)
            bubbleImage.frame = self.bounds
        }
    }
    
    open var isSelected: Bool = false
    
    public func setup() {
//        addSubview(shadowImage)
//        addSubview(bubbleImage)
    }
    
    private func applyMessageStyle() {
        shadowImage.image = style.shadowImage
        bubbleImage.image = style.image?.withRenderingMode(.alwaysTemplate)
    }
}
