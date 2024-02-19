//
//  AuthenticationCodeInput.swift
//  xabber
//
//  Created by MacIntel on 19.02.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

class AuthenticationCodeInputViewController: PasscodeViewController {
    var owner: String
    
    init(owner: String) {
        self.owner = owner
        
        super.init(firstPasscode: nil, delegate: nil, isOnboarding: false)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        passcode.didFinishedEnterCode = {code in
            guard let ake = AccountManager.shared.find(for: self.owner)?.akeManager else {
                return
            }
            ake.code = code
            ake.sendHashToOpponent()
        }
    }
    
    private func setupUI() {
        self.title = "Passcode lock"
        if #available(iOS 13.0, *) {
            self.view.backgroundColor = .systemBackground
        } else {
            self.view.backgroundColor = .white
        }
        cancelButton.target = self
        cancelButton.action = #selector(cancelMyAction)
        skipButton.target = self
        skipButton.action = #selector(skipMyAction)
        let barButton = self.isOnboarding ? skipButton : cancelButton
        navigationItem.setRightBarButton(barButton, animated: true)
        navigationItem.setHidesBackButton(true, animated: false)
        if let _ = firstPasscode {
            caption.text = "Verify your new passcode"
        } else {
            caption.text =  "Create a passcode to protect your data"
        }
        view.addSubview(passcode)
        view.addSubview(caption)
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([passcode.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.6),
                                     passcode.heightAnchor.constraint(equalToConstant: 44),
                                     passcode.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     passcode.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -107),
                                     caption.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     caption.bottomAnchor.constraint(equalTo: passcode.topAnchor, constant: -17),
                                     errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     errorLabel.topAnchor.constraint(equalTo: passcode.bottomAnchor, constant: 5)
        ])
    }
    
    @objc
    private func cancelMyAction() {
        navigationController?.popToRootViewController(animated: true)
    }
    
    @objc
    private func skipMyAction() {
        let vc = SignUpEnableNotificationsViewController()
        self.navigationController?.setViewControllers([vc], animated: true)
    }
}
