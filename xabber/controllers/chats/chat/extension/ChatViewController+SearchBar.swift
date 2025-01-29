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
            self.showLoadingIndicator.accept(false)
            guard let index = self.messagesObserver.firstIndex(where: { $0.archivedId == archivedId }) else {
                return
            }
            let page = index / self.datasourcePageSize
            self.currentPage.setCustomPage(page) {
                var maxIndex = index  + (self.datasourcePageSize / 2)
                var minIndex =  index - (self.datasourcePageSize / 2)
                if minIndex < 0 {
                    minIndex = 0
                    maxIndex = minIndex + self.datasourcePageSize
                }
                if maxIndex > self.messagesObserver.count {
                    maxIndex = self.messagesObserver.count
                }
                let slice = Array(self.messagesObserver.prefix(maxIndex).suffix(maxIndex - minIndex))
                self.currentPage.minIndex = minIndex
                self.currentPage.maxIndex = maxIndex
                callback(slice, index - minIndex)
            }
        }
        func updateDatsource() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                update()
            }
        }
        
        func loadHistoryAfter() {
            let start: Date? = nil
            let end: Date? = date
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                session.mam?.getHistoryByDate(stream, jid: self.jid, conversationType: self.conversationType, start: start, end: end, callback: loadHistoryBefore)
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.mam.getHistoryByDate(stream, jid: self.jid, conversationType: self.conversationType, start: start, end: end, callback: loadHistoryBefore)
                })
            }
        }
        
        func loadHistoryBefore() {
            let start: Date? = date
            let end: Date? = nil
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                session.mam?.getHistoryByDate(stream, jid: self.jid, conversationType: self.conversationType, start: start, end: end, callback: updateDatsource)
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.mam.getHistoryByDate(stream, jid: self.jid, conversationType: self.conversationType, start: start, end: end, callback: updateDatsource)
                })
            }
        }
        
        
        if self.messagesObserver.firstIndex(where: { $0.archivedId == archivedId }) != nil {
            update()
        } else {
            self.showLoadingIndicator.accept(true)
            loadHistoryAfter()
            self.currentPage.locked = true
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
            self.datasource = self.mapDataset(dataset: array)
            self.scrollToSearchedMessage(archivedId: archivedId)
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
            self.datasource = self.mapDataset(dataset: array)
            self.scrollToSearchedMessage(archivedId: archivedId)
        }
    }
    
    internal func onSearchPanelChangeChatViewState() {

    }
    
    internal func scrollToSearchedMessage(archivedId: String) {
        (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.cache.invalidate()
        self.messagesCollectionView.reloadData()
        let scrollIndex = self.datasource.firstIndex(where: { $0.archivedId == archivedId }) ?? 0
        self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: scrollIndex), at: .centeredVertically, animated: false)
        self.messagesCollectionView.layoutIfNeeded()
        self.updateDateLabels(afterIndex: scrollIndex)
    }
}

extension ChatViewController: TemporaryMessageReceiverProtocol {
    
    public final func scrollToMessageAtIndex(archivedId: String, date: Date) {
        
    }
    
    public final func scrollToMessageAtIndex(_ index: Int) {
        
    }
    
    internal final func applySearchResults() {
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
                self.datasource = self.mapDataset(dataset: array)
                self.scrollToSearchedMessage(archivedId: archivedId)
            }
        }
        self.showLoadingIndicator.accept(false)
    }
    
    func didReceiveEndPage(queryId: String, fin: Bool, first: String, last: String, count: Int) {
        if queryId == self.currentSearchQueryId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.applySearchResults()
            }
        }
    }
    
    func didReceiveMessage(_ item: MessageStorageItem, queryId: String) {
        if queryId == self.currentSearchQueryId {
            self.searchMessagesQueue.append(item)
        }
    }
    
    func updateViewportDatasource(first oldestMessageId: String, last newestMessageId: String, count: Int) {
        
    }
}
