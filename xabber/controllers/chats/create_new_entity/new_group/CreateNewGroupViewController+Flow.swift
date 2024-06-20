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
import RxCocoa
import RxSwift
import RealmSwift
import CocoaLumberjack

extension CreateNewGroupViewController {
    @objc
    internal func onSave() {
        self.inSaveMode.accept(true)
        DispatchQueue.main.async {
            self.navigationItem.setRightBarButton(self.createIndicator, animated: true)
        }
        var privacyValue: String = "public"
        if createIncognitoGroup {
            privacyValue = "incognito"
        }
        
        
        AccountManager.shared.find(for: self.account["value"]!)?.action({ (user, stream) in
            user.groupchats.create(
                stream,
                server: self.server["value"]!,
                name: self.name.value!,
                localPart: self.localpart,
                privacy: GroupChatStorageItem.Privacy(rawValue: privacyValue),
                membership: GroupChatStorageItem.Membership(rawValue: self.membership["value"]!),
                index: GroupChatStorageItem.Index(rawValue: self.index["value"]!),
                description: self.descr
            ) { response in
                DispatchQueue.main.async {
                    if let value = response {
                        if value == "success" {
                            self.onSuccess()
                        } else if value == "conflict" {
                            self.onError(conflict: true)
                        } else {
                            self.onError(conflict: false)
                        }
                    }
                }
            }
        })
    }
    
    internal func onSuccess() {
//        self.navigationController?.dismiss(animated: true, completion: nil)
        self.inSaveMode.accept(false)
        
        guard let owner = self.account["value"],
            let domainPart = self.server["value"],
            let localPart = self.localpart else {
                return
        }
        
        let jid = [localPart, domainPart].joined(separator: "@")
//        XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
//            _ = session.mam?.requestHistory(stream, to: jid, count: 2, callback: nil)
//        } fail: {
//            AccountManager.shared.find(for: owner)?.action({ user, stream in
//                _ = user.mam.requestHistory(stream, to: jid, count: 2, callback: nil)
//            })
//        }
        
        DispatchQueue.main.async {
            self.dismiss(animated: true) {
                let splitVc = (UIApplication.shared.delegate as? AppDelegate)?.splitController
                let vc = ChatViewController()
                vc.jid = jid
                vc.owner = owner
                vc.conversationType = .group
                
                if let presenterVc = self.presentationController {
                    showStacked(vc, in: presenterVc.presentingViewController)
                }
            }
        }
    }
    
    internal func onError(conflict: Bool) {
        self.inSaveMode.accept(false)
        self.navigationItem.setRightBarButton(self.saveButton, animated: true)
        self.onCreate.accept(nil)
    }
}
