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
//import Foundation
//import UIKit
//
//extension _AccountInfoViewController: UITableViewDelegate {
//    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
////        if datasource[indexPath.section].kind == .resource {
////            return 64
////        }
//        if datasource[indexPath.section].childs[indexPath.row].key == "account_quota" {
//            return 110
//        }
//        return 44
//    }
//    
//    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
//        tableView.deselectRow(at: indexPath, animated: true)
//        if datasource[indexPath.section].kind == .resource {
//            guard let resource = self.resources?[indexPath.row] else { return }
//            let vc = ContactInfoResourceController()
//            vc.jid = self.jid
//            vc.owner = self.jid
//            vc.resource = resource.resource
//            navigationController?.pushViewController(vc, animated: true)
//        } else {
//            let item = datasource[indexPath.section].childs[indexPath.row]
//            if let key = item.key {
//                switch key {
//                case "account_status":
//                    let vc = AccountNewStatusViewController()
//                    vc.configure(for: jid)
////                    navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
////                    navigationController?.navigationBar.shadowImage = nil
//                    navigationController?.pushViewController(vc, animated: true)
//                case "account_vcard":
//                    let vc = AccountEditViewController()
//                    vc.configure(for: jid)
////                    navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
////                    navigationController?.navigationBar.shadowImage = nil
//                    navigationController?.pushViewController(vc, animated: true)
////                case "account_resource":
////                    let vc = AccountConnectionViewController()
////                    vc.configure(for: jid)
////                    navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
////                    navigationController?.navigationBar.shadowImage = nil
////                    navigationController?.pushViewController(vc, animated: true)
//                case "account_sessions":
//                    let vc = DevicesListViewController()
//                    vc.configure(for: jid)
////                    navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
////                    navigationController?.navigationBar.shadowImage = nil
//                    navigationController?.pushViewController(vc, animated: true)
//                case "account_password":
//                    let vc = AccountSecurityViewController()
//                    vc.configure(for: jid)
////                    navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
////                    navigationController?.navigationBar.shadowImage = nil
//                    navigationController?.pushViewController(vc, animated: true)
//                case "account_color":
//                    let vc = AccountColorViewController()
//                    vc.configure(for: jid)
////                    navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
////                    navigationController?.navigationBar.shadowImage = nil
//                    navigationController?.pushViewController(vc, animated: true)
//                case "manage_storage":
//                    let vc = CloudStorageViewController()
//                    vc.configure(jid: jid)
//                    
//                    navigationController?.pushViewController(vc, animated: true)
//                case "account_groupchat_invitations":
//                    let vc = AccountBlockListViewController()
//                    vc.configure(for: jid, isGroupchatInvitation: true)
////                    navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
////                    navigationController?.navigationBar.shadowImage = nil
//                    navigationController?.pushViewController(vc, animated: true)
//                case "account_blocked_contacts":
//                    let vc = AccountBlockListViewController()
//                    vc.configure(for: jid, isGroupchatInvitation: false)
////                    navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
////                    navigationController?.navigationBar.shadowImage = nil
//                    navigationController?.pushViewController(vc, animated: true)
//                    
//                case "account_encryption":
//                    let vc = AccountEncryptionInfoViewController()
//                    vc.owner = self.jid
//                    navigationController?.pushViewController(vc, animated: true)
//                case "account_yubikey":
//                    let vc = YubikeySetupViewController()
//                    vc.isFromOnboarding = false
//                    navigationController?.pushViewController(vc, animated: true)
//                case "account_quit":
//                    onDeleteAccount()
//                case "qr_code":
//                    onQRCode()
//                default: break
//                }
//            }
//        }
//    }
//    
//}
