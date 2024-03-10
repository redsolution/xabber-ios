//
//  AuthenticationCodeInput.swift
//  xabber
//
//  Created by MacIntel on 19.02.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import SignalProtocolObjC
import XMPPFramework

class AuthenticationPasscodeEditView: UIView, UITextInputTraits {
    var code: String = "" {
        didSet {
            updateStack(by: code)
            if code.count == maxLength, let didFinishedEnterCode = didFinishedEnterCode {
                self.resignFirstResponder()
                didFinishedEnterCode(code)
            }
        }
    }
    
    var didFinishedEnterCode: ((String) -> Void)?
    
    var maxLength = 6
    var keyboardType: UIKeyboardType = .default
    let stack = UIStackView()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        showKeyboardIfNeeded()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setupUI() {
        addSubview(stack)
        self.backgroundColor = .clear
        stack.backgroundColor = .clear
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                                     stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: self.topAnchor),
                                     stack.bottomAnchor.constraint(equalTo: self.bottomAnchor)
                                    ])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        updateStack(by: code)
    }
    
    func updateStack(by code: String) {
        var pins: [UIView] = Array(code).map { pin(char: $0) }
        
        while pins.count != 6 {
            pins.append(emptyPin())
        }
        
        stack.removeAllArrangedSubviews()
        for view in pins {
            stack.addArrangedSubview(view)
        }
        
    }
    
    private func emptyPin() -> UIView {
        let pin = UIView()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "_"
        pin.addSubview(label)
        label.centerXAnchor.constraint(equalTo: pin.centerXAnchor).isActive = true
        label.centerYAnchor.constraint(equalTo: pin.centerYAnchor).isActive = true
        return pin
    }
    
    private func pin(char: Character) -> UIView {
        let pin = UIView()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(char)
        pin.addSubview(label)
        label.centerXAnchor.constraint(equalTo: pin.centerXAnchor).isActive = true
        label.centerYAnchor.constraint(equalTo: pin.centerYAnchor).isActive = true
        return pin
    }
    
    override var canBecomeFirstResponder: Bool {
        return true
    }
    
    private func showKeyboardIfNeeded() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(showKeyboard))
        self.addGestureRecognizer(tapGesture)
    }
    
    @objc private func showKeyboard() {
        self.becomeFirstResponder()
    }
}

extension AuthenticationPasscodeEditView: UIKeyInput {
    var hasText: Bool {
        return code.count > 0
    }
    
    func insertText(_ text: String) {
        guard code.count < maxLength else {
            return
        }
        code.append(contentsOf: text)
        print(code)
    }
    
    func deleteBackward() {
        if hasText {
            code.removeLast()
        }
        print(code)
    }
    
    
}

class AuthenticationCodeInputViewController: UIViewController {
    let owner: String
    let fullJID: XMPPJID
    let sid: String
    let message: XMPPMessage
    
    let code: AuthenticationPasscodeEditView = {
        let view = AuthenticationPasscodeEditView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    init(owner: String, jid: XMPPJID, sid: String, message: XMPPMessage) {
        self.owner = owner
        self.fullJID = jid
        self.sid = sid
        self.message = message
        self.code.keyboardType = .default
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        code.becomeFirstResponder()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        code.didFinishedEnterCode = { code in
            guard let ake = AccountManager.shared.find(for: self.owner)?.akeManager else {
                return
            }
//            
//            ake.state = .hashSentToOpponent
//            ake.code = code
            
            do {
                let realm = try WRealm.safe()
                let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, jid: self.fullJID.bare, sid: self.sid))
                try realm.write {
                    instance?.code = code
                }
            } catch {
                DDLogDebug("AuthenticationCodeInputViewController \(#function). \(error.localizedDescription)")
            }
            
            ake.processReceivedData(jid: self.fullJID.bare, sid: self.sid, message: self.message)
            ake.sendHashToOpponent(fullJID: self.fullJID, sid: self.sid)
        }
    }
    
    private func setupUI() {
        self.title = "Passcode lock"
        
        if #available(iOS 13.0, *) {
            self.view.backgroundColor = .systemBackground
        } else {
            self.view.backgroundColor = .white
        }
        
        view.addSubview(code)
        
        NSLayoutConstraint.activate([code.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.6),
                                     code.heightAnchor.constraint(equalToConstant: 44),
                                     code.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     code.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -107),
        ])
    }
}
