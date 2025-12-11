////
////
////
////  This program is free software; you can redistribute it and/or
////  modify it under the terms of the GNU General Public License as
////  published by the Free Software Foundation; either version 3 of the
////  License.
////
////  This program is distributed in the hope that it will be useful,
////  but WITHOUT ANY WARRANTY; without even the implied warranty of
////  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
////  General Public License for more details.
////
////  You should have received a copy of the GNU General Public License along
////  with this program; if not, write to the Free Software Foundation, Inc.,
////  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
////
////
////
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

class GroupchatInviteListViewController: SimpleBaseViewController {
    
    class Datasource: DiffAware, Equatable, Hashable {
        var jid: String
        var title: String
        var subtitle: String
        var avatarUrl: String?
        
        typealias DiffId = String
        
        var diffId: String {
            get {
                return jid
            }
        }
        
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.jid == rhs.jid
        }
        
        
        init(jid: String, title: String, subtitle: String, avatarUrl: String?) {
            self.jid = jid
            self.title = title
            self.subtitle = subtitle
            self.avatarUrl = avatarUrl
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(jid)
        }
        
        static func compareContent(_ a: Datasource, _ b: Datasource) -> Bool {
            return a.jid == b.jid &&
            a.title == b.title &&
            a.subtitle == b.subtitle &&
            a.avatarUrl == b.avatarUrl
        }
    }
    
    internal var datasource: [Datasource] = []
    
    internal var membersObserver: Results<GroupchatInvitedUsersStorageItem>? = nil
    
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(CommonMemberTableCell.self, forCellReuseIdentifier: CommonMemberTableCell.cellName)
        
        return view
    }()
        
    internal let updateQueue: DispatchQueue = {
        return DispatchQueue.global(qos: .background)
    }()
    
    
    override func subscribe() {
        super.subscribe()
        do {
            let realm = try WRealm.safe()
            membersObserver = realm
                    .objects(GroupchatInvitedUsersStorageItem.self)
                    .filter("groupchatId == %@", [jid, owner].prp())
                    .sorted(by: [
                        SortDescriptor(keyPath: "nickname", ascending: true),
                        SortDescriptor(keyPath: "jid", ascending: true)
                    ])
            
            
            Observable
                .collection(from: membersObserver!)
                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
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
        title = "Invites"
        let inviteBarButton = UIBarButtonItem(image: imageLiteral("xabber.person.plus.fill"), style: .plain, target: self, action: #selector(onInviteBarButtonTouchUpInside))
        
        self.navigationItem.setRightBarButton(inviteBarButton, animated: true)
    }
    
    @objc
    private func onInviteBarButtonTouchUpInside(_ sender: UIBarButtonItem) {
        self.onInvite()
    }
    
    override func onAppear() {
//        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
//        navigationController?.navigationBar.shadowImage = nil
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
                jid: item.jid,
                title: item.nickname.isNotEmpty ? item.nickname : item.jid,
                subtitle: item.nickname.isEmpty ? "" : item.jid,
                avatarUrl: item.avatarUrl
            )
        }
    }
    
    public final var canUpdateDataset = true
    
    
    private final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexPath {
        let section: Int = 0
        
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

extension GroupchatInviteListViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
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
        return cell
    }
    
    
}

extension GroupchatInviteListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
//        if indexPath.section == 0 && self.permissionScope == "owner,admin" {
//            return 52
//        }
        return 64
    }
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 0
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.row]
        let vc = ContactInfoViewController()
        vc.owner = self.owner
        vc.jid = item.jid
        vc.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let index = indexPath.row
        let cancelInviteAction = UIContextualAction(style: .destructive, title: "Revoke") { action, view, handler in
            let item = self.datasource[index]
            self.onCancelInvite(jid: item.jid)
            handler(true)
        }
        
        cancelInviteAction.image = imageLiteral("xmark")
        cancelInviteAction.backgroundColor = .systemRed
        
        let conf = UISwipeActionsConfiguration(actions: [cancelInviteAction])
        conf.performsFirstActionWithFullSwipe = true
        return conf
    }
    
    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
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

extension GroupchatInviteListViewController {
    
    private func onInvite() {
        let vc = GroupchatInviteViewController()
        vc.configure(jid: self.jid, owner: self.owner)
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    private func onCancelInvite(jid invitedJid: String) {
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
