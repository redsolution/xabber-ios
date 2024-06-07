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

class ShowCodeViewController: SimpleBaseViewController {
    
    open var code: String = ""
    open var deviceId: String = ""
    open var sid: String = ""
    open var isVerificationWithOwnDevice: Bool = false
    
    var headerHeightMax: CGFloat = 236
    
    internal let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
        view.titleButton.titleLabel?.font = UIFont.systemFont(ofSize: 20)
        view.additionalTopOffset = 56
        
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
        label.font = UIFont.systemFont(ofSize: 17)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        
        return label
    }()
    
    let descriptionLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 17)
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
    
    override func configure() {
        super.configure()
        
        view.addSubview(stackLabels)
        view.addSubview(cancelButton)
        
        headerView.backgroundColor = .systemGroupedBackground
        
        view.addSubview(headerView)
        stackLabels.addArrangedSubview(subTitleLabel)
        stackLabels.addArrangedSubview(descriptionLabel)
        stackLabels.addArrangedSubview(codeLabel)
        
        stackLabels.setCustomSpacing(40, after: descriptionLabel)
        
        cancelButton.addTarget(self, action: #selector(onCancelButtonPressed), for: .touchUpInside)
        
        if isVerificationWithOwnDevice {
            subTitleLabel.text = "You are about to establish a secure connection with this account"
        } else {
            subTitleLabel.text = "You are about to establish a secure connection with your other device"
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
            stackLabels.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 16),
            stackLabels.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 33),
            stackLabels.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -33),
            subTitleLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            descriptionLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -70)
        ])
        
        cancelButton.addTarget(self, action: #selector(onCancelButtonPressed), for: .touchUpInside)
    }
    
    @objc
    func onCancelButtonPressed() {
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid))
            try realm.write {
                realm.delete(instance!)
            }
        } catch {
            DDLogDebug("ShowCodeViewController: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager.shared.find(for: self.owner)?.akeManager.sendErrorMessage(fullJID: XMPPJID(string: self.jid)!, sid: self.sid, reason: "Сontact canceled verification session")
        self.dismiss(animated: true)
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        
        codeLabel.text = self.code
        do {
            let realm = try WRealm.safe()
            
            var publicName = ""
            var client = ""
            var ip = ""
            var date = ""
            
            if isVerificationWithOwnDevice {
                do {
                    let realm = try WRealm.safe()
                    let sessionInstance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.jid, sid: self.sid))
                    self.deviceId = String(sessionInstance!.opponentDeviceId)
                    
                    let deviceInstance = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND omemoDeviceId == %@", self.jid, Int(self.deviceId)!).first
                    client = deviceInstance!.client
                    ip = deviceInstance!.ip
                    
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "MMM d, yyyy"
                    let dateRaw = deviceInstance!.authDate
                    date = dateFormatter.string(from: dateRaw)
                    
                    let omemoInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: Int(self.deviceId)!))
                    publicName = omemoInstance!.name ?? deviceInstance!.device + " (\(deviceInstance!.omemoDeviceId))"
                } catch {
                    DDLogDebug("ShowCodeViewController: \(#function). \(error.localizedDescription)")
                }
                
                self.headerView.imageButton.imageEdgeInsets = UIEdgeInsets(top: 20, bottom: 20, left: 20, right: 20)
                self.headerView.imageButton.backgroundColor = .white
                
                self.headerView.configure(
                    avatarUrl: nil,
                    owner: self.owner,
                    jid: self.jid,
                    titleColor: .black,
                    title: publicName,
                    subtitle: ip + " • " + date,
                    thirdLine: nil
                )
                
                
                if client == "XabberIOS" {
                    self.headerView.imageButton.setImage(UIImage(systemName: "iphone")?.withTintColor(.systemBlue), for: .normal)
                } else if client == "Xabber for Web" {
                    self.headerView.imageButton.setImage(UIImage(systemName: "desktopcomputer")?.withTintColor(.systemBlue), for: .normal)
                } else {
                    self.headerView.imageButton.setImage(UIImage(systemName: "questionmark")?.withTintColor(.systemBlue), for: .normal)
                }
                
                subTitleLabel.text = "You are receiving a device verification request to ensure secure and encrypted communication."
                
                let attributedString = NSMutableAttributedString(string: "1.\tConfirm that this device is yours and that you recognize the initiating session.\n\n2.\tBelow is the verification code. Display this code to the primary device to complete the encryption key exchange:")
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.headIndent = 28
                attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
                descriptionLabel.attributedText = attributedString
                
                return
            }
            
            let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner))
            if let instance = instance {
                self.headerView.configure(
                    avatarUrl: instance.avatarUrl,
                    owner: self.owner,
                    jid: self.jid,
                    titleColor: .black,
                    title: instance.displayName,
                    subtitle: self.jid,
                    thirdLine: nil
                )
            } else {
                self.headerView.configure(
                    avatarUrl: nil,
                    owner: self.owner,
                    jid: self.jid,
                    titleColor: .black,
                    title: self.jid,
                    subtitle: self.jid,
                    thirdLine: nil
                )
            }
            
            subTitleLabel.text = "You are about to establish a secure connection with this contact."
            
            let attributedString = NSMutableAttributedString(string: "1.\tCarefully verify the address and identity of this contact.\n\n2.\tUse a secure method (preferably in person) to ask the contact to verify identity by entering the following code:")
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = 28
            attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
            descriptionLabel.attributedText = attributedString
        } catch {
            DDLogDebug("ShowCodeViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func onAppear() {
        super.onAppear()
        headerView.frame = CGRect(
            width: view.frame.width,
            height: headerHeightMax
        )
        self.headerView.updateSubviews()
    }
}
