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
    
    internal final func scrollToMessage(archivedId: String, date: Date, direction: ChatDirection, callback: @escaping ((Array<MessageStorageItem>, Int) -> Void)) {
        func update() {
            self.setLoadingIndicatorVisible(false)
            self.ensureObserverLookupMaps()
            guard let index = self.observerArchivedIdIndexMap[archivedId] else {
                return
            }
            let window = self.datasetCoordinator.replacementWindow(around: index, totalCount: self.messagesObserver.count)
            self.currentPage.setCustomPage(index / self.datasourcePageSize) {
                self.syncCurrentPage(with: window)
                callback(self.sliceForWindow(window), index - window.minIndex)
                self.currentPage.unlock()
                self.setFloatingDateVisible(true)
            }
        }
        func updateDatsource() {
            DispatchQueue.main.async {
                update()
            }
        }
        
        func loadHistoryAfter() {
            let start: Date? = nil
            let end: Date? = date
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                session.mam?.getHistoryByDate(stream, jid: self.jid, conversationType: self.conversationType, start: start, end: end, reversed: true, callback: loadHistoryBefore)
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.mam.getHistoryByDate(stream, jid: self.jid, conversationType: self.conversationType, start: start, end: end, reversed: true, callback: loadHistoryBefore)
                })
            }
        }
        
        func loadHistoryBefore() {
            let start: Date? = date
            let end: Date? = nil
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                session.mam?.getHistoryByDate(stream, jid: self.jid, conversationType: self.conversationType, start: start, end: end, reversed: false, callback: updateDatsource)
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.mam.getHistoryByDate(stream, jid: self.jid, conversationType: self.conversationType, start: start, end: end, reversed: false, callback: updateDatsource)
                })
            }
        }
        
        self.setDatasourceLoadingEnabled(false)
        
        self.setFloatingDateVisible(false)
        self.pinnedDateView.hide(withoutAnimation: true)
        self.ensureObserverLookupMaps()
        if self.observerArchivedIdIndexMap[archivedId] != nil {
            update()
            self.setDatasourceLoadingEnabled(true)
        } else {
            self.setLoadingIndicatorVisible(true)
            self.setDatasourceLoadingEnabled(false)
            loadHistoryAfter()
        }
    }
    
    public final func showSearchResultFromExternalSource(message archivedId: String, date: Date) {
        self.chatScrollDirection = .up
        self.scrollToMessage(archivedId: archivedId, date: date, direction: .up) { array, index in
            self.mapAndApplyWindow(self.visibleWindow(), mode: .fullReload(), completion: {
                self.scrollToSearchedMessage(archivedId: archivedId)
            })
        }
    }
    
    internal func onSearchPanelSeekUp() {
        if self.currentPage.locked {
            return
        }
        guard let currentIndex = self.searchMessagesQueue.firstIndex(where: { $0.archivedId == self.selectedSearchResultId }) else {
            return
        }
        if self.searchMessagesQueue.count == 1 {
            return
        }
        FeedbackManager.shared.generate(feedback: .success)
        var newIndex = currentIndex + 1
        if newIndex >= self.searchMessagesQueue.count {
            newIndex = 0
        }
        self.selectedSearchResultId = self.searchMessagesQueue[newIndex].archivedId
        self.xabberInputView.searchPanel.updateResults(current: newIndex, total: self.searchMessagesQueue.count)
        let archivedId = searchMessagesQueue[newIndex].archivedId
        let date = searchMessagesQueue[newIndex].date
        self.chatScrollDirection = .up
        self.scrollToMessage(archivedId: archivedId, date: date, direction: .up) { array, index in
            self.mapAndApplyWindow(self.visibleWindow(), mode: .fullReload(), completion: {
                self.scrollToSearchedMessage(archivedId: archivedId)
            })
        }
    }
    
    internal func onSearchPanelSeekDown() {
        if self.currentPage.locked {
            return
        }
        guard let currentIndex = self.searchMessagesQueue.firstIndex(where: { $0.archivedId == self.selectedSearchResultId }) else {
            return
        }
        if self.searchMessagesQueue.count == 1 {
            return
        }
        FeedbackManager.shared.generate(feedback: .success)
        var newIndex = currentIndex - 1
        self.chatScrollDirection = .down
        if newIndex < 0 {
            newIndex = self.searchMessagesQueue.count - 1
            self.chatScrollDirection = .up
        }
        self.selectedSearchResultId = self.searchMessagesQueue[newIndex].archivedId
        self.xabberInputView.searchPanel.updateResults(current: newIndex, total: self.searchMessagesQueue.count)
        let archivedId = searchMessagesQueue[newIndex].archivedId
        let date = searchMessagesQueue[newIndex].date
        self.scrollToMessage(archivedId: archivedId, date: date, direction: .down) { array, index in
            self.mapAndApplyWindow(self.visibleWindow(), mode: .fullReload(), completion: {
                self.scrollToSearchedMessage(archivedId: archivedId)
            })
        }
    }
    
    internal func onSearchPanelChangeChatViewState() {

    }
    
    internal func scrollToSearchedMessage(primary: String) {
        self.preventHidingDate = true
        (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.cache.invalidate()
        self.applyChatDatasource(self.datasource, mode: .fullReload())
        self.messagesCollectionView.layoutIfNeeded()
        let scrollIndex = self.datasourceSnapshot.primaryIndex[primary] ?? 0
        let cell = self.messagesCollectionView.cellForItem(at: IndexPath(row: 0, section: scrollIndex)) as? MessageContentCell
        cell?.setSelected(state: true)
        self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: scrollIndex), at: .centeredVertically, animated: false)
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        self.preventHidingDate = false
        self.currentPage.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.setFloatingDateVisible(true)
            self.setFloatingDateHidden(true)
            self.setDatasourceLoadingEnabled(true)
            self.currentPage.unlock()
        }
    }
    
    internal func scrollToSearchedMessage(archivedId: String) {
        self.preventHidingDate = true
        (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.cache.invalidate()
        self.applyChatDatasource(self.datasource, mode: .fullReload())
        self.messagesCollectionView.layoutIfNeeded()
        let scrollIndex = self.datasourceSnapshot.archivedIdIndex[archivedId] ?? 0
        
        self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: scrollIndex), at: .centeredVertically, animated: false)
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        self.preventHidingDate = false
        self.currentPage.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.setFloatingDateVisible(true)
            self.setFloatingDateHidden(true)
            self.setDatasourceLoadingEnabled(true)
            self.currentPage.unlock()
            let cell = self.messagesCollectionView.cellForItem(at: IndexPath(row: 0, section: scrollIndex)) as? MessageContentCell
            cell?.setSelected(state: true)
        }
    }
}

