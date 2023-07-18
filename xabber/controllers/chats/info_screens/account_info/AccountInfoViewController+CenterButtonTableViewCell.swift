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
import MaterialComponents.MDCPalettes

class CenterButtonTableViewCell: UITableViewCell {
    
    static let cellName = "CenterButtonTableViewCell"
    
    enum Style {
        case normal
        case danger
    }
    
    var stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
        
        return stack
    }()
    
    var titleLabel: UILabel = {
        let label = UILabel(frame: CGRect(origin: .zero, size: CGSize(width: 200, height: 24)))
        label.textColor = UIColor.gray
        label.textAlignment = .center
        return label
    }()
    
    private func activateConstraints() {
        NSLayoutConstraint.activate([
            titleLabel.leftAnchor.constraint(equalTo: stack.leftAnchor),
            titleLabel.rightAnchor.constraint(equalTo: stack.rightAnchor),
        ])
    }
    
    func configure(for title: String, style: Style) {
        selectionStyle = .blue //?
        addSubview(stack)
        stack.fillSuperview()
        stack.addArrangedSubview(titleLabel)
        backgroundColor = .white
        titleLabel.text = title
        switch style {
        case .normal: titleLabel.textColor = MDCPalette.blue.tint500
        case .danger: titleLabel.textColor = MDCPalette.red.tint500
        }
        activateConstraints()
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
}
