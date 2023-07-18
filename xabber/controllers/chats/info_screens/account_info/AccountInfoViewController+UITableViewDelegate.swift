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

extension AccountInfoViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section < datasource.count {
            if datasource[indexPath.section].childs[indexPath.row].key == .accountQuota {
                return 110
            }
            return 44
        } else {
            let item = tokensDatasource[indexPath.section - datasource.count]
            switch item.kind {
            case .current:
                if item.childs[indexPath.row].kind == .button {
                    return 44
                }
                return 84
            case .token: return 84
            case .button: return 44
            case .text: return 44
            }
        }
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if indexPath.section >= datasource.count {
            let item = tokensDatasource[indexPath.section - datasource.count]
            switch item.kind {
            case .current, .button, .text: return false
            case .token: return true
            }
        } else {
            return false
        }
    }
    
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return false
    }
    
    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        let revokeAction = UITableViewRowAction(style: .destructive, title: "Revoke token".localizeString(id: "settings_account_revoke_token", arguments: [])) { (action, indexPath) in
            guard let item = self.tokens?[indexPath.row] else {
                return
            }
            let uid = item.uid
            XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                session.devices?.revoke(stream, uids: [uid])
            } fail: {
                AccountManager.shared.find(for: self.jid)?.action({ (user, stream) in
                    user.devices.revoke(stream, uids: [uid])
                })
            }
        }
        return [revokeAction]
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        if indexPath.section >= datasource.count {
            switch tokensDatasource[indexPath.section - datasource.count].kind {
            case .current:
                let item = tokensDatasource[indexPath.section - datasource.count].childs[indexPath.row]
                switch item.kind {
                case .button:
                    onRevokeAll()
                    return
                case .token:
                    showTokenInfo(uid: currentToken, canEdit: true)
                    return
                default:
                    return
                }
            case .token:
                guard let uid = tokens?[indexPath.row].uid else {
                    return
                }
                showTokenInfo(uid: uid, canEdit: false)
                return
            case.button:
                onDeleteAccount()
                return
            case .text:
                let item = tokensDatasource[indexPath.section - datasource.count].childs[indexPath.row]
                switch item.kind {
                case .button:
                    onDeleteAccount()
                    return
                default: return
                }
            }
        }
        
        guard datasource[indexPath.section].childs.isNotEmpty else {
            return
        }
        
        let menuItem = datasource[indexPath.section].childs[indexPath.row]
        
        if let key = menuItem.key {
            switch key {
            case .manageStorage:
                let vc = CloudStorageViewController()
                vc.configure(jid: jid)
                navigationController?.pushViewController(vc, animated: true)
                return
            
            case .accountEncryption:
                let vc = AccountEncryptionInfoViewController()
                vc.owner = self.jid
                navigationController?.pushViewController(vc, animated: true)
                return
                
            default: break
            }
        }
        
        if let viewController = menuItem.viewController {
            if let tableVC = viewController.init() as? SimpleTableViewController {
                tableVC.datasource = menuItem
                tableVC.jid = self.jid
                tableVC.resources = self.resources
                tableVC.currentResource = self.currentResource
                navigationController?.pushViewController(tableVC, animated: true)
            } else {
                navigationController?.pushViewController(viewController.init(), animated: true)
            }
            return
        }
    }
}
