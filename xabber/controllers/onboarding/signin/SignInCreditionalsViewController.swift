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
import RxSwift
import RxCocoa
import MaterialComponents.MDCPalettes

class SignInCreditionalsViewController: SimpleBaseViewController {
    
    enum ConnectionStep {
        case step1
        case step2
        case step3
        case step4
    }
    
    class ConnectionStatusView: UIView {
        
        private let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.spacing = 4
            stack.alignment = .leading
            stack.distribution = .fill
            
            return stack
        }()
        
        private let topStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.spacing = 16
            stack.alignment = .leading
            stack.distribution = .fill
            
            return stack
        }()
        
        private let label: UILabel = {
            let label = UILabel()
            
            label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
            
            return label
        }()
        
        private let errorLabel: InsetLabel = {
            let label = InsetLabel()
                        
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = .systemRed
            
            return label
        }()
        
        private let indicator: UIActivityIndicatorView = {
            let view = UIActivityIndicatorView(style: .gray)
            
            view.isHidden = false
            view.startAnimating()
            
            return view
        }()
        
        private let checkView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 24))
            
            view.image = #imageLiteral(resourceName: "check-circle").withRenderingMode(.alwaysTemplate)
            view.tintColor = .systemGreen
            view.isHidden = true
            
            return view
        }()
        
        private final func activateConstrtaints() {
            NSLayoutConstraint.activate([
                indicator.widthAnchor.constraint(equalToConstant:  24),
                indicator.heightAnchor.constraint(equalToConstant: 24),
                checkView.widthAnchor.constraint(equalToConstant:  24),
                checkView.heightAnchor.constraint(equalToConstant: 24),
                label.heightAnchor.constraint(equalToConstant: 24),
                topStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 0),
                errorLabel.heightAnchor.constraint(equalToConstant: 16),
                errorLabel.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 0),
                errorLabel.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: 0)
            ])
        }
        
        private final func setup() {
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(topStack)
            stack.addArrangedSubview(errorLabel)
            topStack.addArrangedSubview(label)
            topStack.addArrangedSubview(indicator)
            topStack.addArrangedSubview(checkView)
            activateConstrtaints()
        }
        
        public final func configure(title: String) {
            label.text = title
        }
        
        public final func reset() {
            UIView.performWithoutAnimation {
                self.isHidden = true
                self.indicator.isHidden = false
                self.checkView.isHidden = true
                self.errorLabel.text = nil
                self.label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
                
            }
        }
        
        public final func setChecked(_ checked: Bool) {
            UIView.performWithoutAnimation {
                if checked {
                    self.checkView.tintColor = .systemGreen
                    self.checkView.image = #imageLiteral(resourceName: "check-circle").withRenderingMode(.alwaysTemplate)
                    self.indicator.isHidden = true
                    self.checkView.isHidden = false
                    if #available(iOS 13.0, *) {
                        self.label.textColor = .label
                    } else {
                        self.label.textColor = .darkText
                    }
                } else {
                    self.label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
                    self.indicator.isHidden = false
                    self.checkView.isHidden = true
                }
            }
        }
        
        public final func setError(_ error: Bool, text: String?) {
            UIView.performWithoutAnimation {
                if error {
                    self.errorLabel.text = text
                    self.checkView.tintColor = .systemRed
                    self.checkView.image = #imageLiteral(resourceName: "information").withRenderingMode(.alwaysTemplate)
                    self.indicator.isHidden = true
                    self.checkView.isHidden = false
                    if #available(iOS 13.0, *) {
                        self.label.textColor = .label
                    } else {
                        self.label.textColor = .darkText
                    }
                } else {
                    self.label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6)
                    self.errorLabel.text = nil
                    self.indicator.isHidden = false
                    self.checkView.isHidden = true
                }
            }
        }
        
        public final func makeConstraints(for stack: UIStackView) -> [NSLayoutConstraint] {
            return [
                heightAnchor.constraint(equalToConstant: 44),
                leftAnchor.constraint(equalTo: stack.leftAnchor),
                rightAnchor.constraint(equalTo: stack.rightAnchor)
            ]
        }
        
        init() {
            super.init(frame: .zero)
            setup()
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
    }
    
    let container: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fill
        
//        stack.isUserInteractionEnabled = false
        
        return stack
    }()
    
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fill
        
        stack.spacing = 16
        
