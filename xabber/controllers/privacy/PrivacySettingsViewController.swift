//
//  PrivacySettingsViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 02.02.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import TOInsetGroupedTableView

class PrivacySettingsViewController: SimpleBaseViewController {
    
    class CheckmarkCell: UITableViewCell {
        static let cellName: String = "PrivacySettingsViewControllerCheckmarkCell"
    }
    
    class BoolCell: UITableViewCell {
        static let cellName: String = "PrivacySettingsViewControllerBoolkCell"
        
        open var key: String!
        
        let switchView: UISwitch = {
            let view = UISwitch(frame: .zero)
            
            return view
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            return label
        }()
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            return stack
        }()
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 4, bottom: 4, left: 20, right: 16)
            stack.addArrangedSubview(self.titleLabel)
            stack.addArrangedSubview(self.switchView)
            switchView.addTarget(self, action: #selector(onSwitchChangeValue), for: .valueChanged)
            selectionStyle = .none
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        @objc
        private func onSwitchChangeValue(_ sender: UISwitch) {
            SettingManager.shared.saveItem(key: self.key, bool: sender.isOn)
        }
    }
    
    private let tableView: InsetGroupedTableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(CheckmarkCell.self, forCellReuseIdentifier: CheckmarkCell.cellName)
        view.register(BoolCell.self, forCellReuseIdentifier: BoolCell.cellName)
        
        return view
    }()
    
    struct Datasource {
        enum Section {
            case privacy
            case typing
            case media
        }
        
        enum ValueType {
            case boolean
            case checkobox
        }
        
        let section: Section
        let valueType: ValueType
        let title: String
        let key: String
        let footerLabel: String
        let childs: [Datasource]
    }
    
    var datasource: [Datasource] = []
    var selectedValue: String = CommonConfigManager.shared.config.default_privacy_level
    
    override func loadDatasource() {
        super.loadDatasource()
        
        self.datasource = [
            Datasource(
                section: .privacy,
                valueType: .checkobox,
                title: "Device Metadata Sharing",
                key: "",
                footerLabel: "Incognito Mode text description",
                childs: [
                    Datasource(
                        section: .privacy,
                        valueType: .checkobox,
                        title: "Server and Contacts",
                        key: SettingManager.PrivacyLevel.serverContacts.rawValue,
                        footerLabel: "This option shares your device information (type and OS) with both the server and your contacts. The server uses this data solely for device management purposes, allowing users to see which devices are connected to their account. Your contacts might see this information during device verification, enhancing the user experience at the cost of some privacy.",
                        childs: []
                    ),
                    Datasource(
                        section: .privacy,
                        valueType: .checkobox,
                        title: "Server Only",
                        key: SettingManager.PrivacyLevel.server.rawValue,
                        footerLabel: "With this setting, your device information is shared only with the server for device management, ensuring users can manage their connected devices. Contacts, however, will see anonymized data instead, preserving your privacy. This setting provides a balance between functional device management and personal privacy.",
                        childs: []
                    ),
                    Datasource(
                        section: .privacy,
                        valueType: .checkobox,
                        title: "Incognito Mode",
                        key: SettingManager.PrivacyLevel.incognito.rawValue,
                        footerLabel: "Incognito Mode offers maximum privacy by not sharing any device details. Both the server and your contacts will see only anonymized data, even in the context of device management. This setting ensures your device information remains completely private, prioritizing user anonymity over personalized device management.",
                        childs: []
                    )
                ]
            ),
            Datasource(
                section: .typing,
                valueType: .boolean,
                title: "typing notifications",
                key: "",
                footerLabel: "typing notifications text description",
                childs: [
                    Datasource(
                        section: .privacy,
                        valueType: .boolean,
                        title: "Send typing notifications",
                        key: SettingManager.PrivacySettings.typingNotification.rawValue,
                        footerLabel: "Server and Contacts text description",
                        childs: []
                    )
                ]
            )
            
        ]
        
        self.selectedValue = SettingManager.shared.getString(for: "privacy_level") ?? CommonConfigManager.shared.config.default_privacy_level
    }
    
    override func activateConstraints() {
        super.activateConstraints()
        self.tableView.fillSuperview()
    }
    
    override func configure() {
        super.configure()
        self.view.addSubview(self.tableView)
        self.navigationItem.title = "Privacy settings"
        self.navigationController?.isNavigationBarHidden = false
        if CommonConfigManager.shared.config.use_large_title {
            self.navigationItem.largeTitleDisplayMode = .automatic
        } else {
            self.navigationItem.largeTitleDisplayMode = .never
        }
        self.navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title
        self.navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        self.navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.navigationBar.setNeedsLayout()
        self.tableView.delegate = self
        self.tableView.dataSource = self
    }
}

extension PrivacySettingsViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource[section].childs.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item =  self.datasource[indexPath.section].childs[indexPath.row]
        switch item.valueType {
            case .checkobox:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: CheckmarkCell.cellName, for: indexPath) as? CheckmarkCell else {
                    fatalError()
                }
                cell.selectionStyle = .none
                cell.textLabel?.text = item.title
                
                if self.selectedValue == item.key {
                    cell.accessoryType = .checkmark
                } else {
                    cell.accessoryType = .none
                }
                
                return cell
            case .boolean:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: BoolCell.cellName, for: indexPath) as? BoolCell else {
                    fatalError()
                }
                cell.key = item.key
                cell.titleLabel.text = item.title
                cell.switchView.setOn(SettingManager.shared.get(bool: item.key), animated: false)
                
                return cell
        }
        
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return datasource[section].title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let item = datasource[section]
        if item.section != .privacy {
            return nil
        }
        guard let index = item.childs.firstIndex(where: { $0.key == self.selectedValue }) else {
            return nil
        }
        return item.childs[index].footerLabel
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 40
    }
    
}

extension PrivacySettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section]
        if item.section == .privacy {
            self.selectedValue = item.childs[indexPath.row].key
            tableView.reloadSections(IndexSet([indexPath.section]), with: .none)
            SettingManager.shared.saveItem(key: "privacy_level", string: self.selectedValue)
        }
    }
}


