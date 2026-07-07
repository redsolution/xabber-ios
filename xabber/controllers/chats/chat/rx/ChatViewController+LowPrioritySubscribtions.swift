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
import RxSwift
import RxCocoa
import RealmSwift
import MaterialComponents.MDCPalettes
import CocoaLumberjack

enum ChatSendButtonReadinessPolicy {
    static func shouldBlockForPendingOrFailedMessages(
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> Bool {
        conversationType.isEncrypted
    }

    static func isEnabled(
        conversationType: ClientSynchronizationManager.ConversationType,
        isSkeletonVisible: Bool,
        isAccountConnecting: Bool,
        hasPendingOrFailedMessage: Bool,
        omemoAvailability: OmemoSendAvailabilityPolicy.Availability = .canSend,
        hasMediaPreparationBlocker: Bool = false
    ) -> Bool {
        guard !isSkeletonVisible,
              !isAccountConnecting,
              !hasMediaPreparationBlocker,
              omemoAvailability.canSend else {
            return false
        }

        return !shouldBlockForPendingOrFailedMessages(conversationType: conversationType) ||
            !hasPendingOrFailedMessage
    }
}

extension ChatViewController {
    internal func pendingOrFailedMessageBlocksSend(in realm: Realm) -> Bool {
        guard ChatSendButtonReadinessPolicy.shouldBlockForPendingOrFailedMessages(
            conversationType: self.conversationType
        ) else {
            return false
        }

        return !realm
            .objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND messageType != %@ AND (state_ == %@ OR state_ == %@)",
                self.owner,
                self.jid,
                self.conversationType.rawValue,
                MessageStorageItem.MessageDisplayType.system.rawValue,
                MessageStorageItem.MessageSendingState.sending.rawValue,
                MessageStorageItem.MessageSendingState.error.rawValue
            )
            .isEmpty
    }

    private func baseOmemoAvailabilityForSendButton() -> OmemoSendAvailabilityPolicy.Availability {
        self.conversationType.isEncrypted ? self.currentOmemoSendAvailability() : .canSend
    }

    internal func applyBaseSendButtonReadiness(
        isSkeletonVisible: Bool,
        isAccountConnecting: Bool,
        hasPendingOrFailedMessage: Bool,
        omemoAvailability: OmemoSendAvailabilityPolicy.Availability? = nil
    ) {
        self.xabberInputView.isSendButtonEnabled = ChatSendButtonReadinessPolicy.isEnabled(
            conversationType: self.conversationType,
            isSkeletonVisible: isSkeletonVisible,
            isAccountConnecting: isAccountConnecting,
            hasPendingOrFailedMessage: hasPendingOrFailedMessage,
            omemoAvailability: omemoAvailability ?? self.baseOmemoAvailabilityForSendButton()
        )
        self.xabberInputView.updateSendButtonState()
    }

    internal func updateStatusText() {
        self.setStatusText(self.connectionAwareStatusText(fallbackStatus: self.contactStatus ?? " "))
        self.statusLabel.layoutIfNeeded()
        if (self.statusLabel.text ?? "").isEmpty {
            self.statusLabel.isHidden = true
        } else {
            self.statusLabel.isHidden = false
        }
    }

