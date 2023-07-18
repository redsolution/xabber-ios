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

class SearchResultsViewController: BaseViewController {
    
    struct Section {
        enum Kind {
            case contacts
            case messages
        }
        
        let header: String
        let footer: String
        let kind: Kind
    }
    
    internal var sections: [Section] = [
        Section(header: "Contacts".localizeString(id: "contacts", arguments: []), footer: "", kind: .contacts),
        Section(header: "Messages".localizeString(id: "groupchat_member_messages", arguments: []), footer: "", kind: .messages)
    ]
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .grouped)

        view.register(MessageCell.self, forCellReuseIdentifier: MessageCell.cellName)
        view.register(ContactCell.self, forCellReuseIdentifier: ContactCell.cellName)
        
        view.keyboardDismissMode = .onDrag
//        if #available(iOS 13.0, *) {
//            view.backgroundColor = .systemBackground
//        } else {
            view.backgroundColor = .white
//        }
        
        return view
    }()
    
    
    
    open var delegate: SearchResultsDelegateProtocol? = nil
    
    internal var isContactsHidden: Bool = false
    internal var isMessagesHidden: Bool = false
    
    internal var bag: DisposeBag = DisposeBag()
    internal var datasetBag: DisposeBag = DisposeBag()
    
    internal var filteredContacts: Results<RosterStorageItem>? = nil
    internal var filteredMessages: Results<MessageStorageItem>? = nil
    
    internal var messagesMetadata: [String: Any] = [:]
    
    internal func updateSearchResults(with text: String) {
        do {
            let realm = try WRealm.safe()
            filteredContacts = realm
                .objects(RosterStorageItem.self)
                .filter("username CONTAINS[c] %@ OR jid CONTAINS[cd] %@ OR customUsername CONTAINS[c] %@",
                        text, text, text)
            
            filteredMessages = realm
                .objects(MessageStorageItem.self)
                .filter("isDeleted == %@ AND body CONTAINS[cd] %@", false, text)
                .sorted(byKeyPath: "date", ascending: false)
            
            subscribeDataset()
        } catch {
            DDLogDebug("cant update search results")
        }
    }
    
    internal func subscribeDataset() {
        datasetBag = DisposeBag()
        if filteredContacts != nil {
            Observable
                .collection(from: filteredContacts!)
                .subscribe(onNext: { (results) in
                    self.isContactsHidden = results.isEmpty
                    self.tableView.reloadData()
                })
                .disposed(by: datasetBag)
        }
        if filteredMessages != nil {
            Observable
                .collection(from: filteredMessages!)
                .subscribe(onNext: { (results) in
                    do {
                        let realm = try WRealm.safe()
                        self.messagesMetadata = results.toArray().reduce(into: [String: Any]()) {
                            let item = realm
                                .object(
                                    ofType: LastChatsStorageItem.self,
                                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                                        jid: $1.opponent,
                                        owner: $1.owner,
                                        conversationType: $1.conversationType
                                    )
                                )
                            $0[[$1.opponent, $1.owner, "username"].prp()] = item?.rosterItem?.displayName ?? $1.opponent
                            $0[[$1.opponent, $1.owner, "groupchat"].prp()] = item?.conversationType == .group
                        }
                    } catch {
                        DDLogDebug("cant update usernames for search results")
                    }
                    self.isMessagesHidden = results.isEmpty
                    self.tableView.reloadData()
                })
                .disposed(by: datasetBag)
        }
    }
    
    internal func subscribe() {
        bag = DisposeBag()
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
        datasetBag = DisposeBag()
    }
    
    internal func activateConstraints() {
        
    }
    
    internal func configure() {
        view.addSubview(tableView)
        tableView.fillSuperview()
        
        tableView.dataSource = self
        tableView.delegate = self
                
//        view.backgroundColor = .white
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
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
        subscribe()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unsubscribe()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
