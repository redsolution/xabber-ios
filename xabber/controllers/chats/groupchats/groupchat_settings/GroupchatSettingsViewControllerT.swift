//
//  GroupchatSettingsViewControllerT.swift
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

class GroupchatSettingsViewControllerT: SimpleBaseViewController {
    
    class HeaderView: UIView {
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.spacing = 4
            stack.alignment = .center
            stack.distribution = .fill
            
            return stack
        }()
        
        internal let imageButton: RoundedAvatarButton = {
            let button = RoundedAvatarButton(frame: CGRect(square: 128),
                                             avatarMaskResourceName: AccountMasksManager.shared.mask128pt)
            button.layer.masksToBounds = true
            button.contentVerticalAlignment = .center
            button.contentHorizontalAlignment = .center
            button.imageView?.contentMode = .scaleAspectFit
            button.contentMode = .scaleAspectFit
            button.backgroundColor = .secondarySystemBackground
            
            return button
        }()
        
        internal let actionButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.title = "Set new photo"
            conf.baseForegroundColor = .tintColor
            conf.buttonSize = .medium
            
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal func activateConstraints() {
            self.stack.fillSuperview()
            NSLayoutConstraint.activate([
                imageButton.heightAnchor.constraint(equalToConstant: 128),
                imageButton.widthAnchor.constraint(equalToConstant: 128),
                actionButton.heightAnchor.constraint(equalToConstant: 44),
                actionButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        
        internal func setupSubviews() {
            self.addSubview(stack)
            self.stack.addArrangedSubview(self.imageButton)
            self.stack.addArrangedSubview(self.actionButton)
            self.activateConstraints()
        }
        
        internal var currentUrl: String? = nil
        
        internal func configure(avatarUrl: String?, username: String, jid: String, owner: String) {
            if currentUrl != avatarUrl {
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 128) { image in
                    if let image = image {
                        self.imageButton.setImage(image, for: .normal)
                        self.currentUrl = avatarUrl
                    } else {
                        self.imageButton.setImage(UIImageView.getDefaultAvatar(for: username, owner: owner, size: 128), for: .normal)
                    }
                }
            }
            
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setupSubviews()
        }
    }
    
    class SettingsTableHeaderCell: UITableViewCell {
        static let cellName: String = "SettingsTableHeaderCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.spacing = 4
            stack.alignment = .center
            stack.distribution = .fill
            
            return stack
        }()
        
        internal let imageButton: RoundedAvatarButton = {
            let button = RoundedAvatarButton(frame: CGRect(square: 128),
                                             avatarMaskResourceName: AccountMasksManager.shared.mask128pt)
            button.layer.masksToBounds = true
            button.contentVerticalAlignment = .center
            button.contentHorizontalAlignment = .center
            button.imageView?.contentMode = .scaleAspectFit
            button.contentMode = .scaleAspectFit
            button.backgroundColor = .secondarySystemBackground
            
            return button
        }()
        
        internal let actionButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.title = "Set new photo"
            conf.baseForegroundColor = .tintColor
            conf.buttonSize = .medium
            
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal func activateConstraints() {
            self.stack.fillSuperview()
            NSLayoutConstraint.activate([
                imageButton.heightAnchor.constraint(equalToConstant: 128),
                imageButton.widthAnchor.constraint(equalToConstant: 128),
                actionButton.heightAnchor.constraint(equalToConstant: 44),
                actionButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        
        internal func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.addArrangedSubview(self.imageButton)
            self.stack.addArrangedSubview(self.actionButton)
            self.activateConstraints()
        }
        
        internal var currentUrl: String? = nil
        
        internal func configure(avatarUrl: String?, username: String, jid: String, owner: String) {
            if currentUrl != avatarUrl {
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 128) { image in
                    if let image = image {
                        self.imageButton.setImage(image, for: .normal)
                        self.currentUrl = avatarUrl
                    } else {
                        self.imageButton.setImage(UIImageView.getDefaultAvatar(for: username, owner: owner, size: 128), for: .normal)
                    }
                }
            }
            
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupSubviews()
        }
    }
    
    class SettingsTextFieldCell: UITableViewCell {
        static let cellName: String = "SettingsTextFieldCell"
        
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
            
            return stack
        }()
        
        var field: UITextField = {
            let field = UITextField()
            
            field.autocorrectionType = .default
            field.clearButtonMode = .never
            field.autocapitalizationType = .sentences
            field.spellCheckingType = .yes
            field.keyboardType = .default
            field.returnKeyType = .done
            
            return field
        }()
        
        var callback: ((UITextField) -> Void)? = nil
        
        private func activateConstraints() {
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.95).isActive = true
        }
        
