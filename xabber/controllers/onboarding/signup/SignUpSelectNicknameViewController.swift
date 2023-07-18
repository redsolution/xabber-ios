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

class SignUpSelectNicknameViewController: SignUpBaseViewController {
        
    override func configure() {
        super.configure()
        self.navigationController?.isNavigationBarHidden = false
        if CommonConfigManager.shared.config.locked_host.isNotEmpty {
            if !self.metadata.keys.contains(where: { $0 == "host" }) {
                self.metadata["host"] = CommonConfigManager.shared.config.locked_host
            }
        } else {
            if !self.metadata.keys.contains(where: { $0 == "host" }) {
                self.metadata["host"] = CommonConfigManager.shared.config.allowed_hosts.first ?? ""
            }
        }
    }
    
    override func onAppear() {
        super.onAppear()
        title = "Sign Up".localizeString(id: "title_register_xabber_account", arguments: [])
    }
    
    override func localizeResources() {
        super.localizeResources()
        titleLabel.text = "Let’s get Started!\nWhat’s your name?".localizeString(id: "xmpp_login__registration_title_nickname", arguments: [])
        setupPlaceholder("nickname".localizeString(id: "title_register_nickname", arguments: []))
        subtitleLabel.text = "Use the name or a nickname you are most comfortable with.".localizeString(id: "xmpp_login__registration_description_nickname", arguments: [])
        button.setTitle("Next".localizeString(id: "xaccount_next", arguments: []), for: .normal)
        button.setTitle("Next".localizeString(id: "xaccount_next", arguments: []), for: .disabled)
    }
    
    override func validateTextFiled(value: String?, callback: @escaping ((Bool) -> Void)) {
        guard let value = value,
              value.count > 0 else {
            callback(false)
            return
        }
        callback(true)
    }
    
    override func onButtonTouchUp() {
        super.onButtonTouchUp()
        let vc = SignUpSelectUsernameViewController()
        self.metadata["nickname"] = self.textFieldValue
        vc.metadata = self.metadata
        self.navigationController?.pushViewController(vc, animated: true)
    }
}

