//
//  ShowCodeViewController.swift
//  xabber
//
//  Created by Admin on 20.03.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

class ShowCodeViewController: UIViewController {
    var code: String = ""
    var owner: String = ""
    var jid: String = ""
    var sid: String = ""
    var isVerificationWithUsersDevice: Bool = false
    
    init(owner: String, jid: String, code: String, sid: String, isVerificationWithUsersDevice: Bool) {
        self.owner = owner
        self.jid = jid
        self.code = code
        self.sid = sid
        self.isVerificationWithUsersDevice = isVerificationWithUsersDevice
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    let codeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont(name: "Courier New", size: 25)
        return label
    }()
    
    let stackLabels: UIStackView = {
        let stack = UIStackView()
        stack.alignment = .center
        stack.axis = .vertical
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: UIFont.labelFontSize, weight: .semibold)
        return label
    }()
    
    let descriptionLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.numberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        return label
    }()
    
    let sidLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()
    
    private func setupUI() {
        view.addSubview(stackLabels)
        stackLabels.addArrangedSubview(titleLabel)
        stackLabels.addArrangedSubview(descriptionLabel)
        stackLabels.addArrangedSubview(sidLabel)
        
        titleLabel.text = "Verification code"
        if isVerificationWithUsersDevice {
            descriptionLabel.text = "You have agreed to verification with your other device, enter this code there"
        } else {
            descriptionLabel.text = "You have agreed to verification with your contact \(self.jid), tell this code to contact"
        }
        sidLabel.text = "SID: \(self.sid)"
        
        if #available(iOS 13.0, *) {
            self.view.backgroundColor = .systemBackground
        } else {
            self.view.backgroundColor = .white
        }
        
        codeLabel.text = self.code
        self.view.addSubview(codeLabel)
        
        NSLayoutConstraint.activate([
            stackLabels.topAnchor.constraint(equalTo: view.topAnchor, constant: 15),
            stackLabels.leftAnchor.constraint(equalTo: view.leftAnchor),
            stackLabels.rightAnchor.constraint(equalTo: view.rightAnchor),
            codeLabel.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            codeLabel.centerYAnchor.constraint(equalTo: self.view.centerYAnchor)
        ])
    }
    
    func configure() {
        setupUI()
    }
}
