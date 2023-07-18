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

extension EditContactViewController {
    
    internal func textFieldDidChangeValue(target: String, value: String?) {
        switch target {
        case "contact_edit_nickname": nickname.accept(value)
        case "contact_new_group": break
        default: break
        }
    }
    
    internal func validate() -> Bool {
        if self.isCircleSelectView {
            if initialGroups != selectedGroups.value {
                return true
            }
        } else {
            if initialNickname != nickname.value {
                return true
            }
        }
        return false
    }
    
    internal func onRosterUpdate(_ success: Bool, error: String?) {
        DispatchQueue.main.async {
            if success {
                self.dismiss(animated: true, completion: nil)
                self.dismissKeyboard()
                self.inSaveMode.accept(false)
                self.saveButtonActive.accept(false)
            } else {
                var message: String = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
                if let error = error {
                    switch error {
                    case "item-not-found":
                        message = "JID \(self.jid) not found".localizeString(id: "contact_jid_not_found", arguments: ["\(self.jid)"])
                    case "forbidden":
                        message = "Can`t perform request".localizeString(id: "contact_cant_perform_request", arguments: [])
                    case "not-acceptable":
                        message = "Invalid circles list".localizeString(id: "invalid_circles_list", arguments: [])
                    case "remote-server-not-found":
                        message = "Remote server not found".localizeString(id: "error_server_not_found", arguments: [])
                    default: break
                    }
                }
                self.view.makeToast(message)
                self.inSaveMode.accept(false)
            }
        }
    }
    