    private func updateComposerContextPreview(forAttachedMessageIds results: [String]) {
        guard results.isNotEmpty, self.editMessageId.value == nil else {
            return
        }

        do {
            if results.count == 1 {
                let realm = try WRealm.safe()
                if let primary = results.first,
                   let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                    let message = NSAttributedString(
                        string: item.displayedBody(),
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                            .foregroundColor: UIColor.secondaryLabel
                        ]
                    )
                    var title = item.outgoing ? self.ownerSender.displayName : self.opponentSender.displayName
                    if item.opponent != self.jid && !item.outgoing {
                        if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: item.opponent, owner: item.owner)) {
                            title = instance.displayName
                        } else {
                            title = item.opponent
                        }
                    }
                    self.xabberInputView.contextPreviewPanel.update(
                        title: "Reply to \(title)",
                        attributed: message
                    )
                    self.showForwardPanel()
                }
            } else {
                var nicknames: Set<String> = Set<String>()
                var jids: Set<String> = Set<String>()
                let realm = try WRealm.safe()
                let items = realm.objects(MessageStorageItem.self).filter("primary IN %@", results)
                items.forEach { jids.insert($0.outgoing ? $0.owner : $0.opponent) }
                jids.forEach {
                    if $0 == self.owner {
                        if let displayName = AccountManager.shared.find(for: $0)?.username {
                            nicknames.insert(displayName)
                        }
                    } else if let displayName = realm
                        .object(ofType: RosterStorageItem.self,
                                forPrimaryKey: [$0, self.owner].prp())?
                        .displayName {
                        nicknames.insert(displayName)
                    }
                }
                let message = NSAttributedString(
                    string: "\(results.count) forwarded messages".localizeString(id: "counted_forwarded_messages", arguments: ["\(results.count)"]),
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                        .foregroundColor: UIColor.secondaryLabel
                    ]
                )
                self.xabberInputView.contextPreviewPanel.update(
                    title: nicknames.joined(separator: ", "),
                    attributed: message
                )
                self.showForwardPanel()
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func lowPrioritySubscribtions() {
        CommonChatStatesManager
            .shared
            .observed
            .asObservable()
            .debounce(.milliseconds(500), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (_) in
                self.updateStatusText()
            })
            .disposed(by: bag)
        
        self.loadDatasourceObserver
            .asObservable()
            .distinctUntilChanged()
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
            self.canLoadDatasource = value
        }.disposed(by: self.bag)

        
        self.showFloatingDateObserver
            .asObservable()
            .skip(1)
            .debounce(.milliseconds(400), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
                if self.showSkeletonObserver.value {
                    return
                }
                if value {
                    let visibleItems = self.messagesCollectionView.indexPathsForVisibleItems
                    let layout = self.messagesCollectionView.collectionViewLayout as! MessagesCollectionViewFlowLayout
                    let visibleDateFrames: [CGRect] = visibleItems.compactMap {
                        path in
                        guard let item = self.datasourceItem(at: path) else {
                            return nil
                        }
                        switch item.kind {
                            case .date, .unread:
                                let attrib = layout.layoutAttributesForItem(at: path)
                                guard let frame = attrib?.frame else { return nil }
                                var convertedPoint = self.messagesCollectionView.convert(frame.origin, to: self.view)
                                let newFrame = CGRect(origin: convertedPoint, size: frame.size)
                                print(newFrame)
                                return newFrame
                            default:
                                return nil
                        }
                    }.filter({
                        $0.minY < 150
                    })
                    if visibleItems.isEmpty {
                        self.setFloatingDateVisible(value)
                    } else if visibleItems.isNotEmpty && visibleDateFrames.isEmpty && ((visibleItems.compactMap({ $0.section }).max() ?? 0) != self.datasource.count - 1) {
                        self.pinnedDateView.show()
                        self.setFloatingDateHidden(true)
                    } else {
                        self.pinnedDateView.hide(fast: true)
                    }
                } else {
                    print(1)
                }
            }.disposed(by: self.bag)
        
        self.hideFloatingDateObserver
            .asObservable()
            .debounce(.seconds(3), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
                if value {
                    self.pinnedDateView.hide()
                }
            }.disposed(by: self.bag)

        
        inTypingMode
            .asObservable()
            .window(timeSpan: .seconds(5), count: 22, scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (_) in
                
                if SettingManager.shared.get(bool: SettingManager.PrivacySettings.typingNotification.rawValue) {
                    if let value = self.inTypingMode.value {
                        if value {
                            self.inTypingMode.accept(nil)
                            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                user.chatStates.composing(stream, to: self.jid, type: .typing)
                            })
                        } else {
                            self.inTypingMode.accept(nil)
                            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                                user.chatStates.pause(stream, to: self.jid)
                            })
                        }
                    }
                }
            })
            .disposed(by: bag)
        
        
        editMessageId
            .asObservable()
            .debounce(.microseconds(5), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (result) in
                if (result?.isNotEmpty ?? false) {
                    do {
                        let realm = try WRealm.safe()
                        if let primary = result,
                            let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                            var nickname = item.outgoing ? self.ownerSender.displayName : ""
                            if self.conversationType == .group {
                                if let instance = realm
                                    .objects(GroupchatUserStorageItem.self)
                                    .filter("groupchatId == %@ AND isMe == true AND isHidden == false", [self.jid, self.owner].prp())
                                    .first {
                                    nickname = instance.nickname
                                }
                            } else if !item.outgoing,
                               let displayName = realm
                                   .object(ofType: RosterStorageItem.self,
                                           forPrimaryKey: [item.opponent,
                                                           item.owner].prp())?
                                   .displayName {
                               nickname = displayName
                           }
                           if nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                               ToastPresenter().presentError(message: "Database error"
                                .localizeString(id: "chat_database_error", arguments: []))
                               return
                           } else {
                               let text = item
                                   .createRefBody([
                                    .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                                       .foregroundColor: MDCPalette.grey.tint800
                                   ])
                               self.xabberInputView.contextPreviewPanel.update(
                                title: nickname,
                                attributed: text
                               )
                               self.xabberInputView.setComposerBody(item.body, references: item.references.toArray())
                               self.xabberInputView.textViewDidChange(force: true)
                               self.showEditPanel()
                           }

                       } else {
                           ToastPresenter().presentError(message: "Database error"
                            .localizeString(id: "chat_database_error", arguments: []))
                           return
                       }
                   } catch {
                       DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                       ToastPresenter().presentError(message: "Database error"
                        .localizeString(id: "chat_database_error", arguments: []))
                       return
                   }
                } else {
                    if self.attachedMessagesIds.value.isEmpty {
                        self.hideMessagePanelBubble()
                    } else {
                        self.updateComposerContextPreview(forAttachedMessageIds: self.attachedMessagesIds.value)
                    }
                }
            })
            .disposed(by: bag)
        
        attachedMessagesIds
            .asObservable()
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                if results.isEmpty {
                    if self.editMessageId.value == nil {
                        self.hideMessagePanelBubble()
                    }
                    return
                }

                self.updateComposerContextPreview(forAttachedMessageIds: results)
                
            })
            .disposed(by: bag)
        
        forwardedIds
            .asObservable()
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                do {
                    let realm = try WRealm.safe()
                    let collection = realm.objects(MessageStorageItem.self).filter("primary IN %@", Array(results))
                    let canDelete = collection.contains {
                        $0.archivedId.isNotEmpty || PendingOutgoingMessageDeletionPolicy.canDeleteLocally($0)
                    }
                    if canDelete {
                        UIView.animate(withDuration: 0.1) {
                            self.xabberInputView.selectionPanel.deleteButton.isEnabled = true
                        }
                    } else {
                        UIView.animate(withDuration: 0.1) {
                            self.xabberInputView.selectionPanel.deleteButton.isEnabled = false
                        }
                    }
                    self.deleteSelectionBarButton.isEnabled = canDelete
                } catch {
                    DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                }
                self.selectionCountLabel.text = "\(results.count) selected"
                self.selectionCountLabel.sizeToFit()
            })
            .disposed(by: bag)
        
        isInSelectionMode
            .asObservable()
            .skip(1)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { (value) in
                let shouldAnimate = ChatNavigationTransitionMutationPolicy.shouldAnimateMutation(
                    requestedAnimated: true,
                    isTransitionActive: self.isNavigationTransitionActive,
                    isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation
                )
                if value {
                    self.invalidateNavigationAvatarItem()
                    NavigationBarItemOwnership.apply(
                        to: self.navigationItem,
                        left: .item(self.deleteSelectionBarButton),
                        right: .item(self.cancelSelectionBarButton),
                        animated: shouldAnimate
                    )
                    self.navigationItem.setHidesBackButton(true, animated: shouldAnimate)
                    self.xabberInputView.showSelectionPanel()
                    self.navigationItem.titleView = self.selectionCountLabel
                } else {
                    self.navigationItem.setHidesBackButton(false, animated: shouldAnimate)
                    self.xabberInputView.hideSelectionPanel()
                    self.configureNavbar()
                }
            })
            .disposed(by: bag)
                

        blockInputFieldByTimeSignature
            .asObservable()
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
                self.onUpdateTimeSignatureBlockState(value)
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: bag)

        
        
        self.showSkeletonObserver
            .asObservable()
