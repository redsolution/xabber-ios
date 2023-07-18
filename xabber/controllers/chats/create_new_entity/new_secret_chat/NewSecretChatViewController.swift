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
//import Realm
import RealmSwift
import RxCocoa
import RxSwift
import RxRealm
import CocoaLumberjack
import TOInsetGroupedTableView

class NewSecretChatViewController: SimpleBaseViewController {
    
    struct Datasource {
        let owner: String
        let jid: String
        let username: String
    }
    
    internal var datasource: [Datasource] = []
    
    public var delegate: AddContactDelegate? = nil
    
    private let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(ContactListTableViewCell.self, forCellReuseIdentifier: ContactListTableViewCell.cellName)
        
        return view
    }()
    
    override func loadDatasource() {
        do {
            let realm = try WRealm.safe()
            let enabledAccounts = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == true")
                .toArray()
                .map { return $0.jid }
            let collection = realm
                .objects(RosterStorageItem.self)
                .filter("owner IN %@", enabledAccounts)
                .sorted(by: [SortDescriptor(keyPath: "jid", ascending: true),
                             SortDescriptor(keyPath: "username", ascending: true),
                             SortDescriptor(keyPath: "customUsername", ascending: true)])
            self.datasource = mapDatasource(collection)
            
        } catch {
            DDLogDebug("NewSecretChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    private final func mapDatasource(_ collection: Results<RosterStorageItem>) -> [Datasource] {
        return collection.compactMap {
            do {
                let realm = try WRealm.safe()
                if realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: $0.jid, owner: $0.owner)) != nil {
                    return nil
                }
            } catch {
                
            }
            return Datasource(owner: $0.owner, jid: $0.jid, username: $0.displayName)
        }
    }
    
    override func configure() {
        super.configure()
        title = "New secret chat".localizeString(id: "new_secret_chat", arguments: [])
        view.addSubview(tableView)
        tableView.fillSuperviewWithOffset(top: -20, bottom: 0, left: 0, right: 0)
        tableView.delegate = self
        tableView.dataSource = self
    }
}

extension NewSecretChatViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 58
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.row]
        AccountManager.shared.find(for: item.owner)?.omemo.initChat(jid: item.jid)
        self.navigationController?.dismiss(animated: true, completion: {
            self.delegate?.didAddContact(
                owner: item.owner,
                jid: item.jid,
                entity: .encryptedChat,
                conversationType: .omemo
            )
        })
        
    }
}

extension NewSecretChatViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.row]
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ContactListTableViewCell.cellName, for: indexPath) as? ContactListTableViewCell else {
            fatalError()
        }
        
        cell.configure(owner: item.owner, jid: item.jid, username: item.username)
        
        return cell
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
}
