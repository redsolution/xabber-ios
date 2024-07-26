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

extension GroupchatInviteViewController {
    class HeaderView: UITableViewHeaderFooterView {
        static public let headerView: String = "HeaderView"
        
        open var delegate: GroupchatInviteViewControllerDelegate? = nil
        
        internal  var group: String = ""
        var collapsed: Bool = false
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 2, left: 0, right: 8)
            
            return stack
        }()
        
        internal let titleButton: UIButton = {
            let button = UIButton()
            
//            if #available(iOS 13.0, *) {
//                button.setTitleColor(.label, for: .normal)
//            } else {
                button.setTitleColor(.darkText, for: .normal)
//            }
            button.titleLabel?.textAlignment = .left
            button.contentHorizontalAlignment = .left
            button.titleEdgeInsets = UIEdgeInsets(top: 4, bottom: 4, left: 4, right: 4)
            
            return button
        }()
        
        internal let collapseButton: UIButton = {
            let button = UIButton(frame: CGRect(width: 44, height: 36))
            
            button.tintColor = MDCPalette.grey.tint700
            
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
            
            return button
        }()
        
        @objc
        internal func onCollapseButtonPress(_ sender: UIButton) {
            delegate?.onCollapse(group: group)
            collapsed = !collapsed
            updateCollapsedIndicator()
        }
        
        @objc
        internal func onTitleButtonPress(_ sender: UIButton) {
            delegate?.onSelect(group: group)
        }
        
        internal func activateConstraints() {
            collapseButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
            collapseButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        
        internal func updateCollapsedIndicator() {
            if self.collapsed {
                collapseButton.setImage(imageLiteral( "chevron-up")?.withRenderingMode(.alwaysTemplate), for: .normal)
            } else {
                collapseButton.setImage(imageLiteral( "chevron-down")?.withRenderingMode(.alwaysTemplate), for: .normal)
            }
        }
        
        open func configure(title: String, collapsed: Bool) {
            self.collapsed = collapsed
            group = title
            titleButton.setTitle(title, for: .normal)
            updateCollapsedIndicator()
        }
        
        override init(reuseIdentifier: String?) {
            super.init(reuseIdentifier: reuseIdentifier)
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(collapseButton)
            stack.addArrangedSubview(titleButton)
            activateConstraints()
            backgroundView = UIView()
            
//            if #available(iOS 13.0, *) {
//                backgroundView?.backgroundColor = UIColor.systemBackground
//            } else {
                backgroundView?.backgroundColor = .white
//            }
//            backgroundColor = .white
//            backgroundView?.backgroundColor = .white
//            plainView.backgroundColor = .white
            
//            backgroundView?.color
            collapseButton.addTarget(self, action: #selector(onCollapseButtonPress), for: .touchDown)
            titleButton.addTarget(self, action: #selector(onTitleButtonPress), for: .touchUpInside)
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
