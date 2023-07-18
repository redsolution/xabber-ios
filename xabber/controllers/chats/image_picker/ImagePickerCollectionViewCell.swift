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
import MaterialComponents.MDCPalettes

class ImagePickerCollectionViewCell: UICollectionViewCell {
    
    var selectedView: UIImageView = {
        let view = UIImageView()
        return view
    }()

    func updateSelection() {
        if isSelected {
            self.selectedView.image = #imageLiteral(resourceName: "check-circle").withRenderingMode(.alwaysTemplate)
            selectedView.tintColor = .systemRed
            selectedView.backgroundColor = UIColor.white//.withAlphaComponent(0.5)
        } else {
            self.selectedView.image = nil
            selectedView.backgroundColor = UIColor.black.withAlphaComponent(0.2)
            selectedView.layer.borderColor = MDCPalette.grey.tint100.cgColor
        }
        self.contentView.bringSubviewToFront(selectedView)
    }
    
    func configure() {
        contentView.backgroundColor = .white
        selectedView.frame = CGRect(x: self.contentView.frame.width - 28, y: 4, width: 22, height: 22)
        selectedView.layer.masksToBounds = true
        selectedView.layer.cornerRadius = selectedView.frame.height/2
        self.contentView.addSubview(selectedView)
    }

}
