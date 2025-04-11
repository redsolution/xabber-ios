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
import MaterialComponents.MDCPalettes
import CocoaLumberjack

protocol MessagesSelectionPanelActionDelegate {
    func selectionPanel(onClose panel: ModernXabberInputView.SelectionPanel)
    func selectionPanel(onDelete panel: ModernXabberInputView.SelectionPanel)
    func selectionPanel(onCopy panel: ModernXabberInputView.SelectionPanel)
    func selectionPanel(onShare panel: ModernXabberInputView.SelectionPanel)
    func selectionPanel(onReply panel: ModernXabberInputView.SelectionPanel)
    func selectionPanel(onForward panel: ModernXabberInputView.SelectionPanel)
    func selectionPanel(onEdit panel: ModernXabberInputView.SelectionPanel)
}

extension ChatViewController: MessagesSelectionPanelActionDelegate {
    
    
//    func showSelectionPanel() {
//        self.selectionPanel.frame = CGRect(width: self.view.frame.width, height: 44)
//        self.xabberInputBar.addSubview(self.selectionPanel)
//        self.xabberInputBar.bringSubviewToFront(self.selectionPanel)
//    }
//    
//    func hideSelectionPanel() {
//        self.selectionPanel.removeFromSuperview()
//    }
    
    func selectionPanel(onClose panel: ModernXabberInputView.SelectionPanel) {
        cancelSelection()
    }
    
    func selectionPanel(onDelete panel: ModernXabberInputView.SelectionPanel) {
        let toDeleteIds = forwardedIds.value
        deleteMessages(forIds: toDeleteIds)
        cancelSelection()
    }
    
    @objc
    func onDeleteAllMessagesButtonTouchDown(_ sender: UIBarButtonItem) {
        deleteAllMessages()
        cancelSelection()
    }
    
    @objc
    func onDeleteMessagesButtonTouchDown(_ sender: UIBarButtonItem) {
        let toDeleteIds = forwardedIds.value
        deleteMessages(forIds: toDeleteIds)
        cancelSelection()
    }
    
