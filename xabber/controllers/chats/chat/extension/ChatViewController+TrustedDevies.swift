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

            button.setTitle("Check devices", for: .normal)
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
                self.showTrustedDevicesBlockingPanel(identityVerification: identityVerification)
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
    
    private func showTrustedDevicesBlockingPanel(identityVerification: Bool) {
//        if UIDevice.needBottomOffset {
//            self.trustedDevicesBlockingPanel.frame = CGRect(x: 0, y: -8, width: self.view.frame.width, height: 84)
//        } else {
//            self.trustedDevicesBlockingPanel.frame = CGRect(width: self.view.frame.width, height: 44)
//        }
//
//        self.xabberInputBar.addSubview(self.trustedDevicesBlockingPanel)
//        self.xabberInputBar.bringSubviewToFront(self.trustedDevicesBlockingPanel)
        if !self.isTimeSignatureBlockingPanelopen {
            self.xabberInputView.changeState(to: identityVerification ? .identityVerification : .checkDevices)
            self.draftMessageText.accept(nil)
            self.xabberInputView.textField.text = nil
            self.isTrustedDevicesBlockingPanelopen = true
        }
    }
    
    private func hideTrustedDevicesBlockingPanel() {
        if !self.isTimeSignatureBlockingPanelopen {
            self.xabberInputView.changeState(to: .normal)
            self.isTrustedDevicesBlockingPanelopen = false
            self.isTimeSignatureBlockingPanelopen = false
        }
//        self.trustedDevicesBlockingPanel.removeFromSuperview()
    }
}


extension ChatViewController: TrustedDevicesBlockingPanelDelegate {
    
    func onCheckButtonTouchUpInside() {
        let vc = TrustedDevicesViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        showModal(vc)
    }
}
