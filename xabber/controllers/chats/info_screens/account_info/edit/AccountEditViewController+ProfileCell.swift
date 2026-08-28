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
import Kingfisher
import MaterialComponents.MDCPalettes

extension AccountEditViewController {
    class ProfileCell: UITableViewCell {
        static let cellName = "ProfileCell"

        final class AvatarActionOverlayView: UIView {
            let gradientLayer = CAGradientLayer()
            let cameraImageView: UIImageView = {
                let view = UIImageView(image: UIImage(systemName: "camera.fill"))
                view.translatesAutoresizingMaskIntoConstraints = false
                view.tintColor = .white
                view.contentMode = .scaleAspectFit
                return view
            }()

            override init(frame: CGRect) {
                super.init(frame: frame)
                isUserInteractionEnabled = false
                gradientLayer.colors = [
                    UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.72).cgColor
                ]
                gradientLayer.locations = [0, 1]
                layer.addSublayer(gradientLayer)
                addSubview(cameraImageView)
                NSLayoutConstraint.activate([
                    cameraImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                    cameraImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                    cameraImageView.widthAnchor.constraint(equalToConstant: 24),
                    cameraImageView.heightAnchor.constraint(equalToConstant: 20)
                ])
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                gradientLayer.frame = bounds
            }
        }
        
        internal var jid: String = ""
        
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .fill
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 8, left: 20, right: 20)
            
            return stack
        }()
        
        var topStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center //.bottom ?
            stack.spacing = 20
            stack.distribution = .fill
            
            return stack
        }()
        
        var fieldStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .fill
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = .zero
            
            return stack
        }()
        
        var avatarButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 128))
            button.backgroundColor = .red
            if AccountMasksManager.shared.load() != "square" {
                button.mask = UIImageView(image: imageLiteral( AccountMasksManager.shared.mask128pt))
            } else {
                button.mask = nil
            }
            button.layer.masksToBounds = true
            button.imageView?.contentMode = .scaleAspectFill
            button.contentMode = .scaleAspectFill
            button.isAccessibilityElement = true
            button.accessibilityLabel = "Change profile picture".localizeString(
                id: "account_change_profile_picture",
                arguments: []
            )
            button.accessibilityHint = "Open profile picture options".localizeString(
                id: "account_change_profile_picture_hint",
                arguments: []
            )
            return button
        }()

        let avatarActionOverlay = AvatarActionOverlayView()
        
        var givenNameField: UITextField = {
            let field = UITextField(frame: .zero)
            
            field.placeholder = "First name".localizeString(id: "vcard_given_name", arguments: [])
            field.restorationIdentifier = "ci_given_name"
            field.clearButtonMode = .always
            
            return field
        }()
        
        var middleNameField: UITextField = {
            let field = UITextField(frame: .zero)
            
            field.placeholder = "Middle name".localizeString(id: "vcard_middle_name", arguments: [])
            field.restorationIdentifier = "ci_middle_name"
            field.clearButtonMode = .always
            
            return field
        }()
        
        var familyNameField: UITextField = {
            let field = UITextField(frame: .zero)
                        
            field.placeholder = "Last name".localizeString(id: "vcard_family_name", arguments: [])
            field.restorationIdentifier = "ci_family_name"
            field.clearButtonMode = .always
            
            return field
        }()
        
        var fullnameField: UITextField = {
            let field = UITextField(frame: .zero)
            
            field.placeholder = "Full name".localizeString(id: "vcard_full_name", arguments: [])
            field.restorationIdentifier = "ci_full_name"
            field.clearButtonMode = .always
            
            return field
        }()
        
        var topSeparatorView: UIView = {
            let view = UIView()
            view.backgroundColor = UIColor.black.withAlphaComponent(0.1)
            return view
        }()
        
        var middleSeparatorView: UIView = {
            let view = UIView()
            view.backgroundColor = UIColor.black.withAlphaComponent(0.1)
            return view
        }()
        
        var bottomSeparatorView: UIView = {
            let view = UIView()
            view.backgroundColor = UIColor.black.withAlphaComponent(0.1)
            return view
        }()
        
