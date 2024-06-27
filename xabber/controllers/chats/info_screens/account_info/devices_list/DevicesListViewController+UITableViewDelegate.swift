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
import XMPPFramework

extension DevicesListViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = datasource[indexPath.section]
        switch item.kind {
        case .current:
            if item.childs[indexPath.row].kind == .button {
                return 44
            }
            return 60
        case .token, .broken:
            if indexPath.row == 0 {
                return tableView.estimatedRowHeight
            }
            return 60
        case .button: return 44
        case .session: return tableView.estimatedRowHeight
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        switch datasource[indexPath.section].kind {
        case .current:
            let item = datasource[indexPath.section].childs[indexPath.row]
            switch item.kind {
            case .button:
                onRevokeAll()
            case .token:
                showTokenInfo(uid: currentDevice, canEdit: true)
            default:
                break
            }
        case .token:
            if indexPath.row == 0 {
                return
            }
            
            let uid = devices[indexPath.row - 1].uid
            showTokenInfo(uid: uid, canEdit: false)
        case .button:
            let item = datasource[indexPath.section].childs[indexPath.row]
            if item.value == "quit" {
                self.quitAccount()
            }
        case .broken:
                let hasConnection = !AccountManager.shared.connectingUsers.value.contains(self.jid)
                if hasConnection {
                    YesNoPresenter().present(
                        in: self,
                        style: .actionSheet,
                        title: "Delete broken device",
                        message: "",
                        yesText: "Delete",
                        dangerYes: true,
                        noText: "Cancel",
                        animated: true) { value in
                            if value {
                                let item = self.brokenOmemoDevices[indexPath.row]
                                let deviceId = item.deviceId
                                AccountManager.shared.find(for: self.jid)?.unsafeAction({ user, stream in
                                    user.omemo.deleteDevice(deviceId: deviceId)
                                })
                            }
                        }
                } else {
                    ActionSheetPresenter().present(
                        in: self,
                        title: "No connection",
                        message: "Please wait while connection established",
                        cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                        values: [],
                        animated: true) { _ in
                            
                        }
                }
        default:
            break
        }
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        let item = datasource[indexPath.section]
        switch item.kind {
        case .current, .button: return false
        case .token: return true
        case .broken: return true
        case .session: return false
        }
    }
    
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return false
    }
    
    
    // invalid number of section of no devices only obsolete
    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        if indexPath.section == 2 {
            let revokeAction = UITableViewRowAction(style: .destructive, title: "Delete key") { (action, indexPath) in
                let item = self.brokenOmemoDevices[indexPath.row]
                let deviceId = item.deviceId
                AccountManager.shared.find(for: self.jid)?.unsafeAction({ user, stream in
                    user.omemo.deleteDevice(deviceId: deviceId)
                })
            }
            return [revokeAction]
        }
        let revokeAction = UITableViewRowAction(style: .destructive, title: "Revoke token".localizeString(id: "settings_account_revoke_token", arguments: [])) { (action, indexPath) in
            
            let hasConnection = !AccountManager.shared.connectingUsers.value.contains(self.jid)
            if hasConnection {
                let item = self.devices[indexPath.row - 1]
                let uid = item.uid
                AccountManager.shared.find(for: self.jid)?.action({ (user, stream) in
                    user.devices.revoke(stream, uids: [uid])
                })
            } else {
                ActionSheetPresenter().present(
                    in: self,
                    title: "No connection",
                    message: "Please wait while connection established",
                    cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                    values: [],
                    animated: true) { _ in
                        
                    }
            }
            
            
            
        }
        return [revokeAction]
    }
}
