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

enum CoreListEmptyStateAction: Equatable {
    case addContact
    case createPublicGroup
    case startCall
}

struct CoreListEmptyStateDescriptor: Equatable {
    let iconSystemName: String
    let title: String
    let subtitle: String
    let buttonTitle: String?
    let buttonAccessibilityIdentifier: String?
    let action: CoreListEmptyStateAction?
}

class EmptyStateView: UIView {

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
    
    let iconImage: UIImageView = {
        let image = UIImageView()
        
        image.tintColor = .tertiaryLabel
        image.contentMode = .scaleAspectFit
        image.isAccessibilityElement = false
        
        return image
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .title2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        label.accessibilityIdentifier = "empty_state_title_label"
        
        return label
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.accessibilityIdentifier = "empty_state_subtitle_label"
        
        return label
    }()
    
    let button: UIButton = {
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
        
        return button
    }()
    
    internal var callback: (() -> Void)? = nil
    
    internal func activaateConstraints() {
        iconImage.widthAnchor.constraint(equalToConstant: 72).isActive = true
        iconImage.heightAnchor.constraint(equalToConstant: 72).isActive = true
        centerStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }
    
    public final func configure(image: UIImage?, title: String, subtitle: String, buttonTitle: String, onButtonTouchUp: (() -> Void)?) {
        self.configure(
            image: image,
            title: title,
            subtitle: subtitle,
            buttonTitle: buttonTitle,
            buttonAccessibilityIdentifier: buttonTitle.isEmpty ? nil : "empty_state_primary_button",
            onButtonTouchUp: onButtonTouchUp
        )
    }

    public final func configure(
        image: UIImage?,
        title: String,
        subtitle: String,
        buttonTitle: String,
        buttonAccessibilityIdentifier: String?,
        onButtonTouchUp: (() -> Void)?
    ) {
        self.update(
            image: image,
            title: title,
            subtitle: subtitle,
            buttonTitle: buttonTitle,
            buttonAccessibilityIdentifier: buttonAccessibilityIdentifier
        )
        callback = onButtonTouchUp
    }

    internal final func configure(descriptor: CoreListEmptyStateDescriptor, onButtonTouchUp: (() -> Void)?) {
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .regular)
        configure(
            image: UIImage(systemName: descriptor.iconSystemName, withConfiguration: symbolConfiguration)?.withRenderingMode(.alwaysTemplate),
            title: descriptor.title,
            subtitle: descriptor.subtitle,
            buttonTitle: descriptor.buttonTitle ?? "",
            buttonAccessibilityIdentifier: descriptor.buttonAccessibilityIdentifier,
            onButtonTouchUp: onButtonTouchUp
        )
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        isAccessibilityElement = false
        accessibilityIdentifier = "empty_state_view"
        addSubview(stack)
        stack.fillSuperview()
        stack.addArrangedSubview(UIStackView())
        stack.addArrangedSubview(centerStack)
        stack.addArrangedSubview(UIStackView())
        centerStack.addArrangedSubview(iconImage)
        centerStack.addArrangedSubview(titleLabel)
        centerStack.addArrangedSubview(subtitleLabel)
        centerStack.setCustomSpacing(20, after: subtitleLabel)
        centerStack.addArrangedSubview(button)
        button.addTarget(self, action: #selector(onButtonPressed), for: .touchUpInside)
        activaateConstraints()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public final func update(image: UIImage?, title: String, subtitle: String, buttonTitle: String) {
        update(
            image: image,
            title: title,
            subtitle: subtitle,
            buttonTitle: buttonTitle,
            buttonAccessibilityIdentifier: buttonTitle.isEmpty ? nil : "empty_state_primary_button"
        )
    }

    public final func update(
        image: UIImage?,
        title: String,
        subtitle: String,
        buttonTitle: String,
        buttonAccessibilityIdentifier: String?
    ) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        var configuration = button.configuration ?? UIButton.Configuration.filled()
        configuration.title = buttonTitle
        button.configuration = configuration
        button.isHidden = buttonTitle.isEmpty
        button.accessibilityLabel = buttonTitle.isEmpty ? nil : buttonTitle
        button.accessibilityIdentifier = buttonAccessibilityIdentifier
        subtitleLabel.isHidden = subtitle.isEmpty
        iconImage.isHidden = image == nil
        iconImage.image = image
    }
    
    @objc
    internal func onButtonPressed(_ sender: UIButton) {
        callback?()
    }
}
