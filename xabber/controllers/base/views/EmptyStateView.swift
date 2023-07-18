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
        stack.spacing = 16
        
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 24, right: 24)
        
        return stack
    }()
    
    let iconImage: UIImageView = {
        let image = UIImageView()
        
        image.tintColor = MDCPalette.grey.tint200
        
        return image
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .title2)
        label.textColor = MDCPalette.grey.tint600
        
        return label
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .title2)
        label.textColor = MDCPalette.grey.tint400
        
        return label
    }()
    
    let button: UIButton = {
        let button = UIButton()
        
        button.setTitleColor(.systemBlue, for: .normal)
        
        return button
    }()
    
    internal var callback: (() -> Void)? = nil
    
    internal func activaateConstraints() {
        
    }
    
    public final func configure(image: UIImage, title: String, subtitle: String, buttonTitle: String, onButtonTouchUp: (() -> Void)?) {
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
        centerStack.addArrangedSubview(iconImage)
        centerStack.addArrangedSubview(titleLabel)
        centerStack.addArrangedSubview(subtitleLabel)
        centerStack.addArrangedSubview(button)
//        titleLabel.text = title
//        subtitleLabel.text = subtitle
        
        self.update(image: image, title: title, subtitle: subtitle, buttonTitle: buttonTitle)
        
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.addTarget(self, action: #selector(onButtonPressed), for: .touchUpInside)
        activaateConstraints()
        callback = onButtonTouchUp
    }
    
    public final func update(image: UIImage, title: String, subtitle: String, buttonTitle: String) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        button.setTitle(buttonTitle, for: .normal)
        iconImage.image = image
    }
    
    @objc
    internal func onButtonPressed(_ sender: UIButton) {
        callback?()
    }
}
