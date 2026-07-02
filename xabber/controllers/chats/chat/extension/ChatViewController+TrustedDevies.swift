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

protocol TrustedDevicesBlockingPanelDelegate {
    func onCheckButtonTouchUpInside()
}

extension ChatViewController {
    class TrustedDevicesBlockingPanel: UIView {
        
        var delegate: TrustedDevicesBlockingPanelDelegate? = nil
        
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
        
        let checkButton: UIButton = {
            let button = UIButton()

            button.setTitle("Check contact’s devices", for: .normal)
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
            stack.addArrangedSubview(checkButton)
            checkButton.addTarget(self, action: #selector(onCheckButtonPress), for: .touchUpInside)
            buttonConstraints = []
            buttonConstraints.append(contentsOf:[
                checkButton.leftAnchor.constraint(equalTo: stack.leftAnchor),
                checkButton.rightAnchor.constraint(equalTo: stack.rightAnchor),
                checkButton.topAnchor.constraint(equalTo: stack.topAnchor),
                checkButton.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            ])
        }
        
        @objc
        internal func onCheckButtonPress(_ sender: UIButton) {
            delegate?.onCheckButtonTouchUpInside()
        }
        
        
        open func show() {
            NSLayoutConstraint.activate(buttonConstraints)
        }
        
        open func hide() {
            NSLayoutConstraint.deactivate(buttonConstraints)
        }
    }
    
    
    internal func onUpdateTrustedDevicesBlockState(_ isBlocked: Bool, identityVerification: Bool) {
        if isBlocked {
//            if !isTrustedDevicesBlockingPanelopen {
                self.showTrustedDevicesBlockingPanel(state: identityVerification ? .identityVerification : .checkOwnDevices)
//            }
        } else {
//            if isTrustedDevicesBlockingPanelopen {
                self.hideTrustedDevicesBlockingPanel()
//            }
        }
        self.titleLabel.attributedText = self.updateTitle()
        self.titleLabel.sizeToFit()
        self.titleLabel.layoutIfNeeded()
    }

    internal func currentOmemoSendAvailability() -> OmemoSendAvailabilityPolicy.Availability {
        do {
            let realm = try WRealm.safe()
            return OmemoSendAvailabilityPolicy.evaluate(
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType,
                realm: realm
            )
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return self.conversationType.isEncrypted ? .blockedByNoTrustedContactDevices : .canSend
        }
    }

    internal func refreshOmemoSendAvailability() {
        onUpdateOmemoSendAvailability(currentOmemoSendAvailability())
    }

    internal func onUpdateOmemoSendAvailability(_ availability: OmemoSendAvailabilityPolicy.Availability) {
        switch availability {
        case .blockedByOwnUntrustedDevices:
            showTrustedDevicesBlockingPanel(state: .checkOwnDevices)
        case .blockedByNoTrustedContactDevices:
            showTrustedDevicesBlockingPanel(state: .checkContactDevices)
        case .canSend, .canSendWithUntrustedContactDeviceWarning:
            hideTrustedDevicesBlockingPanel()
        }

        do {
            let realm = try WRealm.safe()
            self.applyBaseSendButtonReadiness(
                isSkeletonVisible: self.showSkeletonObserver.value,
                isAccountConnecting: AccountManager.shared.connectingUsers.value.contains(self.owner),
                hasPendingOrFailedMessage: self.pendingOrFailedMessageBlocksSend(in: realm),
                omemoAvailability: availability
            )
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }

        self.titleLabel.attributedText = self.updateTitle()
        self.titleLabel.sizeToFit()
        self.titleLabel.layoutIfNeeded()
    }
    
    private func showTrustedDevicesBlockingPanel(state: ModernXabberInputView.InputBarState) {
//        if UIDevice.needBottomOffset {
//            self.trustedDevicesBlockingPanel.frame = CGRect(x: 0, y: -8, width: self.view.frame.width, height: 84)
//        } else {
//            self.trustedDevicesBlockingPanel.frame = CGRect(width: self.view.frame.width, height: 44)
//        }
//
//        self.xabberInputBar.addSubview(self.trustedDevicesBlockingPanel)
//        self.xabberInputBar.bringSubviewToFront(self.trustedDevicesBlockingPanel)
        if !self.isTimeSignatureBlockingPanelopen {
            self.xabberInputView.changeState(to: state)
            self.draftMessageText.accept(nil)
            self.xabberInputView.setComposerText(nil)
            self.isTrustedDevicesBlockingPanelopen = true
        }
    }
    
    private func hideTrustedDevicesBlockingPanel() {
        if !self.isTimeSignatureBlockingPanelopen {
            if self.xabberInputView.state == .checkDevices ||
                self.xabberInputView.state == .checkOwnDevices ||
                self.xabberInputView.state == .checkContactDevices ||
                self.xabberInputView.state == .identityVerification {
                self.xabberInputView.changeState(to: .normal)
            }
            self.isTrustedDevicesBlockingPanelopen = false
            self.isTimeSignatureBlockingPanelopen = false
        }
//        self.trustedDevicesBlockingPanel.removeFromSuperview()
    }

    internal func showToast(error message: String) {
        let midX = self.view.frame.midX
        let midY = self.view.bounds.maxY - (108 + self.view.safeAreaInsets.bottom)
        self.view.makeToast(
            message,
            point: CGPoint(x: midX, y: midY),
            title: nil,
            image: nil,
            completion: nil
        )
    }
}


extension ChatViewController: TrustedDevicesBlockingPanelDelegate {
    
    func onCheckButtonTouchUpInside() {
        let vc = TrustedDevicesViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        showModal(vc, parent: self)
    }
}
