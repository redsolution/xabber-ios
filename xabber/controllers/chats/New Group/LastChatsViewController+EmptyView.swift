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

extension LastChatsViewController {
    class EmptyView: UIView {
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .center
            stack.distribution = .equalSpacing
            
            return stack
        }()
        
        let centerStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 16
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 24, right: 24)
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .title2)
//            if #available(iOS 13.0, *) {
//                label.textColor = .label
//            } else {
                label.textColor = MDCPalette.grey.tint500//.systemGray
//            }//MDCPalette.grey.tint900
            
            return label
        }()
        
        let newChatButton: UIButton = {
            let button = UIButton()
            
            button.setTitleColor(MDCPalette.grey.tint500, for: .normal)
            
            return button
        }()
        
        internal var callback: (() -> Void)? = nil
        
        internal func activaateConstraints() {
//            titleLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 64).isActive = true
        }
        
        open func configure(onCreateChatCallback: @escaping (() -> Void)) {
            if #available(iOS 13.0, *) {
                backgroundColor = .systemBackground
            } else {
                backgroundColor = .white
            }
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(UIStackView())
            stack.addArrangedSubview(centerStack)
            stack.addArrangedSubview(UIStackView())
            centerStack.addArrangedSubview(titleLabel)
            centerStack.addArrangedSubview(newChatButton)
            titleLabel.text = "You don't have any chat".localizeString(id: "have_no_chats", arguments: [])
            newChatButton.setTitle("Add someone to your contacts, then send some messages.".localizeString(id: "chat_add_contacts_hint", arguments: []), for: .normal)
            newChatButton.titleLabel?.numberOfLines = 0
            newChatButton.titleLabel?.textAlignment = .center
            activaateConstraints()
            callback = onCreateChatCallback
        }
        
        open func update(for filter: Filter) {
            switch filter {
            case .chats:
                titleLabel.text = "You don't have any chat".localizeString(id: "have_no_chats", arguments: [])
                newChatButton.isHidden = false
            case .unread:
                titleLabel.text = "You don't have unread messages".localizeString(id: "no_unread_messages", arguments: [])
                newChatButton.isHidden = true
            case .archived:
                titleLabel.text = "You don't have archived chats".localizeString(id: "no_archived_chats", arguments: [])
                newChatButton.isHidden = true
            }
        }
        
        @objc
        internal func onButtonPressed(_ sender: UIButton) {
            callback?()
        }
    }
}
