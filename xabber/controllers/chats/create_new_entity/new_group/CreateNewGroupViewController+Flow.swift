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
        guard let owner = account["value"],
              let serviceJID = selectedServer,
              let groupName = name.value else {
            onError(conflict: false)
            return
        }
        self.inSaveMode.accept(true)
        DispatchQueue.main.async {
            self.navigationItem.setRightBarButton(self.createIndicator, animated: true)
        }
        guard let account = AccountManager.shared.find(for: owner),
              let membership = self.membership["value"].flatMap(GroupMembership.init(rawValue:)),
              let index = self.index["value"].flatMap(GroupIndexVisibility.init(rawValue:)) else {
            onError(conflict: false)
            return
        }
        let request = GroupSnapshot(
            privacy: createIncognitoGroup ? .incognito : .publicGroup,
            localpart: localpart,
            info: GroupInfo(
                name: groupName,
                description: descr.isEmpty ? nil : descr
            ),
            settings: GroupSettings(membership: membership, index: index)
        )

        Task { [weak self, weak account] in
            guard let self, let account else { return }
            do {
                let snapshot = try await account.groupchatService.create(
                    serviceJID: serviceJID,
                    snapshot: request
                )
                guard let rawGroupJID = snapshot.jid else {
                    throw GroupRepositoryError.invalidGroupJID
                }
                let groupJID = GroupStorageKey.bareJID(rawGroupJID)
                guard !groupJID.isEmpty else {
                    throw GroupRepositoryError.invalidGroupJID
                }
                let repository = GroupRepository(realm: try WRealm.safe())
                _ = try await CanonicalCreatedGroupOwnerAdmission.admit(
                    snapshot: snapshot,
                    owner: owner,
                    repository: repository,
                    refreshMembers: { groupJID in
                        try await account.groupchatService.refreshMembers(
                            groupJID: groupJID
                        )
                    }
                )
                account.groupMembershipDidActivate(groupJID)
                await MainActor.run {
                    self.onSuccess(groupJID: groupJID)
                }
            } catch let GroupchatServiceError.iq(error) {
                await MainActor.run {
                    self.onError(conflict: error.condition == "conflict")
                }
            } catch {
                await MainActor.run {
                    self.onError(conflict: false)
                }
            }
        }
    }
    
    internal func onSuccess(groupJID: String) {
        self.inSaveMode.accept(false)
        
        guard let owner = self.account["value"] else {
            return
        }

        DispatchQueue.main.async {
            self.dismiss(animated: true) {
                if self.leftMenuSelectRootCategoryDelegate != nil {
                    self.leftMenuSelectRootCategoryDelegate?.openChatlistWithChat(
                        owner: owner,
                        jid: groupJID,
                        conversationType: .group,
                        configure: { chatViewController in
                            chatViewController?
                                .prepareForNewlyCreatedGroupPresentation()
                        }
                    )
                } else {
                    let vc = ChatViewController()
                    vc.jid = groupJID
                    vc.owner = owner
                    vc.conversationType = .group
                    vc.prepareForNewlyCreatedGroupPresentation()
                    
                    if let presenterVc = self.presentationController {
                        showStacked(vc, in: presenterVc.presentingViewController)
                    }
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
