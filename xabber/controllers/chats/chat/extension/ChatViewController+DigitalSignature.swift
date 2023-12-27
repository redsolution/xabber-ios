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
import CocoaLumberjack
import YubiKit

protocol TimeSignatureBlockingPanelDelegate {
    func onSignButtonTouchUpInside()
}

extension ChatViewController {
    class TimeSignatureBlockingPanel: UIView {
        
        var delegate: TimeSignatureBlockingPanelDelegate? = nil
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .top
            stack.spacing = 12
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, left: 0, bottom: 0, right: 8)
            
            return stack
        }()
        
        let signButton: UIButton = {
            let button = UIButton()

            button.setTitle("Update signature", for: .normal)
            button.setTitleColor(.systemBlue, for: .normal)
            button.tintColor = MDCPalette.grey.tint500
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, bottom: 10, left: 10, right: 10)
            
            return button
        }()
        
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
        
        internal var buttonConstraints: [NSLayoutConstraint] = []
        
        internal func setup() {
            self.backgroundColor = .inputBarGray
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(signButton)
            signButton.addTarget(self, action: #selector(onSignButtonPress), for: .touchUpInside)
            buttonConstraints = []
            buttonConstraints.append(contentsOf:[
                signButton.leftAnchor.constraint(equalTo: stack.leftAnchor),
                signButton.rightAnchor.constraint(equalTo: stack.rightAnchor),
                signButton.heightAnchor.constraint(equalToConstant: 44)
            ])
        }
        
        @objc
        internal func onSignButtonPress(_ sender: UIButton) {
            delegate?.onSignButtonTouchUpInside()
        }
        
        
        open func show() {
            NSLayoutConstraint.activate(buttonConstraints)
        }
        
        open func hide() {
            NSLayoutConstraint.deactivate(buttonConstraints)
        }
    }
    
    internal func startWatchingSignatureTimer() {
//        if CommonConfigManager.shared.config.required_time_signature_for_messages {
        self.watchSignatureTimer?.fire()
        self.watchSignatureTimer?.invalidate()
        self.watchSignatureTimer = nil
        self.watchSignatureTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(watchIfSignatureInvalidated),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(self.watchSignatureTimer!, forMode: .default)
        self.watchSignatureTimer?.fire()
//        }
    }
    
    @objc
    internal func watchIfSignatureInvalidated(_ sender: AnyObject?) {
        if !CommonConfigManager.shared.config.required_time_signature_for_messages {
            return
        }
        if SignatureManager.shared.certificate == nil {
            return
        }
        if !SignatureManager.shared.isSignatureValid() {
            self.blockInputFieldByTimeSignature.accept(true)
        }
    }
    
    internal func onUpdateTimeSignatureBlockState(_ isBlocked: Bool) {
        if isBlocked {
            if !isTimeSignatureBlockingPanelopen {
                self.showTimeSignatureBlockingPanel()
            }
        } else {
            if isTimeSignatureBlockingPanelopen {
                self.hideTimeSignatureBlockingPanel()
            }
        }
    }
    
    private func showTimeSignatureBlockingPanel() {
        self.isTimeSignatureBlockingPanelopen = true
        self.xabberInputView.changeState(to: .updateSignature)
    }
    
    private func hideTimeSignatureBlockingPanel() {
//        if !self.isTrustedDevicesBlockingPanelopen {
            self.isTimeSignatureBlockingPanelopen = false
            self.isTrustedDevicesBlockingPanelopen = false
            do {
                let realm = try WRealm.safe()
                let myUntrustedDevicesCollection = realm
                    .objects(SignalDeviceStorageItem.self)
                    .filter("owner == %@ AND jid == %@ AND state_ != %@", self.owner, self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue)
                
                let theirUntrustDevicesCollection = realm
                    .objects(SignalDeviceStorageItem.self)
                    .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                
                if theirUntrustDevicesCollection.isEmpty {
                    self.onUpdateTrustedDevicesBlockState(true, identityVerification: myUntrustedDevicesCollection.isEmpty)
                } else {
                    self.onUpdateTrustedDevicesBlockState(!myUntrustedDevicesCollection.isEmpty, identityVerification: false)
                }
                    
                self.titleLabel.attributedText = self.updateTitle()
                self.titleLabel.sizeToFit()
                self.titleLabel.layoutIfNeeded()
                
            } catch {
                
            }
            
//            self.xabberInputView.changeState(to: .normal)
//            self.isTrustedDevicesBlockingPanelopen = false
//        }
    }
    
    internal func configureCertificateUpdateTimer() {
        if CommonConfigManager.shared.config.required_time_signature_for_messages {
            self.certificateUpdateTimer = Timer.scheduledTimer(
                timeInterval: 1,
                target: self,
                selector: #selector(self.onCertificateUpdateTimerFire),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(self.certificateUpdateTimer!, forMode: .default)
            self.certificateUpdateTimer?.fire()
        }
    }
    
    @objc
    private final func onCertificateUpdateTimerFire(_ sender: AnyObject) {
        
    }
}


extension ChatViewController: TimeSignatureBlockingPanelDelegate {
    
    func onSignButtonTouchUpInside() {
        SignatureManager.shared.delegate = self
        FeedbackManager.shared.tap()
        if #available(iOS 13.0, *) {
            if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
                YubiKitExternalLocalization.nfcScanAlertMessage = "Generate digital signature for message"
                YubiKitManager.shared.startNFCConnection()
                YubiKitManager.shared.delegate = SignatureManager.shared
                SignatureManager.shared.currentAction = .signature
            }
        }
    }
}

extension ChatViewController: SignatureManagerDelegate {
    func didConnectionStop(with error: Error?) {
        
    }
    
    func didGenerateDigitalSignature(with error: Error?) {
        self.blockInputFieldByTimeSignature.accept(false)
    }
    
    func retrieveCertificate(with error: Error?) {
        
    }
    
    func retrieveYubikeyInfo(with error: Error?) {
        
    }
    
    
}
