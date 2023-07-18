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
import Toast_Swift
import CocoaLumberjack

protocol MessagesSelectionPanelActionDelegate {
    func selectionPanel(onClose panel: ChatViewController.SelectionPanel)
    func selectionPanel(onDelete panel: ChatViewController.SelectionPanel)
    func selectionPanel(onCopy panel: ChatViewController.SelectionPanel)
    func selectionPanel(onShare panel: ChatViewController.SelectionPanel)
    func selectionPanel(onReply panel: ChatViewController.SelectionPanel)
    func selectionPanel(onForward panel: ChatViewController.SelectionPanel)
    func selectionPanel(onEdit panel: ChatViewController.SelectionPanel)
}

extension ChatViewController: MessagesSelectionPanelActionDelegate {
    class SelectionPanel: UIView {
        
        var delegate: MessagesSelectionPanelActionDelegate? = nil
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            stack.spacing = 12
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
            
            return stack
        }()
        
        let closeButton: UIButton = {
            let button = UIButton()
            
            button.setImage(#imageLiteral(resourceName: "feather_close_24pt").withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = MDCPalette.grey.tint500
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, bottom: 10, left: 10, right: 10)
            
            return button
        }()
        
        let selectionLabel: UILabel = {
            let label = UILabel()
            
            label.text = "0"
            label.textColor = MDCPalette.grey.tint700
            label.textAlignment = .left
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        let deleteButton: UIButton = {
            let button = UIButton()
            
            button.setImage(#imageLiteral(resourceName: "trash").withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = MDCPalette.grey.tint500
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, bottom: 10, left: 10, right: 10)
            
            return button
        }()
        
        let shareButton: UIButton = {
            let button = UIButton()
            
            button.setImage(#imageLiteral(resourceName: "share").withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = MDCPalette.grey.tint500
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, bottom: 10, left: 10, right: 10)
            
            return button
        }()
        
        let copyButton: UIButton = {
            let button = UIButton()
            
            button.setImage(#imageLiteral(resourceName: "copy").withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = MDCPalette.grey.tint500
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, bottom: 10, left: 10, right: 10)
            
            return button
        }()
        
        let replyButton: UIButton = {
            let button = UIButton()
            
            button.setImage(#imageLiteral(resourceName: "reply").withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = MDCPalette.grey.tint500
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, bottom: 10, left: 10, right: 10)
            
            return button
        }()
        
        let forwardButton: UIButton = {
            let button = UIButton()
            
            button.setImage(#imageLiteral(resourceName: "forward").withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = MDCPalette.grey.tint500
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, bottom: 10, left: 10, right: 10)
            
            return button
        }()
        
        let editButton: UIButton = {
            let button = UIButton()
            
            button.setImage(#imageLiteral(resourceName: "pencil").withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = MDCPalette.grey.tint500
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, bottom: 10, left: 10, right: 10)
            
            return button
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
        
        internal var buttonConstraints: [NSLayoutConstraint] = []
        
        internal func setup() {
            self.backgroundColor = .inputBarGray
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(closeButton)
            stack.addArrangedSubview(selectionLabel)
            stack.addArrangedSubview(editButton)
            stack.addArrangedSubview(deleteButton)
            stack.addArrangedSubview(copyButton)
            stack.addArrangedSubview(replyButton)
            stack.addArrangedSubview(forwardButton)
            closeButton.addTarget(self, action: #selector(onCloseButtonPress), for: .touchUpInside)
            deleteButton.addTarget(self, action: #selector(onDeleteButtonPress), for: .touchUpInside)
            copyButton.addTarget(self, action: #selector(onCopyButtonPress), for: .touchUpInside)
            shareButton.addTarget(self, action: #selector(onShareButtonPress), for: .touchUpInside)
            replyButton.addTarget(self, action: #selector(onReplyButtonPress), for: .touchUpInside)
            forwardButton.addTarget(self, action: #selector(onForwardButtonPress), for: .touchUpInside)
            editButton.addTarget(self, action: #selector(onEditButtonPress), for: .touchUpInside)
            buttonConstraints = []
            buttonConstraints.append(contentsOf: [closeButton,
                                                  deleteButton,
                                                  copyButton,
                                                  replyButton,
                                                  shareButton]
                .compactMap { $0.widthAnchor.constraint(equalToConstant: 44)})
            
            buttonConstraints.append(contentsOf: [closeButton,
                                                  deleteButton,
                                                  copyButton,
                                                  replyButton,
                                                  shareButton]
                .compactMap { $0.heightAnchor.constraint(equalToConstant: 44)})
        }
        
        @objc
        internal func onCloseButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onClose: self)
        }
        
        @objc
        internal func onDeleteButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onDelete: self)
        }
        
        @objc
        internal func onCopyButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onCopy: self)
        }
        
        @objc
        internal func onShareButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onShare: self)
        }
        
        @objc
        internal func onReplyButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onReply: self)
        }
        
        @objc
        internal func onForwardButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onForward: self)
        }
        
        @objc
        internal func onEditButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onEdit: self)
        }
        
        open func show() {
            NSLayoutConstraint.activate(buttonConstraints)
        }
        
        open func hide() {
            NSLayoutConstraint.deactivate(buttonConstraints)
        }
        
        open func updateSelectionCount(_ count: Int) {
            self.selectionLabel.text = "\(count)"
        }
        
    }
    
    func showSelectionPanel() {
        self.selectionPanel.frame = CGRect(width: self.view.frame.width, height: 44)
        self.xabberInputBar.addSubview(self.selectionPanel)
        self.xabberInputBar.bringSubviewToFront(self.selectionPanel)
    }
    
    func hideSelectionPanel() {
        self.selectionPanel.removeFromSuperview()
    }
    
    func selectionPanel(onClose panel: ChatViewController.SelectionPanel) {
        cancelSelection()
    }
    
    func selectionPanel(onDelete panel: ChatViewController.SelectionPanel) {
        let toDeleteIds = forwardedIds.value
        deleteMessages(forIds: toDeleteIds)
        cancelSelection()
    }
    
    func selectionPanel(onCopy panel: ChatViewController.SelectionPanel) {
        if let text = formatSelectedMessagesBodyForCopy() {
            UIPasteboard.general.string = text
        } else {
            showToast(error: "Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
        }
        cancelSelection()
    }
    
    func selectionPanel(onShare panel: ChatViewController.SelectionPanel) {
        if let text = formatSelectedMessagesBodyForCopy() {
            let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            vc.popoverPresentationController?.sourceView = self.view
            present(vc, animated: true, completion: nil)
        } else {
            showToast(error: "Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
        }
        cancelSelection()
    }
    
    func selectionPanel(onReply panel: ChatViewController.SelectionPanel) {
        attachedMessagesIds.accept(Array(forwardedIds.value))
        cancelSelection()
    }
    
    func selectionPanel(onForward panel: ChatViewController.SelectionPanel) {
        showShareViewController(Array(forwardedIds.value))
        cancelSelection()
    }
    
    func selectionPanel(onEdit panel: ChatViewController.SelectionPanel) {
        if let primary = forwardedIds.value.first,
            let body = messagesObserver?.first(where: { $0.primary == primary })?.body {
            editMessageId.accept(primary)
            self.xabberInputBar.inputTextView.text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        cancelSelection()
    }
    
    internal func formatSelectedMessagesBodyForCopy() -> String? {
        do {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "[HH:mm:ss]"
            let realm = try WRealm.safe()
            let collection = realm
                .objects(MessageStorageItem.self)
                .filter("primary IN %@", Array(self.forwardedIds.value))
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
                if self.groupchat {
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
        let nvc = UINavigationController(rootViewController: vc)
        nvc.modalPresentationStyle = .fullScreen
        nvc.modalTransitionStyle = .coverVertical
        self.definesPresentationContext = true
        self.present(nvc, animated: true, completion: nil)
    }
    
    internal func cancelSelection() {
        self.forwardedIds.accept(Set<String>())
//        self.forwardedIds.value.removeAll()
        self.isInSelectionMode.accept(false)
        self.messagesCollectionView.reloadDataAndKeepOffset()
    }
    
    @objc
    internal func onClearChat() {
        DispatchQueue.main.async {
            DeleteMessagePresenter(username: self.opponentSender.displayName, groupchat: self.groupchat, sended: true)
                .present(in: self, animated: true) { (result) in
                    if let result = result {
                        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                            session.retract?.deleteAllMessages(
                                stream,
                                jid: self.jid,
                                conversationType: self.conversationType,
                                callback: { (error, success) in
                                    DispatchQueue.main.async {
                                        if let error = error {
                                            self.view.makeToast(error)
                                        }
                                    }
                                })
                        }, fail: {
                            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                user.msgDeleteManager
                                    .deleteAllMessages(
                                        stream,
                                        jid: self.jid,
                                        conversationType: self.conversationType
                                    ) { (error, success) in
                                        DispatchQueue.main.async {
                                            if let error = error {
                                                self.view.makeToast(error)
                                            }
                                        }
                                    }
                            })
                        })
                    }
                }
            }
        cancelSelection()
    }
    
    @objc
    internal func onCancelSelection() {
        cancelSelection()
    }
    
    internal func deleteMessages(forIds toDeleteIds: Set<String>) {
        DeleteMessagePresenter(username: self.opponentSender.displayName, groupchat: self.groupchat, sended: true)
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
                        
                        self.canUpdateDataset = true
                        self.runDatasetUpdateTask()
                    } catch {
                        DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                    }
                    modifiedIds.forEach {
                        primary in
                        DispatchQueue.main.async {
                            self.view.makeToastActivity(ToastPosition.center)
                        }
                        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                            session.retract?.deleteMessage(
                                stream,
                                primary: primary,
                                jid: self.groupchat ? self.jid : "",
                                symmetric: result,
                                callback: { (errorMessage, success) in
                                    DispatchQueue.main.async {
                                        self.view.hideToastActivity()
                                        if let error = errorMessage {
                                            self.showToast(error: error)
                                        }
                                    }
                                })
                        }, fail: {
                            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                user.msgDeleteManager
                                    .deleteMessage(stream,
                                                   primary: primary,
                                                   jid: self.groupchat ? self.jid : "",
                                                   symmetric: result)
                                {
                                    (errorMessage, success) in
                                    DispatchQueue.main.async {
                                        self.view.hideToastActivity()
                                        if let error = errorMessage {
                                                self.showToast(error: error)
                                        }
                                    }
                                }
                            })
                        })
                    }
                }
            }
    }
    
}