extension ChatViewController: TemporaryMessageReceiverProtocol {
    
    public final func scrollToMessageAtIndex(archivedId: String, date: Date) {
        
    }
    
    public final func scrollToMessageAtIndex(_ index: Int) {
        
    }
    
    internal final func applySearchResults(emptyList: Bool = false) {
        self.preventHidingDate = true
        self.searchMessagesQueue = self.searchMessagesQueue.sorted(by: { $0.date > $1.date })
        let newIndex = 0
        self.xabberInputView.searchPanel.updateResults(current: newIndex, total: self.searchMessagesQueue.count)
        if self.searchMessagesQueue.isNotEmpty {
            self.selectedSearchResultId = self.searchMessagesQueue[newIndex].archivedId
            self.xabberInputView.searchPanel.updateResults(current: newIndex, total: self.searchMessagesQueue.count)
            let archivedId = searchMessagesQueue[newIndex].archivedId
            let date = searchMessagesQueue[newIndex].date
            self.chatScrollDirection = .up
            self.scrollToMessage(archivedId: archivedId, date: date, direction: .up) { array, index in
                self.mapAndApplyWindow(self.visibleWindow(), mode: .fullReload(), completion: {
                    self.scrollToSearchedMessage(archivedId: archivedId)
                    self.preventHidingDate = false
                })
            }
        }
        if emptyList {
            self.setLoadingIndicatorVisible(false)
        }
        self.setFloatingDateVisible(true)
    }
    
    func didReceiveEndPage(queryId: String, state: MessageArchivePageEndState, first: String, last: String, count: Int) {
        DispatchQueue.main.async {
            if self.handleInitialBootstrapEndPageIfNeeded(queryId: queryId, count: count) {
                return
            }
            if self.completeInteractiveHistoryPageLoadIfNeeded(queryId: queryId, state: state, first: first, last: last, count: count) {
                return
            }
            if queryId == self.currentSearchQueryId {
                self.applySearchResults(emptyList: first == last)
            }
        }
    }
    
    func didReceiveMessage(_ item: MessageStorageItem, queryId: String) {
        DispatchQueue.main.async {
            if queryId == self.currentSearchQueryId {
                self.searchMessagesQueue.append(item)
            }
        }
    }
    
    func updateViewportDatasource(first oldestMessageId: String, last newestMessageId: String, count: Int) {
        
    }
}
