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
    
    func configure(owner: String, sid: String, deviceId: String) {
        self.owner = owner
        self.sid = sid
        self.deviceId = deviceId
        
        headerView.backgroundColor = .systemGroupedBackground
        view.addSubview(headerView)
        
        view.addSubview(tableView)
        tableView.fillSuperviewWithOffset(top: headerHeightMax, bottom: 0, left: 0, right: 0)
        tableView.dataSource = self
        tableView.delegate = self
        
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
            guard let sessionInstance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid)) else {
                return
            }
            
            self.deviceId = String(sessionInstance.opponentDeviceId)
            
            guard let deviceInstance = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND omemoDeviceId == %@", self.owner, Int(self.deviceId)!).first else {
                return
            }
            client = deviceInstance.client
            ip = deviceInstance.ip
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d, yyyy"
            let dateRaw = deviceInstance.authDate
            date = dateFormatter.string(from: dateRaw)
            
            guard let omemoInstance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: Int(self.deviceId)!)) else {
                return
            }
            publicName = omemoInstance.name ?? deviceInstance.device + " (\(deviceInstance.omemoDeviceId))"
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
        
        NotificationCenter.default.addObserver(self, selector: #selector(requestAcceptedByAnotherDevice(_:)), name: NSNotification.Name(rawValue: "VerificationConfirmationViewController"), object: akeManager)
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
            
            self.navigationController?.pushViewController(vc, animated: true)
        } else {
            AccountManager.shared.find(for: self.owner)?.akeManager.rejectRequestToVerify(jid: self.owner, sid: self.sid)
            self.dismiss(animated: true)
            
            return
        }
    }
}