//        stack.isUserInteractionEnabled = false
        
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
    
    let loginField: UITextFiledWithShadow = {
        let field = UITextFiledWithShadow()
        
        field.restorationIdentifier = "LoginFieldRID"
        field.textAlignment = .center
        field.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        field.keyboardType = .emailAddress
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.textContentType = .username
        field.returnKeyType = .next
        
        return field
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
    
    let subtitleButton: UIButton = {
        let button = UIButton()
                
        button.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        button.titleLabel?.textAlignment = .center
        button.titleLabel?.numberOfLines = 0
        button.setTitleColor(UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6), for: .normal)
        
        return button
    }()
    
    let button: UIButton = {
        let button = UIButton()
        
        button.layer.cornerRadius = 22
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        
        return button
    }()
    
    private let statusStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fill
        
        stack.spacing = 0
        
        return stack
    }()
    
    private let activityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .gray)
        
        view.startAnimating()
        view.isHidden = true
        
        return view
    }()
        
    private let step1: ConnectionStatusView = {
        let view = ConnectionStatusView(frame: CGRect(width: 359, height: 24))
        
        view.configure(title: "Finding Server"
                        .localizeString(id: "dialog_jingle_message__status_finding_server", arguments: []))
        view.isHidden = true
        
        return view
    }()
    
    private let step2: ConnectionStatusView = {
        let view = ConnectionStatusView(frame: CGRect(width: 359, height: 24))
        
        view.configure(title: "Communicating with server"
                        .localizeString(id: "dialog_jingle_message__status_communicating", arguments: []))
        view.isHidden = true
        
        return view
    }()
    
    private let step3: ConnectionStatusView = {
        let view = ConnectionStatusView(frame: CGRect(width: 359, height: 24))
        
        view.configure(title: "Checking credentials"
                        .localizeString(id: "dialog_jingle_message__status_checking_credentials", arguments: []))
        view.isHidden = true
        
        return view
    }()
    
    private let step4: ConnectionStatusView = {
        let view = ConnectionStatusView(frame: CGRect(width: 359, height: 24))
        
        view.configure(title: "Requesting server capabilities"
                        .localizeString(id: "dialog_jingle_message__status_requesting_capabilities", arguments: []))
        view.isHidden = true
        
        return view
    }()
    
    public var isModal: Bool = false
    
    public var metadata: [String: String] = [:]
    
    public var loginFieldValueObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    public var passwordFieldValueObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    public var loginFieldValue: String = ""
    public var passwordFieldValue: String = ""
    
    public var shouldShowSignUp: Bool = false
    
    private var host: String? = nil
    
    private var accountStateBag: DisposeBag = DisposeBag()
    
    private var connectionStep: ConnectionStep = .step1
    
    private var shouldDeleteAccount: Bool = true
    
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
            self.button.isEnabled = true
            self.button.backgroundColor = .systemBlue
            self.button.setTitleColor(.white, for: .normal)
        }
    }
    
    public final func makeButtonDisabled(_ animated: Bool) {
        doAnimationsBlock(animated: animated) {
            self.button.isEnabled = false
            self.button.backgroundColor = MDCPalette.grey.tint100
            self.button.setTitleColor(UIColor.black.withAlphaComponent(0.23), for: .disabled)
        }
    }
    
    public func setupPlaceholder(_ string: String, isPassword: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (isPassword ? self.passwordField : self.loginField).attributedPlaceholder = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key.font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            NSAttributedString.Key.foregroundColor: UIColor.black.withAlphaComponent(0.23),
            NSAttributedString.Key.paragraphStyle: paragraph
        ])
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(container)
        var offset: CGFloat = 0
        if #available(iOS 11.0, *) {
            if let topOffset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
                offset += topOffset
            }
        }
        let displayHeigth = UIScreen.main.bounds.height
        container.fillSuperviewWithOffset(top: view.safeAreaInsets.top + displayHeigth * 0.1 + offset, bottom: 0, left: 24, right: 24)
        container.addArrangedSubview(stack)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(loginField)
        stack.addArrangedSubview(passwordField)
        stack.addArrangedSubview(subtitleButton)
        stack.addArrangedSubview(button)
        stack.addArrangedSubview(statusStack)
        stack.addArrangedSubview(UIStackView())
        statusStack.addArrangedSubview(step1)
        statusStack.addArrangedSubview(step2)
        statusStack.addArrangedSubview(step3)
        statusStack.addArrangedSubview(step4)
    }
    
    override func activateConstraints() {
        super.activateConstraints()
        let constraints: [NSLayoutConstraint] = [
            stack.widthAnchor.constraint(equalToConstant: 375),
            statusStack.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 0),
            statusStack.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: 0),
            loginField.heightAnchor.constraint(equalToConstant: 44),
            loginField.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 0),
            loginField.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: 0),
            passwordField.heightAnchor.constraint(equalToConstant: 44),
            passwordField.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 0),
            passwordField.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: 0),
            button.heightAnchor.constraint(equalToConstant: 44),
            button.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 0),
            button.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: 0),
            subtitleButton.heightAnchor.constraint(equalToConstant: 54)//,
