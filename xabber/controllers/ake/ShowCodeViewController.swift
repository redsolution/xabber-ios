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
    
    let titleLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: UIFont.labelFontSize, weight: .semibold)
        return label
    }()
    
    let subTitleLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }()
    
    let descriptionLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
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
        headerView.subtitleLabel.textColor = .systemBlue
        headerView.titleButton.tintColor = .black
        
        stackLabels.addArrangedSubview(titleLabel)
        stackLabels.addArrangedSubview(subTitleLabel)
        stackLabels.addArrangedSubview(headerView)
        stackLabels.addArrangedSubview(descriptionLabel)
        stackLabels.addArrangedSubview(codeLabel)
        
        stackLabels.setCustomSpacing(40, after: descriptionLabel)
        headerView.stack.fillSuperviewWithOffset(top: 40, bottom: 40, left: 0, right: 0)
        
        cancelButton.addTarget(self, action: #selector(onCancelButtonPressed), for: .touchUpInside)
        
        titleLabel.text = "Identity Verification"
        if isVerificationWithUsersDevice {
            subTitleLabel.text = "You are about to establish a secure connection with your other device"
        } else {
            subTitleLabel.text = "You are about to establish a secure connection with this account"
        }
        
        let attributedString = NSMutableAttributedString(string: "1.\tCarefully verify the ")
        let infixAttributedString = NSAttributedString(string: "address", attributes: [NSAttributedString.Key.foregroundColor: UIColor.systemBlue])
        attributedString.append(infixAttributedString)
        attributedString.append(NSAttributedString(string: " and identity of this contact.\n\n2.\tUse a secure method (preferably in person) to ask the contact to verify identity by entering the following code:"))
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.headIndent = 28
        attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
        descriptionLabel.attributedText = attributedString
        
        if #available(iOS 13.0, *) {
            self.view.backgroundColor = .systemBackground
        } else {
            self.view.backgroundColor = .white
        }
        
        codeLabel.text = self.code
        
        NSLayoutConstraint.activate([
            stackLabels.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stackLabels.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 24),
            stackLabels.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -24),
            headerView.titleButton.topAnchor.constraint(equalTo: headerView.imageButton.bottomAnchor, constant: 6),
            headerView.subtitleLabel.topAnchor.constraint(equalTo: headerView.titleButton.bottomAnchor, constant: 6),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -70)
        ])
    }
    
    func configure() {
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
