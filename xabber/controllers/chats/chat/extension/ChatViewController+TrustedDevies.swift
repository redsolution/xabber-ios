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

protocol TrustedDevicesBlockingPanelDelegate: AnyObject {
    func onCheckButtonTouchUpInside()
}

extension ChatViewController {
    class TrustedDevicesBlockingPanel: UIView {
        
        weak var delegate: TrustedDevicesBlockingPanelDelegate? = nil
        
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

            button.setTitle(L10n.text("chat__trusted_devices__check_contacts_devices", fallback: "Check contact’s devices"), for: .normal)
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
        case .blockedByPendingOptOut:
            if !self.isTimeSignatureBlockingPanelopen {
                self.cancelActiveAudioRecordingForLifecycle()
                self.xabberInputView.changeState(to: .pendingOptOut)
                self.xabberInputView.stateButton.isEnabled = !self.isOMEMO2OptOutDecisionInFlight
                self.isTrustedDevicesBlockingPanelopen = true
            }
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

    internal func presentOMEMO2OptOutDecisionPrompt() {
        guard !isOMEMO2OptOutDecisionInFlight, presentedViewController == nil else { return }
        do {
            let realm = try WRealm.safe()
            guard OMEMO2OptOutPolicy.projectedDecision(owner: owner, jid: jid, realm: realm) == .pending else { return }
            var explanation = L10n.text("omemo_opt_out_explanation", fallback: "Your contact has requested to stop encryption. Continue without encryption or keep encrypted messages?")
            if let reason = realm.object(ofType: OMEMO2OptOutStorageItem.self,
                forPrimaryKey: OMEMO2OptOutStorageItem.genPrimary(owner: owner, jid: jid))?.reason,
               !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                explanation += "\n\n" + reason
            }
            let prompt = UIAlertController(
                title: L10n.text("omemo_opt_out_title", fallback: "Contact requests unencrypted messages"),
                message: explanation,
                preferredStyle: .alert
            )
            prompt.view.accessibilityIdentifier = "omemo.optout.confirmation"
            prompt.addAction(UIAlertAction(title: L10n.text("cancel", fallback: "Cancel"), style: .cancel))
            prompt.addAction(UIAlertAction(title: L10n.text("omemo_opt_out_keep", fallback: "Keep encryption"), style: .default) { [weak self] _ in
                self?.performOMEMO2OptOutDecision(.omemo)
            })
            prompt.addAction(UIAlertAction(title: L10n.text("omemo_opt_out_plaintext", fallback: "Continue unencrypted"), style: .destructive) { [weak self] _ in
                self?.performOMEMO2OptOutDecision(.plaintext)
            })
            present(prompt, animated: true)
        } catch {
            showOMEMO2OptOutDecisionFailure()
        }
    }

    internal func performOMEMO2OptOutDecision(_ decision: OMEMO2OptOutPolicy.Decision) {
        guard decision == .plaintext || decision == .omemo, !isOMEMO2OptOutDecisionInFlight else { return }
        do {
            guard OMEMO2OptOutPolicy.projectedDecision(owner: owner, jid: jid, realm: try WRealm.safe()) == .pending else { return }
        } catch {
            showOMEMO2OptOutDecisionFailure()
            return
        }
        let capturedOwner = owner
        let capturedPeer = jid
        isOMEMO2OptOutDecisionInFlight = true
        xabberInputView.stateButton.isEnabled = false
        let completion: (Result<Void, Error>) -> Void = { [weak self] result in
            let apply = { [weak self] in
                guard let self else { return }
                self.isOMEMO2OptOutDecisionInFlight = false
                guard self.owner == capturedOwner, self.jid == capturedPeer else { return }
                self.xabberInputView.stateButton.isEnabled = true
                self.refreshOmemoSendAvailability()
                switch result {
                case .failure:
                    self.showOMEMO2OptOutDecisionFailure()
                case .success:
                    self.routeAfterOMEMO2OptOutDecision(decision)
                }
            }
            if Thread.isMainThread { apply() }
            else { DispatchQueue.main.async(execute: apply) }
        }
        if let execute = omemoOptOutDecisionExecutor {
            execute(decision, completion)
            return
        }
        guard let account = AccountManager.shared.find(for: capturedOwner) else {
            completion(.failure(OMEMO2StorageError.stateUnavailable))
            return
        }
        account.action { user, _ in
            do {
                try OMEMO2OptOutPolicy.resolve(owner: capturedOwner, jid: capturedPeer,
                    decision: decision, at: Date(), realm: try WRealm.safe(), storage: user.omemo.omemo2Storage)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func routeAfterOMEMO2OptOutDecision(_ decision: OMEMO2OptOutPolicy.Decision) {
        let type: ClientSynchronizationManager.ConversationType = decision == .plaintext ? .regular : .omemo
        guard conversationType != type,
              let navigation = navigationController,
              navigation.topViewController === self else { return }
        let route = InfoCardChatSearchRouting.route(owner: owner, jid: jid, conversationType: type)
        let next = InfoCardChatSearchRouting.makeChatViewController(for: route, configure: nil)
        if let root = navigation.viewControllers.first, root !== self {
            navigation.setViewControllers([root, next], animated: true)
        } else {
            navigation.setViewControllers([next], animated: true)
        }
    }

    private func showOMEMO2OptOutDecisionFailure() {
        showToast(error: L10n.text("omemo_opt_out_failed", fallback: "Could not save your encryption choice. Try again."))
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
                self.xabberInputView.state == .pendingOptOut ||
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
