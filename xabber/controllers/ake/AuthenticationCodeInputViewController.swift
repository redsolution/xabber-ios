//
//  AuthenticationCodeInput.swift
//  xabber
//
//  Created by MacIntel on 19.02.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import SignalProtocolObjC
import XMPPFramework

class AuthenticationCodeInputViewController: SimpleBaseViewController, UITextFieldDelegate {

    open var deviceId: String = ""
    open var sid: String = ""
    open var isVerificationWithUsersDevice: Bool = false
    
    var headerHeightMax: CGFloat = 236
    
    internal let scrollView: UIScrollView = {
        let view = UIScrollView(frame: .zero)
        
        return view
    }()
    
    internal let containerView: UIView = {
        let view = UIView()
        
        return view
    }()
    
    let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
        
        view.additionalTopOffset = 56
        
        return view
    }()
    
    let stackLabels: UIStackView = {
        let stack = UIStackView()
        stack.alignment = .center
        stack.axis = .vertical
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        return stack
    }()
    
    let subtitleLabel: UILabel = {
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
    
    let code: UITextField = {
        let textField = UITextField()
        textField.typingAttributes = [NSAttributedString.Key.kern: 5]
        textField.font = UIFont.monospacedSystemFont(ofSize: 48, weight: .regular)
        textField.textAlignment = .center
        
        return textField
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
        view.addSubview(scrollView)
        scrollView.fillSuperview()
        
        scrollView.addSubview(containerView)
        containerView.addSubview(stackLabels)
        containerView.addSubview(cancelButton)
        
        headerView.backgroundColor = .systemGroupedBackground
        
        containerView.addSubview(headerView)
        
        stackLabels.addArrangedSubview(subtitleLabel)
        stackLabels.addArrangedSubview(descriptionLabel)
        stackLabels.addArrangedSubview(code)
        
        stackLabels.setCustomSpacing(40, after: descriptionLabel)
        
        cancelButton.addTarget(self, action: #selector(onCancelButtonPressed), for: .touchUpInside)
        
        self.view.backgroundColor = .systemBackground
        
        NSLayoutConstraint.activate([
            stackLabels.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 16),
            stackLabels.leftAnchor.constraint(equalTo: containerView.leftAnchor, constant: 33),
            stackLabels.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -33),
            subtitleLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            descriptionLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            cancelButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -70),
        ])

    }
    
    override func addObservers() {
        super.addObservers()
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
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        code.becomeFirstResponder()
        code.returnKeyType = .continue
        code.delegate = self
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
            DDLogDebug("AuthenticationCodeInputViewController: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager.shared.find(for: self.owner)?.akeManager.sendErrorMessage(fullJID: XMPPJID(string: self.jid)!, sid: self.sid, reason: "Сontact canceled verification session")
        self.dismiss(animated: true)
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            
            var publicName = ""
            var client = ""
            var ip = ""
            var date = ""
            
            if isVerificationWithUsersDevice {
                let realm = try WRealm.safe()
                guard let sessionInstance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid)) else {
                    return
                }
                self.deviceId = String(sessionInstance.opponentDeviceId)
                
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MMM d, yyyy"
                let dateRaw = Date(timeIntervalSince1970: TimeInterval(floatLiteral: Double(sessionInstance.timestamp)!))
                date = dateFormatter.string(from: dateRaw)
                
                let deviceInstance = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND omemoDeviceId == %@", self.jid, Int(self.deviceId)!).first
                client = deviceInstance!.client
                ip = deviceInstance!.ip
                
                let omemoInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: Int(self.deviceId)!))
                publicName = omemoInstance!.name ?? deviceInstance!.device + " (\(deviceInstance!.omemoDeviceId))"
                
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
                
                subtitleLabel.text = "You are verifying this device to ensure secure and encrypted communication."
                
                let attributedString = NSMutableAttributedString(string: "1.\tEnsure the other device is displaying the verification code.\n\n2.\tEnter the verification code displayed on the other device to complete the encryption key exchange:")
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
                    titleColor: .label,
                    title: instance.displayName,
                    subtitle: self.jid,
                    thirdLine: nil
                )
            } else {
                self.headerView.configure(
                    avatarUrl: nil,
                    owner: self.owner,
                    jid: self.jid,
                    titleColor: .label,
                    title: publicName,
                    subtitle: self.jid,
                    thirdLine: nil
                )
            }
            
            subtitleLabel.text = "You are establishing a secure connection with this contact."
            
            let attributedString = NSMutableAttributedString(string: "1.\tCarefully verify the address and identity of this contact.\n\n2.\tEnter the verification code provided by your contact to confirm the secure connection:")
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = 28
            attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
            descriptionLabel.attributedText = attributedString
        } catch {
            DDLogDebug("AuthenticationCodeInputViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    @objc
    func keyboardWillShowNotification(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            if let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
                let frame = frameValue.cgRectValue
                let keyboardVisibleHeight = frame.size.height
                switch (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber, userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber) {
                case let (.some(duration), .some(curve)):
                    let options = UIView.AnimationOptions(rawValue: curve.uintValue)
                    
                    let codeBottomLine = self.code.frame.origin.y + self.code.frame.height
                    let keyboardTopLine = self.view.frame.height - keyboardVisibleHeight
                    
                    UIView.animate(
                        withDuration: TimeInterval(duration.doubleValue),
                        delay: 0,
                        options: options,
                        animations: {
                            self.scrollView.contentOffset.y = self.scrollView.contentOffset.y + keyboardVisibleHeight
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
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        var deviceId: String = ""
        var saltCiphertext: String = ""
        var saltIv: String = ""
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid))
            deviceId = String(instance!.opponentDeviceId)
            saltCiphertext = instance!.opponentByteSequenceEncrypted
            saltIv = instance!.opponentByteSequenceIv
            if let text = code.text {
                try realm.write {
                    instance?.code = code.text!
                }
            } else {
                return false
            }
        
            guard let salt = AccountManager
                .shared
                .find(for: self.owner)?
                .akeManager
                .decrypt(
                    jid: XMPPJID(string: self.jid)?.bare ?? "",
                    sid: self.sid,
                    deviceId: Int(deviceId) ?? -1,
                    ciphertext: try saltCiphertext.base64decoded(),
                    iv: try saltIv.base64decoded()
                ) else {
                return false
            }
            
            try realm.write {
                instance?.opponentByteSequence = salt.toBase64()
                instance?.opponentDeviceId = Int(deviceId)!
            }
            
            AccountManager.shared.find(for: self.owner)?.akeManager.sendHashToOpponent(fullJID: XMPPJID(string: self.jid)!, sid: self.sid)
            self.dismiss(animated: true)
            return true
            
        } catch {
            DDLogDebug("AuthenticationCodeInputViewController \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    override func onAppear() {
        super.onAppear()
        
        containerView.frame = self.view.bounds
        scrollView.contentSize = CGSize(width: containerView.frame.width, height: containerView.frame.height - 70)
        headerView.frame = CGRect(
            width: view.frame.width,
            height: headerHeightMax
        )
        self.headerView.updateSubviews()
    }
}