        func configure(_ title: String, value: String) {
            field.text = value.isEmpty ? nil : value
            field.placeholder = title
            field.clearButtonMode = .always
            field.addTarget(self, action: #selector(fieldDidChange), for: .editingChanged)
        }
        
        private func setupSubviews() {
            contentView.addSubview(stack)
            selectionStyle = .none
            stack.fillSuperview()
            stack.addArrangedSubview(field)
            backgroundColor = .systemBackground
            activateConstraints()
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            setupSubviews()
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
        
        @objc
        internal func fieldDidChange(_ sender: UITextField) {
            callback?(sender)
        }
    }
    
    class SettingsMultilineTextFieldCell: UITableViewCell {
        static let cellName: String = "SettingsMultilineTextFieldCell"
    }
    
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
        
        func configure(title: String, badge: String, icon: String) {
            self.titleLabel.text = title
            self.imageView?.image = (UIImage(named: icon) ?? UIImage(systemName: icon))?.withRenderingMode(.alwaysTemplate)
            self.badgeView.setTitle(badge, for: .normal)
            self.badgeView.isHidden = false/*badge == "0" ? true : false*/
            var configuration = UIButton.Configuration.filled()
            configuration.title = badge
            configuration.baseBackgroundColor = .clear
            configuration.baseForegroundColor = .secondaryLabel
            configuration.buttonSize = .mini
            configuration.cornerStyle = .capsule
            self.badgeView.configuration = configuration
            self.badgeView.updateConfiguration()
            self.badgeView.setNeedsLayout()
            self.badgeView.layoutIfNeeded()
        }
        
        func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 56, right: 4)
            self.stack.addArrangedSubview(self.titleLabel)
            self.stack.addArrangedSubview(self.badgeView)
            self.accessoryType = .disclosureIndicator
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setupSubviews()
        }
        
        public final func updateTimer(day: Int?, hour: Int?, mins: Int?) {
            var customString = ""
            if let value = day, value > 0 {
                customString += "\(value)d "
            } else if let value = hour, value > 0 {
                customString += "\(value)h "
            } else if let value = mins, value > 0 {
                customString += "\(value)m"
            }
            
            var conf = UIButton.Configuration.plain()
            conf.attributedTitle = AttributedString(NSAttributedString(string: customString, attributes: [
                .font: UIFont.systemFont(ofSize: 13)
            ]))
            self.badgeView.configuration = conf
            self.badgeView.updateConfiguration()
            self.badgeView.sizeToFit()
            self.stack.layoutSubviews()
        }
        
    }
    
    class SettingsDeleteButtonCell: UITableViewCell {
        static let cellName: String = "SettingsDeleteButtonCell"
        
        internal let titleLabel: UILabel = {
            let label = UILabel(frame: .zero)
            
            label.textColor = .systemRed
            label.textAlignment = .center
            
            return label
        }()
        
        internal func activateConstraints() {
            titleLabel.fillSuperview()
        }
        
        internal func setupSubviews() {
            self.contentView.addSubview(titleLabel)
            activateConstraints()
        }
        
        internal func configure(title: String) {
            self.titleLabel.text = title
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupSubviews()
        }
    }
    
    class Datasource {
        enum Kind {
            case header
            case textField
            case multilineTextField
            case item
            case delete
        }
        
        var kind: Kind
        var title: String
        var subtitle: String?
        var icon: String?
        var key: String
        var value: String
        
        init(kind: Kind, title: String, subtitle: String? = nil, icon: String? = nil, key: String, value: String) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.key = key
            self.value = value
        }
        
    }
    
    internal var datasource: [[Datasource]] = []
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(SettingsTableHeaderCell.self, forCellReuseIdentifier: SettingsTableHeaderCell.cellName)
        view.register(SettingsDeleteButtonCell.self, forCellReuseIdentifier: SettingsDeleteButtonCell.cellName)
        view.register(SettingsItemCell.self, forCellReuseIdentifier: SettingsItemCell.cellName)
        view.register(SettingsTextFieldCell.self, forCellReuseIdentifier: SettingsTextFieldCell.cellName)
        view.register(SettingsMultilineTextFieldCell.self, forCellReuseIdentifier: SettingsMultilineTextFieldCell.cellName)
        
        return view
    }()
    
    internal let headerView: HeaderView = {
        let view = HeaderView(frame: CGRect(x: 0, y: -44, width: .zero, height: 176))
        
        return view
    }()
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            let members = realm.objects(GroupchatUserStorageItem.self).filter("owner == %@ AND groupchatId == %@ AND role_ == %@ AND isBlocked == false AND isKicked == false AND isTemporary == false", self.owner, [self.jid, self.owner].prp(), GroupchatUserStorageItem.Role.member.rawValue)
            let admins = realm.objects(GroupchatUserStorageItem.self).filter("owner == %@ AND groupchatId == %@ AND (role_ == %@ OR role_ == %@) AND isBlocked == false AND isKicked == false AND isTemporary == false", self.owner, [self.jid, self.owner].prp(), GroupchatUserStorageItem.Role.admin.rawValue, GroupchatUserStorageItem.Role.owner.rawValue)
            if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                self.datasource = [
                    [
                        Datasource(kind: .textField, title: "Name", key: "nickname", value: instance.name),
                        Datasource(kind: .multilineTextField, title: "Description", key: "nickname", value: instance.descr)
                    ],
                    [
                        Datasource(kind: .item, title: "Group type", subtitle: nil, icon: "custom.person.2.square.fill", key: "membership", value: instance.membership.localized ?? ""),
                    ],
                    [
                        Datasource(kind: .item, title: "Permissions", subtitle: nil, icon: "custom.key.square.fill", key: "permissions", value: "\(self.permissionsList.filter({ $0.status}).count) / \(self.permissionsList.count)"),
//                        Datasource(kind: .item, title: "Members", subtitle: nil, icon: "custom.person.3.square.fill", key: "members", value: "\(members.count)"),
                        Datasource(kind: .item, title: "Administrators", subtitle: nil, icon: "star.square.fill", key: "admins", value: "\(admins.count)"),
                        Datasource(kind: .item, title: "Restricted users", subtitle: nil, icon: "custom.exclamationmark.octagon.square.fill", key: "restrited", value: "")
                    ],
                    [
                        Datasource(kind: .delete, title: "Delete  group", subtitle: nil, icon: nil, key: "delete", value: "")
                    ]
                ]
            }
        } catch {
            DDLogDebug("GroupchatSettingsViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperviewWithOffset(top: -24, bottom: 0, left: 0, right: 0)
        self.tableView.tableHeaderView = self.headerView
        NSLayoutConstraint.activate([
            self.headerView.widthAnchor.constraint(equalTo: self.tableView.widthAnchor),
            self.headerView.heightAnchor.constraint(equalToConstant: 176)
        ])
    }
    
    override func configure() {
        super.configure()
        self.tableView.dataSource = self
        self.tableView.delegate = self
    }
    
    var defaultPermissionsElementId: String? = nil
    var permissionsList: [GroupchatPermission] = []
    
    override func onAppear() {
        super.onAppear()
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                self.headerView.configure(avatarUrl: instance.avatarUrl, username: instance.displayName, jid: self.jid, owner: self.owner)
            }
        } catch {
            DDLogDebug("GroupchatSettingsViewController: \(#function). \(error.localizedDescription)")
        }
        
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.groupchat?.rightsDelegate = self
            self.defaultPermissionsElementId = session.groupchat?.getDefaultRights(stream, groupchat: self.jid)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.groupchats.rightsDelegate = self
                self.defaultPermissionsElementId = user.groupchats.getDefaultRights(stream, groupchat: self.jid)
            }
        }
    }
}