//            .skip(1)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
                var didReloadInitialWindow = false
//                self.runDatasetUpdateTask(shouldScrollToLastMessage: true)
                if value {
                    self.applyBaseSendButtonReadiness(
                        isSkeletonVisible: true,
                        isAccountConnecting: AccountManager.shared.connectingUsers.value.contains(self.owner),
                        hasPendingOrFailedMessage: false
                    )
                    self.setShouldShowInitialMessage(false)
                } else if AccountManager.shared.connectingUsers.value.contains(self.owner) {
                    self.applyBaseSendButtonReadiness(
                        isSkeletonVisible: false,
                        isAccountConnecting: true,
                        hasPendingOrFailedMessage: false
                    )
                } else {
                    do {
                        let realm = try WRealm.safe()
                        self.applyBaseSendButtonReadiness(
                            isSkeletonVisible: false,
                            isAccountConnecting: false,
                            hasPendingOrFailedMessage: self.pendingOrFailedMessageBlocksSend(in: realm)
                            )
                        let chatInstance = realm.object(
                            ofType: LastChatsStorageItem.self,
                            forPrimaryKey: LastChatsStorageItem.genPrimary(
                                jid: self.jid,
                                owner: self.owner,
                                conversationType: self.conversationType
                            )
                        )
                        self.setShouldShowInitialMessage(
                            self.messagesObserver.isEmpty && self.bootstrapViewState(chatInstance: chatInstance) == .empty
                        )
	                    } catch {
	                        DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
	                    }

	                    if !self.isApplyingBootstrapAnchorWindow {
	                        didReloadInitialWindow = self.reloadInitialWindowAfterBootstrapIfNeeded()
	                    }
	                }
	                if !self.isApplyingBootstrapAnchorWindow &&
	                    ChatInitialHistoryAppearancePolicy.shouldApplyFollowupChangesetAfterBootstrapReload(
	                    didReloadInitialWindow: didReloadInitialWindow
	                ) {
	                    self.didReceiveChangeset()
	                }
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)
        
        self.messagesToReadObserver
            .asObservable()
            .debounce(.milliseconds(500), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { [weak self] _ in
                self?.flushPendingVisibleReadTarget()
        } onError: { _ in
            
        } onCompleted: {
            
        } onDisposed: {
            
        }.disposed(by: self.bag)

        
        self.draftMessageText
            .asObservable()
            .debounce(.milliseconds(800), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { value in
                do {
                    let realm  = try WRealm.safe()
                    try realm.write {
                        realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))?.draftMessage = value
                    }
                } catch {
                    DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                }
            }.disposed(by: self.bag)
        
