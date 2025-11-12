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

class OnboardingViewController: SimpleBaseViewController {
    
    private var cachedHost: String? = nil
    
    internal var shouldShowSignUp: Bool = false
    
    let container: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fill
        
        return stack
    }()
    
    private let logoView: UIImageView = {
        let view = UIImageView()
        
        view.backgroundColor = .clear
        
        return view
    }()
        
    private let titleImage: UIImageView = {
        let view = UIImageView()
        
        view.backgroundColor = .clear
        
        return view
    }()
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 34, weight: .regular)
        
        return label
    }()
    
    private let subtitleLabel: UILabel = {
        let label = UILabel()
//        #3C3C43
        label.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
        
        return label
    }()
    
    private let signInButton: UIButton = {
        let button = UIButton()
        
        button.setTitleColor(.systemBlue, for: .normal)
        button.layer.cornerRadius = 22
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor(red: 191/255, green: 191/255, blue: 191/255, alpha: 1.0).cgColor
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        
        return button
    }()
    
    private let signUpButton: UIButton = {
        let button = UIButton()
        
        button.setTitleColor(.systemBlue, for: .normal)
        button.layer.cornerRadius = 22
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor(red: 191/255, green: 191/255, blue: 191/255, alpha: 1.0).cgColor
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
                
        return button
    }()
    
    private let privacyButton: UIButton = {
        let button = UIButton()
        
        button.setTitle("Privacy settings", for: .normal)
        button.setTitleColor(.secondaryLabel, for: .normal)
//        button.layer.cornerRadius = 22
        button.layer.borderWidth = 0
//        button.layer.borderColor = UIColor(red: 191/255, green: 191/255, blue: 191/255, alpha: 1.0).cgColor
        button.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .regular)
                
        return button
    }()
    
    private let activityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        
        view.startAnimating()
        
        return view
    }()
    
    private let footerLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textAlignment = .center
        label.numberOfLines = 3
        label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
        
        return label
    }()
    
    private let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fill
        
        stack.spacing = 8
        
        return stack
    }()
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(container)
        
        container.fillSuperviewWithOffset(top: 160, bottom: view.safeAreaInsets.bottom + 16, left: 32, right: 32)
        container.addArrangedSubview(stack)
        stack.addArrangedSubview(logoView)
        
        if CommonConfigManager.shared.config.show_text_logo {
            stack.addArrangedSubview(titleLabel)
        } else {
            stack.addArrangedSubview(titleImage)
        }
