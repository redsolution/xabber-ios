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
import CocoaLumberjack

extension LastChatsViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 76
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if self.showSkeleton.value {
            return
        }
        let index = showArchivedSection.value ? indexPath.row - 1 : indexPath.row
        if index < 0 {
            let vc = LastChatsViewController()
            self.hidesBottomBarWhenPushed = false
            vc.hidesBottomBarWhenPushed = true
            vc.filter.accept(.archived)
            vc.archivedMode = true
            self.navigationController?.pushViewController(vc, animated: true)
        } else {
            let jid = self.datasource[index].jid
            let owner = self.datasource[index].owner
            if self.datasource[index].verificationState == .receivedRequest {
                guard let sid = self.datasource[index].verificationSessionSid,
                      let akeManager = AccountManager.shared.find(for: owner)?.akeManager else {
                    return
                }
                let agreeAction = UIAlertAction(title: "Accept", style: UIAlertAction.Style.default) { action in
                    let code = akeManager.acceptVerificationRequest(jid: jid, sid: sid)
                    self.canUpdateDataset = true
                    self.runDatasetUpdateTask()
                    var isVerificationWithUsersDevice = false
                    if jid == owner {
                        isVerificationWithUsersDevice = true
                    }
                    let vc = ShowCodeViewController(owner: self.owner, jid: jid, code: code, sid: sid, isVerificationWithUsersDevice: isVerificationWithUsersDevice)
                    vc.configure()
                    self.present(vc, animated: true)
                }
                let disagreeAction = UIAlertAction(title: "Reject", style: .destructive) { action in
                    akeManager.rejectRequestToVerify(jid: jid, sid: sid)
                    self.canUpdateDataset = true
                    self.runDatasetUpdateTask()
                }
                let alert = UIAlertController(title: "Verification session", message: "Do you want to accept verification request from \(jid)?", preferredStyle: UIAlertController.Style.alert)
                alert.addAction(agreeAction)
                alert.addAction(disagreeAction)
                self.present(alert, animated: true)
                return
            } else if self.datasource[index].verificationState == .sentRequest {
                return
            } else if self.datasource[index].verificationState == .acceptedRequest {
                guard let sid = self.datasource[index].verificationSessionSid,
                      let akeManager = AccountManager.shared.find(for: owner)?.akeManager else {
                    return
                }
                var code: String
                do {
                    let realm = try WRealm.safe()
                    let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid))
                    code = instance!.code
                } catch {
                    fatalError()
                }
                var isVerificationWithUsersDevice = false
                if jid == owner {
                    isVerificationWithUsersDevice = true
                }
                let vc = ShowCodeViewController(owner: owner, jid: jid, code: code, sid: sid, isVerificationWithUsersDevice: isVerificationWithUsersDevice)
                vc.configure()
                self.present(vc, animated: true)
                return
            } else if self.datasource[index].verificationState == .receivedRequestAccept {
                guard let sid = self.datasource[index].verificationSessionSid else {
                    return
                }
                var isVerificationWithUsersDevice = false
                if jid == owner {
                    isVerificationWithUsersDevice = true
                }
                let vc = AuthenticationCodeInputViewController(owner: owner, jid: jid, sid: sid, isVerificationWithUsersDevice: isVerificationWithUsersDevice)
                self.present(vc, animated: true)
                return
            } else if self.datasource[index].verificationState == .failed || self.datasource[index].verificationState == .rejected || self.datasource[index].verificationState == .trusted {
                guard let sid = self.datasource[index].verificationSessionSid else {
                    return
                }
                do {
                    let realm = try WRealm.safe()
                    let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: owner, sid: sid))
                    try realm.write {
                        realm.delete(instance!)
                    }
                } catch {
                    fatalError()
                }
                
                var alertMessage = ""
                if self.datasource[index].verificationState == .failed {
                    alertMessage = "Verification session with \(self.datasource[index].jid) failed.\nSID: \(self.datasource[index].verificationSessionSid!)"
                } else if self.datasource[index].verificationState == .rejected {
                    alertMessage = "Verification session with \(self.datasource[index].jid) rejected.\nSID: \(self.datasource[index].verificationSessionSid!)"
                } else if self.datasource[index].verificationState == .trusted {
                    alertMessage = "Verification session with \(self.datasource[index].jid) was successful, the device is now trusted.\nSID: \(self.datasource[index].verificationSessionSid!)"
                }
                let action = UIAlertAction(title: "Okay", style: .cancel) { _ in
                    self.canUpdateDataset = true
                    self.runDatasetUpdateTask()
                }
                let alert = UIAlertController(title: "", message: alertMessage, preferredStyle: UIAlertController.Style.alert)
                alert.addAction(action)
                self.present(alert, animated: true)
                return
            }
            let vc = ChatViewController()
            self.hidesBottomBarWhenPushed = false
            vc.hidesBottomBarWhenPushed = true
            vc.owner = owner
            vc.jid = jid
            vc.conversationType = self.datasource[index].conversationType
            vc.entity = self.datasource[index].entity!
            self.navigationController?.pushViewController(vc, animated: true)
        }
    }
}
