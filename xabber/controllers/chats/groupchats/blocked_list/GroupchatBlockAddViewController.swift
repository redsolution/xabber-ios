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

class GroupchatBlockAddViewController: SimpleBaseViewController {
    
    class Datasource: DiffAware, Equatable, Hashable {
        var userId: String
        var jid: String
        var title: String
        var subtitle: String
        var avatarUrl: String?
        
        typealias DiffId = String
        
        var diffId: String {
            get {
                return userId
            }
        }
        
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.jid == rhs.jid
        }
        
        
        init(userId: String, jid: String, title: String, subtitle: String, avatarUrl: String?) {
            self.userId = userId
            self.jid = jid
            self.title = title
            self.subtitle = subtitle
            self.avatarUrl = avatarUrl
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(jid)
        }
        
        static func compareContent(_ a: Datasource, _ b: Datasource) -> Bool {
            return a.userId == b.userId &&
            a.jid == b.jid &&
            a.title == b.title &&
            a.subtitle == b.subtitle &&
            a.avatarUrl == b.avatarUrl
        }
    }
    
    internal var datasource: [Datasource] = []
    
    internal var membersObserver: Results<GroupchatUserStorageItem>? = nil
    
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(CommonMemberTableCell.self, forCellReuseIdentifier: CommonMemberTableCell.cellName)
        view.register(GroupchatSettingsViewControllerT.SettingsTextFieldCell.self, forCellReuseIdentifier: GroupchatSettingsViewControllerT.SettingsTextFieldCell.cellName)
        
        return view
    }()
    
    internal let saveBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Block", style: .plain, target: nil, action: nil)
        
        button.tintColor = .systemRed
        
        return button
    }()
    
    internal var cancelBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(systemItem: .cancel)
        
        return button
    }()
    
    internal let updateQueue: DispatchQueue = {
        return DispatchQueue.global(qos: .background)
    }()
    
    
    internal var changesObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var selectedJids: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set())
    
    internal var enteredJid: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    override func subscribe() {
        super.subscribe()

        
        self.enteredJid
            .asObservable()
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .subscribe { value in
                if let value = value {
                    
                }
                self.changesObserver.accept((value ?? "").isNotEmpty)
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: self.bag)


        
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
        title = "Blocked"
        
        tableView.delegate = self
        tableView.dataSource = self
        
        self.cancelBarButton.action = #selector(onCancelButtonTouchUpInside)
        self.cancelBarButton.target = self
        self.saveBarButton.action = #selector(onSaveButtonTouchUpInside)
        self.saveBarButton.target = self
    }
    
    @objc
    internal func onCancelButtonTouchUpInside(_ sender: AnyObject) {
        self.navigationController?.popViewController(animated: true)
    }
    
    
    @objc
    internal func onSaveButtonTouchUpInside(_ sender: AnyObject) {
        
        self.navigationController?.popViewController(animated: true)
    }
    
    override func onAppear() {
        
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
                        
            return Datasource(
                userId: item.userId,
                jid: item.jid,
                title: item.nickname.isNotEmpty ? item.nickname : item.jid,
                subtitle: item.nickname.isEmpty ? "" : item.jid,
                avatarUrl: item.avatarUrl
            )
        }
    }
    
    public final var canUpdateDataset = true
    
    
    private final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexPath {
        let section: Int = 1
        
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

extension GroupchatBlockAddViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return 1
        }
        return datasource.count
    }
    
    internal func onTextFieldDidChange(key: String, value: String?) {
        self.enteredJid.accept(value)
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: GroupchatSettingsViewControllerT.SettingsTextFieldCell.cellName, for: indexPath) as? GroupchatSettingsViewControllerT.SettingsTextFieldCell else {
                fatalError()
            }
            
            cell.isEditing = false
            
            cell.configureField { field in
                field.keyboardType = .emailAddress
                field.clearButtonMode = .always
//                field.
            }
            
            cell.configure("name@example.com or example.com", value: nil, key: "item")
            cell.callback = onTextFieldDidChange
            return cell
        }
        guard let cell = tableView.dequeueReusableCell(withIdentifier: CommonMemberTableCell.cellName, for: indexPath) as? CommonMemberTableCell else {
            fatalError()
        }
        let item = datasource[indexPath.row]
        
        cell.configure(
            avatarUrl: item.avatarUrl,
            jid: self.jid,
            owner: self.owner,
            userId: "",
            title: item.title,
            badge: "",
            isMe: false,
            subtitle: item.subtitle,
            status: .offline,
            entity: .contact,
            role: .member
        )
        cell.selectionStyle = .default
        
        return cell
    }
    
    
}

extension GroupchatBlockAddViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
//        if indexPath.section == 0 && self.permissionScope == "owner,admin" {
//            return 52
//        }
        return 64
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 {
            return "Block a specific XMPP address or domain. Blocked users will be unable to join this group in the future."
        }
        return nil
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.section == 0 { return }
        let item = datasource[indexPath.row]
        var value = self.selectedJids.value
        value.insert(item.jid.isEmpty ? item.userId : item.jid)
        self.selectedJids.accept(value)
    }
    
    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if indexPath.section == 0 { return }
        let item = datasource[indexPath.row]
        var value = self.selectedJids.value
        value.remove(item.jid.isEmpty ? item.userId : item.jid)
        self.selectedJids.accept(value)
    }
    
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        if indexPath.section == 0 { return nil }
        let index = indexPath.row
        let cancelInviteAction = UIContextualAction(style: .destructive, title: "Unblock") { action, view, handler in
            let item = self.datasource[index]
            self.onUnblock(jid: item.jid)
            handler(true)
        }
        
        cancelInviteAction.image = imageLiteral("xmark")
        cancelInviteAction.backgroundColor = .systemRed
        
        let conf = UISwipeActionsConfiguration(actions: [cancelInviteAction])
        conf.performsFirstActionWithFullSwipe = true
        return conf
    }
    
    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        if indexPath.section == 0 { return nil }
        let index = indexPath.row
        let directChat = UIContextualAction(style: .normal, title: "Chat") { action, view, handler in
            let item = self.datasource[index]
            self.onDirectChat(jid: item.jid)
            handler(true)
        }
        
        directChat.image = imageLiteral("custom.person.bubble.left.fill")
        directChat.backgroundColor = AccountColorManager.shared.palette(for: self.owner).tint700
        
        let conf = UISwipeActionsConfiguration(actions: [directChat])
        conf.performsFirstActionWithFullSwipe = true
        return conf
    }
}

extension GroupchatBlockAddViewController {
    
    internal func onBlock() {
        
    }
    
    private func onInvite() {
        let vc = GroupchatInviteViewController()
        vc.configure(jid: self.jid, owner: self.owner)
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    private func onUnblock(jid invitedJid: String) {
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.groupchat?.cancelInvite(stream, groupchat: self.jid, jid: invitedJid)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.groupchats.cancelInvite(stream, groupchat: self.jid, jid: invitedJid)
            }
        }
    }
    
    private func onDirectChat(jid invitationJid: String) {
        let conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        if conversationType == .omemo {
            AccountManager.shared.find(for: self.owner)?.omemo.initChat(jid: invitationJid)
        }
        if leftMenuDelegate == nil {
            let chatVc = ChatViewController()
            chatVc.owner = self.owner
            chatVc.jid = invitationJid
            chatVc.conversationType = conversationType
            
            showDetail(chatVc, currentVc: self)
        } else {
            self.leftMenuDelegate?.openChatlistWithChat(owner: self.owner, jid: invitationJid, conversationType: conversationType, configure: nil)
            self.dismiss(animated: true) {
            }
        }
    }
}
