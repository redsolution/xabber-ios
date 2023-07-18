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
import TOInsetGroupedTableView

class GroupchatMembersListViewController: SimpleBaseViewController {
    
    class Datasource: DiffAware, Equatable, Hashable {
        let userId: String
        let title: String
        let badge: String
        let isMe: Bool
        let subtitle: String
        let status: ResourceStatus
        let entity: RosterItemEntity
        let avatarKey: String
        let role: GroupchatUserStorageItem.Role
        
        typealias DiffId = String
        
        var diffId: String {
            get {
                return userId
            }
        }
        
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.userId == rhs.userId
        }
        
        
        init(userId: String, title: String, badge: String, isMe: Bool, subtitle: String, status: ResourceStatus, entity: RosterItemEntity, avatarKey: String, role: GroupchatUserStorageItem.Role) {
            self.userId = userId
            self.title = title
            self.badge = badge
            self.isMe = isMe
            self.subtitle = subtitle
            self.status = status
            self.entity = entity
            self.avatarKey = avatarKey
            self.role = role
            
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
            a.entity == b.entity &&
            a.avatarKey == b.avatarKey &&
            a.role == b.role
        }
    }
    
    internal var datasource: [Datasource] = []
    
//    open var jid: String = ""
//    open var owner: String = ""
    
    internal var membersObserver: Results<GroupchatUserStorageItem>? = nil
    
    internal let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(CommonMemberTableCell.self, forCellReuseIdentifier: CommonMemberTableCell.cellName)
        
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
    
    override func subscribe() {
        super.subscribe()
        do {
            let realm = try WRealm.safe()
            membersObserver = realm
                    .objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@ AND isBlocked == false AND isKicked == false AND isTemporary == false", [jid, owner].prp())
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
    
    override func configure() {
        super.configure()
        tableView.delegate = self
        tableView.dataSource = self
        title = "Members".localizeString(id: "group_settings__members_list__header", arguments: [])
    }
    
    override func onAppear() {
        super.onAppear()
    }
    
    private final func mapDataset() -> [Datasource] {
        
        do {
            let realm = try WRealm.safe()
            
            let collection = realm
                .objects(GroupchatUserStorageItem.self)
                .filter("groupchatId == %@ AND isBlocked == false AND isKicked == false AND isTemporary == false", [jid, owner].prp())
                .sorted(by: [
                    SortDescriptor(keyPath: "isMe", ascending: false),
                    SortDescriptor(keyPath: "sortedRole", ascending: true)
                ])
            
            return collection.compactMap {
                item in
                
                return Datasource(
                    userId: item.userId,
                    title: item.nickname,
                    badge: item.badge,
                    isMe: item.isMe,
                    subtitle: item.isOnline ? "Online".localizeString(id: "account_state_connected", arguments: []): item.dateString ?? "Offline".localizeString(id: "unavailable", arguments: []),
                    status: item.isOnline ? .online : .offline,
                    entity: .contact,
                    avatarKey: [item.userId, self.jid].prp(),
                    role: item.role
                )
            }
        } catch {
            DDLogDebug("GroupchatMembersListViewController: \(#function). \(error.localizedDescription)")
        }
        return []
    }
    
    public final var canUpdateDataset = true
    
    
    private final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexPath {
        let inserts =  changes.compactMap { return $0.insert?.index }.compactMap({ return IndexPath(row:$0, section: 0)})
        let deletes =  changes.compactMap { return $0.delete?.index }.compactMap({ return IndexPath(row:$0, section: 0 )})
        let replaces = changes.compactMap { return $0.replace?.index }.compactMap({ return IndexPath(row:$0, section: 0 )})
        
        let moves = changes.compactMap({ $0.move }).map({
          (
            from: IndexPath(item: $0.fromIndex, section: 0),
            to: IndexPath(item: $0.toIndex, section: 0)
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
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: CommonMemberTableCell.cellName, for: indexPath) as? CommonMemberTableCell else {
            fatalError()
        }
        let item = datasource[indexPath.row]
        
        cell.configure(
            jid: self.jid,
            owner: self.owner,
            userId: item.userId,
            title: item.title,
            badge: item.badge,
            isMe: item.isMe,
            subtitle: item.subtitle,
            status: item.status,
            entity: item.entity,
            role: item.role)
                
        return cell
    }
    
    
}

extension GroupchatMembersListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 64
    }
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 0
    }
}
