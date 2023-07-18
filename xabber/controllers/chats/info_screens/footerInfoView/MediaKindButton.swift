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

class MediaKindButton: UIButton {
    var isBlueLineSetupped = false
    
    var blueLineView = UIView()

    override var isSelected: Bool {
        didSet {
            if isSelected {
                self.blueLineView.isHidden = false
                self.layoutIfNeeded()
            } else {
                self.blueLineView.isHidden = true
                self.layoutIfNeeded()
            }
        }
    }
    
    required init(title: String) {
        super.init(frame: .zero)
        
        self.setTitle(title, for: .normal)
        self.setTitleColor(.systemGray, for: .normal)
        self.setTitleColor(.systemBlue, for: .selected)
        
        self.isSelected = false
    }
    
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        setBlueLine()
    }
    
    func setBlueLine() {
        if !isBlueLineSetupped {
            guard let label = self.titleLabel else { return }
            blueLineView.frame = CGRect(x: label.frame.minX - 1,
                                        y: label.frame.midY + InfoScreenFooterView.scrollViewHeight / 2 - 3,
                                        width: label.frame.width + 2,
                                        height: 6)
            blueLineView.backgroundColor = .systemBlue
            blueLineView.layer.cornerRadius = 3
            self.addSubview(blueLineView)
            
            isBlueLineSetupped.toggle()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