extension GroupchatSettingsViewControllerT: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.kind {
            case .header:
                return 176
            default:
                return 52
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.key {
            case "membership":
                let vc = GroupchatSettingsMembershipViewController()
                
                vc.jid = self.jid
                vc.owner = self.owner
                
                self.navigationController?.pushViewController(vc, animated: true)
            case "permissions":
                let vc = GroupchatSettingsPermissionsViewController()
                
                vc.jid = self.jid
                vc.owner = self.owner
                vc.defaultPermissions = permissionsList
                
                self.navigationController?.pushViewController(vc, animated: true)
            case "members":
                let vc = GroupchatMembersListViewController()
                
                vc.jid = self.jid
                vc.owner = self.owner
                
                self.navigationController?.pushViewController(vc, animated: true)
            case "admins":
                let vc = GroupchatMembersListViewController()
                
                vc.jid = self.jid
                vc.owner = self.owner
                
                self.navigationController?.pushViewController(vc, animated: true)
            default:
                break
        }
    }
}

extension GroupchatSettingsViewControllerT: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.kind {
            case .header:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsTableHeaderCell.cellName, for: indexPath) as? SettingsTableHeaderCell else {
                    fatalError()
                }
                
                cell.configure(avatarUrl: item.icon, username: item.title, jid: self.jid, owner: self.owner)
                cell.selectionStyle = .none
                
                return cell
            case .textField:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsTextFieldCell.cellName, for: indexPath) as? SettingsTextFieldCell else {
                    fatalError()
                }
                
                cell.configure(item.title, value: item.value)
                cell.selectionStyle = .none
                
                return cell
            case .multilineTextField:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsTextFieldCell.cellName, for: indexPath) as? SettingsTextFieldCell else {
                    fatalError()
                }
                
                cell.configure(item.title, value: item.value)
                cell.selectionStyle = .none
                
                return cell
            case .item:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsItemCell.cellName, for: indexPath) as? SettingsItemCell else {
                    fatalError()
                }
                
                cell.configure(title: item.title, badge: item.value, icon: item.icon ?? "settings")
                cell.selectionStyle = .none
                
                return cell
            case .delete:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsDeleteButtonCell.cellName, for: indexPath) as? SettingsDeleteButtonCell else {
                    fatalError()
                }
                
                cell.configure(title: item.title)
                
                return cell
        }
    }
    
    
}


extension GroupchatSettingsViewControllerT: GroupchatPermissionsDelegate {
    func groupchatPermissionsList(default permissions: [GroupchatPermission], elementId: String) {
        self.permissionsList = permissions
        DispatchQueue.main.async {
            guard let index = self.datasource[2].firstIndex(where: { $0.key == "permissions" }) else {
                return
            }
            self.datasource[2][index].value = "\(permissions.filter({ $0.status}).count) / \(permissions.count)"
            self.tableView.reconfigureRows(at: [IndexPath(row: index, section: 2)])
        }
    }
    
    func groupchatPermissionsList(user userId: String, permissions: [GroupchatPermission], elementId: String) {
        
    }
}
