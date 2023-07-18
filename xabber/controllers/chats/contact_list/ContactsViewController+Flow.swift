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
import RealmSwift
import CocoaLumberjack

extension ContactsViewController {
    internal func collapseGroup(_ primary: String, value: Bool) {
        do {
            let realm = try WRealm.safe()
            try realm.write {
                realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: primary)?.isCollapsed = value
            }
        } catch {
            DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func onManageAccount(jid: String) {
        let presenter = ActionSheetPresenter()
        let items: [ActionSheetPresenter.Item] = [
            ActionSheetPresenter.Item(destructive: false, title: "Set status".localizeString(id: "status_editor", arguments: []), value: "status"),
            ActionSheetPresenter.Item(destructive: false, title: "Account settings".localizeString(id: "account_editor", arguments: []), value: "settings"),
            ActionSheetPresenter.Item(destructive: false, title: "Add contact".localizeString(id: "application_action_no_contacts", arguments: []), value: "add-contact")
        ]
        presenter.present(
            in: self,
            title: nil,
            message: nil,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: items,
            animated: true
            ){ (result) in
                switch result {
                case "status":
                    let vc = AccountNewStatusViewController()
                    vc.isModal = false
                    vc.configure(for: jid)
                    self.navigationController?.pushViewController(vc, animated: true)
//                    let nvc = UINavigationController(rootViewController: vc)
//                    nvc.modalPresentationStyle = .fullScreen
//                    nvc.modalTransitionStyle = .coverVertical
//                    self.definesPresentationContext = true
//                    self.present(nvc, animated: true, completion: nil)
                case "settings":
                    let vc = SettingsViewController() //AccountInfoViewController()
                    vc.isModal = false
                    vc.jid = jid
                    self.navigationController?.pushViewController(vc, animated: true)
//                    let nvc = UINavigationController(rootViewController: vc)
//                    nvc.modalPresentationStyle = .fullScreen
//                    nvc.modalTransitionStyle = .coverVertical
//                    self.definesPresentationContext = true
//                    self.present(nvc, animated: true, completion: nil)
                case "add-contact":
                    let vc = AddContactViewController()
                    vc.isModal = false
                    vc.owner = jid
                    vc.delegate = self
                    self.navigationController?.pushViewController(vc, animated: true)
//                    let nvc = UINavigationController(rootViewController: vc)
//                    nvc.modalPresentationStyle = .fullScreen
//                    nvc.modalTransitionStyle = .coverVertical
//                    self.definesPresentationContext = true
//                    self.present(nvc, animated: true, completion: nil)
                default: break
                }
            }
    }
    
    internal func onAccountCollapse(jid: String) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) {
                try realm.write {
                    instance.isCollapsed = !instance.isCollapsed
                }
            }
            let accounts = realm.objects(AccountStorageItem.self)
                .filter("enabled == true")
                .sorted(byKeyPath: "order", ascending: true)
            self.enabledAccounts.accept(accounts.compactMap {
                do {
                    let realm = try WRealm.safe()
                    let contactsCount = realm
                        .objects(RosterStorageItem.self)
                        .filter("owner == %@ AND isHidden == false AND removed == false AND subscription_ != %@", $0.jid, "")
                        .count
                    return EnabledAccount(jid: $0.jid, isCollapsed: $0.isCollapsed, contactsCount: contactsCount)
                } catch {
                    DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
                }
                
                return EnabledAccount(jid: $0.jid, isCollapsed: $0.isCollapsed, contactsCount: 0)
            })
            self.updateSectionHeaders(for: self.enabledAccounts.value)
            self.canUpdateDataset = true
            self.runDatasetUpdateTask(force: true)
        } catch {
            DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
        }
    }
}
