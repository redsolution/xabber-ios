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
    var deviceId: String = ""
    var isVerificationWithOwnDevice: Bool = false
    
    var headerHeightMax: CGFloat = 236
    
    internal let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
        view.titleButton.titleLabel?.font = UIFont.systemFont(ofSize: 20)
        view.additionalTopOffset = 56
        view.backgroundColor = .systemGroupedBackground
        
        return view
    }()
    
    let stackLabels: UIStackView = {
        let stack = UIStackView()
        stack.alignment = .center
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        label.font = label.font.bold()
        label.text = "Incoming Device Verification Request"
        label.numberOfLines = 0
        
        return label
    }()
    
    let descriptionLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        
        return label
    }()
    
    let stepsLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .systemGray
        
        return label
    }()
    
    let agreeButton: UIButton = {
        let button = UIButton()
        button.configuration = UIButton.Configuration.plain()
        button.configuration!.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Proceed to Verification", for: .normal)
        button.setTitleColor(.systemBlue, for: .normal)
        button.backgroundColor = .white
        
        return button
    }()
    
    let rejectButton: UIButton = {
        let button = UIButton()
        button.configuration = UIButton.Configuration.plain()
        button.configuration!.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Cancel verification", for: .normal)
        button.setTitleColor(.systemRed, for: .normal)
        button.backgroundColor = .white
        
        return button
    }()
    
    let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        return view
    }()
    
    override func setupSubviews() {
        view.addSubview(headerView)
        view.addSubview(stackLabels)
        view.addSubview(agreeButton)
        view.addSubview(rejectButton)
        
        stackLabels.addArrangedSubview(titleLabel)
        stackLabels.addArrangedSubview(descriptionLabel)
        stackLabels.addArrangedSubview(stepsLabel)
        
        agreeButton.addTarget(self, action: #selector(onAgreeButtonTapped), for: .touchUpInside)
        rejectButton.addTarget(self, action: #selector(onRejectButtonTapped), for: .touchUpInside)
        
        if isVerificationWithOwnDevice {
            self.headerView.imageButton.imageEdgeInsets = UIEdgeInsets(top: 20, bottom: 20, left: 20, right: 20)
            self.headerView.imageButton.backgroundColor = .white
            self.headerView.imageButton.imageView?.contentMode = .scaleAspectFit
        }
    }
    
    override func loadDatasource() {
        guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
            DDLogDebug("VerificationConfirmationViewController: \(#function).")
            return
        }
        
        if isVerificationWithOwnDevice {
            var client = ""
            var ip = ""
            var publicName = ""
            var date = ""
            
            do {
                let realm = try WRealm.safe()
                
                let deviceInstance = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND omemoDeviceId == %@", self.owner, Int(self.deviceId)!).first
                if deviceInstance == nil {
                    return
                }
                
                client = deviceInstance!.client
                ip = deviceInstance!.ip
                
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MMM d, yyyy"
                let dateRaw = deviceInstance!.authDate
                date = dateFormatter.string(from: dateRaw)
                
                publicName = deviceInstance!.device
            } catch {
                DDLogDebug("ShowCodeViewController: \(#function). \(error.localizedDescription)")
            }
        
            self.descriptionLabel.text = "A verification request has been sent from another device to establish secure and encrypted communication."
            
            let attributedString = NSMutableAttributedString(string: "1.\tConfirm that this device is yours and that you recognize the initiating session.\n\n2.\tProceed to reveal the verification code necessary to complete the encryption key exchange.")
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = 28
            attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
            stepsLabel.attributedText = attributedString
            
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
        } else {
            self.descriptionLabel.text = "A verification request has been sent from your contact to establish secure and encrypted communication."
            
            let attributedString = NSMutableAttributedString(string: "1.\tСonfirm that this contact is who he claims to be and that you recognize the initiating session.\n\n2.\tProceed to reveal the verification code necessary to complete the encryption key exchange.")
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = 28
            attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
            stepsLabel.attributedText = attributedString
            
            do {
                let realm = try WRealm.safe()
                guard let verificationInstance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                    DDLogDebug("VerificationConfirmationViewController: \(#function).")
                    return
                }
                self.jid = verificationInstance.jid
                
                let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: verificationInstance.jid, owner: self.owner))
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
            } catch {
                DDLogDebug("ShowCodeViewController: \(#function). \(error.localizedDescription)")
                return
            }
        }
    }
    
    override func activateConstraints() {
        NSLayoutConstraint.activate ([
            stackLabels.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 16),
            stackLabels.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 33),
            stackLabels.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -33),
            titleLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            descriptionLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            stepsLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            agreeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            agreeButton.bottomAnchor.constraint(equalTo: rejectButton.topAnchor, constant: -8),
            rejectButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            rejectButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -48)
        ])
    }
    
    override func addObservers() {
        let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager
        
        NotificationCenter.default.addObserver(self, selector: #selector(requestAcceptedByAnotherDevice(_:)), name: NSNotification.Name(rawValue: "rejected_VerificationConfirmationViewController"), object: akeManager)
    }
    
    override func onAppear() {
        super.onAppear()
        headerView.frame = CGRect(
            width: view.frame.width,
            height: headerHeightMax
        )
        self.headerView.updateSubviews()
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
    
    @objc
    func onAgreeButtonTapped() {
        let vc = ShowCodeViewController()
        vc.owner = self.owner
        vc.sid = self.sid
        vc.isVerificationWithOwnDevice = self.isVerificationWithOwnDevice
        
        if isVerificationWithOwnDevice {
            guard let code = AccountManager.shared.find(for: self.owner)?.akeManager.acceptVerificationRequest(jid: self.owner, sid: self.sid) else {
                return
            }
            vc.jid = self.owner
            vc.code = code
        } else {
            guard let code = AccountManager.shared.find(for: self.owner)?.akeManager.acceptVerificationRequest(jid: self.jid, sid: self.sid) else {
                return
            }
            vc.jid = self.jid
            vc.code = code
        }
        
        self.navigationController?.setViewControllers([vc], animated: true)
    }
    
    @objc
    func onRejectButtonTapped() {
        if isVerificationWithOwnDevice {
            AccountManager.shared.find(for: self.owner)?.akeManager.rejectRequestToVerify(jid: self.owner, sid: self.sid)
        } else {
            AccountManager.shared.find(for: self.owner)?.akeManager.rejectRequestToVerify(jid: self.jid, sid: self.sid)
        }
        self.dismiss(animated: true)
    }
}
