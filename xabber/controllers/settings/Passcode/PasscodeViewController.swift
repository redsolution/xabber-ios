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

import UIKit

protocol PasscodeViewControllerDelegate: AnyObject {
    var mismatch: Bool { get set }
}

class PasscodeViewController: UIViewController, PasscodeViewControllerDelegate {
    enum VerifiedAction {
        case change
        case remove
    }

    enum Mode {
        case createNew
        case confirmNew(firstPasscode: String)
        case verifyCurrent(VerifiedAction)
    }
    
    var mismatch: Bool = false {
        didSet {
            if mismatch {
                showError("Passcodes did not match. Try again.")
            }
        }
    }
    
    weak var delegate: PasscodeViewControllerDelegate?
    private let mode: Mode

    let passcode: PasscodeEdtitView = {
        let view = PasscodeEdtitView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    let caption: UILabel = {
        let view = UILabel()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.textAlignment = .center
        view.font = .systemFont(ofSize: 17, weight: .regular)
        view.numberOfLines = 0
        return view
    }()
    
    let errorLabel: UILabel = {
        let view = UILabel()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        view.textAlignment = .center
        view.font = .systemFont(ofSize: 14, weight: .regular)
        view.textColor = .systemRed
        return view
    }()
    
    let cancelButton: UIBarButtonItem = {
        let button = UIBarButtonItem(barButtonSystemItem: .cancel, target: nil, action: nil)
        return button
    }()
    
    init(mode: Mode = .createNew, delegate: PasscodeViewControllerDelegate? = nil) {
        self.mode = mode
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(firstPasscode: String? = nil, delegate: PasscodeViewControllerDelegate? = nil, isOnboarding: Bool = false) {
        if let firstPasscode {
            self.init(mode: .confirmNew(firstPasscode: firstPasscode), delegate: delegate)
        } else {
            self.init(mode: .createNew, delegate: delegate)
        }
    }

    override init(nibName: String?, bundle: Bundle?) {
        self.mode = .createNew
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
        passcode.didFinishedEnterCode = { [weak self] code in
            self?.handleCompleted(code: code)
        }
    }
    
    private func setupUI() {
        self.title = titleText
        self.view.backgroundColor = .systemBackground

        cancelButton.target = self
        cancelButton.action = #selector(cancelAction)
        navigationItem.setRightBarButton(cancelButton, animated: true)

        caption.text = captionText
        view.addSubview(passcode)
        view.addSubview(caption)
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            passcode.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.6),
            passcode.heightAnchor.constraint(equalToConstant: 44),
            passcode.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            passcode.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -107),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            caption.bottomAnchor.constraint(equalTo: passcode.topAnchor, constant: -17),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            errorLabel.topAnchor.constraint(equalTo: passcode.bottomAnchor, constant: 8)
        ])
    }

    private var titleText: String {
        switch mode {
        case .createNew, .confirmNew:
            return "Passcode Lock"
        case .verifyCurrent(.change):
            return "Change Passcode"
        case .verifyCurrent(.remove):
            return "Turn Passcode Off"
        }
    }

    private var captionText: String {
        switch mode {
        case .createNew:
            return "Create a passcode to protect your data"
        case .confirmNew:
            return "Confirm your new passcode"
        case .verifyCurrent(.change):
            return "Enter your current passcode to change it"
        case .verifyCurrent(.remove):
            return "Enter your current passcode to turn Passcode Lock off"
        }
    }

    private func handleCompleted(code: String) {
        switch mode {
        case .createNew:
            let secondVC = PasscodeViewController(mode: .confirmNew(firstPasscode: code), delegate: self)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.navigationController?.pushViewController(secondVC, animated: true)
            }

        case .confirmNew(let firstPasscode):
            guard code == firstPasscode else {
                self.delegate?.mismatch = true
                self.navigationController?.popViewController(animated: true)
                return
            }
            saveNewPasscode(code)
            DispatchQueue.main.async {
                self.navigationController?.popToRootViewController(animated: true)
            }

        case .verifyCurrent(let action):
            guard CredentialsManager.shared.validatePincode(code) else {
                showError("Incorrect passcode. Try again.")
                return
            }
            handleVerifiedCurrentPasscode(action)
        }
    }

    private func handleVerifiedCurrentPasscode(_ action: VerifiedAction) {
        switch action {
        case .change:
            let vc = PasscodeViewController(mode: .createNew)
            DispatchQueue.main.async {
                self.navigationController?.pushViewController(vc, animated: true)
            }

        case .remove:
            CredentialsManager.shared.clearPincodes()
            SettingManager.shared.saveItem(for: "", scope: .security, key: "support_touch_id", value: false)
            DispatchQueue.main.async {
                self.navigationController?.popToRootViewController(animated: true)
            }
        }
    }

    private func saveNewPasscode(_ code: String) {
        CredentialsManager.shared.setPincode(code)
        CredentialsManager.shared.setPasscodeAttemptsLeft(5)
        SettingManager.shared.saveItem(for: "", scope: .security, key: SettingsViewController.Datasource.Keys.passcodeAttempts.rawValue, value: 5)
        SettingManager.shared.saveItem(for: "", scope: .security, key: SettingsViewController.Datasource.Keys.displayedAttempts.rawValue, value: 0)
        SettingManager.shared.saveItem(for: "", scope: .security, key: "support_touch_id", value: false)
        SettingManager.shared.saveItem(key: SettingsViewController.Datasource.Keys.showAttempts.rawValue, bool: true)
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        passcode.code = ""
        DispatchQueue.main.async {
            self.passcode.becomeFirstResponder()
        }
    }
    
    @objc
    private func cancelAction() {
        navigationController?.popViewController(animated: true)
    }
}
