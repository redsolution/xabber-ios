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

extension ChatViewController {
    internal func updateStatusText() {
        if let text = CommonChatStatesManager.shared.actionText(for: self.jid, owner: self.owner) {
            self.statusTextObserver.accept(text)
        } else {
            self.statusTextObserver.accept(AccountManager
                .shared
                .connectingUsers
                .value
                .contains(self.owner) ? "Waiting for network..."
                        .localizeString(id: "waiting_for_network", arguments: []) : self.contactStatus ?? " ")
        }
        self.statusLabel.layoutIfNeeded()
        if (self.statusLabel.text ?? "").isEmpty {
            self.statusLabel.isHidden = true
        } else {
            self.statusLabel.isHidden = false
        }
    }
    
    internal func lowPrioritySubscribtions() {
        CommonChatStatesManager
            .shared
            .observed
            .asObservable()
            .debounce(.milliseconds(500), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (_) in
                self.updateStatusText()
            })
            .disposed(by: bag)
        
        self.loadDatasourceObserver.asObservable().debounce(.seconds(1), scheduler: MainScheduler.asyncInstance).subscribe { value in
            self.canLoadDatasource = value
        }.disposed(by: self.bag)

        
        self.showFloatingDateObserver
            .asObservable()
            .skip(1)
            .debounce(.milliseconds(400), scheduler: MainScheduler.asyncInstance)
            .subscribe { value in
                if self.showSkeletonObserver.value {
                    return
                }
                if value {
                    let visibleItems = self.messagesCollectionView.indexPathsForVisibleItems
                    let layout = self.messagesCollectionView.collectionViewLayout as! MessagesCollectionViewFlowLayout
                    let visibleDateFrames: [CGRect] = visibleItems.compactMap {
                        path in
                        switch self.datasource[path.section].kind {
                            case .date, .unread:
                                let attrib = layout.layoutAttributesForItem(at: path)
                                guard let frame = attrib?.frame else { return nil }
                                var convertedPoint = self.messagesCollectionView.convert(frame.origin, to: self.view)
                                convertedPoint.y = convertedPoint.y - frame.height
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
                        self.showFloatingDateObserver.accept(value)
                    } else if visibleItems.isNotEmpty && visibleDateFrames.isEmpty && ((visibleItems.compactMap({ $0.section }).max() ?? 0) != self.datasource.count - 1) {
                        self.pinnedDateView.show()
                        self.hideFloatingDateObserver.accept(true)
                    } else {
                        self.pinnedDateView.hide(fast: true)
                    }
                }
            }.disposed(by: self.bag)
        
        self.hideFloatingDateObserver
            .asObservable()
            .debounce(.seconds(3), scheduler: MainScheduler.asyncInstance)
            .subscribe { value in
                if value {
                    self.pinnedDateView.hide()
                }
            }.disposed(by: self.bag)

        
        inTypingMode
            .asObservable()
            .window(timeSpan: .seconds(5), count: 22, scheduler: MainScheduler.asyncInstance)
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
                                    .filter("groupchatId == %@ AND isMe == true", [self.jid, self.owner].prp())
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
                               self.xabberInputView.editPanel.update(
                                title: nickname,
                                attributed: text
                               )
                               self.xabberInputView.textField.text = text.string
                               self.xabberInputView.textViewDidChange(force: true)
                               self.xabberInputView.showEditPanel()
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
                    self.xabberInputView.hideEditPanel()
                }
            })
            .disposed(by: bag)
        
        attachedMessagesIds
            .asObservable()
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                do {
                    if results.isEmpty {
                        self.xabberInputView.hideForwardPanel()
                    } else if results.count == 1 {
                        let realm = try WRealm.safe()
                        if let primary = results.first,
                            let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                            let message = NSAttributedString(
                                string: item.displayedBody(),
                                attributes: [
                                    .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                                    .foregroundColor: UIColor.secondaryLabel
                                ])
                            var title = item.outgoing ? self.ownerSender.displayName : self.opponentSender.displayName
                            if item.opponent != self.jid && !item.outgoing {
                                if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: item.opponent, owner: item.owner)) {
                                    title = instance.displayName
                                } else {
                                    title = item.opponent
                                }
                            }
                            self.xabberInputView.forwardPanel.update(
                                title: "Reply to \(title)",
                                attributed: message
                            )
                            self.xabberInputView.showForwardPanel()
                        } else {
                            return
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
                            } else {
                                if let displayName = realm
                                    .object(ofType: RosterStorageItem.self,
                                            forPrimaryKey: [$0, self.owner].prp())?
                                    .displayName {
                                    nicknames.insert(displayName)
                                }
                            }
                        }
                        let message = NSAttributedString(
                            string: "\(results.count) forwarded messages".localizeString(id: "counted_forwarded_messages", arguments: ["\(results.count)"]),
                            attributes: [
                                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                                .foregroundColor: UIColor.secondaryLabel
                            ]
                        )
                        self.xabberInputView.forwardPanel.update(
                            title: nicknames.joined(separator: ", "),
                            attributed: message
                        )
                        self.xabberInputView.showForwardPanel()
                    }
                } catch {
                    DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                }
                
            })
            .disposed(by: bag)
        
        forwardedIds
            .asObservable()
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                do {
                    let realm = try WRealm.safe()
                    let collection = realm.objects(MessageStorageItem.self).filter("primary IN %@", Array(results))
                    if collection.filter({ $0.archivedId.isNotEmpty }).isEmpty {
                        UIView.animate(withDuration: 0.1) {
                            self.xabberInputView.selectionPanel.deleteButton.isEnabled = false
                        }
                    } else {
                        UIView.animate(withDuration: 0.1) {
                            self.xabberInputView.selectionPanel.deleteButton.isEnabled = true
                        }
                    }
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
            .subscribe(onNext: { (value) in
                if value {
                    self.navigationItem.setRightBarButton(self.cancelSelectionBarButton, animated: true)
                    self.navigationItem.setHidesBackButton(true, animated: true)
                    self.navigationItem.setLeftBarButton(self.deleteSelectionBarButton, animated: true)
                    self.xabberInputView.showSelectionPanel()
                    self.navigationItem.titleView = self.selectionCountLabel
                } else {
                    self.navigationItem.setHidesBackButton(false, animated: true)
                    self.navigationItem.setLeftBarButton(nil, animated: true)
                    self.navigationItem.setRightBarButton(UIBarButtonItem(customView: self.userBarButton), animated: true)
                    self.xabberInputView.hideSelectionPanel()
                    self.navigationItem.titleView = self.titleButton
                }
            })
            .disposed(by: bag)
                

        blockInputFieldByTimeSignature
            .asObservable()
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .subscribe { value in
                self.onUpdateTimeSignatureBlockState(value)
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: bag)

        
        
        self.showSkeletonObserver
            .asObservable()
//            .skip(1)
            .subscribe { value in
//                self.runDatasetUpdateTask(shouldScrollToLastMessage: true)
                if !value {
                    if AccountManager.shared.connectingUsers.value.contains(self.owner) {
                        self.xabberInputView.isSendButtonEnabled = false
                    } else {
                        do {
                            let realm = try WRealm.safe()
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
                            if value {
                                self.xabberInputView.isSendButtonEnabled = false
                            } else {
                                self.xabberInputView.isSendButtonEnabled = badMessageCollection.isEmpty
                            }
                            if let chatInstance = realm.object(
                                ofType: LastChatsStorageItem.self,
                                forPrimaryKey: LastChatsStorageItem.genPrimary(
                                    jid: self.jid,
                                    owner: self.owner,
                                    conversationType: self.conversationType
                                )
                            ) {
                                self.shouldShowInitialMessage.accept(self.messagesObserver.isEmpty && chatInstance.isSynced)
                            } else {
                                self.shouldShowInitialMessage.accept(self.messagesObserver.isEmpty)
                            }
                        } catch {
                            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                        }
                        
                    }
                }
                self.didReceiveChangeset()
                self.xabberInputView.updateSendButtonState()
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)
        
        self.draftMessageText
            .asObservable()
            .debounce(.milliseconds(800), scheduler: MainScheduler.asyncInstance)
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
            .subscribe { result in
            if result.contains(self.owner) {
                if !self.shouldRequestChatInfo {
                    self.xabberInputView.isSendButtonEnabled = false
                    self.xabberInputView.updateSendButtonState()
                    self.shouldRequestChatInfo = true
                }
            } else {
                if self.shouldRequestChatInfo {
                    self.willEnterForeground()
                    self.shouldRequestChatInfo = false
                }
                do {
                    let realm = try WRealm.safe()
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
                    if self.showSkeletonObserver.value {
                        self.xabberInputView.isSendButtonEnabled = false
                    } else {
//                        print(badMessageCollection.toArray())
                        self.xabberInputView.isSendButtonEnabled = badMessageCollection.isEmpty
                    }
                    self.xabberInputView.updateSendButtonState()
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
                .subscribe { results in
                    self.contactWithSigningCertificate = !results.isEmpty
                    self.titleLabel.attributedText = self.updateTitle()
                    self.titleLabel.sizeToFit()
                    self.titleLabel.layoutIfNeeded()
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
            .subscribe { results in
                if !self.showSkeletonObserver.value {
                    if AccountManager.shared.connectingUsers.value.contains(self.owner) {
                        self.xabberInputView.isSendButtonEnabled = false
                    } else {
                        self.xabberInputView.isSendButtonEnabled = results.isEmpty
                    }
                    self.xabberInputView.updateSendButtonState()
                } else {
                    self.xabberInputView.isSendButtonEnabled = false
                    self.xabberInputView.updateSendButtonState()
                }
            }.disposed(by: bag)
        
        let myUntrustedDevicesCollection = realm
            .objects(SignalDeviceStorageItem.self)
            .filter("owner == %@ AND jid == %@ AND state_ != %@", self.owner, self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue)
        
        let theirUntrustDevicesCollection = realm
            .objects(SignalDeviceStorageItem.self)
            .filter("owner == %@ AND jid == %@", self.owner, self.jid)
        
        Observable
            .collection(from: myUntrustedDevicesCollection)
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .subscribe { results in
                if !results.isEmpty {
                    self.onUpdateTrustedDevicesBlockState(true, identityVerification: false)
                } else {
                    self.onUpdateTrustedDevicesBlockState(false, identityVerification: false)
                }
            }.disposed(by: self.bag)
        
        Observable
            .collection(from: theirUntrustDevicesCollection)
            .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
            .subscribe { results in
                do {
                    let realm = try WRealm.safe()
                    let myUntrustedDevicesCollection = realm
                        .objects(SignalDeviceStorageItem.self)
                        .filter("owner == %@ AND jid == %@ AND state_ != %@", self.owner, self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue)
                    
                    if results.isEmpty {
                        self.onUpdateTrustedDevicesBlockState(true, identityVerification: myUntrustedDevicesCollection.isEmpty)
                    } else {
                        self.onUpdateTrustedDevicesBlockState(!myUntrustedDevicesCollection.isEmpty, identityVerification: false)
                    }
                } catch {
                    
                }
                
                self.titleLabel.attributedText = self.updateTitle()
                self.titleLabel.sizeToFit()
                self.titleLabel.layoutIfNeeded()
            }.disposed(by: self.bag)

        let verificationSessions = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
        Observable
            .collection(from: verificationSessions)
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .subscribe { results in
                if results.isEmpty {
                    let contactDevices = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@ AND state_ IN %@", self.owner, self.jid, [SignalDeviceStorageItem.TrustState.unknown.rawValue, SignalDeviceStorageItem.TrustState.distrusted.rawValue])
                    if !contactDevices.isEmpty {
                        if ![.addContact, .allowSubscribtion, .requestSubscribtion].contains(self.topPanelState.value) {
                            self.topPanelState.accept(.shouldRequestVerification)
                        }
                        return
                    }
                }
                
                let item = results.first
                if ![.addContact, .allowSubscribtion, .requestSubscribtion].contains(self.topPanelState.value) {
                    switch item?.state {
                        case .receivedRequestAccept:
                            self.topPanelState.accept(.enterCodeVerification)
                        case .receivedRequest:
                            self.topPanelState.accept(.requestingVerification)
                        case .acceptedRequest:
                            self.topPanelState.accept(.acceptedVerification)
                        case .trusted:
                            self.topPanelState.accept(.none)
                        default:
                            break
                    }
                }
            }.disposed(by: self.bag)
        
        let contactDevices = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@ AND state_ IN %@", self.owner, self.jid, [SignalDeviceStorageItem.TrustState.distrusted.rawValue, SignalDeviceStorageItem.TrustState.unknown.rawValue])
        Observable
            .collection(from: contactDevices)
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .subscribe { results in
                if results.isEmpty {
                    return
                }
                
                let instance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid).first
                if instance != nil {
                    return
                }
                
                if ![.addContact, .allowSubscribtion, .requestSubscribtion, .shouldRequestVerification].contains(self.topPanelState.value) {
                    self.topPanelState.accept(.shouldRequestVerification)
                }
                
            }.disposed(by: self.bag)
    }
}
