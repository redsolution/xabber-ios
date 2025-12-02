//
//  GroupchatSettingsMembershipViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 27.10.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import Realm
import RealmSwift
import MaterialComponents.MDCPalettes
import CocoaLumberjack

class GroupchatSettingsMembershipViewController: SimpleBaseViewController {
    
    
    class SettingsItemCell: UITableViewCell {
        static let cellName: String = "SettingsItemCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 0, left: 16, right: 16)
            stack.isLayoutMarginsRelativeArrangement = true
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        let badgeView: UIButton = {
            let view = UIButton()

            return view
        }()
        
        func configure(title: String) {
            self.titleLabel.text = title
        }
        
        func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 4, right: 4)
            self.stack.addArrangedSubview(self.titleLabel)
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setupSubviews()
        }
    }
    
    
    class Datasource {
        var title: String
        var value: String
        
        init(title: String, value: String) {
            self.title = title
            self.value = value
        }
    }
    
    internal var datasource: [[Datasource]] = []
    
    internal var currentValue: String = ""
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(SettingsItemCell.self, forCellReuseIdentifier: SettingsItemCell.cellName)
        
        return view
    }()
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                self.currentValue = instance.membership_
            }
        } catch {
            DDLogDebug("GroupchatSettingsMembershipViewController: \(#function). \(error.localizedDescription)")
        }
        self.datasource = [
            [
                Datasource(title: GroupChatStorageItem.Membership.open.localized!, value: GroupChatStorageItem.Membership.open.rawValue),
                Datasource(title: GroupChatStorageItem.Membership.memberOnly.localized!, value: GroupChatStorageItem.Membership.memberOnly.rawValue),
            ]
        ]
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperview()
    }
    
    override func configure() {
        super.configure()
        self.title = "Membership"
        self.tableView.dataSource = self
        self.tableView.delegate = self
    }
    override func onAppear() {
        super.onAppear()
    }
    
    internal func updateValue() {
        
    }
}

extension GroupchatSettingsMembershipViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 52
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = self.datasource[indexPath.section][indexPath.row]
        self.currentValue = item.value
        self.datasource[0].enumerated().forEach {
            (index, item) in
            if index == indexPath.row {
                self.tableView.cellForRow(at: IndexPath(row: index, section: 0))?.accessoryType = .checkmark
            } else {
                self.tableView.cellForRow(at: IndexPath(row: index, section: 0))?.accessoryType = .none
            }
        }
        
        let data: [[String: Any]] = [
            ["type": "hidden", "var": "'FORM_TYPE'", "value": "https://xabber.com/protocol/groups"],
            ["var": "membership", "value": item.value],
        ]

        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            _ = session.groupchat?.updateForm(stream, formType: .settings, groupchat: self.jid, userData: data) { error in
                do {
                    let realm = try WRealm.safe()
                    if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                        try realm.write {
                            instance.membership_ = item.value
                        }
                    }
                } catch {
                    DDLogDebug("")
                }
                DispatchQueue.main.async {
                    if let error {
                        ToastPresenter().presentError(message: "Error: \(error)")
                    } else {
                        ToastPresenter().presentSuccess(message: "Membership updated")
                    }
                }
            }
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                _ = user.groupchats.updateForm(stream, formType: .settings, groupchat: self.jid, userData: data) { error in
                    do {
                        let realm = try WRealm.safe()
                        if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                            try realm.write {
                                instance.membership_ = item.value
                            }
                        }
                    } catch {
                        DDLogDebug("")
                    }
                    DispatchQueue.main.async {
                        if let error {
                            ToastPresenter().presentError(message: "Error: \(error)")
                        } else {
                            ToastPresenter().presentSuccess(message: "Membership updated")
                        }
                    }
                }
            }
        }

    }
}

extension GroupchatSettingsMembershipViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return "Select membership type for this group. Groups with open membership can be joined by any user, unless they are blocked.\n\nTo fight spam, consider setting some default restrictions which are applied to newly joined users."
    }
    
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.section][indexPath.row]
        guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsItemCell.cellName, for: indexPath) as? SettingsItemCell else {
            fatalError()
        }
        
        cell.configure(title: item.title)
        cell.selectionStyle = .none
        if item.value == self.currentValue {
            cell.accessoryType = .checkmark
        } else {
            cell.accessoryType = .none
        }
        return cell
    }
    
    
}

