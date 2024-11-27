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
import MaterialComponents.MDCPalettes
import RxCocoa
import RxSwift
import RxRealm
import CocoaLumberjack

extension ChatViewController {
    internal func onSearchPanelSeekUp() {
        guard let currentIndex = self.searchMessagesQueue.firstIndex(where: { $0.archivedId == self.selectedSearchResultId }) else {
            return
        }
        if self.searchMessagesQueue.count == 1 {
            return
        }
        var newIndex = currentIndex + 1
        if newIndex >= self.searchMessagesQueue.count {
            newIndex = 0
        }
        self.selectedSearchResultId = self.searchMessagesQueue[newIndex].archivedId
        self.xabberInputView.searchPanel.updateResults(current: newIndex, total: self.searchMessagesQueue.count)
        self.scrollToMessageArchivedId = self.searchMessagesQueue[newIndex].archivedId
        let date = searchMessagesQueue[newIndex].date
        self.searchSeekDirection = .up
        if let index = self.messagesObserver?.firstIndex(where: { $0.archivedId == self.searchMessagesQueue[newIndex].archivedId }) { //|| $0.messageId == self.searchMessagesQueue[newIndex].archivedId
            let first = self.searchMessagesQueue[newIndex].archivedId
            self.oldestMessageId = first
            self.messagesBag = DisposeBag()
            self.runDatasetUpdateTask(forceWithoutAnimations: true)
            self.showLoadingIndicator.accept(false)
        } else {
            self.showLoadingIndicator.accept(true)
            if !self.isLoadNextPage {
                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                    self.scrollToMessageTaskId = session.mam?.getHistoryUntill(stream, jid: self.jid, conversationType: self.conversationType, start: date, archived: self.searchMessagesQueue[newIndex].archivedId)
                } fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        self.scrollToMessageTaskId = user.mam.getHistoryUntill(stream, jid: self.jid, conversationType: self.conversationType, start: date, archived: self.searchMessagesQueue[newIndex].archivedId)
                    })
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                        self.scrollToMessageTaskId = session.mam?.getHistoryUntill(stream, jid: self.jid, conversationType: self.conversationType, start: date, archived: self.searchMessagesQueue[newIndex].archivedId)
                    } fail: {
                        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                            self.scrollToMessageTaskId = user.mam.getHistoryUntill(stream, jid: self.jid, conversationType: self.conversationType, start: date, archived: self.searchMessagesQueue[newIndex].archivedId)
                        })
                    }
                }
            }
        }
    }
    
    internal func onSearchPanelSeekDown() {
        guard let currentIndex = self.searchMessagesQueue.firstIndex(where: { $0.archivedId == self.selectedSearchResultId }) else {
            return
        }
        if self.searchMessagesQueue.count == 1 {
            return
        }

        var newIndex = currentIndex - 1
        if newIndex < 0 {
            newIndex = self.searchMessagesQueue.count - 1
        }
        self.selectedSearchResultId = self.searchMessagesQueue[newIndex].archivedId
        self.xabberInputView.searchPanel.updateResults(current: newIndex, total: self.searchMessagesQueue.count)
        self.scrollToMessageArchivedId = self.searchMessagesQueue[newIndex].archivedId
        let date = searchMessagesQueue[newIndex].date
        self.searchSeekDirection = .down
        if let index = self.messagesObserver?.firstIndex(where: { $0.archivedId == self.searchMessagesQueue[newIndex].archivedId }) {
//            let first = self.getMessageIdAtPostionOrLast(index: index + ChatViewController.datasourcePageSize)
            let last = self.searchMessagesQueue[newIndex].archivedId
            self.newestMessageId = last
            self.messagesBag = DisposeBag()
            self.runDatasetUpdateTask(forceWithoutAnimations: true)
            self.showLoadingIndicator.accept(false)
//            self.oldestMessageId = first
        } else {
            self.showLoadingIndicator.accept(true)
            
            
            if !self.isLoadNextPage {
                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                    self.scrollToMessageTaskId = session.mam?.getHistoryUntill(stream, jid: self.jid, conversationType: self.conversationType, start: date, archived: self.searchMessagesQueue[newIndex].archivedId)
                } fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        self.scrollToMessageTaskId = user.mam.getHistoryUntill(stream, jid: self.jid, conversationType: self.conversationType, start: date, archived: self.searchMessagesQueue[newIndex].archivedId)
                    })
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                        self.scrollToMessageTaskId = session.mam?.getHistoryUntill(stream, jid: self.jid, conversationType: self.conversationType, start: date, archived: self.searchMessagesQueue[newIndex].archivedId)
                    } fail: {
                        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                            self.scrollToMessageTaskId = user.mam.getHistoryUntill(stream, jid: self.jid, conversationType: self.conversationType, start: date, archived: self.searchMessagesQueue[newIndex].archivedId)
                        })
                    }
                }
            }
        }
    }
    
    internal func onSearchPanelChangeChatViewState() {
        let vc = SearchChatListViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        vc.conversationType = self.conversationType
//        vc.searchTextObserver.accept(self.searchBar.text)
        vc.searchBar.text = self.searchBar.text
        vc.messagesQueue = self.searchMessagesQueue
        vc.searchPanel.changeState(to: self.xabberInputView.searchPanel.state)
        if let currentIndex = self.searchMessagesQueue.firstIndex(where: { $0.archivedId == self.selectedSearchResultId }) {
            vc.selectedSearchResultId = self.searchMessagesQueue[currentIndex].archivedId
            vc.searchPanel.updateResults(current: currentIndex, total: self.searchMessagesQueue.count)
        }
        do {
            vc.datasource = try vc.mapDatasource(vc.messagesQueue)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        vc.searchResultsObserver.accept(self.selectedSearchResultId)
        self.navigationController?.pushViewController(vc, animated: true)
    }
}

