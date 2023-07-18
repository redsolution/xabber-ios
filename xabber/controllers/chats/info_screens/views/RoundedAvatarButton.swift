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

class RoundedAvatarButton: UIButton {
    init(frame: CGRect, avatarMaskResourceName: String) {
        super.init(frame: frame)
        guard let image = UIImage(named: avatarMaskResourceName) else {
            self.mask = nil
            return
        }
        self.mask = UIImageView(image: image)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func draw(_ rect: CGRect) {
//        layer.cornerRadius = rect.height / 2
        print(rect)
        self.mask?.frame = CGRect(origin: .zero, size: rect.size)
        super.draw(rect)
    }
    
    override func layerWillDraw(_ layer: CALayer) {
        super.layerWillDraw(layer)
    }
    
}
