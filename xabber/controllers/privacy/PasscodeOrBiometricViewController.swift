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
import LocalAuthentication
import Toast_Swift
import RxCocoa
import RxSwift
import CocoaLumberjack
import SwiftUI
import XMPPFramework


class PasscodeOrBiometricViewController: SimpleBaseViewController {
    
    class KeyboardButton: UIButton {
        var keyId: Int
        
        init(for keyId: Int, frame: CGRect) {
            self.keyId = keyId
            super.init(frame: frame)
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
    
    internal var pin: BehaviorRelay<String> = BehaviorRelay<String>(value: "")
    internal let padding: CGFloat = 24
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        
        label.text = "Enter passcode"
        label.font = UIFont.systemFont(ofSize: 23, weight: .regular)
        label.textColor = .black
        label.textAlignment = .center
        
        return label
    }()
    
    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = ""
        label.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        label.textColor = UIColor(red: 60/255, green: 60/255, blue: 65/255, alpha: 0.7)
        label.textAlignment = .center
        
        return label
    }()
    
    private var dots: [UIView] = {
        return (0..<6).compactMap {
            (index) -> UIView in
            let view = UIView(frame: CGRect(square: 24))
            
            view.backgroundColor = UIColor.white//.withAlphaComponent(0.8)
            view.layer.cornerRadius = 12
            view.alpha = 0.6
            
            return view
        }
    }()
    
    private var dotsView: UIView = {
        let view = UIView()
        
        view.backgroundColor = .clear
        
        return view
    }()
    
    private lazy var keyboardButtons: [KeyboardButton] = {
        let biometricsSuport = SettingManager.shared.getKeyBool(for: "", scope: .security, key: "support_touch_id") ?? false
        return (1...12).compactMap {
            (index) -> KeyboardButton in
            let button = KeyboardButton(for: index == 11 ? 0 : index, frame: CGRect(square: 80))
            let title = index == 11 ? "0" : "\(index)"
            if index == 10 {
                if biometricsSuport {
                    button.setImage(imageLiteral("touchid"), for: .normal)
                    button.tintColor = .black.withAlphaComponent(0.4)
                    button.backgroundColor = .clear
                } else {
                    button.backgroundColor = .clear
                    button.isEnabled = false
                }
            } else if index == 12 {
                button.setImage(imageLiteral( "delete.left.fill"), for: .normal)
                button.tintColor = .black.withAlphaComponent(0.4)
                button.backgroundColor = .clear
            } else {
                button.setTitle(title, for: .normal)
                button.backgroundColor = UIColor.black.withAlphaComponent(0.17)
            }
            
            
            button.layer.cornerRadius = 40
            button.titleLabel?.font = UIFont.systemFont(ofSize: 24, weight: .semibold)
            button.setTitleColor(.white, for: .normal)
            
            return button
        }
    }()
    
    private let keyboardView: UIView = {
        let view = UIView()
        
        view.backgroundColor = .clear
        
        return view
    }()
    //let biometricsSuport = SettingManager.shared.getKeyBool(for: "", scope: .security, key: "support_touch_id") ?? false
//    private let touchIdButton : UIButton = {
//        let button = UIButton()
//
//        button.setTitle("Touch Id".uppercased(), for: .normal)
//        button.backgroundColor = UIColor.black.withAlphaComponent(0.17)
//        button.setTitleColor(.white, for: .normal)
//
//        button.layer.cornerRadius = 27
//        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
//
//        return button
//    }()
    
    var attempts: Int = 0
    var fakeAttempts: Int = 0
    var showAttempts: Bool = false
    var isUnlimitedAttempts: Bool = false
    