//            subtitleLabel.widthAnchor.constraint(equalToConstant: 268)
        ]
        NSLayoutConstraint.activate(constraints)
        stack.setCustomSpacing(36, after: titleLabel)
        stack.setCustomSpacing(36, after: button)
        NSLayoutConstraint
            .activate(
                [step1, step2, step3, step4]
                    .compactMap { $0.makeConstraints(for: statusStack) }
                    .reduce([], +)
            )
    }
    
    @objc
    override func close(_ sender: AnyObject) {
        AccountManager.shared.deleteAccount(by: self.loginFieldValue)
        self.unsubscribe()
        self.dismiss(animated: true, completion: nil)
    }
    
    override func configure() {
        super.configure()
        if isModal {
            self.navigationItem.setLeftBarButton(UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close)), animated: true)
            if #available(iOS 13.0, *) {
                isModalInPresentation = true
            } else {
                // Fallback on earlier versions
            }
        }
        self.navigationController?.isNavigationBarHidden = false
        self.navigationController?.navigationBar.prefersLargeTitles = false
        self.navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        self.navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.navigationBar.setNeedsLayout()
        self.makeButtonDisabled(false)
        self.loginField.becomeFirstResponder()
        self.button.addTarget(self, action: #selector(self.onButtonTouchUpSelector), for: .touchUpInside)
        self.subtitleButton.addTarget(self, action: #selector(self.onSubtitleTouchUp), for: .touchUpInside)
        self.loginField.delegate = self
        self.passwordField.delegate = self
        self.loginField.addTarget(self, action: #selector(onLoginFieldDidChangeSelector), for: .editingChanged)
        self.passwordField.addTarget(self, action: #selector(onPasswordFieldDidChangeSelection), for: .editingChanged)
//        XabberAPIManager.shared.getAvailableHosts { hosts in
//            self.host = hosts.first
//        }
        self.host = CommonConfigManager.shared.get().allowed_hosts.first!
        
    }
    
    @objc
    private final func onSubtitleTouchUp(_ sender: UIButton) {
        if self.loginFieldValue.isNotEmpty {
            AccountManager.shared.deleteAccount(by: self.loginFieldValue)
        }
        XMPPRegistrationManager.shared.delegate = self
        self.shouldShowSignUp = true
        do {
            try XMPPRegistrationManager.shared.start(host: XMPPRegistrationManager.getDefaultHost())
        } catch {
            print(error.localizedDescription)
        }
        
        
    }
    
    private final func subscribeOnNewAccountState() {
        self.accountStateBag = DisposeBag()
        DispatchQueue.main.async {
            [self.step1, self.step2, self.step3, self.step4].forEach { $0.reset() }
        }
        self.connectionStep = .step1
        AccountManager
            .shared
            .newAccountObservable
            .subscribe { observer in
                DispatchQueue.main.async {
                    if observer.jid == self.loginFieldValue {
                        switch observer.state {
                        case .none:
                            self.step2.isHidden = false
                            self.connectionStep = .step1
                            break
                        case  .startConnection:
                            self.step1.setChecked(true)
                            self.step2.isHidden = false
                            self.connectionStep = .step2
                            break
                        case .connect:
                            self.step2.setChecked(true)
                            self.step3.isHidden = false
                            self.connectionStep = .step3
                            break
                        case .auth:
                            self.step3.setChecked(true)
                            self.step4.isHidden = false
                            self.connectionStep = .step4
                            break
                        case .capsReceived(let value):
                            self.step4.setChecked(true)
                            self.accountStateBag = DisposeBag()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                self.title = " "
                                if ApplicationStateManager.shared.isSubscribtionsShowed {
                                   return
                                }
                                if CommonConfigManager.shared.config.locked_host.isNotEmpty {
                                    let subscribtion = SubscribtionsManager.shared.subscribtionEnd
                                    if subscribtion != nil {
                                        let vc = PasscodeViewController(isOnboarding: true)
                                        self.navigationController?.pushViewController(vc, animated: true)
                                    } else {
                                        let vc = SignUpEnableNotificationsViewController()
                                        self.navigationController?.pushViewController(vc, animated: true)
                                    }
                                } else {
                                    let vc = SignInServerFeaturesViewController()
                                    vc.features = value
                                    vc.host = self.host
                                    vc.jid = self.loginFieldValue
                                    vc.isModal = self.isModal
                                    self.navigationController?.setViewControllers([vc], animated: true)
                                }
                            }
                            break
                        case .dataLoaded:
                            break
                        case .streamError(_):
                            self.accountStateBag = DisposeBag()
                            self.unsubscribe()
                            ApplicationStateManager.shared.checkApplicationBlockedState(for: self.loginFieldValue)
                            
                        case .failure(let error):
                            AccountManager.shared.find(for: self.loginFieldValue)?.disconnect(hard: true)
                            if self.shouldDeleteAccount {
                                AccountManager.shared.deleteAccount(by: self.loginFieldValue)
                                self.loginField.isEnabled = true
                                self.passwordField.isEnabled = true
                                self.makeButtonDisabled(true)
                                let localizedError: String = error
                                    .replacingOccurrences(of: "-", with: " ")
                                    .replacingOccurrences(of: "_", with: " ")
                                UIView.performWithoutAnimation {
                                    self.subtitleButton.setTitleColor(.systemRed, for: .disabled)
                                    self.subtitleButton.setAttributedTitle(NSAttributedString(string: localizedError, attributes: [.foregroundColor: UIColor.systemRed]), for: .disabled)
                                    self.subtitleButton.isEnabled = false
                                }
                                switch self.connectionStep {
                                case .step1, .step2:
                                    self.step1.setChecked(true)
                                    self.step2.setError(true, text: nil)
                                    [self.step3, self.step4].forEach { $0.reset() }
                                    break
                                case .step3:
                                    [self.step1, self.step2].forEach { $0.setChecked(true) }
                                    self.step3.setError(true, text: nil)
                                    self.step4.reset()
                                    break
                                case .step4:
                                    self.step4.setError(true, text: nil)
                                    [self.step2, self.step3, self.step4].forEach { $0.reset() }
                                    break
                                }
                                self.accountStateBag = DisposeBag()
                            } else {
                                AccountManager.shared.disable(jid: self.loginFieldValue)
                            }
                            break
                        }
                    } else {
                        self.accountStateBag = DisposeBag()
                    }
                }
            } onError: { error in
                DDLogDebug("SignInCreditionalsViewController: \(#function). \(error.localizedDescription)")
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: accountStateBag)

    }
    
    override func subscribe() {
        super.subscribe()

        loginFieldValueObserver
            .asObservable()
            .debounce(.milliseconds(400), scheduler: MainScheduler.asyncInstance)
            .subscribe { value in
                self.validateTextField(value: value) { result in
                    DispatchQueue.main.async {
                        if !self.subtitleButton.isEnabled {
                            self.subtitleButton.isEnabled = true
                            self.subtitleButton.setTitleColor(UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6), for: .normal)
                            [self.step1, self.step2, self.step3, self.step4].forEach { $0.reset() }
                        }
                        if result {
                            self.makeButtonEnabled(true)
                        } else {
                            self.makeButtonDisabled(true)
                        }
                    }
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: bag)
        
        passwordFieldValueObserver
            .asObservable()
            .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
            .subscribe { value in
                self.validateTextField(value: value) { result in
                    DispatchQueue.main.async {
                        if !self.subtitleButton.isEnabled {
                            self.subtitleButton.isEnabled = true
                            self.subtitleButton.setTitleColor(UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.6), for: .normal)
                            [self.step1, self.step2, self.step3, self.step4].forEach { $0.reset() }
                        }
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
    
    override func unsubscribe() {
        super.unsubscribe()
    }
    
    override func localizeResources() {
        super.localizeResources()
        titleLabel.text = "Hi! Connect to your existing account"
            .localizeString(id: "dialog_jingle_message__message_connect", arguments: [])
        setupPlaceholder("john.doe", isPassword: false)
        setupPlaceholder("password".localizeString(id: "dialog_jingle_message__password", arguments: []), isPassword: true)
        //Subtitle should be HTML to be attributed properly
        let subtitle = "If you don't have an account yet, press here to sign up for a Xabber account."
            .localizeHTML(id: "dialog_jingle_message__message_sign_up", arguments: [])
//            .localizeString(id: "dialog_jingle_message__message_sign_up", arguments: [])
        
//        let subtitleData = Data(subtitle.utf8)
//        if let attributedSubtitle = try? NSAttributedString(data: subtitleData,
//                                                          options: [.documentType: NSAttributedString.DocumentType.html],
//                                                          documentAttributes: nil) {
//            subtitleButton.setAttributedTitle(attributedSubtitle, for: .normal)
//        }
        
//        let attrSubtitle = NSMutableAttributedString(string: subtitle)
//        attrSubtitle.addAttributes([.foregroundColor: UIColor.systemBlue.cgColor], range: NSRange(location: 34, length: 10))
        
        subtitleButton.setAttributedTitle(subtitle, for: .normal)
//        subtitleLabel.attributedText = attrSubtitle
        
        button.setTitle("Connect".localizeString(id: "dialog_jingle_message__connect",
                                                 arguments: []), for: .normal)
        button.setTitle("Connect".localizeString(id: "dialog_jingle_message__connect",
                                                 arguments: []), for: .disabled)
//        subtitleLabel.sizeToFit()
    }
    
    override func onAppear() {
        super.onAppear()
        title = "Sign In".localizeString(id: "title_login_xabber_account", arguments: [])
    }
    
    func validateTextField(value: String?, callback: @escaping ((Bool) -> Void)) {
        guard let jid = loginField.text,
              jid.isNotEmpty,
              let password = passwordField.text,
              password.isNotEmpty else {
            callback(false)
            return
        }
        if jid.contains("@") {
            guard let formatJid = XMPPJID(string: jid),
                  let localpart = formatJid.user,
                  localpart.isNotEmpty else {
                callback(false)
                return
            }
            self.loginFieldValue = formatJid.bare
            callback(true)
        } else {
            guard let host = self.host,
                  let formatJid = XMPPJID(user: jid, domain: host, resource: nil),
                  let localpart = formatJid.user,
                  localpart.isNotEmpty else {
                callback(false)
                return
            }
            self.loginFieldValue = formatJid.bare
            callback(true)
        }
    }
    
    func onButtonTouchUp() {
        FeedbackManager.shared.tap()
        makeButtonDisabled(true)
        guard loginFieldValue.isNotEmpty,
              passwordFieldValue.isNotEmpty else {
            return
        }
        self.loginField.isEnabled = false
        self.passwordField.isEnabled = false
        self.subtitleButton.setAttributedTitle(nil, for: .disabled)
        self.subtitleButton.isEnabled = false
        AccountManager
            .shared
            .create(
                jid: loginFieldValue,
                password: passwordFieldValue,
                nickname: nil,
                isFromRegister: false
            )
        subscribeOnNewAccountState()
        self.view.endEditing(true)
    }
    
    @objc
    private final func onButtonTouchUpSelector(_ sender: UIButton) {
        self.onButtonTouchUp()
        
    }
    
    @objc
    public func onLoginFieldDidChangeSelector(_ sender: UITextField) {
        sender.text = sender.text?.lowercased().replacingOccurrences(of: " ", with: ".")
        self.loginFieldValueObserver.accept(sender.text)
    }
    
    @objc
    public func onPasswordFieldDidChangeSelection(_ sender: UITextField) {
        self.passwordFieldValueObserver.accept(sender.text)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if self.connectionStep != .step4 {
            AccountManager.shared.deleteAccount(by: self.loginFieldValue)
        }
    }
}

extension SignInCreditionalsViewController: UITextFieldDelegate {
    
    
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
        print(#function)
        switch textField.restorationIdentifier {
        case "LoginFieldRID":
            passwordField.becomeFirstResponder()
            break
        default:
            textField.resignFirstResponder()
            break
        }
        return true
    }
}


extension SignInCreditionalsViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        print(#function)
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        print(#function)
        return true
    }
}

extension SignInCreditionalsViewController: XMPPRegistrationManagerDelegate {
    func xmppRegistrationManagerCheckUsername(available: Bool) {
        
    }
    
    func xmppRegistrationManagerSuccess() {
        
    }
    
    func xmppRegistrationManagerFail(error: String) {
        
    }
    
    func xmppRegistrationManagerReady() {
        DispatchQueue.main.async {
            if self.shouldShowSignUp {
                let vc = SignUpSelectNicknameViewController()
                vc.metadata = ["host": XMPPRegistrationManager.getDefaultHost()]
                let rootVc = OnboardingViewController()
                rootVc.title = " "
                if self.isModal {
                    self.navigationController?.setViewControllers([vc], animated: true)
                } else {
                    self.navigationController?.setViewControllers([rootVc, vc], animated: true)
                }
                XMPPRegistrationManager.shared.delegate = nil
            }
        }
    }
}