extension ChatViewController: TemporaryMessageReceiverProtocol {
    public final func scrollToMessageAtIndex(_ newIndex: Int) {
        let date = self.searchMessagesQueue[newIndex].date
        if let index = self.datasource.firstIndex(where: { $0.archivedId == self.searchMessagesQueue[newIndex].archivedId || $0.messageId == self.searchMessagesQueue[newIndex].archivedId }) {
            self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: .bottom, animated: true)
            self.showLoadingIndicator.accept(false)
            self.messagesCollectionView.reconfigureItems(at: [IndexPath(row: 0, section: index)])
        } else if let index = self.messagesObserver?.firstIndex(where: { $0.archivedId == self.searchMessagesQueue[newIndex].archivedId || $0.messageId == self.searchMessagesQueue[newIndex].archivedId }) {
            let newestIndex = self.datasource.firstIndex(where: { $0.archivedId == self.newestMessageId || $0.messageId == self.newestMessageId }) ?? 0
            let oldestIndex = self.datasource.firstIndex(where: { $0.archivedId == self.newestMessageId || $0.messageId == self.newestMessageId }) ?? self.messagesCount
            if index < newestIndex {
                self.lastBottomIndex = index
                if self.lastBottomIndex < 0 {
                    self.lastBottomIndex = 0
                }
                self.newestMessageId = self.getMessageIdAtPostionOrLast(index: self.lastBottomIndex)
                self.runDatasetUpdateTask(shouldScrollToLastMessage: false, addToStart: true)
            }
            if index > oldestIndex {
                self.messagesCount += ChatViewController.datasourcePageSize * 2
                self.oldestMessageId = self.getMessageIdAtPostionOrLast(index: index)
                self.runDatasetUpdateTask(shouldScrollToLastMessage: false, addToEnd: true)
            }
            self.searchSeekDirection = nil
//                    self.showLoadingIndicator.accept(false)
        } else {
            self.showLoadingIndicator.accept(true)
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                self.scrollToMessageTaskId = session.mam?.getHistoryUntill(stream, jid: self.jid, conversationType: self.conversationType, start: date, archived: self.searchMessagesQueue[newIndex].archivedId)
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    self.scrollToMessageTaskId = user.mam.getHistoryUntill(stream, jid: self.jid, conversationType: self.conversationType, start: date, archived: self.searchMessagesQueue[newIndex].archivedId)
                })
            }
        }
    }
    
    internal final func applySearchResults() {
        self.searchMessagesQueue = self.searchMessagesQueue.sorted(by: { $0.date > $1.date })
        let newIndex = 0
        self.xabberInputView.searchPanel.updateResults(current: newIndex, total: self.searchMessagesQueue.count)
        
        if self.searchMessagesQueue.isEmpty {
            return
        }
        
        self.selectedSearchResultId = self.searchMessagesQueue[newIndex].archivedId
        
        self.scrollToMessageArchivedId = self.searchMessagesQueue[newIndex].archivedId
//                self.xabberInputView.searchPanel.isInLoadingState = true
        self.showLoadingIndicator.accept(true)
        scrollToMessageAtIndex(newIndex)
    }
    func didReceiveEndPage(queryId: String, fin: Bool, first: String, last: String, count: Int) {
        print("FINALLY SEARCHED", fin)
        print(first, last, count)
        if queryId == self.currentSearchQueryId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.searchResultsFinObserver.accept(fin)
                self.applySearchResults()
            }
        }
        if queryId == self.scrollToMessageTaskId {
            self.scrollToMessageTaskId = nil
            if self.searchSeekDirection  == .up {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.oldestMessageId = first
                    self.messagesBag = DisposeBag()
                    self.runDatasetUpdateTask(shouldScrollToLastMessage: true)
                    try? self.subscribeOnDatasetChanges()
//                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
//                        self.newestMessageId = last
//                        self.messagesBag = DisposeBag()
//                        self.runDatasetUpdateTask(shouldScrollToLastMessage: true)
//                        self.searchSeekDirection = nil
//                        try? self.subscribeOnDatasetChanges()
//                    }
                }
            } else if self.searchSeekDirection == .down {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.newestMessageId = last
                    self.messagesBag = DisposeBag()
                    self.runDatasetUpdateTask(shouldScrollToLastMessage: true)
                    try? self.subscribeOnDatasetChanges()
//                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
//                        self.oldestMessageId = first
//                        self.messagesBag = DisposeBag()
//                        self.runDatasetUpdateTask(shouldScrollToLastMessage: true)
//                        self.searchSeekDirection = nil
//                        try? self.subscribeOnDatasetChanges()
//                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.oldestMessageId = first
                    self.newestMessageId = last
                    self.messagesBag = DisposeBag()
                    self.runDatasetUpdateTask(shouldScrollToLastMessage: true)
                    try? self.subscribeOnDatasetChanges()
                }
            }
            
        }
    }
    
    func didReceiveMessage(_ item: MessageStorageItem, queryId: String) {
        if queryId == self.currentSearchQueryId {
            DispatchQueue.main.async {
                self.searchMessagesQueue.append(item)
                self.searchResultsFinObserver.accept(false)
            }
        }
    }
    
    func updateViewportDatasource(first oldestMessageId: String, last newestMessageId: String, count: Int) {
        
    }
}
