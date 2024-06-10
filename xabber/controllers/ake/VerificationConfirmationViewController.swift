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
import XMPPFramework

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
        button.setTitleColor(.systemBlue, for: .normal)
        button.backgroundColor = .white
        
        return button
    }()
    
    let revokeButton: UIButton = {
        let button = UIButton()
        button.setTitle("Revoke", for: .normal)
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
        
        guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
            DDLogDebug("VerificationConfirmationViewController: \(#function).")
            return
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(requestAcceptedByAnotherDevice(_:)), name: NSNotification.Name(rawValue: "VerificationConfirmationViewController"), object: akeManager)
    }
    
    @objc
    func requestAcceptedByAnotherDevice(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            let sid = userInfo["sid"]
            if self.sid == sid as! String {
                DispatchQueue.main.async {
                    self.dismiss(animated: true)
                }
            }
        }
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
            guard let code = AccountManager.shared.find(for: self.owner)?.akeManager.acceptVerificationRequest(jid: self.owner, sid: self.sid) else {
                return
            }
            
            let vc = ShowCodeViewController()
            vc.jid = self.owner
            vc.owner = self.owner
            vc.code = code
            vc.sid = self.sid
            vc.isVerificationWithOwnDevice = true
            self.dismiss(animated: true) {
                (UIApplication.shared.delegate as? AppDelegate)?.splitController?.present(vc, animated: true)
            }
            
            return
        } else {
            AccountManager.shared.find(for: self.owner)?.akeManager.rejectRequestToVerify(jid: self.owner, sid: self.sid)
            self.dismiss(animated: true)
            
            return
        }
    }
}
