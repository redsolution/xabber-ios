//
//  ManualVerificationDeviceViewController.swift
//  xabber
//
//  Created by Admin on 13.05.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import TOInsetGroupedTableView
import XMPPFramework

class ManualVerificationDeviceViewController: SimpleBaseViewController {
    class Datasource {
        enum Kind {
            case fingerprint
            case button
        }
        
        var kind: Kind
        var deviceId: String?
        var deviceLabel: String?
        var fingerprint: String?
        var title: String?
        
        init(kind: Kind, deviceId: String? = nil, deviceLabel: String? = nil, fingerprint: String? = nil, title: String? = nil) {
            self.kind = kind
            self.deviceId = deviceId
            self.deviceLabel = deviceLabel
            self.fingerprint = fingerprint
            self.title = title
        }
    }
    
    var datasource: [Datasource] = []
    var deviceId: String = ""
    
    let tableView = InsetGroupedTableView(frame: .zero)
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }
    
    override func configure() {
        super.configure()
        title = "Manual verification"
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
        self.navigationItem.backButtonTitle = self.title
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            guard let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: Int(self.deviceId)!)),
                  let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore,
                  let myDevice = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: localStore.localDeviceId())) else {
                DDLogDebug("ManualVerificationDeviceViewController: \(#function).")
                return
            }
            datasource = [
                Datasource(kind: .fingerprint, deviceId: String(device.deviceId), deviceLabel: device.name, fingerprint: device.fingerprint, title: self.jid),
                Datasource(kind: .fingerprint, deviceId: String(myDevice.deviceId), deviceLabel: myDevice.name, fingerprint: myDevice.fingerprint, title: "\(self.owner) ⦁ your device"),
                Datasource(kind: .button, title: "Match")
            ]
        } catch {
            DDLogDebug("ManualVerificationDeviceViewController: \(#function). \(error.localizedDescription)")
            return
        }
    }
}

extension ManualVerificationDeviceViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let item = datasource[section]
        if item.kind == .button {
            return nil
        }
        let header = UITableViewHeaderFooterView()
        var headerConfig = header.defaultContentConfiguration()
        headerConfig.text = item.title
        headerConfig.textProperties.transform = .lowercase
        header.contentConfiguration = headerConfig
        
        return header
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section]
        switch item.kind {
        case .fingerprint:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var cellConfig = cell.defaultContentConfiguration()
            cellConfig.text = item.deviceLabel ?? item.deviceId
            cellConfig.secondaryText = item.fingerprint
            cellConfig.secondaryTextProperties.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .light)
            cellConfig.textToSecondaryTextVerticalPadding = 10
            
            cell.contentConfiguration = cellConfig
            cell.accessoryType = .none
            cell.selectionStyle = .none
            
            return cell
        case .button:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            var cellConfig = cell.defaultContentConfiguration()
            cellConfig.text = item.title
            cellConfig.textProperties.color = .systemBlue
            cellConfig.textProperties.alignment = .center
            cell.contentConfiguration = cellConfig
            
            return cell
        }
    }
    
    
}

extension ManualVerificationDeviceViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return tableView.estimatedRowHeight
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = datasource[indexPath.section]
        if item.kind == .button {
            guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
                  let trustSharingManager = AccountManager.shared.find(for: self.owner)?.trustSharingManager,
                  let localDeviceId = AccountManager.shared.find(for: self.owner)?.omemo.localStore.localDeviceId() else {
                DDLogDebug("ManualVerificationDeviceViewController: \(#function).")
                return
            }
            akeManager.writeTrustedDevice(jid: self.jid, deviceId: Int(self.deviceId)!)
            do {
                let realm = try WRealm.safe()
                let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: Int(self.deviceId)!))
                try realm.write {
                    instance?.trustedByDeviceId = "manual"
                }
            } catch {
                
            }
            if self.jid != self.owner {
                trustSharingManager.sendListOfContactsDevices(opponentFullJid: XMPPJID(string: self.owner)!, deviceId: localDeviceId)
                trustSharingManager.getUserTrustedDevices(jid: XMPPJID(string: self.jid)!, deviceId: String(self.deviceId))
            }
        }
        goBack()
    }
}
