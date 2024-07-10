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
import TOInsetGroupedTableView

class VerificationConfirmationViewController: SimpleBaseViewController {
    class Datasource {
        let name: String
        let ip: String?
        let lastAuth: Date
        let client: String?
        
        init(name: String, ip: String? = nil, lastAuth: Date, client: String? = nil) {
            self.name = name
            self.ip = ip
            self.lastAuth = lastAuth
            self.client = client
        }
    }
    
    var sid: String = ""
    var deviceId: String = ""
    var isVerificationWithOwnDevice: Bool = false
    var code: String = ""
    var state: VerificationSessionStorageItem.VerififcationState = .receivedRequest
    var datasource: [Datasource] = []
    
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
    
    let codeInputField: UITextField = {
        let textField = UITextField()
        textField.typingAttributes = [NSAttributedString.Key.kern: 5]
        textField.font = UIFont.monospacedSystemFont(ofSize: 48, weight: .regular).bold()
        textField.textAlignment = .center
        
        return textField
    }()
    
    internal let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        view.register(DeviceInfoTableCell.self, forCellReuseIdentifier: DeviceInfoTableCell.cellName)
        view.backgroundColor = .white
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let agreeButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.configuration = UIButton.Configuration.plain()
        button.configuration!.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)
        button.setTitle("Proceed to Verification", for: .normal)
        
        return button
    }()
    
    let cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.configuration = UIButton.Configuration.plain()
        button.configuration!.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)
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
                    self.cancelButton.removeTarget(self, action: #selector(self.onRejectButtonTapped), for: .touchUpInside)
                    
                    self.setupSubviews()
                    self.loadDatasource()
                    self.activateConstraints()
                    self.onAppear()
                    
                    break
                    
                case .trusted:
                    self.state = .trusted
                    self.stepsLabel.removeFromSuperview()
                    self.codeLabel.removeFromSuperview()
                    
                    self.cancelButton.removeTarget(self, action: #selector(self.onCancelButtonPressed), for: .touchUpInside)
                    
                    self.setupSubviews()
                    self.loadDatasource()
                    self.activateConstraints()
                    
                    break
                    
                default:
                    break
                }
                
            }).disposed(by: self.bag)
            
            
            let devicesTrustedByThisDevice = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
            Observable.collection(from: devicesTrustedByThisDevice).subscribe(onNext: { results in
                if results.isEmpty || self.state != .trusted {
                    return
                }
                
                self.loadDatasource()
                self.tableView.reloadData()
                
            }).disposed(by: self.bag)

        } catch {
            DDLogDebug("VerificationConfirmationViewController: \(#function). \(error.localizedDescription)")
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
        if state != .trusted {
            stackLabels.addArrangedSubview(stepsLabel)
        }
        
        self.navigationController?.isNavigationBarHidden = true
        
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
            
        } else if state == .receivedRequestAccept {
            agreeButton.configuration = UIButton.Configuration.filled()
            agreeButton.tintColor = .systemBlue
            agreeButton.setTitle("Submit", for: .normal)
            
            containerView.addSubview(agreeButton)
            self.stackLabels.addArrangedSubview(codeInputField)
            self.stackLabels.setCustomSpacing(40, after: self.stepsLabel)
            self.agreeButton.addTarget(self, action: #selector(onSubmitButtonPressed), for: .touchUpInside)
            self.cancelButton.addTarget(self, action: #selector(self.onCancelButtonPressed), for: .touchUpInside)
            
        } else if state == .trusted {
            containerView.addSubview(tableView)
            
            tableView.fillSuperviewWithOffset(top: headerHeightMax + 130, bottom: 80, left: 0, right: 0)
            tableView.dataSource = self
            
            cancelButton.setTitle("Great!", for: .normal)
            cancelButton.setTitleColor(.systemBlue, for: .normal)
            cancelButton.addTarget(self, action: #selector(onCloseButtonPressed), for: .touchUpInside)
            
        }
    }
    
    override func loadDatasource() {
        var titleText = ""
        var descriptionText = ""
        var stepsText = ""
        
        datasource = []
        
        switch state {
        case .receivedRequest:
            titleText = "Incoming Device Verification Request"
            descriptionText = self.owner == self.jid ? "A verification request has been sent from another device to establish secure and encrypted communication." : "A verification request has been sent from your contact to establish secure and encrypted communication."
            stepsText = self.owner == self.jid ? "1.\tConfirm that this device is yours and that you recognize the initiating session.\n\n2.\tProceed to reveal the verification code necessary to complete the encryption key exchange." : "1.\tСonfirm that this contact is who he claims to be and that you recognize the initiating session.\n\n2.\tProceed to reveal the verification code necessary to complete the encryption key exchange."
            
        case .acceptedRequest:
            titleText = "Device Verification"
            descriptionText = self.owner == self.jid ? "You are receiving a device verification request to ensure secure and encrypted communication." : "You are about to establish a secure connection with this contact."
            stepsText = self.owner == self.jid ? "1.\tConfirm that this device is yours and that you recognize the initiating session.\n\n2.\tBelow is the verification code. Enter this code on the primary device to complete the encryption key exchange:" : "1.\tCarefully verify the address and identity of this contact.\n\n2.\tUse a secure method (preferably in person) to ask the contact to verify identity by entering the following code:"
            codeLabel.text = self.code
            
        case .receivedRequestAccept:
            titleText = "Device Verification"
            descriptionText = self.owner == self.jid ? "You are verifying this device to ensure secure and encrypted communication." : "You are establishing a secure connection with this contact."
            stepsText = self.owner == self.jid ? "1.\tEnsure the other device is displaying the verification code.\n\n2.\tEnter the verification code displayed on the other device to complete the encryption key exchange:" : "1.\tCarefully verify the address and identity of this contact.\n\n2.\tEnter the verification code provided by your contact to confirm the secure connection:"
            
        case .trusted:
            titleText = "Verification Successful"
            descriptionText = "Verification has been successfully completed. Your devices can now seamlessly share encrypted communications. The following devices are now trusted:"
        default:
            break
        }
        
        titleLabel.text = titleText
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
                
                let deviceInstance = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND omemoDeviceId == %@", self.owner, Int(self.deviceId) ?? -1).first
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
                
                if self.state == .trusted {
                    self.datasource.append(Datasource(name: deviceInstance!.device, ip: deviceInstance!.ip, lastAuth: deviceInstance!.authDate, client: deviceInstance!.client))
                    
                    let instances = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND state_ == %@ AND trustedByDeviceId == %@", self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue, self.deviceId)
                    for instance in instances {
                        guard let device = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND omemoDeviceId == %@", self.owner, instance.deviceId).first else {
                            continue
                        }
                        self.datasource.append(Datasource(name: device.device, ip: device.ip, lastAuth: device.authDate, client: device.client))
                    }
                    
                }
            } catch {
                DDLogDebug("VerificationConfirmationViewController: \(#function). \(error.localizedDescription)")
            }
            
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
                self.headerView.imageButton.setImage(UIImage(systemName: "questionmark.app.dashed")?.withTintColor(.systemBlue), for: .normal)
            }
        } else {
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
                
                if self.state == .trusted {
                    let currentDevice = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: Int(self.deviceId) ?? -1))
                    if currentDevice == nil {
                        return
                    }
                    
                    self.datasource.append(Datasource(name: currentDevice!.name ?? String(currentDevice!.deviceId), lastAuth: currentDevice!.updateDate))
                    
                    let instances = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND state_ == %@ AND trustedByDeviceId == %@", self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue, self.deviceId)
                    for instance in instances {
                        self.datasource.append(Datasource(name: instance.name ?? String(instance.deviceId), lastAuth: instance.updateDate))
                    }
                }
                
            } catch {
                DDLogDebug("VerificationConfirmationViewController: \(#function). \(error.localizedDescription)")
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
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -40),
        ])
        
        if state != .trusted {
            stepsLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor).isActive = true
        }
        
        if state == .receivedRequest || state == .receivedRequestAccept {
            agreeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
            agreeButton.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -8).isActive = true
            agreeButton.topAnchor.constraint(greaterThanOrEqualTo: stackLabels.bottomAnchor, constant: 40).isActive = true
        }
        
        if state == .trusted {
            tableView.topAnchor.constraint(equalTo: stackLabels.bottomAnchor, constant: 20).isActive = true
        }
    }
    
    override func addObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(closeView(_:)), name: NSNotification.Name(rawValue: "rejected_VerificationConfirmationViewController"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(closeView(_:)), name: NSNotification.Name(rawValue: "close_view"), object: nil)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.keyboardWillShowNotification(_:)),
            name: UIWindow.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.keyboardWillHideNotification(_:)),
            name: UIWindow.keyboardWillHideNotification,
            object: nil
        )
    }
    
    override func onAppear() {
        super.onAppear()
        
        if self.state == .receivedRequestAccept {
            codeInputField.becomeFirstResponder()
            codeInputField.returnKeyType = .continue
            codeInputField.delegate = self
        }
        
        containerView.frame = self.view.bounds
        
        headerView.frame = CGRect(
            width: view.frame.width,
            height: headerHeightMax
        )
        self.headerView.updateSubviews()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid)) {
                if instance.state == .receivedRequest && self.owner == instance.jid {
                    AccountManager.shared.find(for: self.owner)?.action { user, stream in
                        user.akeManager.rejectRequestToVerify(jid: self.owner, sid: self.sid)
                    }
                    
                } else if instance.state == .trusted {
                    try realm.write {
                        realm.delete(instance)
                    }
                    
                }
            }
        } catch {
            DDLogDebug("VerificationConfirmationViewController: \(#function). \(error.localizedDescription)")
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
    func onSubmitButtonPressed() {
        self.dismiss(animated: true)
        submitVerificationCode()
    }
    
    func submitVerificationCode() {
        var deviceId: String = ""
        var saltCiphertext: String = ""
        var saltIv: String = ""
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid))
            if instance == nil {
                return
            }
            
            deviceId = String(instance!.opponentDeviceId)
            saltCiphertext = instance!.opponentByteSequenceEncrypted
            saltIv = instance!.opponentByteSequenceIv
            
            if let text = codeInputField.text {
                try realm.write {
                    instance!.code = text
                }
            } else {
                return
            }
        } catch {
            DDLogDebug("VerificationConfirmationViewController: \(#function). \(error.localizedDescription)")
        }
            
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            do {
                let realm = try WRealm.safe()
                let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid))
                let salt = user.akeManager.decrypt(
                    jid: XMPPJID(string: self.jid)?.bare ?? "",
                    sid: self.sid,
                    deviceId: Int(deviceId) ?? -1,
                    ciphertext: try saltCiphertext.base64decoded(),
                    iv: try saltIv.base64decoded()
                )
                
                try realm.write {
                    instance?.opponentByteSequence = salt.toBase64()
                }
            } catch {
                DDLogDebug("VerificationConfirmationViewController: \(#function). \(error.localizedDescription)")
            }
            
            user.akeManager.sendHashToOpponent(jid: XMPPJID(string: self.jid)!, sid: self.sid)
        }
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
            DDLogDebug("VerificationConfirmationViewController: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager.shared.find(for: self.owner)?.action { user, stream in
            user.akeManager.sendErrorMessage(fullJID: XMPPJID(string: self.jid)!, sid: self.sid, reason: "Сontact canceled verification session")
        }
        
        self.dismiss(animated: true)
    }
    
    @objc
    func onCloseButtonPressed() {
        self.dismiss(animated: true)
    }
    
    @objc
    func keyboardWillShowNotification(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            if let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
                let frame = frameValue.cgRectValue
                let keyboardVisibleHeight = frame.size.height
                if keyboardVisibleHeight == 0 {
                    return
                }
                switch (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber, userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber) {
                case let (.some(duration), .some(curve)):
                    let options = UIView.AnimationOptions(rawValue: curve.uintValue)
                    
                    let codeBottomLine = self.stackLabels.frame.origin.y + self.stackLabels.frame.height + 40 + codeInputField.frame.height
                    let keyboardTopLine = self.view.frame.height - keyboardVisibleHeight
                    
                    UIView.animate(
                        withDuration: TimeInterval(duration.doubleValue),
                        delay: 0,
                        options: options,
                        animations: {
                            self.scrollView.contentOffset.y = codeBottomLine - keyboardTopLine
                            return
                        }, completion: { finished in
                    })
                default:
                    break
                }
            }
        }
    }
    
    @objc func keyboardWillHideNotification(_ notification: NSNotification) {
        if let userInfo = notification.userInfo {
            
            switch (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber, userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber) {
            case let (.some(duration), .some(curve)):
                let options = UIView.AnimationOptions(rawValue: curve.uintValue)
                
                UIView.animate(
                    withDuration: TimeInterval(duration.doubleValue),
                    delay: 0,
                    options: options,
                    animations: {
                        self.scrollView.contentOffset.y = 0
                        return
                    }, completion: { finished in
                })
            default:
                break
            }
        }
    }
}

extension VerificationConfirmationViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.row]
        guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell else {
            return UITableViewCell(frame: .zero)
        }
        
        cell.configure(client: item.client ?? "", device: item.name, description: "", ip: item.ip ?? "", lastAuth: item.lastAuth, current: false, editable: false, isOnline: false)
        
        return cell
    }
}


extension VerificationConfirmationViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.dismiss(animated: true)
        submitVerificationCode()
        
        return true
    }
}
