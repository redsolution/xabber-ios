//
//  VerificationConfirmationViewController.swift
//  xabber
//
//  Created by Admin on 03.06.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import TOInsetGroupedTableView

class VerificationConfirmationViewController: SimpleBaseViewController {
    var sid: String = ""
    
    let stack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        return stack
        
    }()
    
    let agreeButton: UIButton = {
        let button = UIButton()
        button.setTitle("Accept", for: .normal)
//        button.tintColor = .systemBlue
        button.setTitleColor(.systemBlue, for: .normal)
        
        return button
    }()
    
    let revokeButton: UIButton = {
        let button = UIButton()
        button.setTitle("Revoke", for: .normal)
//        button.tintColor = .systemRed
        button.setTitleColor(.systemRed, for: .normal)
        
        return button
    }()
    
    func configure(sid: String) {
        self.sid = sid
        
        view.addSubview(stack)
//        stack.fillSuperview()
        
        stack.addArrangedSubview(agreeButton)
        stack.addArrangedSubview(revokeButton)
        
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 50),
            stack.heightAnchor.constraint(equalToConstant: 50),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }
}
