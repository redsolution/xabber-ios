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

extension ContactInfoResourceController {
    class StatusCell: UITableViewCell {
        
        static public let cellName: String = "StatusCell"
        
        var mainStack: UIStackView = {
            let stack = UIStackView()
            stack.alignment = .center
            stack.axis = .horizontal
            stack.spacing = 10
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 16, right: 16)
            return stack
        }()
        
        var centerStack: UIStackView = {
            let stack = UIStackView()
            stack.alignment = .leading
            stack.axis = .vertical
            stack.spacing = 2
            return stack
        }()
        
        var statusLabel: UILabel = {
            let label = XCopyableLabel(frame: CGRect(origin: .zero, size: CGSize(width: 200, height: 20)))
            label.font = UIFont.preferredFont(forTextStyle: .body).withSize(17)
            label.textColor = MDCPalette.grey.tint800
            return label
        }()
        
        var categoryLabel: UILabel = {
            let label = UILabel(frame: CGRect(origin: .zero, size: CGSize(width: 200, height: 20)))
            label.font = UIFont.preferredFont(forTextStyle: .body).withSize(15)
            label.textColor = MDCPalette.grey.tint600
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
        private func updateStatus(with status: ResourceStatus) {
            let indicatorSize = CGSize(width: 14, height: 14)
            let view = RoundedStatusView()
            view.frame = CGRect(origin: .zero, size: indicatorSize.x3)
            view.backgroundColor = .clear
            view.setStatus(status: status, entity: .contact)
            statusIndicator.image = UIImage(view: view)
            statusIndicator.layer.borderWidth = 0.1
            statusIndicator.layer.masksToBounds = false
            statusIndicator.layer.borderColor = view.borderColor.cgColor
        }
        
        func configure() {
            self.selectionStyle = .none
            contentView.addSubview(mainStack)
            contentView.bringSubviewToFront(mainStack)
            mainStack.fillSuperview()
            
            centerStack.addArrangedSubview(categoryLabel)
            centerStack.addArrangedSubview(statusLabel)
            
            mainStack.addArrangedSubview(centerStack)
            mainStack.addArrangedSubview(statusIndicator)
            
            activateConstraints()
        }
        
        func updateContent(status: ResourceStatus, category: String) {
            statusLabel.text = RosterUtils.shared.convertStatus(status)
            categoryLabel.text = category
            updateStatus(with: status)
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 16, right: 0)
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }

}
