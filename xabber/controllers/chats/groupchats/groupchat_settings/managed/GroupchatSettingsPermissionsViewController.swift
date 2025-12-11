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
import DeepDiff

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
    
    
    class Datasource: DiffAware, Equatable, Hashable {
        enum Kind {
            case permission
            case button
            case member
        }
        
        var kind: Kind
        var title: String
        var value: String
        var status: Bool
        var originalStatus: Bool = false
        var changed: Bool = false
        
        var userId: String = ""
        var jid: String = ""
        var badge: String = ""
        var isMe: Bool = false
        var subtitle: String = ""
        var memberStatus: ResourceStatus = .offline
        var avatarUrl: String = ""
        var role: GroupchatUserStorageItem.Role = .member
        
        typealias DiffId = String
        
        var diffId: String {
            get {
                return userId
            }
        }
        
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.userId == rhs.userId
        }
        
        init(kind: Kind, title: String, value: String, status: Bool = false, badge: String? = nil) {
            self.userId = value
            self.kind = kind
            self.title = title
            self.value = value
            self.status = status
            self.originalStatus = status
            self.badge = badge ?? ""
        }
        
        init(forMember userId: String, jid: String, title: String, badge: String, isMe: Bool, subtitle: String, status: ResourceStatus, avatarUrl: String, role: GroupchatUserStorageItem.Role) {
            self.kind = .member
            self.value = ""
            self.status = false
            self.originalStatus = false
            
            self.userId = userId
            self.jid = jid
            self.title = title
            self.badge = badge
            self.isMe = isMe
            self.subtitle = subtitle
            self.memberStatus = status
            self.avatarUrl = avatarUrl
            self.role = role
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(self.userId)
        }
        
        static func compareContent(_ a: GroupchatMembersListViewController.Datasource, _ b: GroupchatMembersListViewController.Datasource) -> Bool {
            return a.userId == b.userId &&
            a.title == b.title &&
            a.badge == b.badge &&
            a.isMe == b.isMe &&
            a.subtitle == b.subtitle &&
            a.status == b.status &&
            a.avatarUrl == b.avatarUrl &&
            a.role == b.role
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
        view.register(CommonMemberTableCell.self, forCellReuseIdentifier: CommonMemberTableCell.cellName)
        
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
    
    internal var membersObserver: Results<GroupchatUserStorageItem>? = nil
    
    internal var canUpdateDataset: Bool = true
    
    private func runDatasetUpdateTask(firstLaunch: Bool) {
        guard let collection = self.membersObserver else {
            return
        }
        
        let out = collection.toArray()
            .filter({ $0.permissionsDiffer(then: self.defaultPermissions) })
            .compactMap {
            item in
            return Datasource(
                forMember: item.userId,
                jid: item.jid,
                title: item.nickname,
                badge: item.badge,
                isMe: item.isMe,
                subtitle: item.isOnline ? "Online".localizeString(id: "account_state_connected", arguments: []): item.dateString ?? "Offline".localizeString(id: "unavailable", arguments: []),
                status: item.isOnline ? .online : .offline,
                avatarUrl: item.avatarURI,
                role: item.role,
            )
        }
        if firstLaunch {
            let index = self.datasource.count - 1
            self.datasource[index] = out
            self.tableView.reloadData()
        } else {
            self.apply(members: out)
        }
        
    }
    
    private func apply(members newDataset: [Datasource]) {
        let index = self.datasource.count - 1
        let oldDataset = self.datasource[index]
        let changes = diff(old: oldDataset, new: newDataset)
        let indexPaths = self.convertChangeset(changes: changes)
        DispatchQueue.main.async {
            self.apply(changes: indexPaths) {
                self.datasource[index] = newDataset
            }
        }
    
    }

    private final func apply(changes: ChangesWithIndexPath, prepare: @escaping (() -> Void)) {
        if changes.deletes.isEmpty &&
            changes.inserts.isEmpty &&
            changes.moves.isEmpty &&
            changes.replaces.isEmpty {
            prepare()
            self.canUpdateDataset = true
            return
        }
        UIView.performWithoutAnimation {
            self.tableView.performBatchUpdates({
                prepare()
                if !changes.deletes.isEmpty {
                    self.tableView.deleteRows(at: changes.deletes, with: .none)
                }
                
                if !changes.inserts.isEmpty {
                    self.tableView.insertRows(at: changes.inserts, with: .none)
                }
                
                if changes.moves.isNotEmpty {
                    changes.moves.forEach {
                        (from, to) in
                        self.tableView.moveRow(at: from, to: to)
                    }
                }
            }, completion: {
                result in
                self.canUpdateDataset = true
                if changes.replaces.isEmpty { return }
                self.tableView.reloadRows(at: changes.replaces, with: .none)
            })
        }
    }
    
    private final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexPath {
        let section: Int = self.datasource.count - 1
        
        let inserts =  changes.compactMap { return $0.insert?.index }.compactMap({ return IndexPath(row:$0, section: section)})
        let deletes =  changes.compactMap { return $0.delete?.index }.compactMap({ return IndexPath(row:$0, section: section )})
        let replaces = changes.compactMap { return $0.replace?.index }.compactMap({ return IndexPath(row:$0, section: section )})
        
        let moves = changes.compactMap({ $0.move }).map({
          (
            from: IndexPath(item: $0.fromIndex, section: section),
            to: IndexPath(item: $0.toIndex, section: section)
          )
        })
        
        return ChangesWithIndexPath(
            inserts: inserts,
            deletes: deletes,
            replaces: replaces,
            moves: moves
        )
    }
    
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
        
        do {
            let realm = try WRealm.safe()
            membersObserver = realm
                    .objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@ AND isBlocked == false AND isKicked == false AND isTemporary == false AND isHidden == false", [jid, owner].prp())
                    .sorted(by: [
                        SortDescriptor(keyPath: "isMe", ascending: false),
                        SortDescriptor(keyPath: "sortedRole", ascending: true)
                    ])
            
            
            Observable
                .collection(from: membersObserver!)
                .debounce(.milliseconds(400), scheduler: MainScheduler.asyncInstance)
                .subscribe { (results) in
                    self.runDatasetUpdateTask(firstLaunch: false)
                } onError: { (error) in
                    DDLogDebug("GroupchatMembersListViewController: \(#function). RX error: \(error.localizedDescription)")
                } onCompleted: {
                    DDLogDebug("GroupchatMembersListViewController: \(#function). RX state: completed")
                } onDisposed: {
                    DDLogDebug("GroupchatMembersListViewController: \(#function). RX state: disposed")
                }
                .disposed(by: bag)

            canUpdateDataset = true
            runDatasetUpdateTask(firstLaunch: true)
            
        } catch {
            DDLogDebug("GroupchatMembersListViewController: \(#function). \(error.localizedDescription)")
        }
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
        
        var newbiesBadge: String? = nil
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                self.defaultPermissions = instance.defaultPermissions
                newbiesBadge = "\(instance.newbiesPermissions.count) / \(instance.defaultPermissions.count)"
            }
        } catch {
            DDLogDebug("GroupchatSettingsMembershipViewController: \(#function). \(error.localizedDescription)")
        }
        self.datasource = [
            self.defaultPermissions.compactMap {
                return Datasource(kind: .permission, title: $0.displayName, value: $0.name, status: $0.status)
            },
            [
                Datasource(kind: .button, title: "Permissions for new members", value: "newbies", badge: newbiesBadge)
            ],
            []
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
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.groupchat?.getDefaultPermissions(stream, groupchat: self.jid)
            session.groupchat?.getNewbiesPermissions(stream, groupchat: self.jid)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.groupchats.getDefaultPermissions(stream, groupchat: self.jid)
                user.groupchats.getNewbiesPermissions(stream, groupchat: self.jid)
            }
        }
    }
    
    internal func updateValue() {
        
    }
}

extension GroupchatSettingsPermissionsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.kind {
            case .button, .permission:
                return 52
            case .member:
                return 64
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.kind {
            case .member:
                let vc = GroupchatSettingsRestrictUserViewController()
                
                vc.userId = item.userId
                vc.jid = self.jid
                vc.owner = self.owner
                
                self.navigationController?.pushViewController(vc, animated: true)
            case .button:
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
            case .permission:
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
                
                cell.configure(title: item.title, badge: item.badge, icon: "custom.person.fill.badge.minus.square.fill")
                cell.selectionStyle = .none
                cell.accessoryType = .disclosureIndicator
                return cell
            case .member:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: CommonMemberTableCell.cellName, for: indexPath) as? CommonMemberTableCell else {
                    fatalError()
                }
                cell.configure(
                    avatarUrl: item.avatarUrl,
                    jid: item.jid,
                    owner: self.owner,
                    userId: item.userId,
                    title: item.title,
                    badge: item.badge,
                    isMe: item.isMe,
                    subtitle: item.subtitle,
                    status: item.memberStatus,
                    entity: .contact,
                    role: item.role
                )
                cell.selectionStyle = .none
                cell.accessoryType = .disclosureIndicator
                return cell
        }
    }
    
    
}

