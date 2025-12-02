//
//  GroupchatSettingsPermissionsViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 29.10.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import Realm
import RealmSwift
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import RxSwift
import RxCocoa
import RxRelay

class GroupchatSettingsPermissionsViewController: SimpleBaseViewController {
    
    
    class SettingsSwitchCell: UITableViewCell {
        static let cellName: String = "SettingsSwitchCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            stack.spacing = 4
            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 0, left: 16, right: 16)
            stack.isLayoutMarginsRelativeArrangement = true
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            return label
        }()
                
        let switchView: UISwitch = {
            let view = UISwitch()
            
            view.isOn = false
            view.tintColor = .green
            view.preferredStyle = .sliding
            
            return view
        }()
        
        
        var key: String = ""
        var originalStatus: Bool = false
        
        func configure(title: String, isOn: Bool, key: String, isChanged: Bool, originalStatus: Bool) {
            self.titleLabel.text = title
            self.switchView.isOn = isOn
            self.key = key
            self.originalStatus = originalStatus
            if originalStatus != isOn {
                self.switchView.backgroundColor = .systemGreen
                self.switchView.onTintColor = .systemGreen
            } else {
                self.switchView.backgroundColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
                self.switchView.onTintColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
            }
        }
        
        open var onSwitchValueChangedCallback: ((String, Bool) -> Void)? = nil
        
        @objc
        func onChangeSwitchValue(_ sender: UISwitch) {
//            print()
            UIView.animate(withDuration: 0.33) {
                if self.originalStatus != sender.isOn {
                    self.switchView.backgroundColor = .systemGreen
                    self.switchView.onTintColor = .systemGreen
                } else {
                    self.switchView.backgroundColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
                    self.switchView.onTintColor = MDCPalette.green.tint100//.systemGreen.withAlphaComponent(0.2)
                }
            }
            self.onSwitchValueChangedCallback?(self.key, sender.isOn)
        }
        
        func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 4, right: 4)
            self.stack.addArrangedSubview(self.titleLabel)
            self.stack.addArrangedSubview(self.switchView)
            self.switchView.backgroundColor = .red
            self.switchView.layer.cornerRadius = self.switchView.bounds.height / 2
            self.switchView.layer.masksToBounds = true
            self.switchView.addTarget(self, action: #selector(onChangeSwitchValue), for: .valueChanged)
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setupSubviews()
        }
        
        open var onCustomPeriodCallback: ((String) -> Void)? = nil
        
        @objc
        private func onCustomPeriodButtonTouchUpInside(_ sender: UIButton) {
            self.onCustomPeriodCallback?(self.key)
        }
    }
    
    
    class Datasource {
        enum Kind {
            case permission
            case button
        }
        
        var kind: Kind
        var title: String
        var value: String
        var status: Bool
        var originalStatus: Bool = false
        var changed: Bool = false
        
        init(kind: Kind, title: String, value: String, status: Bool = false) {
            self.kind = kind
            self.title = title
            self.value = value
            self.status = status
            self.originalStatus = status
        }
    }
    
    internal var datasource: [[Datasource]] = []
    
    internal var currentValue: String = ""
    
    internal var defaultPermissions: [GroupchatPermission] = []
    
    internal var changesObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(SettingsSwitchCell.self, forCellReuseIdentifier: SettingsSwitchCell.cellName)
        view.register(GroupchatSettingsViewControllerT.SettingsItemCell.self, forCellReuseIdentifier: GroupchatSettingsViewControllerT.SettingsItemCell.cellName)
        
        return view
    }()
    
    internal let saveBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(systemItem: .save)
        
        return button
    }()
    
    internal var cancelBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(systemItem: .cancel)
        
        return button
    }()
    
    override func subscribe() {
        super.subscribe()
        self.changesObserver
            .asObservable()
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .subscribe { value in
                if value {
                    self.navigationItem.setLeftBarButton(self.cancelBarButton, animated: true)
                    self.navigationItem.setRightBarButton(self.saveBarButton, animated: true)
                } else {
                    self.navigationItem.setLeftBarButton(self.navigationItem.backBarButtonItem, animated: true)
                    self.navigationItem.setRightBarButton(nil, animated: true)
                }
            }
            .disposed(by: self.bag)

    }
    
    @objc
    internal func onCancelButtonTouchUpInside(_ sender: AnyObject) {
        self.navigationController?.popViewController(animated: true)
    }
        
    @objc
    internal func onSaveButtonTouchUpInside(_ sender: AnyObject) {
        let changes = self.datasource[0].filter({ $0.changed }).compactMap({
            return GroupchatPermission(role: "member", name: $0.value, status: $0.status, displayName: $0.title, expires: nil)
        })
        guard changes.isNotEmpty else {
            return
        }
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.groupchat?.updateDefaultPermissions(stream, groupchat: self.jid, changes: changes)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.groupchats.updateDefaultPermissions(stream, groupchat: self.jid, changes: changes)
            }
        }
        ToastPresenter().presentSuccess(message: "Chages saved")
        self.navigationController?.popViewController(animated: true)
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                self.defaultPermissions = instance.defaultPermissions
            }
        } catch {
            DDLogDebug("GroupchatSettingsMembershipViewController: \(#function). \(error.localizedDescription)")
        }
        self.datasource = [
            self.defaultPermissions.compactMap {
                return Datasource(kind: .permission, title: $0.displayName, value: $0.name, status: $0.status)
            },
            [
                Datasource(kind: .button, title: "Permissions for new members", value: "newbies")
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
        self.title = "Permissions"
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.cancelBarButton.action = #selector(onCancelButtonTouchUpInside)
        self.cancelBarButton.target = self
        self.saveBarButton.action = #selector(onSaveButtonTouchUpInside)
        self.saveBarButton.target = self
    }
    override func onAppear() {
        super.onAppear()
    }
    
    internal func updateValue() {
        
    }
}

extension GroupchatSettingsPermissionsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 52
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.value {
            case "newbies":
                let vc = GroupchatSettingsNewbiesPermissionsViewController()
                
                vc.jid = self.jid
                vc.owner = self.owner
                vc.defaultPermissions = defaultPermissions
                
                self.navigationController?.pushViewController(vc, animated: true)
            default:
                break
        }
    }
}

extension GroupchatSettingsPermissionsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section{
            case 0:
                return "Default permissions are applied to newly joined group members. This is a way to control spam and unpredictable behaviour by newcomers. Note that group admins can apply more severe restrictions on any group member."
            case 1:
                return "Secure your group with these settings. Changes apply instantly to protect your chats."
            default:
                return nil
        }
        
    }
    
    func onSwitchValueChangedCallback(key: String, value: Bool) {
        guard let index = self.datasource[0].firstIndex(where: { $0.value == key }) else {
            return
        }
        self.datasource[0][index].status = value
        if self.datasource[0][index].originalStatus != value {
            self.datasource[0][index].changed = true
            let item = self.datasource[0][index]
        } else {
            self.datasource[0][index].changed = false
        }
        self.changesObserver.accept(self.datasource[0].filter({ $0.changed }).isNotEmpty)
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.kind {
            case .permission:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsSwitchCell.cellName, for: indexPath) as? SettingsSwitchCell else {
                    fatalError()
                }
                
                cell.configure(title: item.title, isOn: item.status, key: item.value, isChanged: item.changed, originalStatus: item.originalStatus)
                cell.onSwitchValueChangedCallback = self.onSwitchValueChangedCallback
                cell.selectionStyle = .none
                cell.accessoryType = .none
                return cell
            case .button:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: GroupchatSettingsViewControllerT.SettingsItemCell.cellName, for: indexPath) as? GroupchatSettingsViewControllerT.SettingsItemCell else {
                    fatalError()
                }
                
                cell.configure(title: item.title, badge: "", icon: "custom.person.fill.badge.minus.square.fill")
                cell.selectionStyle = .none
                cell.accessoryType = .disclosureIndicator
                return cell
        }
    }
    
    
}

