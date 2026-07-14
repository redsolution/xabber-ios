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
    private var chatPresentationRefreshKey: String {
        "chat.presentation.\(owner).\(jid).\(conversationType.rawValue)"
    }

    final func runOrDeferChatPresentationRefresh(
        keySuffix: String,
        work: @escaping () -> Void
    ) {
        ChatUIResponsivenessGate.shared.runOrDefer(
            workKind: .presentationRefresh,
            key: "\(chatPresentationRefreshKey).\(keySuffix)",
            work: work
        )
    }

    public func updateSearchResults(value: String?) {
        acceptSearchSessionQuery(value, flushImmediately: true)
    }

    internal func executeSearchRequest(_ request: ChatSearchSession.Request) {
        guard searchSession.isCurrentRequest(request),
              request.scope.owner == owner,
              request.scope.jid == jid,
              request.scope.conversationTypeRawValue == conversationType.rawValue else {
            return
        }
        let normalizedValue = request.query
        self.reduceSearchPresentationState(
            .debounceElapsed(generation: self.searchPresentationState.generation)
        )
        if request.provider == .localEncrypted {
            guard let context = self.beginInChatSearchQueryIfNeeded(
                text: normalizedValue,
                queryId: "Local search:\(request.generation):\(NanoID.new(8))"
            ) else {
                return
            }
            searchSessionGenerationByQueryId[context.queryId] = request.generation
            searchOlderPageNavigationGate.reset(generation: request.generation)
            self.searchMessagesQueue = []
            self.searchResultPresentations = []
            let localRequest = ChatSearchLocalProvider.Request(
                generation: request.generation,
                queryId: context.queryId,
                query: normalizedValue,
                mappingContext: inChatSearchResultMappingContext
            )
            searchLocalProvider.search(localRequest) { [weak self] event in
                guard let self,
                      event.generation == request.generation,
                      event.queryId == context.queryId,
                      self.searchSession.isCurrentRequest(request),
                      self.isCurrentInChatSearchQuery(queryId: context.queryId) else {
                    return
                }
                switch event.phase {
                case .batch(let results):
                    _ = self.appendDetachedInChatSearchResultsIfCurrent(
                        results,
                        queryId: context.queryId
                    )
                case .completed:
                    _ = self.finishInChatSearchQueryIfCurrent(
                        queryId: context.queryId,
                        emptyList: self.searchResultPresentations.isEmpty
                    )
                case .failed(let failure):
                    DDLogDebug("ChatViewController: local search failed: \(failure)")
                    _ = self.handleInChatSearchQueryFailure(queryId: context.queryId)
                case .cancelled:
                    break
                }
            }
        } else {
            guard let context = self.beginInChatSearchQueryIfNeeded(
                text: normalizedValue,
                queryId: "MAM search:\(request.generation):\(NanoID.new(8))"
            ) else {
                return
            }
            searchSessionGenerationByQueryId[context.queryId] = request.generation
            searchOlderPageNavigationGate.reset(generation: request.generation)
            self.applyLegacySearchPanelStateFromPresentation()
            self.registerRemoteHistoryFailureDispatcher(queryId: context.queryId)
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: { [weak self] item, queryId in
                    guard self?.searchSession.isCurrentRequest(request) == true else {
                        return
                    }
                    self?.didReceiveMessage(item, queryId: queryId)
                },
                onEndPage: { [weak self] queryId, state, first, last, count in
                    guard self?.searchSession.isCurrentRequest(request) == true else {
                        return
                    }
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                },
                onFailure: { [weak self] event in
                    guard self?.searchSession.isCurrentRequest(request) == true else {
                        return
                    }
                    _ = self?.handleInChatSearchQueryFailure(queryId: event.queryId)
                },
                onSearchTerminal: { [weak self] queryId, terminal in
                    guard self?.searchSession.isCurrentRequest(request) == true else {
                        return
                    }
                    if case .failed = terminal {
                        _ = self?.handleInChatSearchQueryFailure(queryId: queryId)
                    }
                    self?.markOlderSearchResultsTerminal(generation: request.generation)
                },
                onSearchContinuationAvailable: { [weak self] queryId, cursor in
                    DispatchQueue.main.async {
                        self?.offerOlderSearchResultsCursor(
                            cursor,
                            queryId: queryId,
                            generation: request.generation
                        )
                    }
                }
            )
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { [weak self] stream, session in
                guard let self,
                      self.searchSession.isCurrentRequest(request),
                      self.isCurrentInChatSearchQuery(queryId: context.queryId) else {
                    return
                }
                guard let mam = session.mam else {
                    self.handleInChatSearchQueryFailure(queryId: context.queryId)
                    return
                }
                let queryId = mam.searchText(
                    stream,
                    jid: context.jid,
                    conversationType: context.conversationType,
                    text: context.text,
                    queryId: context.queryId,
                    generation: request.generation,
                    requestCallbacks: requestCallbacks
                )
                self.searchArchiveManagersByQueryId[queryId] = mam
                self.registerRemoteHistoryPersistenceSource(session.messages, queryId: queryId)
            } fail: { [weak self] in
                guard let self,
                      self.searchSession.isCurrentRequest(request),
                      self.isCurrentInChatSearchQuery(queryId: context.queryId) else {
                    return
                }
                guard let account = AccountManager.shared.find(for: self.owner) else {
                    self.handleInChatSearchQueryFailure(queryId: context.queryId)
                    return
                }
                account.action({ [weak self] user, stream in
                    guard let self,
                          self.searchSession.isCurrentRequest(request),
                          self.isCurrentInChatSearchQuery(queryId: context.queryId) else {
                        return
                    }
                    let queryId = user.mam.searchText(
                        stream,
                        jid: context.jid,
                        conversationType: context.conversationType,
                        text: context.text,
                        queryId: context.queryId,
                        generation: request.generation,
                        requestCallbacks: requestCallbacks
                    )
                    self.searchArchiveManagersByQueryId[queryId] = user.mam
                    self.registerRemoteHistoryPersistenceSource(user.messages, queryId: queryId)
                })
            }
        }
    }
    
    internal func subscribe() throws {
        NotifyManager.shared.currentDialog = [self.jid, self.owner].prp()
        self.bag = DisposeBag()
        let realm = try WRealm.safe()
        self.configureDataset()
        self.cancelInitialBootstrapLocalHistoryFallback()
        let initialChatInstance = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType
            )
        )
        let initialBootstrapViewState = self.bootstrapViewState(chatInstance: initialChatInstance)
        self.applyBootstrapViewState(
            initialBootstrapViewState,
            forceRender: self.datasource.isEmpty || !self.isShowingBootstrapPlaceholder
        )
        if initialBootstrapViewState == .skeleton {
            self.scheduleInitialBootstrapLocalHistoryFallbackIfNeeded()
        }
        let bootstrapRequestCallbacks = MessageArchiveManager.RequestCallbacks(
            onMessage: nil,
            onEndPage: { [weak self] queryId, state, first, last, count in
                self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
            }
        )
        let bootstrapQueryId = "MAM bootstrap history: \(NanoID.new(6))"
        self.registerRemoteHistoryEndPageDispatcher(queryId: bootstrapQueryId)

        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            let result = session.mam?.syncChat(
                stream,
                jid: self.jid,
                conversationType: self.conversationType,
                pageSize: self.initialBootstrapArchiveRequestPageSize,
                queryId: bootstrapQueryId,
                callback: nil,
                requestCallbacks: bootstrapRequestCallbacks
            ) ?? .noop
            if case .bootstrapStarted(let queryId) = result {
                self.registerRemoteHistoryPersistenceSource(session.messages, queryId: queryId)
            } else {
                self.unregisterRemoteHistoryEndPageDispatcher(queryId: bootstrapQueryId)
            }
            self.handleSyncChatStartResult(result)
        } fail: {
            guard let account = AccountManager.shared.find(for: self.owner) else {
                self.unregisterRemoteHistoryEndPageDispatcher(queryId: bootstrapQueryId)
                return
            }
            account.action({ user, stream in
                let result = user.mam.syncChat(
                    stream,
                    jid: self.jid,
                    conversationType: self.conversationType,
                    pageSize: self.initialBootstrapArchiveRequestPageSize,
                    queryId: bootstrapQueryId,
                    callback: nil,
                    requestCallbacks: bootstrapRequestCallbacks
                )
                if case .bootstrapStarted(let queryId) = result {
                    self.registerRemoteHistoryPersistenceSource(user.messages, queryId: queryId)
                } else {
                    self.unregisterRemoteHistoryEndPageDispatcher(queryId: bootstrapQueryId)
                }
                self.handleSyncChatStartResult(result)
            })
        }
        
        Observable
            .collection(from: self.messagesObserver, synchronousStart: true)
            .skip(1)
            .debounce(.milliseconds(30), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe {
                (_) in
                self.handleMessagesObserverRefresh()
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
                Observable
                    .collection(
                        from: realm
                            .objects(GroupChatStorageItem.self)
                            .filter("owner == %@ AND jid == %@", self.owner, self.jid),
                        synchronousStart: true
                    )
                    .debounce(.milliseconds(30), scheduler: MainScheduler.asyncInstance)
                    .observe(on: MainScheduler.asyncInstance)
                    .subscribe(onNext: { results in
                        guard let groupchat = results.first else {
                            self.updatePinnedMessagePanelState(pinnedMessageId: nil, canUnpin: false)
                            return
                        }
                        self.updatePinnedMessagePanelState(
                            pinnedMessageId: groupchat.pinnedMessage,
                            canUnpin: groupchat.canChangeSettings
                        )
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
                if self.deferUntilNavigationTransitionCompletesIfNeeded({ [weak self] in
                    self?.inSearchMode.accept(value)
                }) {
                    return
                }
                if value {
                    self.configureSearchModeForCurrentActivation(
                        defaultActivateKeyboard: !self.isNavigationTransitionActive,
                        defaultAnimated: ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
                            requestedAnimated: true,
                            isTransitionActive: self.isNavigationTransitionActive,
                            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
                        )
                    )
                    self.xabberInputView.changeState(to: .search)
                    self.updateChatInputKeyboardLayoutMode()
                    self.shouldShowScrollDownButton.accept(false)
                    if self.shouldShowUnreadMentionsNavigator.value {
                        self.shouldShowUnreadMentionsNavigator.accept(false)
                    }
                } else {
                    self.searchTextObserver.accept(nil)
                    self.configureNavbar()
                    self.xabberInputView.changeState(to: .normal)
                    self.updateChatInputKeyboardLayoutMode()
                    self.applyChatDatasource(
                        self.datasource,
                        mode: .fullReload(),
                        animated: ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
                            requestedAnimated: true,
                            isTransitionActive: self.isNavigationTransitionActive,
                            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
                        )
                    )
                    self.refreshUnreadMentionsNavigatorState(animated: true)
                }
            })
            .disposed(by: bag)
        
        self.searchTextObserver
            .asObservable()
            .skip(1)
            .distinctUntilChanged()
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (value) in
                self.acceptSearchSessionQuery(value, flushImmediately: false)
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
                        self.updateUnreadMentionsNavigatorFrame(animated: true)
                    }
                } else {
                    self.updateScrollDownButtonFrame(animated: true)
                    self.updateUnreadMentionsNavigatorFrame(animated: true)
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
                let animated = self.shouldAnimateDuringInitialLatestStabilization(requestedAnimated: true)
                let shouldShow = ChatScrollDownButtonVisibilityPolicy.shouldShow(
                    contentOffsetY: value,
                    isNearBottom: self.isNearBottom(),
                    isSearchMode: self.inSearchMode.value
                )
                if shouldShow {
                    if !self.shouldShowScrollDownButton.value {
                        self.shouldShowScrollDownButton.accept(true)
                    }
                } else {
                    if self.shouldShowScrollDownButton.value {
                        self.shouldShowScrollDownButton.accept(false)
                    }
                }
                self.refreshUnreadMentionsNavigatorState(animated: animated)
            }
            .disposed(by: bag)

        self.contentOffsetObserver
            .asObservable()
            .skip(1)
            .debounce(.milliseconds(500), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { _ in
                self.saveCurrentVisibleMessagePositionIfNeeded()
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
                let statusStr = self.connectionAwareStatusText(fallbackStatus: status)
                self.runOrDeferChatPresentationRefresh(keySuffix: "presence") { [weak self] in
                    guard let self else { return }
                    self.titleLabel.attributedText = self.updateTitle()
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
                }
                
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
                let presentation = self.chatSubscriptionPresentation(
                    rosterItem: results.first,
                    realm: realm
                )
                self.runOrDeferChatPresentationRefresh(keySuffix: "subscription") { [weak self] in
                    guard let self else { return }
                    self.applyChatSubscriptionPresentation(presentation)
                    if presentation.showsNormalPresenceStatus {
                        self.applyNormalPresenceStatus(realm: realm)
                    }
                }
            }).disposed(by: bag)

        Observable
            .collection(from: realm
                .objects(BlockStorageItem.self)
                .filter("owner == %@ AND jid == %@", owner, jid))
            .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { _ in
                guard self.conversationType != .group,
                      self.conversationType != .saved,
                      !(XMPPJID(string: self.jid)?.isServer ?? false) else {
                    return
                }

                let rosterItem = realm.object(
                    ofType: RosterStorageItem.self,
                    forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner)
                )
                let presentation = self.chatSubscriptionPresentation(
                    rosterItem: rosterItem,
                    realm: realm
                )
                self.runOrDeferChatPresentationRefresh(keySuffix: "block") { [weak self] in
                    guard let self else { return }
                    self.applyChatSubscriptionPresentation(presentation)
                    if presentation.showsNormalPresenceStatus {
                        self.applyNormalPresenceStatus(realm: realm)
                    }
                }
            }).disposed(by: bag)

        
        self.statusLabel.text = self.statusTextObserver.value
        self.statusLabel.layoutIfNeeded()
        self.statusTextObserver
            .asObservable()
            .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { (value) in
                self.runOrDeferChatPresentationRefresh(keySuffix: "statusText") { [weak self] in
                    guard let self else { return }
                    self.statusLabel.text = value
                    self.statusLabel.layoutIfNeeded()
                }
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
                self.scheduleInitialBootstrapLocalHistoryFallbackIfNeeded()
            case .gapRepairOnly, .noop:
                self.resetInitialBootstrapTracking()
                _ = self.revealStaleLocalHistoryIfNeeded()
            }
        }
    }

    private final func updateContentByLastChatInstance(_ item: LastChatsStorageItem) {
//        self.lastReadMessageId = item.lastReadId
        let state = self.bootstrapViewState(chatInstance: item)
        let shouldShowSkeleton = state == .skeleton
        if self.showSkeletonObserver.value != shouldShowSkeleton {
            self.applyBootstrapViewState(state)
        } else if !shouldShowSkeleton {
            self.reloadInitialWindowAfterBootstrapIfNeeded()
        }
        if shouldShowSkeleton {
            self.scheduleInitialBootstrapLocalHistoryFallbackIfNeeded()
        }
        _ = self.completeInitialBootstrapIfNeeded()
        self.rebuildUnreadMentionItems()
        self.refreshUnreadMentionsNavigatorState(
            animated: self.shouldAnimateDuringInitialLatestStabilization(requestedAnimated: true)
        )
        let id = self.opponentSender.id
        if !(item.rosterItem?.isInvalidated ?? false) {
            self.opponentSender = Sender(
                id: id,
                displayName: item.rosterItem?.displayName ?? item.jid
            )
        }
//        self.contactUsename = self.opponentSender.displayName
        self.titleLabel.attributedText = self.updateTitle()
        self.setStatusText(self.connectionAwareStatusText(fallbackStatus: self.contactStatus ?? " "))
        
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
