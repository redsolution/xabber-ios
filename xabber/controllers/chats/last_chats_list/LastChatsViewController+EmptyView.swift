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
            stack.spacing = 12
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 28, right: 28)
            
            return stack
        }()

        let iconImageView: UIImageView = {
            let imageView = UIImageView()

            let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .regular)
            imageView.image = UIImage(systemName: "bubble.left.and.bubble.right", withConfiguration: symbolConfiguration)
            imageView.tintColor = .tertiaryLabel
            imageView.contentMode = .scaleAspectFit
            imageView.isAccessibilityElement = false

            return imageView
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .title2)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
            label.textAlignment = .center
            label.numberOfLines = 0
            label.accessibilityIdentifier = "last_chats_empty_title_label"
            
            return label
        }()

        let subtitleLabel: UILabel = {
            let label = UILabel()

            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 0
            label.accessibilityIdentifier = "last_chats_empty_subtitle_label"

            return label
        }()
        
        let addContactButton: UIButton = {
            let button = UIButton()

            var configuration = UIButton.Configuration.filled()
            configuration.baseForegroundColor = .white
            configuration.baseBackgroundColor = .tintColor
            configuration.cornerStyle = .medium
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 22, bottom: 10, trailing: 22)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.preferredFont(forTextStyle: .headline)
                return outgoing
            }
            
            button.configuration = configuration
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 1
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.accessibilityIdentifier = "last_chats_empty_add_contact_button"
            
            return button
        }()
        
        internal var callback: (() -> Void)? = nil
        
        internal func activaateConstraints() {
            iconImageView.widthAnchor.constraint(equalToConstant: 72).isActive = true
            iconImageView.heightAnchor.constraint(equalToConstant: 72).isActive = true
            centerStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48).isActive = true
            addContactButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        
        open func configure(onAddContactCallback: @escaping (() -> Void)) {
            backgroundColor = ContinuousSplitBackgroundExperiment.isActive ? .clear : .systemBackground
            update(for: .chats)
            callback = onAddContactCallback
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = false
            accessibilityIdentifier = "last_chats_empty_view"
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(UIStackView())
            stack.addArrangedSubview(centerStack)
            stack.addArrangedSubview(UIStackView())
            centerStack.addArrangedSubview(iconImageView)
            centerStack.addArrangedSubview(titleLabel)
            centerStack.addArrangedSubview(subtitleLabel)
            centerStack.setCustomSpacing(20, after: subtitleLabel)
            centerStack.addArrangedSubview(addContactButton)
            addContactButton.addTarget(self, action: #selector(onButtonPressed), for: .touchUpInside)
            activaateConstraints()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        open func update(for filter: Filter) {
            switch filter {
            case .chats:
                titleLabel.text = "No chats yet".localizeString(id: "last_chats_empty_title", arguments: [])
                subtitleLabel.text = "Add your first contact to start messaging.".localizeString(id: "last_chats_empty_subtitle", arguments: [])
                let addContactTitle = "Add Contact".localizeString(id: "last_chats_empty_add_contact", arguments: [])
                addContactButton.configuration?.title = addContactTitle
                addContactButton.accessibilityLabel = addContactTitle
                iconImageView.isHidden = false
                subtitleLabel.isHidden = false
                addContactButton.isHidden = false
            case .unread:
                titleLabel.text = "No unread chats".localizeString(id: "unreaded_chats_list_empty", arguments: [])
                subtitleLabel.text = ""
                iconImageView.isHidden = false
                subtitleLabel.isHidden = true
                addContactButton.isHidden = true
            case .archived:
                titleLabel.text = "No archived chats yet".localizeString(id: "archived_chats_empty_title", arguments: [])
                subtitleLabel.text = "Chats you archive will appear here.".localizeString(id: "archived_chats_empty_subtitle", arguments: [])
                iconImageView.isHidden = false
                subtitleLabel.isHidden = false
                addContactButton.isHidden = true
            default:
                titleLabel.text = ""
                subtitleLabel.text = ""
                iconImageView.isHidden = true
                subtitleLabel.isHidden = true
                addContactButton.isHidden = true
                break
            }
        }
        
        @objc
        internal func onButtonPressed(_ sender: UIButton) {
            callback?()
        }
    }
}
