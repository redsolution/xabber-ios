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
import XMPPFramework.XMPPJID

class SignUpSelectUsernameViewController: SignUpBaseViewController {
    
    
    
    override func configure() {
        super.configure()
        self.textField.keyboardType = .asciiCapable
        self.textField.textContentType = .username
        self.textField.configure()
//        self.container.addSubview(diceButton)
        
        self.textField.button.isHidden = false
        self.textField.button.setImage(UIImage(systemName: "dice"), for: .normal)
        self.textField.button.addTarget(self, action: #selector(onDiceButtonTouchUpinside), for: .touchUpInside)
        
        XMPPRegistrationManager.shared.delegate = self
    }
    
    @objc
    internal func onDiceButtonTouchUpinside(_ sender: AnyObject) {
        let nick = NickGenerator.shared.genRandomNick().lowercased().replacingOccurrences(of: " ", with: ".")
        self.textField.text = nick
        textFieldValueObserver.accept(nick)
    }
    
    override func onAppear() {
        super.onAppear()
        title = "Username".localizeString(id: "account_user_name", arguments: [])
    }
    
    override func localizeResources() {
        super.localizeResources()
        titleLabel.text = "Great! Now, choose a username for people to find you on Clandestino.".localizeString(id: "registration_title_choose_username", arguments: [])
        setupPlaceholder("username".localizeString(id: "account_user_name", arguments: []).lowercased())
        subtitleLabel.text = "The account will be created on Clandestino server.".localizeString(id: "registration_title_account_created", arguments: [])
        button.setTitle("Next".localizeString(id: "xaccount_next", arguments: []), for: .normal)
        button.setTitle("Next".localizeString(id: "xaccount_next", arguments: []), for: .disabled)
    }
    
    override func validateTextFiled(value: String?, callback: @escaping ((Bool) -> Void)) {
        guard let value = value,
              value.count > 3,
              let host = self.metadata["host"],
              let jid = XMPPJID(user: value, domain: host, resource: nil),
              let localpart = jid.user,
              localpart.isNotEmpty else {
            self.subtitleLabel.text = "The account will be created on Clandestino server.".localizeString(id: "registration_title_account_created", arguments: [])
            UIView.animate(withDuration: 0.33, delay: 0.0, options: [.curveEaseOut]) {
                self.subtitleLabel.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
            } completion: { result in
                
            }
            callback(false)
            return
        }
        do {
            try XMPPRegistrationManager.shared.check(username: localpart)
        } catch {
            print(error.localizedDescription)
        }
        
//        XabberAPIManager.shared.checkUsernameAvailability(username: localpart, host: host) { (result, message) in
//            DispatchQueue.main.async {
//                if let message = message {
//                    self.subtitleLabel.text = message
//                    UIView.animate(withDuration: 0.33, delay: 0.0, options: [.curveEaseOut]) {
//                        self.subtitleLabel.textColor = .systemRed
//                    } completion: { result in
//
//                    }
//
//                } else {
//
//                }
//            }
//            callback(result)
//        }
    }
    
    override func onButtonTouchUp() {
        super.onButtonTouchUp()
        self.metadata["username"] = self.textFieldValue
        let vc = SignUpSelectPasswordViewController()
        vc.metadata = self.metadata
        if let rootVc = self.navigationController?.viewControllers.first {
            self.navigationController?.setViewControllers([rootVc, vc], animated: true)
        } else {
            self.navigationController?.pushViewController(vc, animated: true)
        }
    }
    
    @objc
    override func onTextFieldDidChangeSelector(_ sender: UITextField) {
        sender.text = sender.text?.lowercased().replacingOccurrences(of: " ", with: ".")
        textFieldValueObserver.accept(sender.text)
    }
}

extension SignUpSelectUsernameViewController: XMPPRegistrationManagerDelegate {
    func xmppRegistrationManagerReady() {
        
    }
    
    func xmppRegistrationManagerCheckUsername(available: Bool) {
        DispatchQueue.main.async {
            if available {
                self.makeButtonEnabled(true)
                self.subtitleLabel.text = "✓ Nice! That username is available.".localizeString(id: "xmpp_login__registration_jid_available", arguments: [])
                UIView.animate(withDuration: 0.33, delay: 0.0, options: [.curveEaseOut]) {
                    self.subtitleLabel.textColor = .systemBlue
                } completion: { result in
                    
                }
            } else {
                self.makeButtonDisabled(true)
                self.subtitleLabel.text = "The account will be created on Clandestino server.".localizeString(id: "registration_title_account_created", arguments: [])
                UIView.animate(withDuration: 0.33, delay: 0.0, options: [.curveEaseOut]) {
                    self.subtitleLabel.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
                } completion: { result in
                    
                }
            }
        }
    }
    
    func xmppRegistrationManagerSuccess() {
        
    }
    
    func xmppRegistrationManagerFail(error: String) {
        
    }
    
    
}
