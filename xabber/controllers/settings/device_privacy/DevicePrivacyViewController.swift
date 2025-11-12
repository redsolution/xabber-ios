//
//  DevicePrivacyViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 02.10.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import CocoaLumberjack

class DevicePrivacyViewController: SimpleBaseViewController {
    
    private var deviceName: String = ""
    private var isDeviceInfoTransferEnabled: Bool = false
    private var yetAnotherDeviceName: String = ""
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(SimpleTableViewController.SwitchCell.self, forCellReuseIdentifier: SimpleTableViewController.SwitchCell.cellName)
        view.register(DeviceNameTextFieldCell.self, forCellReuseIdentifier: DeviceNameTextFieldCell.cellName)
        
        return view
    }()

    override func activateConstraints() {
        tableView.fillSuperview()
    }
    
    override func setupSubviews() {
        view.addSubview(tableView)
    }
    
    override func configure() {
        super.configure()
        self.title = "Privacy"
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.yetAnotherDeviceName = NickGenerator.shared.genRandomNick()
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                self.deviceName = instance.deviceName
            }
        } catch {
            DDLogDebug("DevicePrivacyViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
}

extension DevicePrivacyViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceNameTextFieldCell.cellName, for: indexPath) as? DeviceNameTextFieldCell else {
                fatalError()
            }
            
            cell.configure(value: self.deviceName, placeholder: self.yetAnotherDeviceName)
            
            return cell
            
        } else if indexPath.section == 1 {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SimpleTableViewController.SwitchCell.cellName, for: indexPath) as? SimpleTableViewController.SwitchCell else {
                fatalError()
            }
            
            cell.configure(key: "enabled", for: "Share device info", active: false)
            
            return cell
        } else {
            return UITableViewCell()
        }
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return "Your contacts can see this device name in identity section"
        } else if section == 1 {
            return "If this option enabled, your device info will be available for your contacts as \([[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " "))"
        } else {
            return nil
        }
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        2
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return 1
        } else if section == 1 {
            return 1
        } else {
            return 0
        }
    }
    
}

extension DevicePrivacyViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if #available(iOS 26, *) {
            return 52
        } else {
            return 44
        }
    }
    
}

extension DevicePrivacyViewController {
    class DeviceNameTextFieldCell: BaseTableCell {
        
        static let cellName: String = "DeviceNameTextFieldCell"
        
        var value: String = ""
        var placeholder: String = ""
        
        let textField: UITextField = {
            let field = UITextField()
            
            return field
        }()
        
        override func activateConstraints() {
            self.textField.fillSuperviewWithOffset(top: 4, bottom: 4, left: 16, right: 20)
        }
        
        override func setupSubviews() {
            self.contentView.addSubview(textField)
        }
        
        final public func configure(value: String, placeholder: String) {
            self.value = value
            self.placeholder = placeholder
            self.textField.text = value
            self.textField.placeholder = placeholder
        }
        
        var callback: ((String) -> Void)? = nil
        
        @objc
        private func onTextFieldValueDidChange(_ sender: UITextField) {
            self.callback?(sender.text ?? self.placeholder)
        }
        
    }
}
