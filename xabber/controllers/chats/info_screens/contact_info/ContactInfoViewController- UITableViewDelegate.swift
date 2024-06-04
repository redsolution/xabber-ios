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

extension ContactInfoViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if datasource[indexPath.section].childs[indexPath.row].key == "circles" {
            return tableView.estimatedRowHeight
        }
        switch datasource[indexPath.section].childs[indexPath.row].kind {
        case .session: return tableView.estimatedRowHeight
        default: return 44
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = datasource[indexPath.section].childs[indexPath.row]
        if let key = item.key {
            switch key {
            case "jid_field":
                let shareVC = UIActivityViewController(activityItems: [jid],
                                                       applicationActivities: [])
                
                if UIDevice.current.userInterfaceIdiom == .pad {
                    if let popoverController = shareVC.popoverPresentationController {
                        popoverController.sourceView = self.view
                        popoverController.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                        popoverController.permittedArrowDirections = []
                    }
                }
                self.present(shareVC, animated: true, completion: nil)
            case "open_chat_button":
                openChat()
            case "notify_chat_button":
                onChangeNotifications()
            case "block_chat_button":
                onBlock()
            case "delete_chat_button":
                onDelete()
            case "qr_code":
                onQRCode()
            case "circles":
                editCircles()
            case "fingerprints":
                showFingerprints()
            case "start_encrypted_chat":
                onStartEncryptedChat()
            case "accept_verification":
                guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
                      let sid = item.verificationSid else {
                    fatalError()
                }
                guard let code = akeManager.acceptVerificationRequest(jid: self.jid, sid: sid) else {
                    return
                }
                let vc = ShowCodeViewController()
                vc.configure(owner: self.owner, jid: self.jid, code: code, sid: sid, isVerificationWithUsersDevice: false)
                self.navigationController!.present(vc, animated: true)
                
                return
            case "show_verification_code":
                let code: String
                do {
                    let realm = try WRealm.safe()
                    guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: item.verificationSid!)) else {
                        fatalError()
                    }
                    code = instance.code
                } catch {
                    fatalError()
                }
                
                let vc = ShowCodeViewController()
                vc.configure(owner: self.owner, jid: self.jid, code: code, sid: item.verificationSid!, isVerificationWithUsersDevice: false)
                self.navigationController!.present(vc, animated: true)
                
                return
            case "hide_session":
                do {
                    let realm = try WRealm.safe()
                    let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: item.verificationSid!))
                    try realm.write {
                        realm.delete(instance!)
                    }
                } catch {
                    fatalError()
                }
                tableView.reloadData()
                
                return
            case "enter_verification_code":
                let vc = AuthenticationCodeInputViewController()
                vc.configure(owner: self.owner, jid: self.jid, sid: item.verificationSid!, isVerificationWithUsersDevice: false)
                self.navigationController!.present(vc, animated: true)
                
                return
            case "reject_verification":
                guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
                    fatalError()
                }
                akeManager.rejectRequestToVerify(jid: self.jid, sid: item.verificationSid!)
                
                return
            default: break
            }
        }
    }
}
