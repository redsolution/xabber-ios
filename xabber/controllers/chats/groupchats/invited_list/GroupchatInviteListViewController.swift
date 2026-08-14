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
import DeepDiff
import CocoaLumberjack
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
    
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(CommonMemberTableCell.self, forCellReuseIdentifier: CommonMemberTableCell.cellName)
        
        return view
    }()
        
    override func subscribe() {
        super.subscribe()
        refreshOutgoingInvites()
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
        refreshOutgoingInvites()
    }
    
    var canPromote: Bool = true
    var canRestrict: Bool = true
    var canEdit: Bool = true
    var canKick: Bool = true
    
    private final func mapDataset(_ targets: [String]) -> [Datasource] {
        targets
            .map(GroupStorageKey.bareJID)
            .filter(\.isNotEmpty)
            .reduce(into: [String]()) { result, target in
                if !result.contains(target) {
                    result.append(target)
                }
            }
            .sorted()
            .map { target in
                Datasource(
                    jid: target,
                    title: target,
                    subtitle: "",
                    avatarUrl: nil
                )
            }
    }
    
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
    
    @MainActor
    private final func applyOutgoingInvites(_ targets: [String]) {
        let newDataset = mapDataset(targets)
        let changes = diff(old: datasource, new: newDataset)
        let indexPaths = convertChangeset(changes: changes)
        apply(changes: indexPaths) {
            self.datasource = newDataset
        }
    }
    
    private final func apply(changes: ChangesWithIndexPath, prepare: @escaping (() -> Void)) {

        if changes.deletes.isEmpty &&
            changes.inserts.isEmpty &&
            changes.moves.isEmpty &&
            changes.replaces.isEmpty {
            prepare()
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
    private func refreshOutgoingInvites() {
        guard let account = AccountManager.shared.find(for: owner) else {
            return
        }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                let targets = try await account.groupchatService.refreshInvites(
                    groupJID: self.jid
                )
                let records = try GroupRepository(
                    realm: WRealm.safe()
                ).replaceOutgoingInvites(
                    owner: self.owner,
                    groupJID: self.jid,
                    targets: targets
                )
                self.applyOutgoingInvites(records.map(\.target))
            } catch {
                DDLogDebug("GroupchatInviteListViewController: \(#function). \(error.localizedDescription)")
                self.view.makeToast(
                    CanonicalGroupMembershipLifecycle.localizedErrorMessage(error),
                    danger: true
                )
            }
        }
    }
    
    private func onInvite() {
        let vc = GroupchatInviteViewController()
        vc.configure(jid: self.jid, owner: self.owner)
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    private func onCancelInvite(jid invitedJid: String) {
        guard let account = AccountManager.shared.find(for: owner) else {
            return
        }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                let targets = try await account.groupchatService.revokeInvite(
                    groupJID: self.jid,
                    targetJID: invitedJid
                )
                let records = try GroupRepository(
                    realm: WRealm.safe()
                ).replaceOutgoingInvites(
                    owner: self.owner,
                    groupJID: self.jid,
                    targets: targets
                )
                self.applyOutgoingInvites(records.map(\.target))
            } catch {
                self.view.makeToast(
                    CanonicalGroupMembershipLifecycle.localizedErrorMessage(error),
                    danger: true
                )
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
