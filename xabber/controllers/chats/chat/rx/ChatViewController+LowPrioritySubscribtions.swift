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
import Toast_Swift

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
        
        inTypingMode
            .asObservable()
            .window(timeSpan: .seconds(5), count: 22, scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (_) in
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
            })
            .disposed(by: bag)
        
        
        editMessageId
            .asObservable()
            .debounce(.microseconds(5), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (result) in
//                if (result?.isNotEmpty ?? false) {
//                    do {
//                        let realm = try WRealm.safe()
//                        if let primary = result,
//                            let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
//                            var nickname = item.outgoing ? self.ownerSender.displayName : ""
//                            if self.groupchat {
//                                if let instance = realm
//                                    .objects(GroupchatUserStorageItem.self)
//                                    .filter("groupchatId == %@ AND isMe == true", [self.jid, self.owner].prp())
//                                    .first {
//                                    nickname = instance.nickname
//                                }
//                            } else if !item.outgoing,
//                               let displayName = realm
//                                   .object(ofType: RosterStorageItem.self,
//                                           forPrimaryKey: [item.opponent,
//                                                           item.owner].prp())?
//                                   .displayName {
//                               nickname = displayName
//                           }
//                           if nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//                               self.messagesPanelValidationError("Database error"
//                                    .localizeString(id: "chat_database_error", arguments: []))
//                               return
//                           } else {
//                               self.messagesPanel
//                                   .update(title: nickname,
//                                           message: item
//                                               .createRefBody([
//                                                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
//                                                   .foregroundColor: MDCPalette.grey.tint800
//                                               ]),
//                                           color: self.accountPallete)
//                                self.messagesPanel.show()
//                                self.xabberInputBar.setStackViewItems([self.messagesPanel], forStack: .top, animated: false, forceHeight: 48)
//                           }
//
//                       } else {
//                           self.messagesPanelValidationError("Database error"
//                                    .localizeString(id: "chat_database_error", arguments: []))
//                           return
//                       }
//                   } catch {
//                       DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
//                       self.messagesPanelValidationError("Database error"
//                                    .localizeString(id: "chat_database_error", arguments: []))
//                       return
//                   }
//                } else {
//                    self.messagesPanel.hide()
//                    if self.xabberInputBar.topStackView.arrangedSubviews.isNotEmpty {
//                        self.xabberInputBar.setStackViewItems([], forStack: .top, animated: false, forceHeight: 0)
//                    }
//                }
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
                                string: item.displayedBody(entity: self.entity),
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
                                title: title,
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
                
        toolsButtonStateObserver
            .asObservable()
            .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (value) in
                self.toolsButton.changeState(value)
            })
            .disposed(by: bag)
        
        searchTextBouncerObserver
            .asObservable()
            .debounce(.milliseconds(600), scheduler: MainScheduler.asyncInstance)
            .skip(1)
            .subscribe(onNext: { (value) in
                if self.searchTextObserver.value != value {
                    self.searchTextObserver.accept(value)
                    self.canUpdateDataset = true
                    self.runDatasetUpdateTask()
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

        
        if [.omemo, .omemo1, .axolotl].contains(self.conversationType) {
            do {
                let realm = try Realm()
                if CommonConfigManager.shared.config.required_time_signature_for_messages {
                    let certsCollection = realm.objects(X509StorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
                    
                    Observable
                        .collection(from: certsCollection)
                        .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
                        .subscribe { results in
                            self.contactWithSigningCertificate = !results.isEmpty
                            self.titleLabel.attributedText = self.updateTitle()
                        } onError: { error in
                            
                        } onCompleted: {
                            
                        } onDisposed: {
                            
                        }.disposed(by: bag)
                    
                }
                
                let myUntrustedDevicesCollection = realm
                    .objects(SignalDeviceStorageItem.self)
                    .filter("owner == %@ AND jid == %@ AND state_ != %@", self.owner, self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue)
                
                
                Observable.collection(from: myUntrustedDevicesCollection)
                    .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
                    .subscribe { results in
                        self.titleLabel.attributedText = self.updateTitle()
                        if !results.isEmpty {
                            self.onUpdateTrustedDevicesBlockState(true)
                        } else {
                            do {
                                let realm = try Realm()
                                let collection = realm
                                    .objects(SignalDeviceStorageItem.self)
                                    .filter("owner == %@ AND jid == %@ AND state_ == %@", self.owner, self.jid, SignalDeviceStorageItem.TrustState.trusted.rawValue)
                                self.onUpdateTrustedDevicesBlockState(collection.isEmpty)
                            } catch {
                                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                            }
                        }
                    } onError: { error in
                        
                    } onCompleted: {
                        
                    } onDisposed: {
                        
                    }.disposed(by: self.bag)

            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
        self.showSkeletonObserver
            .asObservable()
            .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
            .subscribe { value in
                self.isSkeletonHided = !value
                if !value {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.canUpdateDataset = true
                        self.runDatasetUpdateTask(shouldScrollToLastMessage: true)
                    }
                }
//                self.messagesCollectionView.isScrollEnabled = !value
//                self.messagesCollectionView.isUserInteractionEnabled = !value
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
        
    }
    
}
