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
        
        internal var jid: String = ""
        
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 8, left: 20, right: 0)
            
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
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 12)
            
            return stack
        }()
        
        var avatarButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 128))
            button.backgroundColor = .red
            if AccountMasksManager.shared.load() != "square" {
                button.mask = UIImageView(image: #imageLiteral(resourceName: AccountMasksManager.shared.mask128pt))
            } else {
                button.mask = nil
            }
            button.layer.masksToBounds = true
            button.imageView?.contentMode = .scaleAspectFill
            button.contentMode = .scaleAspectFill
            return button
        }()
        
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
                avatarButton.mask = UIImageView(image: #imageLiteral(resourceName: AccountMasksManager.shared.mask128pt))
            } else {
                avatarButton.mask = nil
            }
        }
        
        private func activateConstraints() {
            NSLayoutConstraint.activate([
                topStack.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 1),
                avatarButton.widthAnchor.constraint(equalToConstant: 128),
                avatarButton.heightAnchor.constraint(equalToConstant: 128),
                imageActivityIndicator.centerXAnchor.constraint(equalTo: avatarButton.centerXAnchor),
                imageActivityIndicator.centerYAnchor.constraint(equalTo: avatarButton.centerYAnchor),
                topSeparatorView.heightAnchor.constraint(equalToConstant: 1),
                topSeparatorView.widthAnchor.constraint(equalTo: fieldStack.widthAnchor, multiplier: 1),
                middleSeparatorView.heightAnchor.constraint(equalToConstant: 1),
                middleSeparatorView.widthAnchor.constraint(equalTo: fieldStack.widthAnchor, multiplier: 1),
                givenNameField.heightAnchor.constraint(equalToConstant: 24),
                givenNameField.trailingAnchor.constraint(equalTo: fieldStack.trailingAnchor, constant: -20),
                middleNameField.heightAnchor.constraint(equalToConstant: 24),
                middleNameField.trailingAnchor.constraint(equalTo: fieldStack.trailingAnchor, constant: -20),
                familyNameField.heightAnchor.constraint(equalToConstant: 24),
                familyNameField.trailingAnchor.constraint(equalTo: fieldStack.trailingAnchor, constant: -20),
                fullnameField.heightAnchor.constraint(equalToConstant: 24),
                fullnameField.trailingAnchor.constraint(equalTo: fieldStack.trailingAnchor, constant: -20),
                bottomSeparatorView.heightAnchor.constraint(equalToConstant: 1),
                bottomSeparatorView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20)
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
            contentView.addSubview(avatarButton)
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
            
            backgroundColor = .white
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
