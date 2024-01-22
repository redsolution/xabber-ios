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
import RxSwift
import RxCocoa

class CredentialsExpiredViewController: SimpleBaseViewController {
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fill
        
        return stack
    }()
    
    let centralStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 16
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
        label.numberOfLines = 0
        label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
        
        return label
    }()
    
    let passwordField: UITextFiledWithShadow = {
        let field = UITextFiledWithShadow()
        
        field.restorationIdentifier = "PasswordFieldRID"
        field.isSecureTextEntry = true
        field.textAlignment = .center
        field.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.textContentType = .password
        field.keyboardType = .default
        field.returnKeyType = .done
        
        return field
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
        
        return label
    }()
    
    let connectButton: UIButton = {
        let button = UIButton()
        
        button.layer.cornerRadius = 22
        button.layer.masksToBounds = true
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        
        return button
    }()
    
    let deleteButton: UIButton = {
        let button = UIButton()
        
        button.backgroundColor = .clear
        button.setTitleColor(UIColor.systemRed, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        
        return button
    }()
    
    let deleteBarButton: UIBarButtonItem = {
        
        if #available(iOS 13.0, *) {
            let item = UIBarButtonItem(image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), style: .plain, target: nil, action: nil)
            return item
        } else {
            let item = UIBarButtonItem(title: "Quit", style: .plain, target: nil, action: nil)
            return item
        }
    }()
    
    public var passwordFieldValueObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    private var passwordFieldValue: String? = nil
    
    public var isInConnectingProcess: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    
    private final func doAnimationsBlock(animated: Bool, block: @escaping (() -> Void)) {
        if animated {
            UIView.animate(
                withDuration: 0.33,
                delay: 0.0,
                options: [.curveEaseIn],
                animations: block,
                completion: nil
            )
        } else {
            UIView.performWithoutAnimation(block)
        }
    }
    
    public final func makeButtonEnabled(_ animated: Bool) {
        doAnimationsBlock(animated: animated) {
            self.connectButton.isEnabled = true
            self.connectButton.backgroundColor = .systemBlue
            self.connectButton.setTitleColor(.white, for: .normal)
        }
    }
    
    public final func makeButtonDisabled(_ animated: Bool) {
        doAnimationsBlock(animated: animated) {
            self.connectButton.isEnabled = false
            self.connectButton.backgroundColor = MDCPalette.grey.tint100
            self.connectButton.setTitleColor(UIColor.black.withAlphaComponent(0.23), for: .disabled)
        }
    }
    
    private final func validateTextField(value: String?, callback: ((Bool) -> Void)) {
        guard let value = value,
              value.isNotEmpty else {
            callback(false)
            return
        }
        callback(true)
    }
    
    override func subscribe() {
        super.subscribe()
        
        passwordFieldValueObserver
            .asObservable()
            .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
            .subscribe { value in
                self.validateTextField(value: value) { result in
                    DispatchQueue.main.async {

                        if result {
                            self.makeButtonEnabled(true)
                        } else {
                            self.makeButtonDisabled(true)
                        }
                    }
                    if let value = value {
                        self.passwordFieldValue = value
                    }
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: bag)
    }
    
    override func activateConstraints() {
        super.activateConstraints()
        NSLayoutConstraint.activate([
            centralStack.widthAnchor.constraint(lessThanOrEqualToConstant: 375),
            passwordField.leftAnchor.constraint(equalTo: centralStack.leftAnchor),
            passwordField.rightAnchor.constraint(equalTo: centralStack.rightAnchor),
            passwordField.heightAnchor.constraint(equalToConstant: 44),
            connectButton.leftAnchor.constraint(equalTo: centralStack.leftAnchor, constant: 0),
            connectButton.rightAnchor.constraint(equalTo: centralStack.rightAnchor, constant: 0),
            connectButton.heightAnchor.constraint(equalToConstant: 44),
//            deleteButton.leftAnchor.constraint(equalTo: centralStack.leftAnchor, constant: 0),
//            deleteButton.rightAnchor.constraint(equalTo: centralStack.rightAnchor, constant: 0),
//            deleteButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(stack)
        var offset: CGFloat = 0
        if #available(iOS 11.0, *) {
            if let topOffset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
                offset += topOffset
            }
        }
        let displayHeigth = UIScreen.main.bounds.height
        stack.fillSuperviewWithOffset(top: view.safeAreaInsets.top + displayHeigth * 0.1 + offset, bottom: 0, left: 24, right: 24)
        stack.addArrangedSubview(centralStack)
        centralStack.addArrangedSubview(titleLabel)
        centralStack.addArrangedSubview(passwordField)
        centralStack.addArrangedSubview(subtitleLabel)
        centralStack.addArrangedSubview(connectButton)
//        centralStack.addArrangedSubview(deleteButton)
        centralStack.addArrangedSubview(UIStackView())
        centralStack.setCustomSpacing(36, after: titleLabel)
        passwordField.addTarget(self, action: #selector(onPasswordFieldDidChangeSelection), for: .editingChanged)
        self.navigationItem.setRightBarButton(deleteBarButton, animated: true)
        deleteBarButton.target = self
        deleteBarButton.action = #selector(deleteAccountButtonTouchUpInside)
        connectButton.addTarget(self, action: #selector(connectButtonTouchUpInside), for: UIControl.Event.touchUpInside)
    }
    
    override func configure() {
        super.configure()
        self.makeButtonDisabled(false)
        title = "Security check"
        titleLabel.text = "Please enter your password to continue using \(CommonConfigManager.shared.config.app_name)"
        subtitleLabel.text = "Sometimes we ask for you to enter your password to confirm that you are the rightful owner of this account"
        connectButton.setTitle("Continue", for: .normal)
        deleteButton.setTitle("Quit account", for: .normal)
        
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        passwordField.attributedPlaceholder = NSAttributedString(string: "Password", attributes: [
            NSAttributedString.Key.font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            NSAttributedString.Key.foregroundColor: UIColor.black.withAlphaComponent(0.23),
            NSAttributedString.Key.paragraphStyle: paragraph
        ])
        AccountManager.shared.find(for: self.owner)?.disconnect(hard: true)
    }
    
    @objc
    private func onPasswordFieldDidChangeSelection(_ sender: UITextField) {
        self.passwordFieldValueObserver.accept(sender.text)
    }
    
    @objc
    private func connectButtonTouchUpInside(_ sender: UIButton) {
        guard let passwordFieldValue = passwordFieldValue else {
            return
        }
        CredentialsManager.shared.setItem(for: self.owner, password: passwordFieldValue, keepSecret: true)
        CredentialsManager.shared.getItem(for: self.owner).updateKind(to: .password)
        
        AccountManager.shared.find(for: self.owner)?.asyncConnect(shouldReregisterDFevice: true)
        self.dismiss(animated: true)
    }
    
    @objc
    private func deleteAccountButtonTouchUpInside(_ sender: AnyObject) {
        let presenter = QuitAccountPresenter(jid: owner)
        presenter.present(in: self, animated: true) {
            self.unsubscribe()
            AccountManager.shared.deleteAccount(by: self.owner)
            if AccountManager.shared.emptyAccountsList() {
                DispatchQueue.main.async {
                    let vc = OnboardingViewController()
                    
                    let navigationController = UINavigationController(rootViewController: vc)
                    
                    navigationController.isNavigationBarHidden = true
                    (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = navigationController
                }
            } else {
                DispatchQueue.main.async {
                    self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                    self.navigationController?.navigationBar.shadowImage = nil
                    self.navigationController?.popToRootViewController(animated: true)
                }
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        (UIApplication.shared.delegate as? AppDelegate)?.credentialsExpiredPresenterShowed = false
    }
}

extension CredentialsExpiredViewController: UITextFieldDelegate {
    
    
    func textFieldDidBeginEditing(_ textField: UITextField) {
        if !textField.isSelected {
            textField.isSelected = true
        }
    }
    
    func textFieldDidEndEditing(_ textField: UITextField) {
        if textField.isSelected {
            textField.isSelected = false
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField, reason: UITextField.DidEndEditingReason) {
        if textField.isSelected {
            textField.isSelected = false
        }
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
 
