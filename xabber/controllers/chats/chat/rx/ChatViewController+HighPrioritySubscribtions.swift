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

    public func updateSearchResults(value: String?) {
        if (value ?? "").isEmpty {
            self.xabberInputView.searchPanel.changeState(to: .empty)
            return
        } else {
            self.xabberInputView.searchPanel.changeState(to: .withResults)
        }
        if self.conversationType.isEncrypted {
            if let value = value, value.isNotEmpty {
                do {
                    self.searchMessagesQueue = []
                    let realm = try WRealm.safe()
                    realm
                        .objects(MessageStorageItem.self)
                        .filter(
                            "owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@ AND messageType != %@ AND body CONTAINS[cd] %@",
                            self.owner,
                            self.jid,
                            self.conversationType.rawValue,
                            MessageStorageItem.MessageDisplayType.system.rawValue,
                            value
                        )
                        .sorted(byKeyPath: "date", ascending: false)
                        .toArray()
                        .forEach {
                            item in
                            self.searchMessagesQueue.append(item)
                        }
                    self.setLoadingIndicatorVisible(false)
                    self.applySearchResults()
                } catch {
                    DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                }
            }
        } else {
            if let value = value, value.isNotEmpty {
                self.searchMessagesQueue = []
                let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                    onMessage: { [weak self] item, queryId in
                        self?.didReceiveMessage(item, queryId: queryId)
                    },
                    onEndPage: { [weak self] queryId, state, first, last, count in
                        self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                    }
                )
                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                    self.currentSearchQueryId = session.mam?.searchText(
                        stream,
                        jid: self.jid,
                        conversationType: self.conversationType,
                        text: value,
                        requestCallbacks: requestCallbacks
                    )
                } fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        self.currentSearchQueryId = user.mam.searchText(
                            stream,
                            jid: self.jid,
                            conversationType: self.conversationType,
                            text: value,
                            requestCallbacks: requestCallbacks
                        )
                    })
                }
            } else {
                self.searchMessagesQueue = []
            }
        }
    }
    
    internal func subscribe() throws {
        NotifyManager.shared.currentDialog = [self.jid, self.owner].prp()
        self.bag = DisposeBag()
        let realm = try WRealm.safe()
        let bootstrapRequestCallbacks = MessageArchiveManager.RequestCallbacks(
            onMessage: nil,
            onEndPage: { [weak self] queryId, state, first, last, count in
                self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
            }
        )

        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            let result = session.mam?.syncChat(
                stream,
                jid: self.jid,
                conversationType: self.conversationType,
                pageSize: self.datasourcePageSize,
                callback: nil,
                requestCallbacks: bootstrapRequestCallbacks
            ) ?? .noop
            self.handleSyncChatStartResult(result)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                let result = user.mam.syncChat(
                    stream,
                    jid: self.jid,
                    conversationType: self.conversationType,
                    pageSize: self.datasourcePageSize,
                    callback: nil,
                    requestCallbacks: bootstrapRequestCallbacks
                )
                self.handleSyncChatStartResult(result)
            })
        }
        
        self.configureDataset()
        Observable
            .collection(from: self.messagesObserver, synchronousStart: true)
            .skip(1)
            .debounce(.milliseconds(30), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe {
                (_) in
                if self.showSkeletonObserver.value {
                    _ = self.completeInitialBootstrapIfNeeded()
                    self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
                    return
                }
                if self.currentPage.locked {
                    _ = self.tryFinishInteractiveHistoryPageLoadIfReady()
                    return
                }
                self.didReceiveChangeset()
            }
            .disposed(by: self.bag)

        if self.conversationType == .group {
            do {
                let realm = try WRealm.safe()
                let myGroupUser = realm.objects(GroupchatUserStorageItem.self)
                    .filter("groupchatId == %@ AND isMe == true", [self.jid, self.owner].prp())
                let mentionNotifications = realm.objects(NotificationStorageItem.self)
                    .filter("owner == %@ AND category_ == %@", self.owner, XMPPNotificationsManager.Category.mention.rawValue)
                Observable
                    .collection(from: myGroupUser, synchronousStart: true)
                    .debounce(.milliseconds(30), scheduler: MainScheduler.asyncInstance)
                    .observe(on: MainScheduler.asyncInstance)
                    .subscribe(onNext: { _ in
                        self.rebuildUnreadMentionItems()
                        self.refreshUnreadMentionsNavigatorState(animated: true)
                    })
                    .disposed(by: self.bag)
                Observable
                    .collection(from: mentionNotifications, synchronousStart: true)
                    .debounce(.milliseconds(30), scheduler: MainScheduler.asyncInstance)
                    .observe(on: MainScheduler.asyncInstance)
                    .subscribe(onNext: { _ in
                        self.rebuildUnreadMentionItems()
                        self.refreshUnreadMentionsNavigatorState(animated: true)
                    })
                    .disposed(by: self.bag)
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
        
        self.showLoadingIndicator
            .asObservable()
            .debounce(.microseconds(100), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
//                DispatchQueue.main.async {
                self.chatViewLoadingOverlay.isHidden = !value
//                }
            }
            .disposed(by: bag)
        
        self.shouldShowInitialMessage
            .asObservable()
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
            if value {
                if self.initialMessageOverlayView.superview == nil {
                    self.view.addSubview(self.initialMessageOverlayView)
                }
                self.updateInitialMessageOverlayFrame()
                self.initialMessageOverlayView.isHidden = false
            } else {
                self.initialMessageOverlayView.isHidden = true
                self.initialMessageOverlayView.removeFromSuperview()
            }
        }.disposed(by: bag)

        
        self.inSearchMode
            .asObservable()
            .skip(1)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (value) in
                if value {
                    self.configureSearchBar()
                    self.xabberInputView.changeState(to: .search)
                    self.shouldShowScrollDownButton.accept(false)
                    if self.shouldShowUnreadMentionsNavigator.value {
                        self.shouldShowUnreadMentionsNavigator.accept(false)
                    }
                } else {
                    self.searchTextObserver.accept(nil)
                    self.configureNavbar()
                    self.xabberInputView.changeState(to: self.xabberInputView.state)
                    self.applyChatDatasource(self.datasource, mode: .fullReload())
                    self.refreshUnreadMentionsNavigatorState(animated: true)
                }
            })
            .disposed(by: bag)
        
        self.searchTextObserver
            .asObservable()
            .skip(1)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (value) in
                self.setLoadingIndicatorVisible((value ?? "").isNotEmpty)
                self.updateSearchResults(value: value)
            })
            .disposed(by: bag)

        
        self.shouldShowScrollDownButton
            .asObservable()
            .debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
                if value {
                    if self.inSearchMode.value {
                        self.shouldShowScrollDownButton.accept(false)
                    } else {
                        self.updateScrollDownButtonFrame(animated: true)
                    }
                } else {
                    self.updateScrollDownButtonFrame(animated: true)
                }
            }
            .disposed(by: bag)

        self.shouldShowUnreadMentionsNavigator
            .asObservable()
            .debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { _ in
                self.updateUnreadMentionsNavigatorFrame(animated: true)
                self.updateScrollDownButtonFrame(animated: true)
            }
            .disposed(by: bag)
        
        self.contentOffsetObserver
            .asObservable()
            .debounce(.milliseconds(40), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
//                self.showFloatingDateObserver.accept(false)
                if self.isNearBottom() {
                    if self.shouldShowScrollDownButton.value {
                        self.shouldShowScrollDownButton.accept(false)
                    }
                } else if value > 64 {
                    if !self.shouldShowScrollDownButton.value {
                        if !self.inSearchMode.value {
                            self.shouldShowScrollDownButton.accept(true)
                        }
                    }
                } else {
                    if self.shouldShowScrollDownButton.value {
                        self.shouldShowScrollDownButton.accept(false)
                    }
                }
                self.refreshUnreadMentionsNavigatorState(animated: true)
            }
            .disposed(by: bag)

        self.updateFloatingDateObserverSignal
            .asObservable()
            .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { _ in
                self.updateFloatingDate()
            }
            .disposed(by: bag)

        
        self.topPanelState
            .asObservable()
            .debounce(.nanoseconds(1), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { state in
                switch state {
                    case .none:
                        self.hideTopPanelBubble(animated: false)
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
                    case .acceptedVerification:
                        self.applyAcceptedVerification()
                    case .audioPlayer:
                        self.hideTopPanelBubble(animated: false)
                        self.applyAudioPlayerPanel()
                }
            }.disposed(by: bag)

        
//        if !self.groupchat {
        Observable
            .collection(from: realm
                                .objects(ResourceStorageItem.self)
                                .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                                .sorted(by: [SortDescriptor(keyPath: "timestamp", ascending: false),
                                             SortDescriptor(keyPath: "priority", ascending: false)]))
            .observe(on: MainScheduler.asyncInstance)
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
//                .skip(1)
            .subscribe(onNext: { (results) in
                let nickname = self.opponentSender.displayName
                let offlineStatus = "last seen recently".localizeString(id: "last_seen_recently", arguments: [])
                let status = (results.first?.statusMessage.isEmpty ?? true) ? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus) : results.first?.statusMessage ?? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus)
//                    self.contactUsename = nickname
                self.titleLabel.attributedText = self.updateTitle()
                let statusStr = AccountManager.shared.connectingUsers.value.contains(self.owner) ? "Waiting for network...".localizeString(id: "waiting_for_network", arguments: []) : status
                if self.statusLabel.text == " " && self.conversationType != .saved {
                    self.statusLabel.text = statusStr
                }
                if self.shouldShowNormalStatus {
                    self.setStatusText(statusStr)
                    self.contactStatus = status
                    self.statusLabel.layoutIfNeeded()
                }
                self.titleLabel.sizeToFit()
                self.titleLabel.layoutIfNeeded()
                
            })
            .disposed(by: bag)
