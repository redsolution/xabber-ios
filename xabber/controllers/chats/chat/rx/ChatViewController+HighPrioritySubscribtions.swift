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
                    if self.searchLocalProvider.hasPendingPage(
                        queryId: context.queryId,
                        generation: request.generation
                    ) {
                        self.offerOlderSearchResultsCursor(
                            "local:\(self.searchMessagesQueue.count)",
                            queryId: context.queryId,
                            generation: request.generation
                        )
                    }
                    self.consumePendingOlderSearchResultNavigationIfReady(
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
            self.applySearchPanelStateFromPresentation()
            let startRemotePage: () -> Void = { [weak self] in
                guard let self,
                      self.searchSession.isCurrentRequest(request),
                      self.isCurrentInChatSearchQuery(queryId: context.queryId) else {
                    return
                }
                guard let account = AccountManager.shared.find(for: self.owner) else {
                    self.handleInChatSearchQueryFailure(queryId: context.queryId)
                    return
                }
                let intent = ArchiveSearchIntent(
                    clientQueryID: context.queryId,
                    conversation: self.archiveEngineConversationKey,
                    query: context.text
                )
                self.beginArchiveSearchInteractiveCriticalSection(
                    queryID: context.queryId
                )
                Task {
                    _ = await account.archiveEngine.startSearch(intent)
                }
            }
            var didStartRemotePage = false
            let startRemotePageOnce: () -> Void = {
                guard !didStartRemotePage else { return }
                didStartRemotePage = true
                startRemotePage()
            }
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
                    self.applySearchResults(emptyList: false)
                    startRemotePageOnce()
                    _ = self.searchLocalProvider.cancel(
                        queryId: context.queryId,
                        generation: request.generation
                    )
                case .completed, .failed:
                    startRemotePageOnce()
                case .cancelled:
                    break
                }
            }
        }
    }
    
    internal func bindInitialMessageOverlayVisibility() {
        self.shouldShowInitialMessage
            .asObservable()
            .observe(on: MainScheduler.instance)
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
            }
            .disposed(by: self.bag)
    }

    internal func subscribe() throws {
        NotifyManager.shared.currentDialog = [self.jid, self.owner].prp()
        self.bag = DisposeBag()
        self.groupProjectionObserver?.invalidate()
        self.groupProjectionObserver = nil
        self.canonicalGroupProjectionState = nil
        self.canonicalGroupChatPresenceState = nil
        let realm = try WRealm.safe()
        self.configureDataset()
        self.startArchiveEnginePresentationIfNeeded()
        
        if self.conversationType == .group {
            do {
                try observeCanonicalGroupProjection()
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
        
        self.bindInitialMessageOverlayVisibility()

        
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
                        ),
                        presentationOwner: .archiveEngine
                    )
                    self.refreshUnreadMentionsNavigatorState(animated: true)
                }
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
                self.refreshUnreadMentionsNavigatorState(animated: true)
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

        
        Observable
            .collection(from: realm
                                .objects(ResourceStorageItem.self)
                                .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                                .sorted(by: [SortDescriptor(keyPath: "timestamp", ascending: false),
                                             SortDescriptor(keyPath: "priority", ascending: false)]))
            .observe(on: MainScheduler.asyncInstance)
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                guard ChatGroupNavbarStatusPolicy.allowsResourcePresence(
                    conversationType: self.conversationType
                ) else {
                    return
                }
                let offlineStatus = "last seen recently".localizeString(id: "last_seen_recently", arguments: [])
                let status = (results.first?.statusMessage.isEmpty ?? true) ? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus) : results.first?.statusMessage ?? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus)
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
        }
        Observable
            .collection(from: lastChatsObservedCollection)
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .skip(1)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                guard let item = results.first else { return }
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
    
    private final func updateContentByLastChatInstance(_ item: LastChatsStorageItem) {
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

    internal func observeCanonicalGroupProjection() throws {
        let observer = ChatGroupProjectionObserver()
        let repository = GroupRepository(realm: try WRealm.safe())
        groupProjectionObserver?.invalidate()
        groupProjectionObserver = observer
        do {
            try observer.observe(
                repository: repository,
                owner: owner,
                groupJID: jid
            ) { [weak self] state in
                guard let self else { return }
                let applyState = { [weak self] in
                    guard let self else { return }
                    let previousState = self.canonicalGroupProjectionState
                    self.canonicalGroupProjectionState = state
                    self.applyCanonicalGroupNavbarStatus(state)
                    self.xabberInputView.groupMentionSenderRole = state.selfMember?.role
                    self.xabberInputView.groupMentionAllCapabilityGranted = false
                    if previousState?.members != state.members {
                        self.hasRequestedMentionUsersRefresh = false
                        self.xabberInputView.refreshMentionSuggestions()
                    }
                    if previousState != nil,
                       previousState?.selfMemberID != state.selfMemberID ||
                        previousState?.members != state.members {
                        _ = self.timelineSession?.refreshUnreadMetadata()
                    }
                    self.rebuildUnreadMentionItems()
                    self.refreshUnreadMentionsNavigatorState(animated: true)
                    if self.viewIfLoaded?.window != nil,
                       UIApplication.shared.applicationState == .active {
                        self.sendCanonicalGroupChatPresence(.active)
                    }
                    self.updatePinnedMessagePanelState(
                        pinnedMessageId: state.lastPinnedMessageID,
                        canUnpin: state.canUnpinLastMessage
                    )
                    do {
                        let realm = try WRealm.safe()
                        self.applyBaseSendButtonReadiness(
                            isSkeletonVisible: self.showSkeletonObserver.value,
                            isAccountConnecting: AccountManager.shared.connectingUsers.value.contains(self.owner),
                            hasPendingOrFailedMessage: self.pendingOrFailedMessageBlocksSend(in: realm)
                        )
                    } catch {
                        DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                    }
                }
                if Thread.isMainThread {
                    applyState()
                } else {
                    DispatchQueue.main.async(execute: applyState)
                }
            }
        } catch {
            groupProjectionObserver = nil
            throw error
        }
    }
    
}
