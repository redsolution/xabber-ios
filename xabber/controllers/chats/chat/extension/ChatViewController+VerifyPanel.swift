//
//  ChatViewController+VerifyPanel.swift
//  xabber
//
//  Created by Игорь Болдин on 27.06.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import RxRealm
import RxSwift
import RxCocoa
import MaterialComponents.MDCPalettes
import Toast_Swift
import CocoaLumberjack

extension ChatViewController {

    class VerifyBarView: UIView {
        
        enum State {
            case nonVerified
            case requested
            case requesting
            case enterCode
        }
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .bottom
            stack.spacing = 8
//            stack.distribution = .fill
//
//            stack.isLayoutMarginsRelativeArrangement = true
//            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 2, left: 8, right: 8)
            
            return stack
        }()
        
        let middleStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .leading
            stack.spacing = 4
            stack.distribution = .fill
            
            stack.isUserInteractionEnabled = true
            
            return stack
        }()
                
        let button: UIButton = {
            let button = UIButton()
            
            button.tintColor = .systemBlue
            button.setTitle("Add contact".localizeString(id: "application_action_no_contacts", arguments: []), for: .normal)
            button.setTitleColor(.systemBlue, for: .normal)
            
            
            return button
        }()
                
        let cancelButton: UIButton = {
            let button = UIButton()
            
            button.setImage(#imageLiteral(resourceName: "feather_close_24pt").withRenderingMode(.alwaysTemplate), for: .normal)
            button.frame = CGRect(square: 36)
            button.tintColor = .gray
            
            button.imageEdgeInsets = UIEdgeInsets(top: 6, bottom: 6, left: 6, right: 6)
            
            return button
        }()
        
        internal let bottomLine: UIView = {
            let view = UIView()
            
            view.backgroundColor = UIColor.black.withAlphaComponent(0.21)
            
            return view
        }()
        
        open var state: State = .requesting
        
        open var onCancelCallback: (() -> Void)? = nil
        
        open var onButtonTouchUpInsideCallback: (() -> Void)? = nil
        
        @objc
        internal func onButtonTouchUpInside() {
            onButtonTouchUpInsideCallback?()
        }
                
        @objc
        internal func onCancel() {
            onCancelCallback?()
        }
        
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
                self.button.widthAnchor.constraint(equalTo: self.stack.widthAnchor),
                self.button.heightAnchor.constraint(equalTo: self.stack.heightAnchor)
            ])
        }
        
        open func configure(for state: State) -> CGFloat {
            self.state = state
            switch state {
                case .nonVerified:
                    self.button.setTitle("Verify", for: .normal)
                    return 40
                
                case .requested:
                    self.button.setTitle("Requested", for: .normal)
                    self.button.isEnabled = false
                    return 40
                    
                case .requesting:
                    self.button.setTitle("Accept", for: .normal)
                    return 40
            
                case .enterCode:
                    self.button.setTitle("Enter code", for: .normal)
                    return 40
            }
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(stack)
            stack.fillSuperviewWithOffset(top: 64, bottom: 0, left: 0, right: 0)
            stack.addArrangedSubview(button)
            stack.addArrangedSubview(cancelButton)
            activateConstraints()
            
            cancelButton.addTarget(self, action: #selector(onCancel), for: .touchUpInside)
            button.addTarget(self, action: #selector(onButtonTouchUpInside), for: .touchUpInside)
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
        }
        
        open func layoutBottomLine() {
            bottomLine.frame = CGRect(x: 0, y: frame.maxY - 0.5, width: frame.width, height: 0.5)
            bringSubviewToFront(bottomLine)
            setNeedsLayout()
        }
    }
    
    internal func showVerifyBar(animated: Bool, state: VerifyBarView.State) {
        
        let height = verifyBarView.configure(for: state)
        
        func transition(_ block: @escaping (() -> Void), completion: ((Bool) -> Void)?) {
            if animated {
                UIView.animate(withDuration: 0.3,
                               animations: block,
                               completion: completion)
            } else {
                block()
                completion?(true)
            }
        }
        
        if let maxY = self.navigationController?.navigationBar.frame.maxY,
            let width = self.navigationController?.navigationBar.frame.width {
            
            verifyBarView.frame = CGRect(x: 0, y: 0, width: width, height: height)
//            additionalBottomInset = 40
            verifyBarView.onCancelCallback = onCancelSubscribtionBarButtonPressed
            verifyBarView.onButtonTouchUpInsideCallback = onVerifyBarButtonPressed
            
            transition({
                self.verifyBar.isHidden = false
                self.verifyBarView.isHidden = false
                self.verifyBar.frame = CGRect(x: 0, y: 0, width: width, height: maxY + height)
                self.verifyBarView.layoutBottomLine()
            }) { (result) in
                self.verifyBarView.layoutBottomLine()
            }
        }
    }
    
    
    internal func hideVerifyBar(animated: Bool) {
        func transition(_ block: @escaping (() -> Void), completion: ((Bool) -> Void)?) {
            if animated {
                UIView.animate(withDuration: 0.3,
                               animations: block,
                               completion: completion)
            } else {
                block()
                completion?(true)
            }
        }
        let width = self.verifyBar.frame.width
        transition({
            self.verifyBar.frame = CGRect(x: 0, y: 0, width: width, height: 64)
            self.verifyBarView.isHidden = true
            self.verifyBar.isHidden = true
        }) { (result) in
            
        }
        
    }
    
    func onVerifyBarButtonPressed() {
        switch self.verifyBarView.state {
        case .nonVerified:
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.akeManager.sendVerificationRequest(jid: self.jid)
            }
            
            self.verifyBarView.state = .requested
            break
            
        case .requested:
            break
        case .requesting:
            break
        case .enterCode:
            break
        }
    }
}