    internal func onSave() {
        var delayedDismiss: Bool = false
        if initialNickname != nickname.value || initialGroups != selectedGroups.value {
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                session.roster?.setContact(stream,
                                       jid: self.jid,
                                       nickname: self.nickname.value,
                                       groups: self.selectedGroups.value.sorted())
                { (jid, error, success) in
                    self.onRosterUpdate(success, error: error)
                }
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                    user.roster.setContact(stream,
                                           jid: self.jid,
                                           nickname: self.nickname.value,
                                           groups: self.selectedGroups.value.sorted())
                    { (jid, error, success) in
                        self.onRosterUpdate(success, error: error)
                    }
                })
            }

            
            delayedDismiss = true
        }
        if isGroupchat { return }
        if !delayedDismiss {
            self.dismiss(animated: true, completion: nil)
        }
    }
    
    func onPresenceReceiveRowTap() {
        var items: [ActionSheetPresenter.Item] = []
        
        switch subscribtion.value {
        case .to:
            switch ask.value {
            case .none, .in:
                items = [
                    ActionSheetPresenter.Item(destructive: false, title: "Stop receiving", value: "unsubscribe")
                ]
            default:
                break
            }
        case .from:
            switch ask.value {
            case .none:
                items = [
                    ActionSheetPresenter.Item(destructive: false, title: "Request subscription", value: "subscribe")
                ]
            case .out:
                items = [
                    ActionSheetPresenter.Item(destructive: false, title: "Cancel request", value: "unsubscribe")
                ]
            default:
                break
            }
        case .both:
            items = [
                ActionSheetPresenter.Item(destructive: false, title: "Stop receiving", value: "unsubscribe")
            ]
        case .none:
            switch ask.value {
            case .none, .in:
                items = [
                    ActionSheetPresenter.Item(destructive: false, title: "Request subscription", value: "subscribe")
                ]
            case .out, .both:
                items = [
                    ActionSheetPresenter.Item(destructive: false, title: "Cancel request", value: "unsubscribe")
                ]
            }
        case .undefined:
            items = [
                ActionSheetPresenter.Item(destructive: false, title: "Add contact", value: "add_contact")
            ]
        }
        
        ActionSheetPresenter().present(in: self, title: nil, message: nil, cancel: "Cancel".localizeString(id: "cancel", arguments: []), values: items, animated: true) { key in
            self.shouldSendPresenceRequest(key)
        }
    }
    
    func onPresenceSendRowTap() {
        var items: [ActionSheetPresenter.Item] = []
        
        print("contact", self.jid, subscribtion.value, ask.value, approved.value)
        
        switch subscribtion.value {
        case .to:
            switch ask.value {
            case .none:
                if approved.value {
                    items = [
                        ActionSheetPresenter.Item(destructive: false, title: "Unallow subscription", value: "unsubscribed")
                    ]
                } else {
                    items = [
                        ActionSheetPresenter.Item(destructive: false, title: "Allow subscription", value: "subscribed")
                    ]
                }
            case .in:
                items = [
                    ActionSheetPresenter.Item(destructive: false, title: "Allow subscription", value: "subscribed"),
                    ActionSheetPresenter.Item(destructive: false, title: "Decline", value: "unsubscribed")
                ]
            default:
                break
            }
        case .from:
            switch ask.value {
            case .none, .out:
                items = [
                    ActionSheetPresenter.Item(destructive: false, title: "Stop sending", value: "unsubscribed")
                ]
            default:
                break
            }
        case .both:
            items = [
                ActionSheetPresenter.Item(destructive: false, title: "Stop sending", value: "unsubscribed")
            ]
        case .none:
            switch ask.value {
            case .none, .out:
                if approved.value {
                    items = [
                        ActionSheetPresenter.Item(destructive: false, title: "Unallow subscribtion", value: "unsubscribed")
                    ]
                } else {
                    items = [
                        ActionSheetPresenter.Item(destructive: false, title: "Allow subscribtion".localizeString(id: "contact_subscription_allow_subscription", arguments: []), value: "subscribed")
                    ]
                }
            case .in, .both:
                items = [
                    ActionSheetPresenter.Item(destructive: false, title: "Allow subscribtion".localizeString(id: "contact_subscription_allow_subscription", arguments: []), value: "subscribed"),
                    ActionSheetPresenter.Item(destructive: false, title: "Decline".localizeString(id: "decline", arguments: []), value: "unsubscribed")
                ]
            }
        case .undefined:
            return
        }
        
        ActionSheetPresenter().present(in: self, title: nil, message: nil, cancel: "Cancel".localizeString(id: "cancel", arguments: []), values: items, animated: true) { key in
            self.shouldSendPresenceRequest(key)
        }
    }
    
    private func shouldSendPresenceRequest(_ value: String) {
        switch value {
        case "subscribe":
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.presences.subscribe(stream, jid: self.jid)
            })
        case "unsubscribe":
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.presences.unsubscribe(stream, jid: self.jid)
            })
        case "subscribed":
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.presences.subscribed(stream, jid: self.jid, storePreaproved: false)
            })
        case "unsubscribed":
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.presences.unsubscribed(stream, jid: self.jid)
            })
        case "add_contact":
            AccountManager.shared.find(for: owner)?.action({ user, stream in
                user.presences.subscribe(stream, jid: self.jid)
                user.presences.subscribed(stream, jid: self.jid)
            })
            XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
                session.roster?.setContact(stream, jid: self.jid, nickname: self.nickname.value, groups: [], callback: nil)
                session.vcardManager?.requestItem(stream, jid: self.jid)
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.roster.setContact(stream, jid: self.jid, nickname: self.nickname.value, groups: [], callback: nil)
                    user.vcards.requestItem(stream, jid: self.jid)
                })
            }
        default:
            break
        }
    }
    
    internal final func deleteContact() {
        
        do {
            let realm = try WRealm.safe()
            let displayedName = realm.object(ofType: RosterStorageItem.self,
                                             forPrimaryKey: [jid, owner].prp())?.displayName ?? jid
            let deleteItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: true, title: "Delete".localizeString(id: "delete", arguments: []), value: "delete"),
            ]
            ActionSheetPresenter().present(
                in: self,
                title: "Delete contact".localizeString(id: "remove_contact", arguments: []),
                message: "Do you really want to delete contact \(displayedName)?",
                cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                values: deleteItems,
                animated: true
            ) { value in
                switch value {
                case "delete":
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        user.roster.removeContact(stream, jid: self.jid)
                    })
                    DispatchQueue.main.async {
                        self.navigationController?.popViewController(animated: true)
                    }
                default: break
                }
            }
        } catch {
            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
}
