//
//  ShowCodeViewController.swift
//  xabber
//
//  Created by Admin on 20.03.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import XMPPFramework

class ShowCodeViewController: UIViewController {
    var code: String = ""
    var owner: String = ""
    var jid: String = ""
    var sid: String = ""
    var isVerificationWithUsersDevice: Bool = false
    
    let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
        
        return view
    }()
    
    let codeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.monospacedSystemFont(ofSize: 48, weight: .regular)
        
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
    
    let subTitleLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .left
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        
        return label
    }()
    
    let descriptionLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .systemGray
        
        return label
    }()
    
    let cancelButton: UIButton = {
        let button = UIButton()
        button.setTitle("Cancel verification", for: .normal)
        button.setTitleColor(.systemBlue, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        
        return button
    }()
    
    private func setupUI() {
        view.addSubview(stackLabels)
        view.addSubview(cancelButton)
        
        headerView.buttonsStack.removeFromSuperview()
        headerView.subtitleLabel.textColor = .systemGray
        headerView.titleButton.tintColor = .black
        headerView.backgroundColor = .systemGroupedBackground
        
        stackLabels.addArrangedSubview(headerView)
        stackLabels.addArrangedSubview(subTitleLabel)
        stackLabels.addArrangedSubview(descriptionLabel)
        stackLabels.addArrangedSubview(codeLabel)
        
        stackLabels.setCustomSpacing(40, after: descriptionLabel)
        headerView.stack.fillSuperview()
        
        cancelButton.addTarget(self, action: #selector(onCancelButtonPressed), for: .touchUpInside)
        
        if isVerificationWithUsersDevice {
            subTitleLabel.text = "You are about to establish a secure connection with your other device"
        } else {
            subTitleLabel.text = "You are about to establish a secure connection with this account"
        }
        
        let attributedString = NSMutableAttributedString(string: "1.\tCarefully verify the address and identity of this contact.\n\n2.\tUse a secure method (preferably in person) to ask the contact to verify identity by entering the following code:")
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.headIndent = 28
        attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
        descriptionLabel.attributedText = attributedString
        
        self.view.backgroundColor = .systemBackground
        
        codeLabel.text = self.code
        
        NSLayoutConstraint.activate([
            stackLabels.topAnchor.constraint(equalTo: view.topAnchor),
            stackLabels.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 33),
            stackLabels.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -33),
            headerView.topAnchor.constraint(equalTo: stackLabels.topAnchor),
            headerView.bottomAnchor.constraint(equalTo: headerView.subtitleLabel.bottomAnchor, constant: 15),
            headerView.leftAnchor.constraint(equalTo: view.leftAnchor),
            headerView.rightAnchor.constraint(equalTo: view.rightAnchor),
            headerView.titleButton.topAnchor.constraint(equalTo: headerView.imageButton.bottomAnchor, constant: 6),
            headerView.subtitleLabel.topAnchor.constraint(equalTo: headerView.titleButton.bottomAnchor, constant: 6),
            headerView.stack.topAnchor.constraint(equalTo: stackLabels.topAnchor, constant: 48),
            subTitleLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            descriptionLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -70)
        ])
    }
    
    func configure(owner: String, jid: String, code: String, sid: String, isVerificationWithUsersDevice: Bool) {
        self.owner = owner
        self.jid = jid
        self.code = code
        self.sid = sid
        self.isVerificationWithUsersDevice = isVerificationWithUsersDevice
        
        loadDatasource()
        setupUI()
    }
    
    @objc
    func onCancelButtonPressed() {
        guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
            fatalError()
        }
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid))
            try realm.write {
                realm.delete(instance!)
            }
        } catch {
            fatalError()
        }
        
        akeManager.sendErrorMessage(fullJID: XMPPJID(string: self.jid)!, sid: self.sid, reason: "Сontact canceled verification session")
        self.dismiss(animated: true)
    }
    
    func loadDatasource() {
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner))
            if let instance = instance {
                self.headerView.configure(
                    avatarUrl: instance.avatarMaxUrl ?? instance.avatarMinUrl ?? instance.oldschoolAvatarKey,
                    jid: self.jid,
                    owner: self.owner,
                    userId: nil,
                    title: instance.displayName,
                    subtitle: self.jid,
                    thirdLine: nil,
                    titleColor: .black
                )
            } else {
                self.headerView.configure(
                    avatarUrl: nil,
                    jid: self.jid,
                    owner: self.owner,
                    userId: nil,
                    title: self.jid,
                    subtitle: self.jid,
                    thirdLine: nil,
                    titleColor: .black
                )
            }
        } catch {
            fatalError()
        }
    }
}