//        }
        
        let lastChatsObservedCollection = realm
            .objects(LastChatsStorageItem.self)
            .filter("jid == %@ AND owner == %@ AND conversationType_ == %@", self.jid, self.owner, self.conversationType.rawValue)
        if let chat = lastChatsObservedCollection.first {
            self.xabberInputView.setComposerText(chat.draftMessage)
            self.xabberInputView.textViewDidChange(force: true)

            self.updateContentByLastChatInstance(chat)
        } else {
            self.applyBootstrapViewState(self.bootstrapViewState(chatInstance: nil), forceRender: self.datasource.isEmpty)
        }
        Observable
            .collection(from: lastChatsObservedCollection)
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .skip(1)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                guard let item = results.first else {
                    self.applyBootstrapViewState(self.bootstrapViewState(chatInstance: nil), forceRender: self.datasource.isEmpty)
                    return
                }
                self.updateContentByLastChatInstance(item)
                    
            })
            .disposed(by: bag)

        Observable
            .collection(from: realm
                .objects(RosterStorageItem.self)
                .filter("owner == %@ AND jid == %@", owner, jid))
            .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                if self.conversationType == .group { return }
                
                if self.conversationType == .saved {
                    let usersCount = AccountManager.shared.users.count
                    
                    if usersCount > 1 {
                        self.contactStatus = self.owner
                        self.updateStatusText()
                    }
                    
                    return
                    
                } else if (XMPPJID(string: self.jid)?.isServer ?? false) {
                    self.contactStatus = "Server"
                    self.updateStatusText()
                    return
                }
                if let item = results.first {
                    switch item.subscribtion {
                        case .none:
                            switch item.ask {
                                case .in, .both:
                                    self.setTopPanelState(.allowSubscribtion)
                                default:
                                    if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                        self.setTopPanelState(.none)
                                    }
                            }
                        case .to:
                            switch item.ask {
                                case .in:
                                    self.setTopPanelState(.addContact)
                                default:
                                    if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                        self.setTopPanelState(.none)
                                    }
                            }
                        case .undefined:
                            switch item.ask {
                                case .in:
                                    self.setTopPanelState(.allowSubscribtion)
                                default:
                                    if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                        self.setTopPanelState(.none)
                                    } else {
                                        self.setTopPanelState(.addContact)
                                    }
                            }
                        default:
                            if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                self.setTopPanelState(.none)
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
            .observe(on: MainScheduler.asyncInstance)
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
    
    internal func handleSyncChatStartResult(_ result: MessageArchiveManager.SyncChatStartResult) {
        DispatchQueue.main.async {
            switch result {
            case .bootstrapStarted(let queryId):
                self.beginInitialBootstrapTracking(queryId: queryId)
                self.applyBootstrapViewState(self.currentBootstrapViewState(), forceRender: true)
            case .gapRepairOnly, .noop:
                self.resetInitialBootstrapTracking()
            }
        }
    }

    private final func updateContentByLastChatInstance(_ item: LastChatsStorageItem) {
//        self.lastReadMessageId = item.lastReadId
        let state = self.bootstrapViewState(chatInstance: item)
        let shouldShowSkeleton = state == .skeleton
        if self.showSkeletonObserver.value != shouldShowSkeleton {
            self.applyBootstrapViewState(state)

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
        } else if !shouldShowSkeleton {
            self.reloadInitialWindowAfterBootstrapIfNeeded()
        }
        _ = self.completeInitialBootstrapIfNeeded()
        self.rebuildUnreadMentionItems()
        self.refreshUnreadMentionsNavigatorState(animated: true)
        let id = self.opponentSender.id
        if !(item.rosterItem?.isInvalidated ?? false) {
            self.opponentSender = Sender(
                id: id,
                displayName: item.rosterItem?.displayName ?? item.jid
            )
        }
//        self.contactUsename = self.opponentSender.displayName
        self.titleLabel.attributedText = self.updateTitle()
        self.setStatusText(AccountManager
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
    
    internal final func groupSubscribtions() throws {
        
        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            session.groupchat?.getDefaultPermissions(stream, groupchat: self.jid)
            session.groupchat?.requestMyPermissions(stream, groupchat: self.jid)
        } fail: {
            AccountManager.shared.find(for: self.owner)?.action { user, stream in
                user.groupchats.getDefaultPermissions(stream, groupchat: self.jid)
                user.groupchats.requestMyPermissions(stream, groupchat: self.jid)
            }
        }

        let realm = try WRealm.safe()
        let mentionUsers = self.mentionUsersResults(in: realm)
        Observable
            .collection(from: mentionUsers)
            .debounce(.milliseconds(20), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { results in
                if !results.isEmpty {
                    self.hasRequestedMentionUsersRefresh = false
                }
                self.xabberInputView.refreshMentionSuggestions()
            })
            .disposed(by: bag)

//        let realm = try WRealm.safe()
//        
//        self.showMyNickname = realm
//            .objects(GroupchatUserStorageItem.self)
//            .filter("groupchatId == %@ AND isMe == true", [self.jid, self.owner].prp())
//            .first?
//            .nickname == AccountManager.shared.find(for: self.owner)?.username
//        Observable
//            .collection(from: realm
//                .objects(GroupchatInvitesStorageItem.self)
//                .filter("owner == %@ AND groupchat == %@ AND isProcessed == false", self.owner, self.jid))
//            .subscribe { (results) in
//                if let item = results.first {
//                    self.didReceiveInvite(item.primary)
//                }
//            } onError: { (error) in
//                DDLogDebug("ChatViewController: \(#function). Invite error \(error.localizedDescription)")
//            } onCompleted: {
//                DDLogDebug("ChatViewController: \(#function). Invite completed")
//            } onDisposed: {
//                DDLogDebug("ChatViewController: \(#function). Invite disposed")
//            }
//            .disposed(by: bag)
//        
//        Observable
//            .collection(from: realm
//                                .objects(GroupChatStorageItem.self)
//                                .filter("jid == %@ AND owner == %@", jid, owner))
//            .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
//            .subscribe(onNext: { (results) in
//                
//                let nickname = self.opponentSender.displayName
//                if let item = results.first {
//                    if item.descr != self.groupchatDescr {
//                        self.groupchatDescr = item.descr
//                        do {
//                            let realm = try WRealm.safe()
//                            if let initialMessageInstance = realm.object(
//                                ofType: MessageStorageItem.self,
//                                forPrimaryKey: MessageStorageItem.genPrimary(
//                                    messageId: MessageStorageItem.messageIdForInitial(jid: self.jid, conversationType: self.conversationType),
//                                    owner: self.owner
//                                )
//                            ) {
//                                if initialMessageInstance.isDeleted {
//                                    try realm.write {
//                                        if initialMessageInstance.isInvalidated { return }
//                                        initialMessageInstance.owner = self.owner
//                                    }
//                                }
//                            }
//                        } catch {
//                            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
//                        }
//                    }
//                    
//                    if item.isDeleted {
//                        if let value = self.isInitiallyDeletedGroup,
//                            value == false {
//                            self.navigationController?.popToRootViewController(animated: true)
//                        }
//                    } else {
//                        self.titleLabel.text = nickname
//                        let statusStr = self.isInviteViewControllerShowed ? (item.privacy == .incognito ? "Incognito group".localizeString(id: "intro_incognito_group", arguments: []) : "Public group".localizeString(id: "intro_public_group", arguments: [])) : item.statusString
//                        if self.statusLabel.text == " " {
//                            self.statusLabel.text = statusStr
//                        }
//                        
//                        self.statusTextObserver.accept(statusStr)
//                        
//                        self.contactStatus = self.isInviteViewControllerShowed ? (item.privacy == .incognito ?"Incognito group".localizeString(id: "intro_incognito_group", arguments: []) : "Public group".localizeString(id: "intro_public_group", arguments: [])) : item.statusString
//                    }
//                    self.isInitiallyDeletedGroup = item.isDeleted
//                } else {
//                    let status = "Unknown".localizeString(id: "unknown", arguments: [])
////                            if self.entity != .incognitoChat || self.entity != .groupchat {
////                                self.entity = .groupchat
////                            }
//                    if ![.incognitoChat, .groupchat].contains(self.entity) {
//                        self.entity = .groupchat
//                    }
//                    
//                    self.titleLabel.text = nickname
//                    self.statusTextObserver.accept(status)
//                    self.contactStatus = status
//                }
//                self.titleLabel.layoutIfNeeded()
//            })
//            .disposed(by: bag)


//        Observable
//            .collection(from: realm
//                .objects(GroupchatUserStorageItem.self)
//                .filter("groupchatId == %@ AND isMe == true", [self.jid, self.owner].prp()))
//            .subscribe(onNext: { (results) in
//                if let item = results.first {
//                    if item.nickname != (AccountManager.shared.find(for: self.owner)?.username ?? "") {
//                        if !self.showMyNickname {
//                            self.showMyNickname = true
//                            UIView.performWithoutAnimation {
//                                self.messagesCollectionView.reloadData()
//                            }
//                        }
//                    } else {
//                        if self.showMyNickname {
//                            self.showMyNickname = false
//                            UIView.performWithoutAnimation {
//                                self.messagesCollectionView.reloadData()
//                            }
//                        }
//                    }
//                }
//            })
//            .disposed(by: bag)
    }
}
