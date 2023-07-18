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

extension AccountNewStatusViewController {
    class BaseStatus: UITableViewCell {
        
        static let cellName = "BaseStatusCell"
        
        var mainStack: UIStackView = {
            let stack = UIStackView()
            
            stack.alignment = .center
            stack.axis = .horizontal
            stack.spacing = 10
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
            
            return stack
        }()
        
        var centerStack: UIStackView = {
            let stack = UIStackView()
            stack.alignment = .leading
            stack.axis = .vertical
            stack.spacing = 2
            return stack
        }()
        
        var resourceImage: UIImageView = {
            let image = UIImageView()
//            image.image = #imageLiteral(resourceName: "lightBulbOn36").withRenderingMode(.alwaysTemplate)
            image.frame = CGRect(origin: .zero, size: CGSize(width: 64, height: 64))
            return image
        }()
        
        var statusLabel: UILabel = {
            let label = UILabel()
            label.text = " "
            label.frame = CGRect(x: 0, y: 0, width: 200, height: 18)
            label.font = UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
            label.textColor = MDCPalette.grey.tint900
            return label
        }()
        
        
        var statusIndicator: UIImageView = {
            let imageView = UIImageView()
            return imageView
        }()
        
        private func activateConstraints() {
            statusIndicator.widthAnchor.constraint(equalToConstant: 14).isActive = true
            statusIndicator.heightAnchor.constraint(equalToConstant: 14).isActive = true
        }
        
        func configure(status: ResourceStatus, current: Bool) {
            contentView.addSubview(mainStack)
            contentView.bringSubviewToFront(mainStack)
            mainStack.fillSuperview()
            
            centerStack.addArrangedSubview(statusLabel)
            
            mainStack.addArrangedSubview(centerStack)
            mainStack.addArrangedSubview(statusIndicator)
            
            statusLabel.text = RosterUtils.shared.convertStatus(status)
            
            if current {
                backgroundColor = UIColor.incomingGray
            } else {
                backgroundColor = .white
            }
            
            let indicatorSize = CGSize(width: 14, height: 14)
            let view = RoundedStatusView()
            view.frame = CGRect(origin: .zero, size: indicatorSize.x3)
            view.backgroundColor = .clear
            view.setStatus(status: status, entity: .contact)
            statusIndicator.image = UIImage(view: view)
            statusIndicator.layer.borderWidth = 0.1
            statusIndicator.layer.masksToBounds = false
            statusIndicator.layer.borderColor = view.borderColor.cgColor
            activateConstraints()
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
}
