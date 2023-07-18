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
import YubiKit
import Toast_Swift

class YubikeyApproveViewController: SimpleBaseViewController {
        
    private let button: UIButton = {
        let button = UIButton()
        
        button.setTitle("Tap to unlock".uppercased(), for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.17)
        button.setTitleColor(.white, for: .normal)
        
        button.layer.cornerRadius = 27
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        
        return button
    }()

    override func setupSubviews() {
        super.setupSubviews()
        button.frame = CGRect(width: 164, height: 56)
        button.center = self.view.center
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
        vibrancyView.contentView.addSubview(button)
        view.addSubview(blurEffectView)

    }
    
    override func activateConstraints() {
        super.activateConstraints()
    }
    
    override func configure() {
        button.addTarget(self, action: #selector(onButtonTouchUpInside), for: .touchUpInside)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        FeedbackManager.shared.tap()
        if #available(iOS 13.0, *) {
            if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
                SignatureManager.shared.currentAction = .certificate
                YubiKitManager.shared.startNFCConnection()
                YubiKitManager.shared.delegate = SignatureManager.shared
                SignatureManager.shared.delegate = self
            }
        }
    }
    
    @objc
    internal func onButtonTouchUpInside(_ sender: UIButton) {
        FeedbackManager.shared.tap()
        if let yuType = CredentialsManager.shared.getSignatureDeviceType() {
            switch yuType {
            case .dongle:
                if YubiKitDeviceCapabilities.supportsMFIAccessoryKey {
                    SignatureManager.shared.currentAction = .certificate
                    YubiKitManager.shared.startAccessoryConnection()
                    YubiKitManager.shared.delegate = SignatureManager.shared
                    SignatureManager.shared.delegate = self
                }
            case .nfc:
                if #available(iOS 13.0, *) {
                    if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
                        SignatureManager.shared.currentAction = .certificate
                        YubiKitManager.shared.startNFCConnection()
                        YubiKitManager.shared.delegate = SignatureManager.shared
                        SignatureManager.shared.delegate = self
                    }
                }
            }
        }
    }
    
}

extension YubikeyApproveViewController: SignatureManagerDelegate {
    func didConnectionStop(with error: Error?) {
        SignatureManager.shared.delegate = nil
        DispatchQueue.main.async {
            if let error = error {
                print(error)
                self.view.makeToast("Internal error")
            } else {
                self.navigationController?.dismiss(animated: true, completion: nil)
            }
        }
    }
    
    func didGenerateDigitalSignature(with error: Error?) {
        SignatureManager.shared.delegate = nil
        DispatchQueue.main.async {
            if let error = error {
                print(error)
                self.view.makeToast("Internal error")
            } else {
                self.navigationController?.dismiss(animated: true, completion: nil)
            }
        }
    }
    
    func retrieveCertificate(with error: Error?) {
        
    }
    
    func retrieveYubikeyInfo(with error: Error?) {
        
    }
}
