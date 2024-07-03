//
//  VerificationConfirmationViewController.swift
//  xabber
//
//  Created by Admin on 03.06.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import XMPPFramework
import RxSwift

class VerificationConfirmationViewController: SimpleBaseViewController {
    var sid: String = ""
    var deviceId: String = ""
    var isVerificationWithOwnDevice: Bool = false
    var code: String = ""
    
    var state: VerificationSessionStorageItem.VerififcationState = .receivedRequest
    
    var headerHeightMax: CGFloat = 236
    
    let scrollView: UIScrollView = {
        let view = UIScrollView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let containerView: UIView = {
        let view = UIView()
        
        return view
    }()
    
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
    
    let codeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.monospacedSystemFont(ofSize: 48, weight: .regular).bold()
        
        return label
    }()
    
    let agreeButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Proceed to Verification", for: .normal)
        
        return button
    }()
    
    let cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Cancel verification", for: .normal)
        button.setTitleColor(.systemRed, for: .normal)
        
        return button
    }()
    
    override func subscribe() {
        super.subscribe()
        
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(VerificationSessionStorageItem.self).filter("owner = %@ AND sid = %@", self.owner, self.sid)
            
            Observable.collection(from: collection).subscribe(onNext: { results in
                if results.isEmpty {
                    return
                }
                
                let item = results.first
                switch item?.state {
                case .acceptedRequest:
                    self.state = .acceptedRequest
                    self.code = item!.code
                    
                    self.agreeButton.removeFromSuperview()
                    self.cancelButton.removeFromSuperview()
                    
                    self.setupSubviews()
                    self.loadDatasource()
                    self.activateConstraints()
                    
//                    var attributedString = NSMutableAttributedString()
//                    if self.isVerificationWithOwnDevice {
//                        self.descriptionLabel.text = "You are receiving a device verification request to ensure secure and encrypted communication."
//                        attributedString = NSMutableAttributedString(string: "1.\tConfirm that this device is yours and that you recognize the initiating session.\n\n2.\tBelow is the verification code. Enter this code on the primary device to complete the encryption key exchange:")
//                    } else {
//                        self.descriptionLabel.text = "You are about to establish a secure connection with this contact."
//                        attributedString = NSMutableAttributedString(string: "1.\tCarefully verify the address and identity of this contact.\n\n2.\tUse a secure method (preferably in person) to ask the contact to verify identity by entering the following code:")
//                    }
//                    
//                    let paragraphStyle = NSMutableParagraphStyle()
//                    paragraphStyle.headIndent = 28
//                    attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
//                    self.stepsLabel.attributedText = attributedString
//                    
//                    self.view.backgroundColor = .systemBackground
//                    
//                    if item?.code == "" {
//                        return
//                    }
//                    self.codeLabel.text = item?.code
//                    self.stackLabels.addArrangedSubview(self.codeLabel)
//                    self.stackLabels.setCustomSpacing(40, after: self.stepsLabel)
//                    
//                    self.cancelButton.addTarget(self, action: #selector(self.onCancelButtonPressed), for: .touchUpInside)
                    break
                    
                default:
                    break
                }
                
            }).disposed(by: self.bag)

        } catch {
            DDLogDebug("ShowCodeViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func setupSubviews() {
        view.addSubview(scrollView)
        scrollView.fillSuperview()
        
        scrollView.addSubview(containerView)
        
        containerView.addSubview(headerView)
        containerView.addSubview(stackLabels)
        containerView.addSubview(cancelButton)
        
        stackLabels.addArrangedSubview(titleLabel)
        stackLabels.addArrangedSubview(descriptionLabel)
        stackLabels.addArrangedSubview(stepsLabel)
        
        if self.owner == self.jid {
            self.headerView.imageButton.imageEdgeInsets = UIEdgeInsets(top: 20, bottom: 20, left: 20, right: 20)
            self.headerView.imageButton.backgroundColor = .white
            self.headerView.imageButton.imageView?.contentMode = .scaleAspectFit
        }
        
        if state == .receivedRequest {
            containerView.addSubview(agreeButton)
            agreeButton.addTarget(self, action: #selector(onAgreeButtonTapped), for: .touchUpInside)
            cancelButton.addTarget(self, action: #selector(onRejectButtonTapped), for: .touchUpInside)
            
        } else if state == .acceptedRequest {
            self.stackLabels.addArrangedSubview(self.codeLabel)
            self.stackLabels.setCustomSpacing(40, after: self.stepsLabel)
            self.cancelButton.addTarget(self, action: #selector(self.onCancelButtonPressed), for: .touchUpInside)
            
        }
        
        
        
        
    }
    
    override func loadDatasource() {
        var descriptionText = ""
        var stepsText = ""
        
        switch state {
        case .receivedRequest:
            descriptionText = self.owner == self.jid ? "A verification request has been sent from another device to establish secure and encrypted communication." : "A verification request has been sent from your contact to establish secure and encrypted communication."
            stepsText = self.owner == self.jid ? "1.\tConfirm that this device is yours and that you recognize the initiating session.\n\n2.\tProceed to reveal the verification code necessary to complete the encryption key exchange." : "1.\tСonfirm that this contact is who he claims to be and that you recognize the initiating session.\n\n2.\tProceed to reveal the verification code necessary to complete the encryption key exchange."
            
        case .acceptedRequest:
            descriptionText = self.owner == self.jid ? "You are receiving a device verification request to ensure secure and encrypted communication." : "You are about to establish a secure connection with this contact."
            stepsText = self.owner == self.jid ? "1.\tConfirm that this device is yours and that you recognize the initiating session.\n\n2.\tBelow is the verification code. Enter this code on the primary device to complete the encryption key exchange:" : "1.\tCarefully verify the address and identity of this contact.\n\n2.\tUse a secure method (preferably in person) to ask the contact to verify identity by entering the following code:"
            codeLabel.text = self.code
            
        default:
            break
        }
        
        descriptionLabel.text = descriptionText
        
        let attributedString = NSMutableAttributedString(string: stepsText)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.headIndent = 28
        attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
        stepsLabel.attributedText = attributedString
        
        if self.owner == self.jid {
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
        
//            self.descriptionLabel.text = "A verification request has been sent from another device to establish secure and encrypted communication."
//            
//            let attributedString = NSMutableAttributedString(string: "1.\tConfirm that this device is yours and that you recognize the initiating session.\n\n2.\tProceed to reveal the verification code necessary to complete the encryption key exchange.")
//            let paragraphStyle = NSMutableParagraphStyle()
//            paragraphStyle.headIndent = 28
//            attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
//            stepsLabel.attributedText = attributedString
            
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
//            self.descriptionLabel.text = "A verification request has been sent from your contact to establish secure and encrypted communication."
//            
//            let attributedString = NSMutableAttributedString(string: "1.\tСonfirm that this contact is who he claims to be and that you recognize the initiating session.\n\n2.\tProceed to reveal the verification code necessary to complete the encryption key exchange.")
//            let paragraphStyle = NSMutableParagraphStyle()
//            paragraphStyle.headIndent = 28
//            attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
//            stepsLabel.attributedText = attributedString
            
            do {
                let realm = try WRealm.safe()
                guard let verificationInstance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                    DDLogDebug("VerificationConfirmationViewController: \(#function).")
                    return
                }
                
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
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -40),
        ])
        
        if state == .receivedRequest {
            agreeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
            agreeButton.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -8).isActive = true
        }
    }
    
    override func addObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(closeView(_:)), name: NSNotification.Name(rawValue: "rejected_VerificationConfirmationViewController"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(closeView(_:)), name: NSNotification.Name(rawValue: "close_view"), object: nil)
    }
    
    override func onAppear() {
        super.onAppear()
        
        containerView.frame = self.view.bounds
        
        headerView.frame = CGRect(
            width: view.frame.width,
            height: headerHeightMax
        )
        self.headerView.updateSubviews()
        self.navigationController?.isNavigationBarHidden = true
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid)) {
                if instance.state == .receivedRequest && self.owner == instance.jid {
                    let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager
                    akeManager?.rejectRequestToVerify(jid: self.owner, sid: self.sid)
                }
            }
        } catch {
            DDLogDebug("ShowCodeViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    @objc
    func closeView(_ notification: Notification) {
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
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            _ = user.akeManager.acceptVerificationRequest(jid: self.jid, sid: self.sid)
        }
    }
    
    @objc
    func onRejectButtonTapped() {
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            user.akeManager.rejectRequestToVerify(jid: self.jid, sid: self.sid)
        }
        
        self.dismiss(animated: true)
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
        
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            user.akeManager.sendErrorMessage(fullJID: XMPPJID(string: self.jid)!, sid: self.sid, reason: "Сontact canceled verification session")
        }
        
        self.dismiss(animated: true)
    }
}
