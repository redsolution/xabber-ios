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
import RxRealm
import RxSwift
import RxCocoa
import DeepDiff
import CocoaLumberjack
import XMPPFramework.XMPPJID

extension ChatViewController {

    internal func subscribe() throws {
        NotifyManager.shared.currentDialog = [self.jid, self.owner].prp()
        self.reloadDataset(withSearchText: self.searchTextObserver.value)
        self.bag = DisposeBag()
        DispatchQueue.global(qos: .default).async {
            do {
                let realm = try  WRealm.safe()
                self.showMyNickname = realm
                    .objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@ AND isMe == true", [self.jid, self.owner].prp())
                    .first?
                    .nickname == AccountManager.shared.find(for: self.owner)?.username
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
        let realm = try WRealm.safe()
        
        Observable
            .collection(from: realm
                .objects(GroupchatInvitesStorageItem.self)
                .filter("owner == %@ AND groupchat == %@ AND isProcessed == false", self.owner, self.jid))
            .subscribe { (results) in
                if let item = results.first {
                    self.didReceiveInvite(item.primary)
                }
            } onError: { (error) in
                DDLogDebug("ChatViewController: \(#function). Invite error \(error.localizedDescription)")
            } onCompleted: {
                DDLogDebug("ChatViewController: \(#function). Invite completed")
            } onDisposed: {
                DDLogDebug("ChatViewController: \(#function). Invite disposed")
            }
            .disposed(by: bag)
        
        inSearchMode
            .asObservable()
            .subscribe(onNext: { (value) in
                if value {
                    self.configureSearchBar()
                } else {
                    self.searchTextObserver.accept(nil)
                    self.configureNavigationBar()
                }
            })
            .disposed(by: bag)
        
        searchTextObserver
            .asObservable()
            .skip(1)
            .subscribe(onNext: { (value) in
                self.reloadDataset(withSearchText: value)
            })
            .disposed(by: bag)
        
        self.topPanelState
            .asObservable()
            .debounce(.nanoseconds(1), scheduler: MainScheduler.asyncInstance)
            .subscribe { state in
                switch state {
                    case .none:
                        (self.navigationController as? NavBarController)?.clearAdditionalPanel()
                    case .pinnedMessage:
                        self.applyPinMessagePanel()
                    case .addContact:
                        self.applyAddContactPanel()
                    case .requestSubscribtion:
                        self.applyRequestSubscribtionPanel()
                    case .allowSubscribtion:
                        self.applyAllowSubscribtion()
                    case .requestedVerification:
                        self.applyRequestedVerificationPanel()
                    case .enterCodeVerification:
                        self.applyEnterCodePanel()
                    case .requestingVerification:
                        self.applyRequestingVerificationPanel()
                    case .shouldRequestVerification:
                        self.applyShouldRequestVerificationPanel()
                }
                switch state {
                    case .none:
                        (self.navigationController as? NavBarController)?.hideAdditionalPanel(animated: false)
                    default:
                        (self.navigationController as? NavBarController)?.showAdditionalPanel(animated: false)
                }
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: bag)

        
        if [.group, .channel].contains(self.conversationType) {
            try groupSubscribtions()
        } else {
            Observable
                .collection(from: realm
                                    .objects(ResourceStorageItem.self)
                                    .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                                    .sorted(by: [SortDescriptor(keyPath: "timestamp", ascending: false),
                                                 SortDescriptor(keyPath: "priority", ascending: false)]))
                .observe(on: MainScheduler.asyncInstance)
                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    let nickname = self.opponentSender.displayName
                    let offlineStatus = "last seen recently".localizeString(id: "last_seen_recently", arguments: [])
                    let status = (results.first?.statusMessage.isEmpty ?? true) ? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus) : results.first?.statusMessage ?? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus)
                    self.contactUsename = nickname
                    self.titleLabel.attributedText = self.updateTitle()
                    let statusStr = AccountManager.shared.connectingUsers.value.contains(self.owner) ? "Waiting for network...".localizeString(id: "waiting_for_network", arguments: []) : status
                    if self.statusLabel.text == " " {
                        self.statusLabel.text = statusStr
                    }
                    if self.shouldShowNormalStatus {
                        self.statusTextObserver.accept(statusStr)
                        self.contactStatus = status
                        self.statusLabel.layoutIfNeeded()
                    }
                    self.titleLabel.sizeToFit()
                    self.titleLabel.layoutIfNeeded()
                    
                })
                .disposed(by: bag)
        }
        
        let lastChatsObservedCollection = realm
            .objects(LastChatsStorageItem.self)
            .filter("jid == %@ AND owner == %@ AND conversationType_ == %@", self.jid, self.owner, self.conversationType.rawValue)
        if let chat = lastChatsObservedCollection.first {
            self.xabberInputView.textField.text = chat.draftMessage
            self.xabberInputView.textViewDidChange()
            self.updateContentByLastChatInstance(chat)
        }
        Observable
            .collection(from: lastChatsObservedCollection)
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .skip(1)
            .subscribe(onNext: { (results) in
                guard let item = results.first else {
                    self.showSkeletonObserver.accept(false)
                    return
                }
                self.updateContentByLastChatInstance(item)
                    
            })
            .disposed(by: bag)

        Observable
            .collection(from: realm
                .objects(RosterStorageItem.self)
                .filter("owner == %@ AND jid == %@", owner, jid))
            .debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                if self.groupchat { return }
                if (XMPPJID(string: self.jid)?.isServer ?? false) {
                    self.contactStatus = "Server"
                    self.updateStatusText()
                    return
                }
                if let item = results.first {
                    switch item.subscribtion {
                        case .none:
                            switch item.ask {
                                case .in, .both:
                                    self.topPanelState.accept(.addContact)
                                default:
                                    if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                        self.topPanelState.accept(.none)
                                    }
                            }
                        case .to:
                            switch item.ask {
                                case .in:
                                    self.topPanelState.accept(.addContact)
                                default:
                                    if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                        self.topPanelState.accept(.none)
                                    }
                            }
                        case .undefined:
                            switch item.ask {
                                case .in:
                                    self.topPanelState.accept(.requestSubscribtion)
                                default:
                                    if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                        self.topPanelState.accept(.none)
                                    }
                            }
                        default:
                            if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                self.topPanelState.accept(.none)
                            }
                    }
                    self.shouldShowNormalStatus = false
                    switch item.subscribtion {
                    case .from:
                        switch item.ask {
                            case .none:
                                self.contactStatus = "Receives your presence updates"
                                    .localizeString(id: "chat_receives_presence_updates", arguments: [])
                            case .out:
                                self.contactStatus = "Subscription request pending..."
                                    .localizeString(id: "chat_subscription_request_pending", arguments: [])
                            default:
                                break
                        }
                    case .none:
                        switch item.ask {
                        case .out, .both:
                            self.contactStatus = "Subscription request pending..."
                                .localizeString(id: "chat_subscription_request_pending", arguments: [])
                        case .in:
                            self.contactStatus = "In your contacts"
                                .localizeString(id: "contact_state_in_contact_list", arguments: [])
                        case .none:
                            self.contactStatus = "In your contacts"
                                .localizeString(id: "contact_state_in_contact_list", arguments: [])
                        }
                    case .undefined:
                        self.contactStatus = "Not in your contacts"
                            .localizeString(id: "contact_state_not_in_contact_list", arguments: [])
                    default:
                        self.shouldShowNormalStatus = true
                        break
                    }
                } else {
                    self.contactStatus = "Not in your contacts"
                        .localizeString(id: "contact_state_not_in_contact_list", arguments: [])
//                    self.showSubscribtionBar(animated: true, state: .notInRoster)
                }
                self.updateStatusText()
            }).disposed(by: bag)

        
        self.statusLabel.text = self.statusTextObserver.value
        self.statusLabel.layoutIfNeeded()
        self.statusTextObserver
            .asObservable()
            .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
            .subscribe { (value) in
                self.statusLabel.text = value
                self.statusLabel.layoutIfNeeded()
            } onError: { (error) in
                DDLogDebug("\(#function). \(error.localizedDescription)")
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: self.bag)

    }
    
    private final func updateContentByLastChatInstance(_ item: LastChatsStorageItem) {
        self.lastReadMessageId = item.lastReadId
        if self.showSkeletonObserver.value != (!item.isSynced) {
            self.showSkeletonObserver.accept(!item.isSynced)
            if item.isSynced {
                if item.unread > 0 {
                    self.updateQueue
                        .asyncAfter(deadline: .now() + 3) {
                            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                                user.messages.readLastMessage(jid: self.jid, conversationType: self.conversationType)
                            })
                        }
                }
            }
        }
        self.toolsButton.setUnreadBadge(item.unread)
        let id = self.opponentSender.id
        if !(item.rosterItem?.isInvalidated ?? false) {
            self.opponentSender = Sender(
                id: id,
                displayName: item.rosterItem?.displayName ?? item.jid
            )
        }
        self.contactUsename = self.opponentSender.displayName
        self.titleLabel.attributedText = self.updateTitle()
        self.statusTextObserver.accept(AccountManager
            .shared
            .connectingUsers
            .value
            .contains(self.owner) ? "Waiting for network..."
                    .localizeString(id: "waiting_for_network", arguments: []) : self.contactStatus ?? " ")
        
        switch ChatMarkersManager.BurnMessagesTimerValues(rawValue: Int(item.afterburnInterval)) {
            case .off, .none:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "stopwatch"), for: .normal)
            case .s5:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "5.circle"), for: .normal)
            case .s10:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "10.circle"), for: .normal)
            case .s15:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "15.circle"), for: .normal)
            case .s30:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "30.circle"), for: .normal)
            case .m1:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "1.square"), for: .normal)
            case .m5:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "5.square"), for: .normal)
            case .m10:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "10.square"), for: .normal)
            case .m15:
                self.xabberInputView.timerButton.setImage(UIImage(systemName: "15.square"), for: .normal)
            
        }
    }
    
    private final func groupSubscribtions() throws {
//        subscribePinMessageBar()
        let realm = try WRealm.safe()
        
        Observable
            .collection(from: realm
                                .objects(GroupChatStorageItem.self)
                                .filter("jid == %@ AND owner == %@", jid, owner))
            .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                
                let nickname = self.opponentSender.displayName
                if let item = results.first {
                    if item.descr != self.groupchatDescr {
                        self.groupchatDescr = item.descr
                        do {
                            let realm = try WRealm.safe()
                            if let initialMessageInstance = realm.object(
                                ofType: MessageStorageItem.self,
                                forPrimaryKey: MessageStorageItem.genPrimary(
                                    messageId: MessageStorageItem.messageIdForInitial(jid: self.jid, conversationType: self.conversationType),
                                    owner: self.owner
                                )
                            ) {
                                if initialMessageInstance.isDeleted {
                                    try realm.write {
                                        if initialMessageInstance.isInvalidated { return }
                                        initialMessageInstance.owner = self.owner
                                    }
                                }
                            }
                        } catch {
                            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                        }
                    }
                    
                    if item.isDeleted {
                        if let value = self.isInitiallyDeletedGroup,
                            value == false {
                            self.navigationController?.popToRootViewController(animated: true)
                        }
                    } else {
                        self.titleLabel.text = nickname
                        let statusStr = self.isInviteViewControllerShowed ? (item.privacy == .incognito ? "Incognito group".localizeString(id: "intro_incognito_group", arguments: []) : "Public group".localizeString(id: "intro_public_group", arguments: [])) : item.statusString
                        if self.statusLabel.text == " " {
                            self.statusLabel.text = statusStr
                        }
                        
                        self.statusTextObserver.accept(statusStr)
                        
                        self.contactStatus = self.isInviteViewControllerShowed ? (item.privacy == .incognito ?"Incognito group".localizeString(id: "intro_incognito_group", arguments: []) : "Public group".localizeString(id: "intro_public_group", arguments: [])) : item.statusString
                    }
                    self.isInitiallyDeletedGroup = item.isDeleted
                } else {
                    let status = "Unknown".localizeString(id: "unknown", arguments: [])
//                            if self.entity != .incognitoChat || self.entity != .groupchat {
//                                self.entity = .groupchat
//                            }
                    if ![.incognitoChat, .groupchat].contains(self.entity) {
                        self.entity = .groupchat
                    }
                    
                    self.titleLabel.text = nickname
                    self.statusTextObserver.accept(status)
                    self.contactStatus = status
                }
                self.titleLabel.layoutIfNeeded()
            })
            .disposed(by: bag)


        Observable
            .collection(from: realm
                .objects(GroupchatUserStorageItem.self)
                .filter("groupchatId == %@ AND isMe == true", [self.jid, self.owner].prp()))
            .subscribe(onNext: { (results) in
                if let item = results.first {
                    if item.nickname != (AccountManager.shared.find(for: self.owner)?.username ?? "") {
                        if !self.showMyNickname {
                            self.showMyNickname = true
                            UIView.performWithoutAnimation {
                                self.messagesCollectionView.reloadData()
                            }
                        }
                    } else {
                        if self.showMyNickname {
                            self.showMyNickname = false
                            UIView.performWithoutAnimation {
                                self.messagesCollectionView.reloadData()
                            }
                        }
                    }
                }
            })
            .disposed(by: bag)
    }
}
