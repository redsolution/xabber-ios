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
import Toast_Swift

class GroupChatMessagesByUserViewController: ChatViewController {
    public var userId: String = ""
    
    public var nickname: String = ""
    
    override var groupchat: Bool {
        get {
            return true
        } set {
            self.groupchat = true
        }
    }
    
    override func prepareDataset() -> Results<MessageStorageItem> {
        do {
            let realm = try WRealm.safe()
            let dataset: Results<MessageStorageItem>
            realm.refresh()
            if let value = self.searchTextObserver.value,
               value.isNotEmpty {
                dataset = realm
                    .objects(MessageStorageItem.self)
                    .filter ("owner == %@ AND opponent == %@ AND body CONTAINS[cd] %@ AND isDeleted == false AND groupchatCard.userId == %@", self.owner, self.jid, value, self.userId)
                    .sorted (byKeyPath: "date", ascending: false)
            } else {
                dataset = realm
                    .objects(MessageStorageItem.self)
                    .filter ("owner == %@ AND opponent == %@ AND isDeleted == false AND groupchatCard.userId == %@", self.owner, self.jid, self.userId)
                    .sorted (byKeyPath: "date", ascending: false)
            }
            return dataset
        } catch {
            fatalError()
        }
    }
    
    override func reloadDataset(withSearchText value: String?) {
        DispatchQueue.main.async {
            do {
                let realm = try WRealm.safe()
                if let value = value {
                    self.messagesObserver = realm
                        .objects(MessageStorageItem.self)
                        .filter("owner == %@ AND opponent == %@ AND body CONTAINS[cd] %@ AND isDeleted == false AND groupchatCard.userId == %@", self.owner, self.jid, value, self.userId)
                        .sorted(byKeyPath: "date", ascending: false)
                    self.shouldUpdateMessagesCount = true
                } else {
                    self.messagesObserver = realm
                        .objects(MessageStorageItem.self)
                        .filter("owner == %@ AND opponent == %@ AND isDeleted == false AND groupchatCard.userId == %@", self.owner, self.jid, self.userId)
                        .sorted(byKeyPath: "date", ascending: false)
                }
                self.subscribeOnDatasetChanges()
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    override func configureNavigationBar() {
        navigationController?.setNavigationBarHidden(false, animated: false)
        let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))
        let deleteButton = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(deleteUserMessages))
        self.navigationItem.setLeftBarButton(cancelButton, animated: true)
        self.navigationItem.setRightBarButton(deleteButton, animated: true)
        self.title = "User messages".localizeString(id: "groupchats_user_messages", arguments: [])
    }
    
//    override func configurePinMessagePanel() {
//        
//    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        do {
            let realm = try WRealm.safe()
            self.nickname = realm.object(ofType: GroupchatUserStorageItem.self, forPrimaryKey: [self.userId, self.jid, self.owner].prp())?.nickname ?? self.userId
        } catch {
            DDLogDebug("GroupChatMessagesByUserViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    @objc
    internal func close(_ sender: AnyObject) {
        self.dismiss(animated: true, completion: nil)
    }
    
    @objc
    internal func deleteUserMessages(_ sender: AnyObject) {
        let deleteItems: [ActionSheetPresenter.Item] = [
            ActionSheetPresenter.Item(destructive: true, title: "Delete".localizeString(id: "delete_chat_button", arguments: []), value: "delete"),
        ]
        let message = "Delete all \(self.nickname) messages in this group chat?".localizeString(id: "dialog_delete_user_messages__confirm", arguments: [])
        ActionSheetPresenter().present(
            in: self,
            title: "Delete user messages".localizeString(id: "dialog_delete_user_messages__header", arguments: []),
            message: message,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: deleteItems,
            animated: true
        ) { (value) in
            switch value {
            case "delete":
                self.view.makeToastActivity(ToastPosition.center)
                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                    session.retract?.deleteMessageGroupchat(stream, chat: self.jid, userId: self.userId)
                    { (error, result) in
                        DispatchQueue.main.async {
                            self.view.hideToastActivity()
                        }
                        if result {
                            self.postDeleteAllMessages()
                        } else {
                            DispatchQueue.main.async {
                                if let error = error {
                                    self.view.makeToast("Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"]))
                                }
                            }
                        }
                    }
                }, fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.msgDeleteManager
                            .deleteMessageGroupchat(stream, chat: self.jid, userId: self.userId)
                            { (error, result) in
                                DispatchQueue.main.async {
                                    self.view.hideToastActivity()
                                }
                                if result {
                                    self.postDeleteAllMessages()
                                } else {
                                    DispatchQueue.main.async {
                                        if let error = error {
                                            self.view.makeToast("Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"]))
                                        }
                                    }
                                }
                            }
                    })
                })
            default:
                break
            }
        }

    }
    
    private final func postDeleteAllMessages(){
        do {
            let realm = try WRealm.safe()

            let collection = realm
                .objects(MessageStorageItem.self)
                .filter ("owner == %@ AND opponent == %@ AND isDeleted == false AND groupchatCard.userId == %@", self.owner, self.jid, self.userId)
            
            try realm.write {
                realm.delete(collection)
            }
            
        } catch {
            DDLogDebug("GroupChatMessagesByUserViewController: \(#function). \(error.localizedDescription)")
        }
        DispatchQueue.main.async {
            self.dismiss(animated: true, completion: nil)
        }
    }
}
