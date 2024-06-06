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
        button.backgroundColor = .white
        
        return button
    }()
    
    let revokeButton: UIButton = {
        let button = UIButton()
        button.setTitle("Revoke", for: .normal)
//        button.tintColor = .systemRed
        button.setTitleColor(.systemRed, for: .normal)
        button.backgroundColor = .white
        
        return button
    }()
    
    let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        return view
    }()
    
    func configure(owner: String, sid: String) {
        self.owner = owner
        self.sid = sid
        
        self.title = "Verify device"
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
//        view.backgroundColor = .systemGroupedBackground
//        
//        view.addSubview(stack)
////        stack.fillSuperview()
//        
//        stack.addArrangedSubview(agreeButton)
//        stack.addArrangedSubview(revokeButton)
//        
//        NSLayoutConstraint.activate([
//            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 50),
//            stack.heightAnchor.constraint(equalToConstant: 50),
//            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor)
//        ])
    }
}

extension VerificationConfirmationViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        var contentConfig = cell.defaultContentConfiguration()
        if indexPath.row == 0 {
            contentConfig.text = "Accept"
            contentConfig.textProperties.color = .systemBlue
        } else {
            contentConfig.text = "Revoke"
            contentConfig.textProperties.color = .systemRed
        }
        
        cell.contentConfiguration = contentConfig
        return cell
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 2
    }
}

extension VerificationConfirmationViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0 {
            guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
                  let code = akeManager.acceptVerificationRequest(jid: self.owner, sid: self.sid) else {
                fatalError()
            }
            
            let vc = ShowCodeViewController()
            vc.configure(owner: self.owner, jid: self.owner, code: code, sid: self.sid, isVerificationWithOwnDevice: true)
            self.dismiss(animated: true)
            guard let presenter = (UIApplication.shared.delegate as? AppDelegate)?.splitController else {
                fatalError()
            }
            presenter.present(vc, animated: true)
            
            return
        } else {
            guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
                fatalError()
            }
            akeManager.rejectRequestToVerify(jid: self.owner, sid: self.sid)
            self.dismiss(animated: true)
            
            return
        }
    }
}
