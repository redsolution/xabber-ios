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

import UIKit
import LocalAuthentication

protocol PasscodeViewControllerDelegate {
    var mismatch: Bool { get set }
}

class PasscodeViewController: UIViewController, PasscodeViewControllerDelegate {
    
    var mismatch: Bool = false {
        didSet {
            errorLabel.isHidden = !mismatch
            passcode.code = ""
        }
    }
    
    var delegate: PasscodeViewControllerDelegate?

    let passcode: PasscodeEdtitView = {
        let view = PasscodeEdtitView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    let caption: UILabel = {
        let view = UILabel()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    let errorLabel: UILabel = {
        let view = UILabel()
        view.text = "Passcodes did not match. Try again."
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()
    
    let cancelButton: UIBarButtonItem = {
        let button = UIBarButtonItem(barButtonSystemItem: .cancel, target: nil, action: nil)
        return button
    }()

    let skipButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Skip", style: .plain, target: nil, action: nil)
        return button
    }()
    
    var firstPasscode: String?
    var isOnboarding: Bool = false
    
    init(firstPasscode: String? = nil, delegate: PasscodeViewControllerDelegate? = nil, isOnboarding: Bool = false) {
        self.firstPasscode = firstPasscode
        self.delegate = delegate
        self.isOnboarding = isOnboarding
        super.init(nibName: nil, bundle: nil)
    }

    override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        passcode.becomeFirstResponder()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        passcode.didFinishedEnterCode = { code in
            if let firstPasscode = self.firstPasscode {
                if code == firstPasscode {
                    CredentialsManager.shared.setPincode(code)
                    CredentialsManager.shared.setPasscodeAttemptsLeft(5)
                    SettingManager.shared.saveItem(for: "", scope: .security, key: SettingsViewController.Datasource.Keys.passcodeAttempts.rawValue, value: 5)
                    SettingManager.shared.saveItem(for: "", scope: .security, key: SettingsViewController.Datasource.Keys.displayedAttempts.rawValue, value: 0)
                    SettingManager.shared.saveItem(for: "", scope: .security, key: "support_touch_id", value: false)
                    SettingManager.shared.saveItem(key: SettingsViewController.Datasource.Keys.showAttempts.rawValue, bool: true)
                        DispatchQueue.main.async {
                            if self.isOnboarding {
                                let vc = SignUpEnableNotificationsViewController()
                                self.navigationController?.setViewControllers([vc], animated: true)
                            } else {
                                self.navigationController?.popToRootViewController(animated: true)
                            }
                        }
                } else {
                    self.delegate?.mismatch = true
                    self.navigationController?.popViewController(animated: true)
                }
            } else {
                let secondVC = PasscodeViewController(firstPasscode: code, delegate: self, isOnboarding: self.isOnboarding)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.navigationController?.pushViewController(secondVC, animated: true)
                }
            }
            
        }
    }
    
    private func setupUI() {
        self.title = "Passcode lock"
        if #available(iOS 13.0, *) {
            self.view.backgroundColor = .systemBackground
        } else {
            self.view.backgroundColor = .white
        }
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction)
        skipButton.target = self
        skipButton.action = #selector(skipAction)
        let barButton = self.isOnboarding ? skipButton : cancelButton
        navigationItem.setRightBarButton(barButton, animated: true)
        navigationItem.setHidesBackButton(true, animated: false)
        if let _ = firstPasscode {
            caption.text = "Verify your new passcode"
        } else {
            caption.text =  "Create a passcode to protect your data"
        }
        view.addSubview(passcode)
        view.addSubview(caption)
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([passcode.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.6),
                                     passcode.heightAnchor.constraint(equalToConstant: 44),
                                     passcode.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     passcode.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -107),
                                     caption.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     caption.bottomAnchor.constraint(equalTo: passcode.topAnchor, constant: -17),
                                     errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     errorLabel.topAnchor.constraint(equalTo: passcode.bottomAnchor, constant: 5)
        ])
    }
    
    @objc
    private func cancelAction() {
        navigationController?.popToRootViewController(animated: true)
    }
    
    @objc
    private func skipAction() {
        let vc = SignUpEnableNotificationsViewController()
        self.navigationController?.setViewControllers([vc], animated: true)
    }
}