    func selectionPanel(onCopy panel: ModernXabberInputView.SelectionPanel) {
        if let text = formatSelectedMessagesBodyForCopy() {
            UIPasteboard.general.string = text
            
            ToastPresenter().presentSuccess(message: "Text was copied to clipboard")
        } else {
            ToastPresenter().presentError(message: "Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
        }
        cancelSelection()
    }
    
    func selectionPanel(onShare panel: ModernXabberInputView.SelectionPanel) {
        if let text = formatSelectedMessagesBodyForCopy() {
            let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            vc.popoverPresentationController?.sourceView = self.view
            present(vc, animated: true, completion: nil)
        } else {
            ToastPresenter().presentError(message: "Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
        }
        cancelSelection()
    }
    
    func selectionPanel(onReply panel: ModernXabberInputView.SelectionPanel) {
        attachedMessagesIds.accept(Array(forwardedIds.value))
        cancelSelection()
    }
    
    func selectionPanel(onForward panel: ModernXabberInputView.SelectionPanel) {
        showShareViewController(Array(forwardedIds.value))
        cancelSelection()
    }
    
    func selectionPanel(onEdit panel: ModernXabberInputView.SelectionPanel) {
        
    }
    
    internal func formatSelectedMessagesBodyForCopy(forwardedIdsManual: [String]? = nil) -> String? {
        do {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "[HH:mm:ss]"
            let realm = try WRealm.safe()
            let ids: [String] = forwardedIdsManual ?? Array(self.forwardedIds.value)
            let collection = realm
                .objects(MessageStorageItem.self)
                .filter("primary IN %@", ids)
                .sorted(byKeyPath: "date", ascending: true)
            return collection.compactMap {
                (item) -> String? in
                var body: String = ""
                if item.legacyBody.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty {
                    body = item.legacyBody
                } else {
                    body = item.body
                }
                let timeString = timeFormatter.string(from: item.date)
                var nickname: String = ""
                if self.conversationType == .group {
                    if let gcNickname = realm.objects(GroupchatUserStorageItem.self)
                        .filter("groupchatId == %@ AND jid == %@", [self.jid, self.owner].prp(), item.outgoing ? item.owner : item.opponent).first?.nickname {
                        nickname = gcNickname
                    }
                } else {
                    nickname = item.outgoing ? self.ownerSender.displayName : self.opponentSender.displayName
                }
                return [dateFormatter.string(from: item.date), [timeString, nickname].joined(separator: " "), body].joined(separator: "\n")
            }.joined(separator: "\n")
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        return nil
    }
    
    internal func showShareViewController(_ messages: [String]) {
        let vc = ShareDialogController()
        vc.owner = self.owner
        vc.forwardIds = messages
        vc.delegate = self
        showModal(vc)
    }
    
    internal func cancelSelection() {
        self.forwardedIds.accept(Set<String>())
//        self.forwardedIds.value.removeAll()
        self.isInSelectionMode.accept(false)
        self.messagesCollectionView.reloadDataAndKeepOffset()
    }
    
    @objc
    internal func onClearChat() {
//        DispatchQueue.main.async {
//            DeleteMessagePresenter(username: self.opponentSender.displayName, groupchat: self.groupchat, sended: true)
//                .present(in: self, animated: true) { (result) in
//                    if let result = result {
//                        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
//                            session.retract?.deleteAllMessages(
//                                stream,
//                                jid: self.jid,
//                                conversationType: self.conversationType,
//                                callback: { (error, success) in
//                                    DispatchQueue.main.async {
//                                        if let error = error {
//                                            self.view.makeToast(error)
//                                        }
//                                    }
//                                })
//                        }, fail: {
//                            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                                user.msgDeleteManager
//                                    .deleteAllMessages(
//                                        stream,
//                                        jid: self.jid,
//                                        conversationType: self.conversationType
//                                    ) { (error, success) in
//                                        DispatchQueue.main.async {
//                                            if let error = error {
//                                                self.view.makeToast(error)
//                                            }
//                                        }
//                                    }
//                            })
//                        })
//                    }
//                }
//            }
        cancelSelection()
    }
    
    @objc
    internal func onCancelSelection(_ sender: AnyObject) {
        cancelSelection()
    }
    
    internal func deleteAllMessages() {
//        ActionSheetPresenter().present(
//            in: self,
//            title: nil,
//            message: "Do you want to clear chat history",
//            cancel: "Cancel",
//            values: [ActionSheetPresenter.Item(destructive: true, title: "Clear", value: "delete")],
//            animated: true) { value in
//                switch value {
//                    case "delete":
//                        DispatchQueue.main.async {
//                            self.view.makeToastActivity(ToastPosition.center)
//                        }
//                        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
//                            session.retract?.deleteAllMessages(
//                                stream,
//                                jid: self.jid,
//                                conversationType: self.conversationType,
//                                callback: { (errorMessage, success) in
//                                    LastChats.updateErrorState(for: self.jid, owner: self.owner, conversationType: self.conversationType)
//                                    DispatchQueue.main.async {
//                                        self.view.hideToastActivity()
//                                        if let error = errorMessage {
//                                            self.showToast(error: error)
//                                        }
//                                    }
//                                })
//                        }, fail: {
//                            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                                user.msgDeleteManager
//                                    .deleteAllMessages(
//                                        stream,
//                                        jid: self.jid,
//                                        conversationType: self.conversationType,
//                                        callback: { (errorMessage, success) in
//                                            LastChats.updateErrorState(for: self.jid, owner: self.owner, conversationType: self.conversationType)
//                                            DispatchQueue.main.async {
//                                                self.view.hideToastActivity()
//                                                if let error = errorMessage {
//                                                    self.showToast(error: error)
//                                                }
//                                            }
//                                        })
//                            })
//                        })
//                    default: break
//                }
//            }
    }
    
    internal func deleteMessages(forIds toDeleteIds: Set<String>) {
        DeleteMessagePresenter(username: self.opponentSender.displayName, groupchat: self.conversationType == .group, sended: true)
            .present(in: self, animated: true) { (result) in
                if let result = result {
                    var modifiedIds: Set<String> = Set<String>()
                    do {
                        let realm = try WRealm.safe()
                        try toDeleteIds.forEach {
                            primary in
                            try realm.write {
                                if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                                    if instance.state == .error {
                                        if instance.isInvalidated { return }
                                        realm.delete(instance)
                                    } else {
                                        instance.isDeleted = true
                                        modifiedIds.insert(primary)
                                    }
                                }
                            }
                            (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?
                                .invalidateLastMessageCachedSize(primary: primary)
                        }
                        
//                        self.canUpdateDataset = true
//                        self.runDatasetUpdateTask()
                    } catch {
                        DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                    }
                    var messagesQueue = modifiedIds
                    modifiedIds.forEach {
                        primary in
                        DispatchQueue.main.async {
                            self.view.makeToastActivity(ToastPosition.center)
                        }
                        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                            session.retract?.deleteMessage(
                                stream,
                                primary: primary,
                                jid: self.conversationType == .group ? self.jid : "",
                                conversationType: self.conversationType,
                                symmetric: result,
                                callback: { (errorMessage, success) in
                                    DispatchQueue.main.async {
                                        self.view.hideToastActivity()
                                        if let error = errorMessage {
                                            ToastPresenter().presentError(message: error)
                                        } else {
                                            messagesQueue.remove(primary)
                                            if messagesQueue.isEmpty {
                                                ToastPresenter().presentSuccess(message: "Success")
                                            }
                                        }
                                    }
                                })
                        }, fail: {
                            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                user.msgDeleteManager
                                    .deleteMessage(stream,
                                                   primary: primary,
                                                   jid: self.conversationType == .group ? self.jid : "",
                                                   conversationType: self.conversationType,
                                                   symmetric: result)
                                {
                                    (errorMessage, success) in
                                    DispatchQueue.main.async {
                                        self.view.hideToastActivity()
                                        if let error = errorMessage {
                                            ToastPresenter().presentError(message: error)
                                        } else {
                                            messagesQueue.remove(primary)
                                            if messagesQueue.isEmpty {
                                                ToastPresenter().presentSuccess(message: "Success")
                                            }
                                        }
                                    }
                                }
                            })
                        })
                    }
                    LastChats.updateErrorState(for: self.jid, owner: self.owner, conversationType: self.conversationType)
                }
            }
    }
    
}
