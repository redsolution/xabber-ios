//
//  YubikeySetupViewController.swift
//  clandestino
//
//  Created by Игорь Болдин on 13.05.2022.
//  Copyright © 2022 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import YubiKit
import Toast_Swift

class YubikeySetupViewController: SignUpBaseViewController {
    open var isFromOnboarding: Bool = true
    
    
    @objc
    func cancel() {
        self.navigationController?.popViewController(animated: true)
    }
    
    override func configure() {
        self.navigationItem.hidesBackButton = true
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
        let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.setLeftBarButton(cancelButton, animated: true)
        
        textField.isHidden = true
        button.isHidden = false
        navigationController?.isNavigationBarHidden = false
        button.addTarget(self, action: #selector(self.onMFIButtonTouchUpSelector), for: .touchUpInside)
        secondaryButton.addTarget(self, action: #selector(self.onNFCSecondaryButtonTouchUpSelector), for: .touchUpInside)
    }
    
    override func onAppear() {
        super.onAppear()
        SignatureManager.shared.delegate = self
        button.setTitle("Connect dongle", for: .normal)
        
        if #available(iOS 13.0, *) {
            if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
                makeSecondaryButtonEnabled(true)
                secondaryButton.setTitle("Connect with NFC", for: .normal)
            }
        }
        title = "Verify account".localizeString(id: "yubikey_configure_screen_title", arguments: [])
    }
    
    override func localizeResources() {
        super.localizeResources()
        titleLabel.text = "Plug your YubiKey to verify your account".localizeString(id: "yubikey_configure_screen_title_label", arguments: [])
    }
    
    @objc
    private func onMFIButtonTouchUpSelector(_ sender: UIButton) {
        self.onButtonTouchUp()
    }
    
    @objc
    private func onNFCSecondaryButtonTouchUpSelector(_ sender: UIButton) {
        self.onSecondaryButtonTouchUp()
    }
    
    override func onButtonTouchUp() {
        FeedbackManager.shared.tap()
        print(YubiKitDeviceCapabilities.self)
        if #available(iOS 13.0, *) {
            if YubiKitDeviceCapabilities.supportsMFIAccessoryKey {
                YubiKitManager.shared.startAccessoryConnection()
                YubiKitManager.shared.delegate = SignatureManager.shared
                SignatureManager.shared.currentAction = .certificate
            }
        }
    }
    
    override func onSecondaryButtonTouchUp() {
        FeedbackManager.shared.tap()
        if #available(iOS 13.0, *) {
            if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
                YubiKitManager.shared.startNFCConnection()
                YubiKitManager.shared.delegate = SignatureManager.shared
                SignatureManager.shared.currentAction = .certificate
            }
        }
        
    }
    
    private final func goNext() {
        if isFromOnboarding {
            let vc = SignUpEnableNotificationsViewController()
            self.navigationController?.setViewControllers([vc], animated: true)
        } else {
            
            self.navigationController?.popViewController(animated: true)
        }
        
    }
}

extension YubikeySetupViewController: SignatureManagerDelegate {
    func didGenerateDigitalSignature(with error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.view.makeToast("Internal error")
            }
        } else {
            DispatchQueue.main.async {
                self.view.makeToast("Yubikey registered")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.goNext()
        }
    }
    
    func didConnectionStop(with error: Error?) {
        
    }
}

extension YubikeySetupViewController: YKFManagerDelegate {
    func didConnectNFC(_ connection: YKFNFCConnection) {
        print(#function)
    }
    
    func didDisconnectNFC(_ connection: YKFNFCConnection, error: Error?) {
        print(#function)
    }
    
    func didConnectAccessory(_ connection: YKFAccessoryConnection) {
        print(#function)
    }
    
    func didDisconnectAccessory(_ connection: YKFAccessoryConnection, error: Error?) {
        print(#function)
    }
    
    
}
