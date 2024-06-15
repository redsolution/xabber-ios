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
    
    var headerHeightMax: CGFloat = 236
    
    internal let headerView: InfoScreenHeaderView = {
        let view = InfoScreenHeaderView(frame: .zero)
        view.titleButton.titleLabel?.font = UIFont.systemFont(ofSize: 20)
        view.additionalTopOffset = 56
        
        return view
    }()
    
    let stack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
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
    
    let firstLineLabel: UILabel = {
        let label = UILabel()
        
        return label
    }()
    
    let agreeButton: UIButton = {
        let button = UIButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Proceed to Verification", for: .normal)
        button.setTitleColor(.systemBlue, for: .normal)
        button.backgroundColor = .white
        
        return button
    }()
    
    let rejectButton: UIButton = {
        let button = UIButton()
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
    
    func configure(owner: String, sid: String, deviceId: String) {
        self.owner = owner
        self.sid = sid
        self.deviceId = deviceId
        
        headerView.backgroundColor = .systemGroupedBackground
        view.addSubview(headerView)
        
        view.addSubview(agreeButton)
        view.addSubview(rejectButton)
        
        agreeButton.addTarget(self, action: #selector(onAgreeButtonTapped), for: .touchUpInside)
        rejectButton.addTarget(self, action: #selector(onRejectButtonTapped), for: .touchUpInside)
        
        guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
            DDLogDebug("VerificationConfirmationViewController: \(#function).")
            return
        }
        
        var client = ""
        var ip = ""
        var publicName = ""
        var date = ""
        
        do {
            let realm = try WRealm.safe()
            
            guard let deviceInstance = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND omemoDeviceId == %@", self.owner, Int(self.deviceId)!).first else {
                return
            }
            client = deviceInstance.client
            ip = deviceInstance.ip
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d, yyyy"
            let dateRaw = deviceInstance.authDate
            date = dateFormatter.string(from: dateRaw)
            
            publicName = deviceInstance.device
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
            self.headerView.imageButton.setImage(UIImage(systemName: "iphone")?.withTintColor(.systemBlue).withRenderingMode(.alwaysTemplate), for: .normal)
        } else if client == "Xabber for Web" {
            self.headerView.imageButton.setImage(UIImage(systemName: "desktopcomputer")?.withTintColor(.systemBlue).withRenderingMode(.alwaysTemplate), for: .normal)
        } else {
            self.headerView.imageButton.setImage(UIImage(systemName: "questionmark")?.withTintColor(.systemBlue).withRenderingMode(.alwaysTemplate), for: .normal)
        }
        
        NSLayoutConstraint.activate ([
            agreeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            agreeButton.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 10),
            rejectButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            rejectButton.topAnchor.constraint(equalTo: agreeButton.bottomAnchor, constant: 10)
        ])
        
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
        guard let code = AccountManager.shared.find(for: self.owner)?.akeManager.acceptVerificationRequest(jid: self.owner, sid: self.sid) else {
            return
        }
        
        let vc = ShowCodeViewController()
        vc.jid = self.owner
        vc.owner = self.owner
        vc.code = code
        vc.sid = self.sid
        vc.isVerificationWithOwnDevice = true
        
        self.navigationController?.setViewControllers([vc], animated: true)
    }
    
    @objc
    func onRejectButtonTapped() {
        AccountManager.shared.find(for: self.owner)?.akeManager.rejectRequestToVerify(jid: self.owner, sid: self.sid)
        self.dismiss(animated: true)
    }
}