    override func setupSubviews() {
        super.setupSubviews()
        keyboardView.frame = CGRect(width: 240 + (padding * 4), height: 460 + (padding * 3))
        keyboardView.center = self.view.center
        
        var x: CGFloat = padding
        var y: CGFloat = 40
        keyboardButtons.enumerated().forEach {
            (offset, item) in
            
            if offset % 3 == 0 {
                y += 80 + padding
                x = padding
            } else {
                x += 80 + padding
            }
            
            item.frame = CGRect(
                x: x,
                y: y,
                width: 80,
                height: 80
            )
            
            keyboardView.addSubview(item)
            if offset == 9 {
                item.addTarget(self, action: #selector(self.onTouchIdButtonTouchUpInside), for: .touchDown)
            } else if offset == 11 {
                item.addTarget(self, action: #selector(self.onBackspaceButtonTouchUpInside), for: .touchDown)
            } else {
                item.addTarget(self, action: #selector(self.onKeyboardButtonTouchUpInside), for: .touchDown)
            }
            
        }
        
        dotsView.frame = CGRect(
            x: 0,
            y: 48,
            width: keyboardView.frame.width,
            height: 80
        )
        
        keyboardView.addSubview(dotsView)
        titleLabel.frame = CGRect(
            x: 0,
            y: keyboardView.frame.minY,
            width: view.frame.width,
            height: 24
        )
        
        subtitleLabel.frame = CGRect(x: 0,
                                     y: keyboardView.frame.minY + 28,
                                     width: view.frame.width,
                                     height: 24)
        keyboardView.addSubview(titleLabel)
        keyboardView.addSubview(subtitleLabel)
        
        x = padding + 12 + 4
        dots.enumerated().forEach {
            (offset, item) in
            item.frame = CGRect(
                x: x,
                y: 20,
                width: 24,
                height: 24
            )
            x += 24 + padding - 4
            dotsView.addSubview(item)
        }
        
        self.view.backgroundColor = .clear
        let blurEffect = UIBlurEffect(style: UIBlurEffect.Style.regular)
        let vibrancyEffect = UIVibrancyEffect(blurEffect: blurEffect)
        let blurEffectView = UIVisualEffectView(effect: blurEffect)
        let vibrancyView = UIVisualEffectView(effect: vibrancyEffect)
        blurEffectView.frame = view.bounds
        vibrancyView.frame = view.bounds
        blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vibrancyView.translatesAutoresizingMaskIntoConstraints = false
        blurEffectView.contentView.addSubview(vibrancyView)
        vibrancyView.contentView.addSubview(keyboardView)
        view.addSubview(blurEffectView)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
    }
    
    override func activateConstraints() {
        super.activateConstraints()
    }
    
    override func subscribe() {
        super.subscribe()
        if !(self.isUnlimitedAttempts) {
            AccountManager.shared.authenticatedUsers.asObservable().debounce(.milliseconds(250),
                                                                          scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                DispatchQueue.main.async {
                    self.updateSubtitle()
                    self.updateKeyboardView()
                }
            })
            .disposed(by: bag)
        }
        
        self.pin
            .asObservable()
            .subscribe { value in
            if value.count == self.dots.count {
                self.dots.last?.backgroundColor = UIColor.black
                
                guard self.canEnterPasscode() else {
                    return
                }
                
                if self.validatePasscode(value) {
                    self.attempts = self.getSettingsPasscodeAttempts()
                    self.setPasscodeAttemptsLeft(self.attempts)
//                    DispatchQueue.main.async {
//                        FeedbackManager.shared.errorFeedback()
                        self.onPasscodeValid(value)
//                    }
                } else {
                    if !(self.isUnlimitedAttempts) {
                        if self.attempts > 1 {
                            self.decrementAttemptsLeft()
                        } else {
                            if !CommonConfigManager.shared.config.supports_multiaccounts {
                                guard let account = AccountManager.shared.users.first else {
                                    return
                                }
//                                FeedbackManager.shared.errorFeedback()
                                self.sendAlarmAndQuit(jid: account.jid)
                            }
                            return
                        }
                        self.updateSubtitle()
                    }
                    
//                    FeedbackManager.shared.errorFeedback()
                    let oldFrame = self.dotsView.frame
                    UIView.animate(withDuration: 0.18) {
                        self.dots.enumerated().forEach {
                            (offset, item) in
                            if offset < value.count {
                                item.backgroundColor = UIColor.black//.withAlphaComponent(0.27)
                            } else {
                                item.backgroundColor = UIColor.white//.withAlphaComponent(0.8)
                            }
                        }
                    }
                    UIView.animate(
                        withDuration: 0.18,
                        delay: 0.18,
                        options: []) {
                            self.dots.forEach{
                                item in
                                item.backgroundColor = UIColor.white
                            }
                        } completion: { _ in
                            UIView.animate(
                                withDuration: 0.08,
                                delay: 0.0,
                                options: [.curveEaseInOut]) {
                                    let newFrame = CGRect(
                                        origin: CGPoint(
                                            x: oldFrame.origin.x - 12,
                                            y: oldFrame.origin.y
                                        ),
                                        size: oldFrame.size
                                    )
                                    self.dotsView.frame = newFrame
                                } completion: { _ in
                                    UIView.animate(
                                        withDuration: 0.08,
                                        delay: 0.0,
                                        options: [.curveEaseInOut]) {
                                            self.dotsView.frame = oldFrame
                                        } completion: { _ in
                                            self.pin.accept("")
                                        }
                                }
                        }
                    
                    
                }
            } else if value.count < self.dots.count {
                UIView.animate(withDuration: 0.18) {
                    self.dots.enumerated().forEach {
                        (offset, item) in
                        if offset < value.count {
                            item.backgroundColor = UIColor.black//.withAlphaComponent(0.27)
                        } else {
                            item.backgroundColor = UIColor.white//.withAlphaComponent(0.8)
                        }
                    }
                }
            }
            
        } onError: { error in
            
        } onCompleted: {
            
        } onDisposed: {
            
        }.disposed(by: bag)
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.isUnlimitedAttempts = getSettingsPasscodeAttempts() == 0 ? true : false
        self.fakeAttempts = getSettingsFakeAttempts()
        self.showAttempts = getSettingsShowAttempts()
        updateSubtitle()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        FeedbackManager.shared.tap()
    }
    
    private final func canEnterPasscode() -> Bool {
        guard AccountManager.shared.authenticatedUsers.value.isEmpty || self.isUnlimitedAttempts else {
            return false
        }
        return true
    }
    
    private final func updateKeyboardView() {
        if self.canEnterPasscode() {
            self.keyboardView.alpha = 1.0
        } else {
            self.keyboardView.alpha = 0.3
        }
    }
    
    private final func updateSubtitle() {
        if self.isUnlimitedAttempts {
            self.subtitleLabel.text = ""
        } else {
            self.attempts = getPasscodeAttemptsLeft()
            if AccountManager.shared.authenticatedUsers.value.isNotEmpty {
                self.subtitleLabel.text = "Connecting...".localizeString(id: "account_state_connecting", arguments: [])
                self.keyboardButtons[9].isEnabled = false
            } else {
                self.subtitleLabel.text = self.showAttempts ? "\(self.attempts + self.fakeAttempts) attempts left" : ""
                self.keyboardButtons[9].isEnabled = true
            }
        }
    }
    
    @objc
    internal func onButtonTouchUpInside(_ sender: UIButton) {
        FeedbackManager.shared.tap()
        
    }
    
    @objc
    internal func onKeyboardButtonTouchUpInside(_ sender: KeyboardButton) {
        guard self.pin.value.count < 6 else {
            return
        }
        guard self.canEnterPasscode() else {
            FeedbackManager.shared.generate(feedback: .success)
            return
        }
        if self.pin.value.count < 5 {
            FeedbackManager.shared.generate(feedback: .success)
        }
        self.pin.accept("\(self.pin.value)\(sender.keyId)")
    }
    
    @objc
    internal func onBackspaceButtonTouchUpInside(_ sender: KeyboardButton) {
        FeedbackManager.shared.tap()
        var newVal = self.pin.value
        if newVal.count == 0 { return }
        newVal.removeLast()
        self.pin.accept(newVal)
    }
    
    
    @objc
    internal func onTouchIdButtonTouchUpInside(_ sender: KeyboardButton) {
        if (SettingManager.shared.getKeyBool(for: "", scope: .security, key: "support_touch_id") ?? false) {
            FeedbackManager.shared.tap()
            let context = LAContext()
            context.localizedCancelTitle = "Enter passcode"
            let reason = "Unlock \(CommonConfigManager.shared.config.app_name)"
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason ) { success, error in
                if success {
                    defer {
                        ApplicationStateManager.shared.isPincodeShowed = false
                    }
                    CredentialsManager.shared.updateOnlyPincodeTimestamp()
                    DispatchQueue.main.async {
                        self.navigationController?.dismiss(animated: true, completion: nil)
                        self.blurViewFadeOut()
                    }
                }
            }
        } else {
            FeedbackManager.shared.errorFeedback()
            self.view.makeToast("Touch Id not supported")
        }
    }
    
    private final func validatePasscode(_ value: String) -> Bool {
        return CredentialsManager.shared.validatePincode(value)
    }
    
    private final func getSettingsPasscodeAttempts() -> Int {
        return SettingManager.shared.getInt(for: "", scope: .security, key: SettingsViewController.Datasource.Keys.passcodeAttempts.rawValue)
    }
    
    private final func getSettingsFakeAttempts() -> Int  {
        return SettingManager.shared.getInt(for: "", scope: .security, key: SettingsViewController.Datasource.Keys.displayedAttempts.rawValue)
    }
    
    private final func getSettingsShowAttempts() -> Bool {
        return SettingManager.shared.get(bool: SettingsViewController.Datasource.Keys.showAttempts.rawValue)
    }
    
    private final func getPasscodeAttemptsLeft() -> Int {
        return CredentialsManager.shared.getPasscodeAttemptsLeft()
    }
    
    private final func setPasscodeAttemptsLeft(_ value: Int) {
        CredentialsManager.shared.setPasscodeAttemptsLeft(value)
    }
    
    private final func decrementAttemptsLeft() {
        self.attempts -= 1
        setPasscodeAttemptsLeft(self.attempts)
    }
    
    private final func onPasscodeValid(_ value: String) {
        if CredentialsManager.shared.updatePincode(value) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                defer { ApplicationStateManager.shared.isPincodeShowed = false }
                self.navigationController?.dismiss(animated: true, completion: nil)
                self.blurViewFadeOut()
            }
        } else {
            self.view.makeToast("Internal error")
        }
    }
    
    private final func blurViewFadeOut() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
              let blurEffectView = appDelegate.blurEffectView else {
            return
        }
        UIView.animate(withDuration: 0.5, delay: 0, options: .curveLinear, animations: {
            blurEffectView.layer.opacity = 0
        }, completion: { _ in
            blurEffectView.removeFromSuperview()
            appDelegate.blurEffectView = nil
        })
    }
    
    private final func sendAlarmAndQuit(jid: String) {
        
        do {
            let realm = try WRealm.safe()
    
            guard let account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid),
                  let tokenInstance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [account.deviceUuid, jid].prp()) else {
                return
            }
            
            let deviceName = tokenInstance.device
            let ip = tokenInstance.ip
            let messageText =  "Token of device \(deviceName) (\(ip)) was revoked because too many unlock attempts. User data deleted."
                .localizeString(id: "too_many_unlock_attempts", arguments: [deviceName, ip])
            let elementId = UUID().uuidString
            let messageStanza = XMPPMessage(messageType: .chat, to: XMPPJID(string: jid), elementID: elementId, child: nil)
        
            messageStanza.addOriginId(elementId)
            messageStanza.addBody(messageText)
            messageStanza.addAttribute(withName: "from", stringValue: jid)
        
            AccountManager.shared.find(for: jid)?.unsafeAction({ (user, stream) in
                stream.send(messageStanza)
                self.unsubscribe()
                AccountManager.shared.deleteAccount(by: jid, hard: false)
                
                DispatchQueue.main.async {
                    let vc = OnboardingViewController()
                    let navigationController = UINavigationController(rootViewController: vc)
                    navigationController.isNavigationBarHidden = true
                    (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = navigationController
                    
                    let alert = UIAlertController(title: nil, message: messageText, preferredStyle: .alert)
                    let action = UIAlertAction(title: "OK", style: .default)
                    alert.addAction(action)
                    vc.present(alert, animated: true, completion: nil)
                }
            })
        } catch {
        DDLogDebug("PasscodeOrBiometricViewController: \(#function). \(error.localizedDescription)")
        }
    }
}
