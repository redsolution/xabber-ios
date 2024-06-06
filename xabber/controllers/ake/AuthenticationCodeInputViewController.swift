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

class AuthenticationCodeInputViewController: UIViewController, UITextFieldDelegate {
    var owner: String = ""
    var jid: String = ""
    var deviceId: String = ""
    var sid: String = ""
    var isVerificationWithUsersDevice: Bool = false
    
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
    
    func configure(owner: String, jid: String, sid: String, isVerificationWithUsersDevice: Bool) {
        self.owner = owner
        self.jid = jid
        self.sid = sid
        self.isVerificationWithUsersDevice = isVerificationWithUsersDevice
        
        loadDatasource()
        setupUI()
        
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
    
    private func setupUI() {
        view.addSubview(scrollView)
        scrollView.fillSuperview()
        containerView.frame = CGRect(origin: .zero, size: CGSize(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height))
        scrollView.contentSize = CGSize(width: containerView.frame.width, height: containerView.frame.height - 70)
        scrollView.addSubview(containerView)
        containerView.addSubview(stackLabels)
        containerView.addSubview(cancelButton)
        
        headerView.buttonsStack.removeFromSuperview()
        headerView.subtitleLabel.textColor = .systemGray
        headerView.backgroundColor = .systemGroupedBackground
        
        stackLabels.addArrangedSubview(headerView)
        stackLabels.addArrangedSubview(subtitleLabel)
        stackLabels.addArrangedSubview(descriptionLabel)
        stackLabels.addArrangedSubview(code)
        
        stackLabels.setCustomSpacing(40, after: descriptionLabel)
        headerView.stack.fillSuperviewWithOffset(top: 40, bottom: 40, left: 0, right: 0)
        
        cancelButton.addTarget(self, action: #selector(onCancelButtonPressed), for: .touchUpInside)
        
        self.view.backgroundColor = .systemBackground
        
        NSLayoutConstraint.activate([
            stackLabels.topAnchor.constraint(equalTo: containerView.topAnchor),
            stackLabels.leftAnchor.constraint(equalTo: containerView.leftAnchor, constant: 33),
            stackLabels.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -33),
            headerView.topAnchor.constraint(equalTo: stackLabels.topAnchor),
            headerView.bottomAnchor.constraint(equalTo: headerView.subtitleLabel.bottomAnchor, constant: 15),
            headerView.leftAnchor.constraint(equalTo: view.leftAnchor),
            headerView.rightAnchor.constraint(equalTo: view.rightAnchor),
            headerView.titleButton.topAnchor.constraint(equalTo: headerView.imageButton.bottomAnchor, constant: 6),
            headerView.subtitleLabel.topAnchor.constraint(equalTo: headerView.titleButton.bottomAnchor, constant: 6),
            headerView.stack.topAnchor.constraint(equalTo: stackLabels.topAnchor, constant: 48),
            subtitleLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            descriptionLabel.leftAnchor.constraint(equalTo: stackLabels.leftAnchor),
            cancelButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -70),
        ])
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
            
            var publicName = ""
            var client = ""
            var ip = ""
            var date = ""
            
            if isVerificationWithUsersDevice {
                let realm = try WRealm.safe()
                let sessionInstance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid))
                self.deviceId = String(sessionInstance!.opponentDeviceId)
                
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MMM d, yyyy"
                let dateRaw = Date(timeIntervalSince1970: TimeInterval(floatLiteral: Double(sessionInstance!.timestamp)!))
                date = dateFormatter.string(from: dateRaw)
                
                let deviceInstance = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND omemoDeviceId == %@", self.jid, Int(self.deviceId)!).first
                client = deviceInstance!.client
                ip = deviceInstance!.ip
                
                let omemoInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: Int(self.deviceId)!))
                publicName = omemoInstance!.name ?? deviceInstance!.device + " (\(deviceInstance!.omemoDeviceId))"
                
                self.headerView.configure(avatarUrl: nil, jid: "", owner: "", userId: nil, title: publicName, subtitle: nil, titleColor: .black)
                self.headerView.subtitleLabel.text = ip + " • " + date
                self.headerView.imageButton.imageEdgeInsets = UIEdgeInsets(top: 20, bottom: 20, left: 20, right: 20)
                self.headerView.imageButton.backgroundColor = .white
                
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
            
            subtitleLabel.text = "You are establishing a secure connection with this contact."
            
            let attributedString = NSMutableAttributedString(string: "1.\tCarefully verify the address and identity of this contact.\n\n2.\tEnter the verification code provided by your contact to confirm the secure connection:")
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = 28
            attributedString.addAttributes([NSAttributedString.Key.paragraphStyle: paragraphStyle], range: NSRange(location: 0, length: attributedString.length))
            descriptionLabel.attributedText = attributedString
        } catch {
            fatalError()
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
                            self.scrollView.contentOffset.y = codeBottomLine - keyboardTopLine + 30
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
        guard let ake = AccountManager.shared.find(for: self.owner)?.akeManager else {
            return false
        }
        
        var deviceId: String = ""
        var saltCiphertext: String = ""
        var saltIv: String = ""
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid))
            deviceId = String(instance!.opponentDeviceId)
            saltCiphertext = instance!.opponentByteSequenceEncrypted
            saltIv = instance!.opponentByteSequenceIv
            try realm.write {
                instance?.code = code.text!
            }
        } catch {
            DDLogDebug("AuthenticationCodeInputViewController \(#function). \(error.localizedDescription)")
        }
        
        let salt = ake.decrypt(jid: XMPPJID(string: self.jid)!.bare, sid: self.sid, deviceId: Int(deviceId)!, ciphertext: try! saltCiphertext.base64decoded(), iv: try! saltIv.base64decoded())
        
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid))
            try realm.write {
                instance?.opponentByteSequence = salt.toBase64()
                instance?.opponentDeviceId = Int(deviceId)!
            }
        } catch {
            DDLogDebug("AuthenticatedKeyExchangeManager: \(#function). \(error.localizedDescription)")
        }
        
        ake.sendHashToOpponent(fullJID: XMPPJID(string: self.jid)!, sid: self.sid)
        self.dismiss(animated: true)
        return true
    }
}