//        self.bottomVisibleMessageId
//            .asObservable()
//            .debounce(.milliseconds(800), scheduler: MainScheduler.asyncInstance)
//            .subscribe { value in
//                do {
////                    guard let minVisibleItem = self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ $0.section }).min() else {
////                        return
////                    }
////                    let messageId = self.datasource[minVisibleItem].archivedId
////                    self.bottomVisibleMessageId.accept(messageId)
//                    let realm  = try WRealm.safe()
//                    try realm.write {
//                        realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))?.lastBottomDisplayedMessageId = value
//                    }
//                } catch {
//                    DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
//                }
//            }.disposed(by: self.bag)
        
        AccountManager
            .shared
            .connectingUsers
            .asObservable()
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { result in
            self.updateStatusText()
            if result.contains(self.owner) {
                if !self.shouldRequestChatInfo {
                    self.applyBaseSendButtonReadiness(
                        isSkeletonVisible: self.showSkeletonObserver.value,
                        isAccountConnecting: true,
                        hasPendingOrFailedMessage: false
                    )
                    self.shouldRequestChatInfo = true
                }
            } else {
                if self.shouldRequestChatInfo {
                    self.willEnterForeground()
                    self.shouldRequestChatInfo = false
                }
                do {
                    let realm = try WRealm.safe()
                    self.applyBaseSendButtonReadiness(
                        isSkeletonVisible: self.showSkeletonObserver.value,
                        isAccountConnecting: false,
                        hasPendingOrFailedMessage: self.pendingOrFailedMessageBlocksSend(in: realm)
                        )
                } catch {
                    DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                }
            }
        } onError: { _ in
            
        } onCompleted: {
            
        } onDisposed: {
            
        }.disposed(by: self.bag)

        
    }
    
    final func encryptedSubscribtions() throws {
        if !self.conversationType.isEncrypted { return }

        let realm = try Realm()
        if CommonConfigManager.shared.config.required_time_signature_for_messages {
            let certsCollection = realm.objects(X509StorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
            
        Observable
            .collection(from: certsCollection)
            .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { results in
                self.contactWithSigningCertificate = !results.isEmpty
                self.runOrDeferChatPresentationRefresh(keySuffix: "signingCertificate") { [weak self] in
                    guard let self else { return }
                    self.titleLabel.attributedText = self.updateTitle()
                    self.titleLabel.sizeToFit()
                    self.titleLabel.layoutIfNeeded()
                }
                } onError: { error in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: bag)
            
        }
        
        let badMessageCollection = realm
            .objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND messageType != %@ AND (state_ == %@ OR state_ == %@)",
                self.owner,
                self.jid,
                self.conversationType.rawValue,
                MessageStorageItem.MessageDisplayType.system.rawValue,
                MessageStorageItem.MessageSendingState.sending.rawValue,
                MessageStorageItem.MessageSendingState.error.rawValue
            )
        
        Observable
            .collection(from: badMessageCollection)
            .debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { results in
                self.applyBaseSendButtonReadiness(
                    isSkeletonVisible: self.showSkeletonObserver.value,
                    isAccountConnecting: AccountManager.shared.connectingUsers.value.contains(self.owner),
                    hasPendingOrFailedMessage: !results.isEmpty
                )
            }).disposed(by: bag)
        
        let ownDevicesCollection = realm
            .objects(SignalDeviceStorageItem.self)
            .filter("owner == %@ AND jid == %@", self.owner, self.owner)

        let contactDevicesCollection = realm
            .objects(SignalDeviceStorageItem.self)
            .filter("owner == %@ AND jid == %@", self.owner, self.jid)
        
        Observable
            .collection(from: ownDevicesCollection)
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { _ in
                self.refreshOmemoSendAvailability()
            }.disposed(by: self.bag)
        
        Observable
            .collection(from: contactDevicesCollection)
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { _ in
                self.refreshOmemoSendAvailability()
                self.runOrDeferChatPresentationRefresh(keySuffix: "contactDevices") { [weak self] in
                    guard let self else { return }
                    self.titleLabel.attributedText = self.updateTitle()
                    self.titleLabel.sizeToFit()
                    self.titleLabel.layoutIfNeeded()
                }
            }.disposed(by: self.bag)

        self.refreshOmemoSendAvailability()

        let verificationSessions = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
        Observable
            .collection(from: verificationSessions)
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { results in
                if results.isEmpty {
                    let contactDevices = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@ AND state_ IN %@", self.owner, self.jid, [SignalDeviceStorageItem.TrustState.unknown.rawValue, SignalDeviceStorageItem.TrustState.distrusted.rawValue])
                    if !contactDevices.isEmpty {
                        if !self.topPanelState.value.isSubscriptionPanel {
                            self.setTopPanelState(.shouldRequestVerification)
                        }
                        return
                    }
                }
                
                let item = results.first
                if !self.topPanelState.value.isSubscriptionPanel {
                    switch item?.state {
                        case .receivedRequestAccept:
                            self.setTopPanelState(.enterCodeVerification)
                        case .receivedRequest:
                            self.setTopPanelState(.requestingVerification)
                        case .acceptedRequest:
                            self.setTopPanelState(.acceptedVerification)
                        case .trusted:
                            self.setTopPanelState(.none)
                        default:
                            break
                    }
                }
            }.disposed(by: self.bag)
        
        let contactDevices = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@ AND state_ IN %@", self.owner, self.jid, [SignalDeviceStorageItem.TrustState.distrusted.rawValue, SignalDeviceStorageItem.TrustState.unknown.rawValue])
        Observable
            .collection(from: contactDevices)
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .observe(on: MainScheduler.asyncInstance)
            .subscribe { results in
                if results.isEmpty {
                    return
                }
                
                let instance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid).first
                if instance != nil {
                    return
                }
                
                if !self.topPanelState.value.isSubscriptionPanel && self.topPanelState.value != .shouldRequestVerification {
                    self.setTopPanelState(.shouldRequestVerification)
                }
                
            }.disposed(by: self.bag)
    }
}
