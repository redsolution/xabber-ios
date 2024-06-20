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
import CocoaLumberjack
import TOInsetGroupedTableView

class NewSecretChatViewController: SimpleBaseViewController {
    
    struct Datasource {
        let owner: String
        let jid: String
        let username: NSAttributedString
        let avatarUrl: String?
        let hasSecretChat: Bool
        let hasBrokenDevices: Bool
        let hasUntrustedDevices: Bool
    }
    
    internal var datasource: [Datasource] = []
    
    public var delegate: AddContactDelegate? = nil
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
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
                if $0.jid == $0.owner {
                    return nil
                }
                let devices = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", $0.owner, $0.jid).toArray()
                if devices.count == 0 {
                    return nil
                }
                let hasSecretChat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: $0.jid, owner: $0.owner, conversationType: .omemo)) != nil
                let hasBrokenDevices = devices.filter({$0.state == .fingerprintChanged}).isNotEmpty
                let hasUntrustedDevices = devices.filter({$0.state != .trusted}).isNotEmpty
                
                let username = $0.displayName
                
                let attributedTitle: NSMutableAttributedString = NSMutableAttributedString()
                let indicatorAttach = NSTextAttachment()
                var color: UIColor = .label
                if devices.count == 0 {
                    color = .secondaryLabel
                    indicatorAttach.image = UIImage(systemName: "lock.fill")?.withTintColor(.secondaryLabel)
                    attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                } else if hasBrokenDevices {
                    color = .systemRed
                    indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemRed)
                    attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                } else if hasUntrustedDevices {
                    color = .systemOrange
                    indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemOrange)
                    attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                } else if devices.filter({ $0.isTrustedByCertificate }).count > 0 {
                    color = .systemGreen
                    indicatorAttach.image = UIImage(systemName: "lock.circle.fill")?.withTintColor(.systemGreen)
                    attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                } else {
                    color = .systemGreen
                    indicatorAttach.image = UIImage(systemName: "lock.fill")?.withTintColor(.systemGreen)
                    attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                }
                
                attributedTitle.append(NSAttributedString(string: username, attributes: [
                    .foregroundColor: color,
                    .font: UIFont.systemFont(ofSize: 17, weight: .medium)
                ]))
                let attributedUsername: NSAttributedString = attributedTitle as NSAttributedString
                
                
                return Datasource(
                    owner: $0.owner,
                    jid: $0.jid,
                    username: attributedUsername,
                    avatarUrl: $0.avatarMaxUrl ?? $0.avatarMinUrl ?? $0.oldschoolAvatarKey,
                    hasSecretChat: hasSecretChat,
                    hasBrokenDevices: hasBrokenDevices,
                    hasUntrustedDevices: hasUntrustedDevices
                )
            } catch {
                DDLogDebug("NewSecretChatViewController: \(#function). \(error.localizedDescription)")
            }
            return nil
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
        return 84
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.row]
        AccountManager.shared.find(for: item.owner)?.omemo.initChat(jid: item.jid)
        self.dismiss(animated: true) {
            let splitVc = (UIApplication.shared.delegate as? AppDelegate)?.splitController
            let vc = ChatViewController()
            vc.jid = item.jid
            vc.owner = item.owner
            vc.conversationType = .omemo
            
            if let presenterVc = self.presentationController {
                showStacked(vc, in: presenterVc.presentingViewController)
            }
        }
    }
}

extension NewSecretChatViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.row]
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ContactListTableViewCell.cellName, for: indexPath) as? ContactListTableViewCell else {
            fatalError()
        }
        
        cell.configure(owner: item.owner, jid: item.jid, attributedUsername: item.username, username: "", avatarUrl: item.avatarUrl)
        
        return cell
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
}
