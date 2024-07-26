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

extension ContactsViewController {
    class SectionHeader: UITableViewHeaderFooterView {
        
        internal var jid: String = ""
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .fill
            stack.spacing = 8
            stack.distribution = .fill
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 16, right: 16)
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.textAlignment = .left
            label.font = UIFont.preferredFont(forTextStyle: .title3)//systemFont(ofSize: 18, weight: UIFont.Weight.medium)
            
            return label
        }()
        
        let subtitleLabel: UILabel = {
            let label = UILabel()
            
            return label
        }()
        
        let contactsCountLabel: UILabel = {
            let label = UILabel()
            
            label.text = ""
            label.font = UIFont.preferredFont(forTextStyle: .body)
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = .gray
            }
            
            return label
        }()
        
        let collapseButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 24))
            
            button.tintColor = MDCPalette.grey.tint400
            
            return button
        }()
        
        let menuButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 24))
            
            button.setImage(imageLiteral( "menu")?.withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = .gray
            
            return button
        }()
        
        let bottomBorder: UIView = {
            let view = UIView()
            
            view.backgroundColor = UIColor.black.withAlphaComponent(0.27)
            
            return view
        }()
        
        public var isCollapsed: Bool = false
        
        var collapseCallback: ((String) -> Void)? = nil
        var menuCallback: ((String) -> Void)? = nil
        
        func setup() {
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(contactsCountLabel)
            stack.addArrangedSubview(collapseButton)
//            stack.addArrangedSubview(UIStackView())
//            stack.addArrangedSubview(menuButton)
//            addSubview(bottomBorder)
            activateConstraints()
        }
        
        func activateConstraints() {
            NSLayoutConstraint.activate([
//                collapseButton.leftAnchor.constraint(equalTo: contactsCountLabel.rightAnchor, constant: 16),
                collapseButton.heightAnchor.constraint(equalToConstant: 24),
                collapseButton.widthAnchor.constraint(equalToConstant: 24),//,
//                menuButton.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: -16),
//                menuButton.widthAnchor.constraint(equalToConstant: 24)
//                bottomBorder.leftAnchor.constraint(equalTo: leftAnchor),
//                bottomBorder.rightAnchor.constraint(equalTo: rightAnchor),
//                bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
//                bottomBorder.heightAnchor.constraint(equalToConstant: 0.33)
            ])
        }
        
        func configure(collapsed: Bool, title: String, jid: String, subtitle: String, color: UIColor) {
            self.jid = jid
            self.isCollapsed = collapsed
            if collapsed {
                collapseButton.setImage( imageLiteral( "chevron-up")?.withRenderingMode(.alwaysTemplate), for: .normal)
            } else {
                collapseButton.setImage( imageLiteral( "chevron-down")?.withRenderingMode(.alwaysTemplate), for: .normal)
            }
            menuButton.addTarget(self, action: #selector(onMenuButtonPressed), for: .touchUpInside)
            collapseButton.addTarget(self, action: #selector(onCollapseAccount), for: .touchUpInside)
            titleLabel.text = title
            contactsCountLabel.text = subtitle
            titleLabel.textColor = color
        }
        
        @objc
        internal func onCollapseAccount(_ sender: AnyObject) {
            self.collapseCallback?(self.jid)
            self.isCollapsed = !self.isCollapsed
            if self.isCollapsed {
                collapseButton.setImage( imageLiteral( "chevron-up")?.withRenderingMode(.alwaysTemplate), for: .normal)
            } else {
                collapseButton.setImage( imageLiteral( "chevron-down")?.withRenderingMode(.alwaysTemplate), for: .normal)
            }
        }
        
        @objc
        internal func onMenuButtonPressed(_ sender: AnyObject) {
            self.menuCallback?(self.jid)
        }
    }
}
