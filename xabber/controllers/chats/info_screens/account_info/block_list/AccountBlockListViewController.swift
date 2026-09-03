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
import RxRealm
import RxSwift
import CocoaLumberjack

struct AccountBlockListContactPresentation {
    let title: String
    let jid: String
    let avatarURL: String?
    let groups: [String]
    let status: ResourceStatus
    let entity: RosterItemEntity
}

enum AccountBlockListPresentationFactory {
    static func make(
        blockedJID: String,
        rosterItem: RosterStorageItem?,
        status: ResourceStatus?,
        entity: RosterItemEntity?
    ) -> AccountBlockListContactPresentation {
        AccountBlockListContactPresentation(
            title: rosterItem?.displayName
                ?? JidManager.shared.prepareJid(jid: blockedJID),
            jid: blockedJID,
            avatarURL: rosterItem?.avatarUrl,
            groups: [],
            status: status ?? .offline,
            entity: entity ?? .contact
        )
    }

    static func configure(
        cell: ContactsViewController.ContactCell,
        presentation: AccountBlockListContactPresentation,
        owner: String
    ) {
        cell.configure(
            title: presentation.title,
            subtitle: presentation.jid,
            bottomLine: nil,
            groups: presentation.groups,
            jid: presentation.jid,
            owner: owner,
            showAvatar: true,
            avatarUrl: presentation.avatarURL,
            entity: presentation.entity,
            status: presentation.status
        )
    }
}

enum AccountBlockListRowAction: Equatable {
    case unblock
    case report
}

struct AccountBlockListContactRoute: Equatable {
    let owner: String
    let jid: String
    let conversationType: ClientSynchronizationManager.ConversationType
}

enum AccountBlockListInteractionPolicy {
    static let trailingActions: [AccountBlockListRowAction] = [.unblock, .report]

    static func contactRoute(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> AccountBlockListContactRoute {
        AccountBlockListContactRoute(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
    }
}

class AccountBlockListViewController: BaseViewController {
    
//    internal var jid: String = ""
    internal var isGroupchatInvitation: Bool = false
    internal var bag: DisposeBag = DisposeBag()
    
    internal var datasource: Results<BlockStorageItem>? = nil
    
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(
            ContactsViewController.ContactCell.self,
            forCellReuseIdentifier: ContactsViewController.ContactCell.cellName
        )
        view.rowHeight = UITableView.automaticDimension
        view.estimatedRowHeight = 84
        view.applyContinuousSplitInsetGroupedAppearance()
        
        return view
    }()
    
    internal let emptyStateLabel: UILabel = {
        let label = UILabel()
        
        label.text = "Block list is empty".localizeString(id: "groupchat_blocklist_empty", arguments: [])
        label.isHidden = true
        label.textAlignment = .center
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .gray
        }
        
        return label
    }()
    
    func load() {
        do {
            let realm = try WRealm.safe()
            datasource = realm
                .objects(BlockStorageItem.self)
                .filter("owner == %@ AND isGroupchatInvitation == %@", jid, isGroupchatInvitation)
                .sorted(byKeyPath: "timestamp", ascending: false)
        } catch {
            DDLogDebug("cant load info about account \(jid)")
        }
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        guard let datasource else {
            return
        }
        Observable
            .changeset(from: datasource)
            .subscribe(onNext: { (result) in
                if result.1 != nil { self.tableView.reloadData() }
            })
            .disposed(by: bag)
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func activateConstraints() {
        
    }
    
    open func configure(for jid: String, isGroupchatInvitation: Bool = false) {
        self.jid =  jid
        self.isGroupchatInvitation = isGroupchatInvitation
        if isGroupchatInvitation {
            title = "Groupchat invitations".localizeString(id: "groupchats_groupchat_invitations", arguments: [])
        } else {
            title = "Blocked contacts".localizeString(id: "blocked_contacts", arguments: [])
        }
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        emptyStateLabel.frame = CGRect(width: view.frame.width, height: 88)
        tableView.backgroundView = emptyStateLabel
        hideKeyboardWhenTappedAround()
        load()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        activateConstraints()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    override func reloadDatasource() {
        tableView.reloadData()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: true)
        subscribe()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
        
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
        unsubscribe()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
