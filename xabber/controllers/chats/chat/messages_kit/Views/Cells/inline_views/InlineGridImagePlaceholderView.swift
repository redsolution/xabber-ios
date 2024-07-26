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
import Kingfisher
import MaterialComponents.MDCPalettes

class InlineGridImagePlaceholderView: UIImageView, Placeholder {
    override init(frame: CGRect) {
        super.init(frame: frame)
    }
 
    internal func setup() {
        self.image = imageLiteral("image")?.withRenderingMode(.alwaysTemplate)
        self.tintColor = MDCPalette.grey.tint600
        self.layer.borderColor = MDCPalette.grey.tint600.cgColor
        self.layer.borderWidth = 1
        self.contentMode = .center
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