//        var middleSeparatorView: UIView = {
//            let view = UIView()
//            view.backgroundColor = UIColor.black.withAlphaComponent(0.1)
//            return view
//        }()
        
        let imageActivityIndicator: UIActivityIndicatorView = {
            let indicator = UIActivityIndicatorView()
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.stopAnimating()
            indicator.hidesWhenStopped = true
            indicator.style = .white
            
            return indicator
        }()
        
        let darkenedView: UIView = {
            let view = UIView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.backgroundColor = .black.withAlphaComponent(0.27)
            view.alpha = 0
            
            return view
        }()
        
        var callback: (() -> Void)?
        var usernameCallback: ((String, String?) -> Void)?
    
        var firstName: String = ""
        var middleName: String = ""
        var familyName: String = ""
                
        func setMask() {
            if AccountMasksManager.shared.load() != "square" {
                avatarButton.mask = UIImageView(image: imageLiteral( AccountMasksManager.shared.mask128pt))
            } else {
                avatarButton.mask = nil
            }
        }
        
        private func activateConstraints() {
            NSLayoutConstraint.activate([
                avatarButton.widthAnchor.constraint(equalToConstant: 128),
                avatarButton.heightAnchor.constraint(equalToConstant: 128),
                avatarActionOverlay.leadingAnchor.constraint(equalTo: avatarButton.leadingAnchor),
                avatarActionOverlay.trailingAnchor.constraint(equalTo: avatarButton.trailingAnchor),
                avatarActionOverlay.bottomAnchor.constraint(equalTo: avatarButton.bottomAnchor),
                avatarActionOverlay.heightAnchor.constraint(equalToConstant: 48),
                imageActivityIndicator.centerXAnchor.constraint(equalTo: avatarButton.centerXAnchor),
                imageActivityIndicator.centerYAnchor.constraint(equalTo: avatarButton.centerYAnchor),
                topSeparatorView.heightAnchor.constraint(equalToConstant: 1),
                middleSeparatorView.heightAnchor.constraint(equalToConstant: 1),
                givenNameField.heightAnchor.constraint(equalToConstant: 24),
                middleNameField.heightAnchor.constraint(equalToConstant: 24),
                familyNameField.heightAnchor.constraint(equalToConstant: 24),
                fullnameField.heightAnchor.constraint(equalToConstant: 24),
                bottomSeparatorView.heightAnchor.constraint(equalToConstant: 1)
            ])
        }
        
        var currentUrl: String? = ""
        
        func configure(avatarUrl:String?, nickname: String, jid: String, editable: Bool, given: String, middle: String, family: String, fullname: String) {
            
            
            
            if currentUrl != avatarUrl {
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: jid, size: 128) { image in
                    if let image = image {
                        self.avatarButton.setImage(image, for: .normal)
                        self.currentUrl = avatarUrl
                    } else {
                        self.avatarButton.setImage(UIImageView.getDefaultAvatar(for: nickname, owner: jid, size: 128), for: .normal)
                    }
                }
            }
            self.jid = jid
            givenNameField.text = given
            middleNameField.text = middle
            familyNameField.text = family
            fullnameField.text = fullname
            
            firstName = given
            middleName = middle
            familyName = family
            
            let fn = [firstName, middleName, familyName].compactMap({ (item) -> String? in
                if item.isNotEmpty { return item }
                return nil
            }).joined(separator: " ")
            
            self.usernameCallback?("ci_nickname_temp", fn)
        }
        
        func showDarkenedView() {
            imageActivityIndicator.startAnimating()
            UIView.animate(withDuration: 0.2) {
                self.darkenedView.alpha = 1
            }
        }
        
        func hideDarkenedView() {
            imageActivityIndicator.stopAnimating()
            UIView.animate(withDuration: 0.2) {
                self.darkenedView.alpha = 0
            }
        }
        
        func setAvatar(image: UIImage?) {
            self.avatarButton.setImage(image, for: .normal)
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            selectionStyle = .none
            avatarActionOverlay.translatesAutoresizingMaskIntoConstraints = false
            avatarButton.addSubview(avatarActionOverlay)
            avatarButton.addSubview(darkenedView)
            darkenedView.fillSuperview()
            avatarButton.addSubview(imageActivityIndicator)
            
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(topStack)
            stack.addArrangedSubview(bottomSeparatorView)
            stack.addArrangedSubview(fullnameField)
            fieldStack.addArrangedSubview(givenNameField)
            fieldStack.addArrangedSubview(topSeparatorView)
            fieldStack.addArrangedSubview(middleNameField)
            fieldStack.addArrangedSubview(middleSeparatorView)
            fieldStack.addArrangedSubview(familyNameField)
            topStack.addArrangedSubview(avatarButton)
            topStack.addArrangedSubview(fieldStack)

            avatarButton.setContentHuggingPriority(.required, for: .horizontal)
            avatarButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            fieldStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            fieldStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            
            backgroundColor = .systemBackground
            contentView.backgroundColor = .systemBackground
            topSeparatorView.backgroundColor = .separator
            middleSeparatorView.backgroundColor = .separator
            bottomSeparatorView.backgroundColor = .separator
            VCardInputPolicy.apply(to: givenNameField, key: "ci_given_name")
            VCardInputPolicy.apply(to: middleNameField, key: "ci_middle_name")
            VCardInputPolicy.apply(to: familyNameField, key: "ci_family_name")
            VCardInputPolicy.apply(to: fullnameField, key: "ci_full_name")
            givenNameField.addTarget(self, action: #selector(onFieldDidChange), for: .editingChanged)
            middleNameField.addTarget(self, action: #selector(onFieldDidChange), for: .editingChanged)
            familyNameField.addTarget(self, action: #selector(onFieldDidChange), for: .editingChanged)
            fullnameField.addTarget(self, action: #selector(onFieldDidChange), for: .editingChanged)
            activateConstraints()
            
            avatarButton.addTarget(self, action: #selector(onAvatarButtonTapped), for: .touchUpInside)
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
        
        @objc
        internal func onAvatarButtonTapped(_ sender: UIButton) {
            callback?()
        }
        
        @objc
        internal func onFieldDidChange(_ sender: UITextField) {
            switch sender.restorationIdentifier {
            case "ci_given_name": firstName = sender.text ?? ""
            case "ci_middle_name": middleName = sender.text ?? ""
            case "ci_family_name": familyName = sender.text ?? ""
            default: break
            }
            if sender.restorationIdentifier != "ci_full_name" {
                let fn = [firstName, middleName, familyName].compactMap({ (item) -> String? in
                    if item.isNotEmpty { return item }
                    return nil
                }).joined(separator: " ")
                usernameCallback?("ci_nickname_temp", fn)
            }
            usernameCallback?(sender.restorationIdentifier ?? "", sender.text)
        }
    }
}