//        stack.addArrangedSubview(titleImage)
            
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(UIStackView())
        stack.addArrangedSubview(signInButton)
        stack.addArrangedSubview(signUpButton)
        stack.addArrangedSubview(privacyButton)
        stack.addArrangedSubview(footerLabel)
    }
    
    override func activateConstraints() {
        super.activateConstraints()
        let constraints: [NSLayoutConstraint] = [
            stack.widthAnchor.constraint(equalToConstant: 375),
            logoView.widthAnchor.constraint(equalToConstant: 128),
            logoView.heightAnchor.constraint(equalToConstant: 128),
            titleImage.widthAnchor.constraint(equalToConstant: 164),
            signUpButton.heightAnchor.constraint(equalToConstant: 44),
            signUpButton.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 16),
            signUpButton.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: -16),
            signInButton.heightAnchor.constraint(equalToConstant: 44),
            signInButton.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 16),
            signInButton.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: -16),
            privacyButton.heightAnchor.constraint(equalToConstant: 36),
            privacyButton.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 16),
            privacyButton.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: -16)
        ]
        NSLayoutConstraint.activate(constraints)
        
        stack.setCustomSpacing(16, after: logoView)
        stack.setCustomSpacing(16, after: signInButton)
        stack.setCustomSpacing(2, after: signUpButton)
        stack.setCustomSpacing(16, after: privacyButton)
    }
    
    override func localizeResources() {
        super.localizeResources()
        logoView.image = UIImage(named: "onboarding_logo_128pt")
        titleImage.image = UIImage(named: "onboarding_logo_name_contrast_164pt")
        titleLabel.text = CommonConfigManager.shared.config.app_name
        titleLabel.sizeToFit()
        subtitleLabel.text = CommonConfigManager.shared.config.onboarding_subtitle_text//"Secure chat".localizeString(id: "chat_type_secure", arguments: [])
        subtitleLabel.sizeToFit()
        signInButton.setTitle("Connect existing account".localizeString(id: "xmpp_login__button_sign_in", arguments: []), for: .normal)
        signUpButton.setTitle("Create new account".localizeString(id: "xmpp_login__button_sign_up", arguments: []), for: .normal)
        footerLabel.text = ""
        footerLabel.sizeToFit()
    }
    
    override func configure() {
        super.configure()
        title = " "
        self.navigationController?.title = " "
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        self.signInButton.addTarget(self, action: #selector(self.onSignInButtonTouchUp), for: .touchUpInside)
        self.signUpButton.addTarget(self, action: #selector(self.onSignUpButtonTouchUp), for: .touchUpInside)
        self.privacyButton.addTarget(self, action: #selector(self.onPrivacyButtonTouchUp), for: .touchUpInside)
    }
    
    @objc
    private final func onSignUpButtonTouchUp(_ sender: UIButton) {
        FeedbackManager.shared.tap()
//        func showVC(_ host: String) {
//            DispatchQueue.main.async {
//                let vc = SignUpSelectNicknameViewController()
//                vc.metadata = ["host": host]
//                self.navigationController?.pushViewController(vc, animated: true)
//            }
//        }
//
//        if let host = self.cachedHost {
//            showVC(host)
//        } else {
        self.signInButton.alpha = 0.0
        self.activityIndicator.frame = self.signUpButton.bounds
        self.signUpButton.layer.borderColor = UIColor.clear.cgColor
        self.signUpButton.setTitle("", for: .normal)
        self.signUpButton.addSubview(activityIndicator)
        XMPPRegistrationManager.shared.delegate = self
        self.shouldShowSignUp = true
        do {
            try XMPPRegistrationManager.shared.start(host: XMPPRegistrationManager.getDefaultHost())
        } catch {
            print(error.localizedDescription)
        }
        
//            XabberAPIManager.shared.getAvailableHosts { hosts in
//                guard let host = hosts.first else {
//                    return
//                }
//                self.cachedHost = host
//                showVC(host)
//            }
//        }
    }
    
    @objc
    private final func onSignInButtonTouchUp(_ sender: UIButton) {
        FeedbackManager.shared.tap()
        let vc = SignInCreditionalsViewController()
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    @objc
    private final func onPrivacyButtonTouchUp(_ sender: UIButton) {
        FeedbackManager.shared.tap()
        let vc = PrivacySettingsViewController()
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.signUpButton.layer.borderColor = UIColor(red: 191/255, green: 191/255, blue: 191/255, alpha: 1.0).cgColor
        self.signUpButton.setTitle("Create new account".localizeString(id: "xmpp_login__button_sign_up", arguments: []), for: .normal)
        self.activityIndicator.removeFromSuperview()
        self.signInButton.alpha = 1.0
        title = " "
        self.navigationController?.title = " "
        self.navigationItem.largeTitleDisplayMode = .never
        self.navigationController?.navigationBar.prefersLargeTitles = false
        self.navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        self.navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.navigationBar.setNeedsLayout()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        CredentialsManager.shared.clearKeychain()
    }
    
}

extension OnboardingViewController: XMPPRegistrationManagerDelegate {
    func xmppRegistrationManagerCheckUsername(available: Bool) {
        
    }
    
    func xmppRegistrationManagerSuccess() {
        
    }
    
    func xmppRegistrationManagerFail(error: String) {
        
    }
    
    func xmppRegistrationManagerReady() {
        DispatchQueue.main.async {
            if self.shouldShowSignUp {
                if CommonConfigManager.shared.config.skip_vcard_nickname_onboarding_step {
                    let vc = SignUpSelectUsernameViewController()
                    vc.metadata = ["host": XMPPRegistrationManager.getDefaultHost()]
                    self.navigationController?.pushViewController(vc, animated: true)
                } else {
                    let vc = SignUpSelectNicknameViewController()
                    vc.metadata = ["host": XMPPRegistrationManager.getDefaultHost()]
                    self.navigationController?.pushViewController(vc, animated: true)
                }
                
                XMPPRegistrationManager.shared.delegate = nil
                self.shouldShowSignUp = false
            }
        }
    }
}
