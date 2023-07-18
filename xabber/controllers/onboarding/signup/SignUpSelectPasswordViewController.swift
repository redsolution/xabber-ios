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

class SignUpSelectPasswordViewController: SignUpBaseViewController {
    
    private var isRegistrationRequestSended: Bool = false
    
    private let activityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .gray)
        
        view.startAnimating()
        view.isHidden = true
        
        return view
    }()
    
    private let hiddenField: UITextField = {
        let field = UITextField(frame: CGRect(x: -100, y: -100, width: 50, height: 50))
        
        field.font = UIFont.systemFont(ofSize: 1)
        if #available(iOS 13.0, *) {
            field.textColor = UIColor.systemBackground.withAlphaComponent(0.01)
        } else {
            field.textColor = UIColor.white.withAlphaComponent(0.01)
        }
        
        field.textContentType = .username
        
        return field
    }()
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(hiddenField)
    }
    
    override func configure() {
        super.configure()
        textField.textContentType = .newPassword
        textField.isSecureTextEntry = true
        self.navigationController?.isNavigationBarHidden = false
        if let username = self.metadata["username"],
           let host = self.metadata["host"] {
            hiddenField.text = [username, host].joined(separator: "@")
        }
    }
    
    override func activateConstraints() {
        super.activateConstraints()
        
    }
    
    override func onAppear() {
        super.onAppear()
        title = "Password".localizeString(id: "account_password", arguments: [])
    }
    
    override func localizeResources() {
        super.localizeResources()
        titleLabel.text = "Shiny! Time to pick a secure password for your account.".localizeString(id: "xmpp_login__registration_title_password", arguments: [])
        setupPlaceholder("password")
        subtitleLabel.text = "Using a strong password is vital for your safety. We recommend you use unique passwords and password manager apps to keep track of them.".localizeString(id: "xmpp_login__registration_description_password", arguments: [])
        button.setTitle("Next".localizeString(id: "xaccount_next", arguments: []), for: .normal)
        button.setTitle("Next".localizeString(id: "xaccount_next", arguments: []), for: .disabled)
    }
    
    override func validateTextFiled(value: String?, callback: @escaping ((Bool) -> Void)) {
        guard let value = value,
              value.count > 4 else {
            callback(false)
            return
        }
        callback(true)
    }
    
    override func onButtonTouchUp() {
        
        if self.isRegistrationRequestSended {
            
        } else {
            guard let username = metadata["username"],
                  let host = metadata["host"] else {
                return
            }
            self.metadata["jid"] = [username, host].joined(separator: "@")
            self.metadata["password"] = self.textFieldValue
            let password = self.textFieldValue
            self.isRegistrationRequestSended = true
            
            do {
                try XMPPRegistrationManager.shared.register(username: username, password: password)
                XMPPRegistrationManager.shared.delegate = self
            } catch {
                print(error.localizedDescription)
            }
            
//            XabberAPIManager.shared.registerAccount(username: username, host: host, password: password) { (result, message) in
//                self.postRegister(result, message: message)
//            }
        }
        if self.isRegistrationRequestSended {
            self.activityIndicator.isHidden = false
            self.button.addSubview(self.activityIndicator)
            self.activityIndicator.frame = self.button.bounds
            self.activityIndicator.layoutIfNeeded()
            self.button.setTitle(" ", for: .disabled)
            self.makeButtonDisabled(true)
            
        } else {
            self.activityIndicator.isHidden = true
        }
    }
    
    private final func postRegister(_ result: Bool, message: String?) {
        self.isRegistrationRequestSended = false
        if result {
            guard let jid = self.metadata["jid"],
                  let password = self.metadata["password"],
                  let nickname = self.metadata["nickname"] else {
                return
            }
            AccountManager.shared.create(jid: jid, password: password, nickname: nickname, isFromRegister: true)
            let vc = SignUpSelectAvatarViewController()
            vc.metadata = self.metadata
            self.navigationController?.setViewControllers([vc], animated: true)
        } else {
            self.activityIndicator.removeFromSuperview()
            self.button.setTitle("Next".localizeString(id: "xaccount_next", arguments: []), for: .disabled)
            self.textField.text = nil
            self.makeButtonDisabled(true)
            if let message = message {
                self.subtitleLabel.text = message
            } else {
                self.subtitleLabel.text = "Sorry. Server not responding.".localizeString(id: "registration_title_server_not_responding", arguments: [])
            }
            self.subtitleLabel.textColor = .systemRed
        }
    }
}

extension SignUpSelectPasswordViewController: XMPPRegistrationManagerDelegate {
    func xmppRegistrationManagerReady() {
        
    }
    
    func xmppRegistrationManagerCheckUsername(available: Bool) {
        
    }
    
    func xmppRegistrationManagerSuccess() {
        DispatchQueue.main.async {
            self.postRegister(true, message: nil)
        }
        
    }
    
    func xmppRegistrationManagerFail(error: String) {
        DispatchQueue.main.async {
            self.postRegister(false, message: error)
        }
    }
    
    
}
