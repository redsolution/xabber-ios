//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit
import RealmSwift
import RxCocoa
import RxSwift
import RxRealm
import DeepDiff
import CocoaLumberjack
import Kingfisher
import MaterialComponents.MDCPalettes

class GroupchatMembersListViewController: SimpleBaseViewController {
    
    class ButtonTableCell: UITableViewCell {
        static let cellName: String = "ButtonTableCell"
        
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
            
            label.textColor = .tintColor
            
            return label
        }()
        
        func configure(title: String) {
            self.titleLabel.text = title
        }
        
        func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.fillSuperview()
            self.stack.addArrangedSubview(self.titleLabel)
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
    }
    
    class Datasource: DiffAware, Equatable, Hashable {
        var userId: String
        var jid: String
        var title: String
        var badge: String
        var isMe: Bool
        var subtitle: String
        var status: ResourceStatus
        var avatarUrl: String
        var role: GroupchatUserStorageItem.Role
        var canPromote: Bool
        var canRestrict: Bool
        var canEdit: Bool
        var canKick: Bool
        
        typealias DiffId = String
        
        var diffId: String {
            get {
                return userId
            }
        }
        
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.userId == rhs.userId
        }
        
        
        init(userId: String, jid: String, title: String, badge: String, isMe: Bool, subtitle: String, status: ResourceStatus, avatarUrl: String, role: GroupchatUserStorageItem.Role, canPromote: Bool, canRestrict: Bool, canEdit: Bool, canKick: Bool) {
            self.userId = userId
            self.jid = jid
            self.title = title
            self.badge = badge
            self.isMe = isMe
            self.subtitle = subtitle
            self.status = status
            self.avatarUrl = avatarUrl
            self.role = role
            self.canPromote = canPromote
            self.canRestrict = canRestrict
            self.canEdit = canEdit
            self.canKick = canKick
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(userId)
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
    
    internal var datasource: [Datasource] = []
    
//    open var jid: String = ""
//    open var owner: String = ""
    
    internal var membersObserver: Results<GroupchatUserStorageItem>? = nil
    
//    open var showOnlyAdmins: Bool = false
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(CommonMemberTableCell.self, forCellReuseIdentifier: CommonMemberTableCell.cellName)
        view.register(ButtonTableCell.self, forCellReuseIdentifier: ButtonTableCell.cellName)
        
        return view
    }()
        
    internal let updateQueue: DispatchQueue = {
//        let queue = DispatchQueue(
//            label: "com.xabber.lastchats.updater",
//            qos: .background,
//            attributes: [],
//            autoreleaseFrequency: .never,
//            target: nil
//        )
//        return queue
        return DispatchQueue.global(qos: .background)
    }()
    
    open var permissionScope: String = "member"
    
    override func subscribe() {
        super.subscribe()
        do {
            let realm = try WRealm.safe()
            membersObserver = realm
                    .objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@ AND isBlocked == false AND isKicked == false AND isTemporary == false AND role_ IN %@ AND isHidden == false", [jid, owner].prp(), permissionScope.components(separatedBy: ","))
                    .sorted(by: [
                        SortDescriptor(keyPath: "isMe", ascending: false),
                        SortDescriptor(keyPath: "sortedRole", ascending: true)
                    ])
            
            
            Observable
                .collection(from: membersObserver!)
                .debounce(.milliseconds(400), scheduler: MainScheduler.asyncInstance)
                .subscribe { (results) in
                    self.runDatasetUpdateTask()
                } onError: { (error) in
                    DDLogDebug("GroupchatMembersListViewController: \(#function). RX error: \(error.localizedDescription)")
                } onCompleted: {
                    DDLogDebug("GroupchatMembersListViewController: \(#function). RX state: completed")
                } onDisposed: {
                    DDLogDebug("GroupchatMembersListViewController: \(#function). RX state: disposed")
                }
                .disposed(by: bag)

            canUpdateDataset = true
            runDatasetUpdateTask()
            
        } catch {
            DDLogDebug("GroupchatMembersListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }
    
    internal var isPromoteAdmin: Bool = false
    
    public final func configurePromoteAdmin() {
        self.isPromoteAdmin = true
    }
    
    override func configure() {
        super.configure()
        tableView.delegate = self
        tableView.dataSource = self
        if self.permissionScope == "member" {
            title = "Members".localizeString(id: "group_settings__members_list__header", arguments: [])
        } else if self.permissionScope == "owner,admin" {
            title = "Administrators"
        } else if self.isPromoteAdmin {
            title = "Select user"
        } else if self.permissionScope == "restrited" {
            title = "Restricted users"
        } else {
            title = nil
        }
    }
    
    override func onAppear() {
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
    }
    
    var canPromote: Bool = true
    var canRestrict: Bool = true
    var canEdit: Bool = true
    var canKick: Bool = true
    
    private final func mapDataset() -> [Datasource] {
        guard let collection = membersObserver else {
            return []
        }
        return collection.compactMap {
            item in
            
            let canPromote: Bool = !item.isMe && self.canPromote
            let canRestrict: Bool = !item.isMe && self.canRestrict
            let canEdit: Bool = !item.isMe && self.canEdit
            let canKick: Bool = !item.isMe && self.canKick
            
            return Datasource(
                userId: item.userId,
                jid: item.jid,
                title: item.nickname,
                badge: item.badge,
                isMe: item.isMe,
                subtitle: item.isOnline ? "Online".localizeString(id: "account_state_connected", arguments: []): item.dateString ?? "Offline".localizeString(id: "unavailable", arguments: []),
                status: item.isOnline ? .online : .offline,
                avatarUrl: item.avatarURI,
                role: item.role,
                canPromote: canPromote,
                canRestrict: canRestrict,
                canEdit: canEdit,
                canKick: canKick
            )
        }
    }
    
    public final var canUpdateDataset = true
    
    
    private final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexPath {
        let section: Int = self.permissionScope == "owner,admin" ? 1 : 0
        
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
    
    public final func initializeDataset() {
        
    }
    
    public final func runDatasetUpdateTask() {
        preprocessDataset()
        postprocessDataset()
    }
    
    private final func preprocessDataset() {
        if !canUpdateDataset { return }
        self.updateQueue.sync {
            self.canUpdateDataset = false
            let newDataset = self.mapDataset()
            let changes = diff(old: self.datasource, new: newDataset)
            let indexPaths = self.convertChangeset(changes: changes)
            DispatchQueue.main.async {
                self.apply(changes: indexPaths) {
                    self.datasource = newDataset
                }
            }
        }
    }
    
    private final func postprocessDataset() {
        
    }
    
    private final func apply(changes: ChangesWithIndexPath, prepare: @escaping (() -> Void)) {
        
//        print("changes", changes.deletes.count, changes.inserts.count, changes.moves.count, changes.replaces.count)
        
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
    
    
}

extension GroupchatMembersListViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        if self.isPromoteAdmin {
            return 1
        }
        if self.permissionScope == "member" {
            return 1
        } else if self.permissionScope == "owner,admin" {
            return 2
        } else {
            return 1
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if self.isPromoteAdmin {
            return datasource.count
        }
        if self.permissionScope == "owner,admin" {
            if section == 0 {
                return 1
            } else {
                return datasource.count
            }
        } else {
            return datasource.count
        }
        
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 && self.permissionScope == "owner,admin" {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableCell.cellName, for: indexPath) as? ButtonTableCell else {
                fatalError()
            }
            
            cell.configure(title: "Add Administrator")
            cell.selectionStyle = .none
            
            return cell
        } else {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: CommonMemberTableCell.cellName, for: indexPath) as? CommonMemberTableCell else {
                fatalError()
            }
            let item = datasource[indexPath.row]
            
            cell.configure(
                avatarUrl: item.avatarUrl,
                jid: self.jid,
                owner: self.owner,
                userId: item.userId,
                title: item.title,
                badge: item.badge,
                isMe: item.isMe,
                subtitle: item.subtitle,
                status: item.status,
                entity: .contact,
                role: item.role
            )
            return cell
        }
        
    }
    
    
}

extension GroupchatMembersListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section == 0 && self.permissionScope == "owner,admin" {
            return 52
        }
        return 64
    }
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 0
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.row]
        if self.isPromoteAdmin {
            let vc = GroupchatSettingsPromoteAdminViewController()
            
            vc.userId = item.userId
            vc.jid = self.jid
            vc.owner = self.owner
            
            self.navigationController?.pushViewController(vc, animated: true)
            return
        }
        if indexPath.section == 0 && self.permissionScope == "owner,admin" {
            self.onAddAdmin()
            return
        }
        if self.permissionScope == "owner,admin" {
            let vc = GroupchatSettingsPromoteAdminViewController()
            
            vc.userId = item.userId
            vc.jid = self.jid
            vc.owner = self.owner
            
            self.navigationController?.pushViewController(vc, animated: true)
            return
        }
        if item.jid.isNotEmpty {
            let vc = ContactInfoViewController()
            vc.owner = self.owner
            vc.jid = item.jid
            vc.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
            self.navigationController?.pushViewController(vc, animated: true)
            return
        } else {
            let vc = GroupchatContactInfoViewController()
            vc.owner = self.owner
            vc.jid = self.jid
            vc.userId = item.userId
            
            navigationController?.pushViewController(vc, animated: true)
            return
        }
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        if self.isPromoteAdmin {
            return nil
        }
        let index = indexPath.row
        let item = self.datasource[index]
        
        let infoAction = UIContextualAction(style: .destructive, title: "Information") { action, view, handler in
            let item = self.datasource[index]
            self.onInfoUser(userId: item.userId)
            handler(true)
        }
        
        infoAction.image = imageLiteral("person.fill")
        infoAction.backgroundColor = .systemBlue
        
        let kickAction = UIContextualAction(style: .destructive, title: "Kick") { action, view, handler in
            let item = self.datasource[index]
            self.onKickUser(userId: item.userId)
            handler(true)
        }
        
        kickAction.image = imageLiteral("person.fill.xmark")
        kickAction.backgroundColor = .systemRed
        
        let restrictAction = UIContextualAction(style: .normal, title: "Restrict") { action, view, handler in
            let item = self.datasource[index]
            self.onRestrictUser(userId: item.userId)
            handler(true)
        }
        
        restrictAction.image = imageLiteral("person.badge.key.fill")
        restrictAction.backgroundColor = .systemYellow
        
        let promoteAction = UIContextualAction(style: .normal, title: "Promote") { action, view, handler in
            let item = self.datasource[index]
            self.onPromoteUser(userId: item.userId)
            handler(true)
        }
        
        promoteAction.image = imageLiteral("xabber.person.star.fill")
        promoteAction.backgroundColor = .systemBlue
        
        var actions: [UIContextualAction] = []
        
        if item.isMe {
            actions.append(infoAction)
        } else {
            if item.canKick {
                actions.append(kickAction)
            }
            if item.canRestrict {
                if item.role == .member || item.role == .custom {
                    actions.append(restrictAction)
                }
            }
            if item.canPromote {
                actions.append(promoteAction)
            }
        }
        
        let conf = UISwipeActionsConfiguration(actions: actions)
        conf.performsFirstActionWithFullSwipe = true
        return conf
    }
    
    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        if self.isPromoteAdmin {
            return nil
        }
        let item = self.datasource[indexPath.row]
        let index = indexPath.row
        let directChat = UIContextualAction(style: .normal, title: "Chat") { action, view, handler in
            let item = self.datasource[index]
            self.onDirectChat(jid: item.jid)
            handler(true)
        }
        
        directChat.image = imageLiteral("custom.person.bubble.left.fill")
        directChat.backgroundColor = AccountColorManager.shared.palette(for: self.owner).tint700
        
        let privateChat = UIContextualAction(style: .normal, title: "Chat") { action, view, handler in
            let item = self.datasource[index]
            self.onPrivateChat(userId: item.userId)
            handler(true)
        }
        
        privateChat.image = imageLiteral("xabber.incognito.fill.bubble.left.fill")
        privateChat.backgroundColor = AccountColorManager.shared.palette(for: self.owner).tint700
        
        let messagesFilterAction = UIContextualAction(style: .normal, title: "Messages") { action, view, handler in
            let item = self.datasource[index]
            self.onShowMessages(userId: item.userId)
            handler(true)
        }
        
        messagesFilterAction.image = imageLiteral("bubble.left.and.bubble.right.fill")
        messagesFilterAction.backgroundColor = .systemBlue
        
        let editUserAction = UIContextualAction(style: .normal, title: "Edit") { action, view, handler in
            let item = self.datasource[index]
            self.onEditUser(userId: item.userId)
            handler(true)
        }
        
        editUserAction.image = imageLiteral("pencil")
        editUserAction.backgroundColor = .systemOrange
        
        var actions: [UIContextualAction] = []
        if !item.isMe {
            if item.jid.isEmpty {
                actions.append(privateChat)
            } else {
                actions.append(directChat)
            }
        }
        actions.append(messagesFilterAction)
        if item.canEdit {
            actions.append(editUserAction)
        }
        
        let conf = UISwipeActionsConfiguration(actions: [directChat, messagesFilterAction, editUserAction])
        conf.performsFirstActionWithFullSwipe = true
        return conf
    }
}

extension GroupchatMembersListViewController {
    private func onDirectChat(jid: String) {
        
    }
    
    private func onPrivateChat(userId: String) {
        
    }
    
    private func onShowMessages(userId: String) {
        
    }
    
    private func onEditUser(userId: String) {
        
    }
    
    private func onKickUser(userId: String) {
        
    }
    
    private func onRestrictUser(userId: String) {
        let vc = GroupchatSettingsRestrictUserViewController()
        
        vc.userId = userId
        vc.jid = self.jid
        vc.owner = self.owner
        
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    private func onPromoteUser(userId: String) {
        let vc = GroupchatSettingsPromoteAdminViewController()
        
        vc.userId = userId
        vc.jid = self.jid
        vc.owner = self.owner
        
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    private func onInfoUser(userId: String) {
        
    }
    
    private func onAddAdmin() {
        let vc = GroupchatMembersListViewController()
        
        vc.permissionScope = "member"
        vc.jid = self.jid
        vc.owner = self.owner
        vc.configurePromoteAdmin()
        
        self.navigationController?.pushViewController(vc, animated: true)
    }
}
