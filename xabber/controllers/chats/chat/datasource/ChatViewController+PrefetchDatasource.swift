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
import RxSwift
import RxCocoa
import RxRealm

extension ChatViewController: UICollectionViewDataSourcePrefetching {

    private struct BoundaryPagingAvailability {
        let hasLocalOlderAvailable: Bool
        let hasLocalNewerAvailable: Bool
        let hasRemoteOlderAvailable: Bool
        let hasRemoteNewerAvailable: Bool
    }

    private func triggerPaging(_ pageDirection: ChatHistoryPageDirection) {
        self.setDatasourceLoadingEnabled(false)
        switch pageDirection {
        case .older:
            self.onTouchEndPage(direction: .older)
        case .newer:
            self.onTouchStartPage(direction: .newer)
        }
    }

    private func hasRemoteOlderHistoryAvailable(_ archiveState: ChatArchiveStateSnapshot) -> Bool {
        let shouldProbePersistedArchiveEnd = ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
            persistedArchiveEnded: archiveState.fullArchiveLoaded,
            hasConfirmedArchiveEndThisSession: self.hasConfirmedArchiveEndThisSession,
            hasUsedVerificationProbe: self.hasUsedArchiveEndVerificationProbe
        )
        let effectiveArchiveEnded = ChatArchiveEndVerificationPolicy.effectiveArchiveEnded(
            persistedArchiveEnded: archiveState.fullArchiveLoaded,
            shouldProbePersistedArchiveEnd: shouldProbePersistedArchiveEnd
        )
        return !effectiveArchiveEnded
    }

    private func isOlderBoundaryVisible(_ boundaryContext: ChatHistoryPagingBoundaryContext) -> Bool {
        guard let firstRealSection = boundaryContext.firstRealSection else {
            return false
        }
        return boundaryContext.visibleRealSections.contains { $0 <= firstRealSection }
    }

    private func isNewerBoundaryVisible(_ boundaryContext: ChatHistoryPagingBoundaryContext) -> Bool {
        guard let lastRealSection = boundaryContext.lastRealSection else {
            return false
        }
        return boundaryContext.visibleRealSections.contains { $0 >= lastRealSection }
    }

    private func localBoundaryPagingAvailability(
        boundaryContext: ChatHistoryPagingBoundaryContext
    ) -> (older: Bool, newer: Bool) {
        let shouldCheckOlder = self.isOlderBoundaryVisible(boundaryContext)
        let shouldCheckNewer = self.isNewerBoundaryVisible(boundaryContext)
        guard shouldCheckOlder || shouldCheckNewer else {
            return (older: false, newer: false)
        }

        let normalizedState = self.virtualTimelineState.normalized(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        do {
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            let hasLocalOlder: Bool
            if shouldCheckOlder, let oldest = normalizedState.oldest {
                hasLocalOlder = provider.older(before: oldest, limit: 1).isNotEmpty
            } else {
                hasLocalOlder = false
            }

            let hasLocalNewer: Bool
            if shouldCheckNewer, let newest = normalizedState.newest {
                hasLocalNewer = provider.newer(after: newest, limit: 1).isNotEmpty
            } else {
                hasLocalNewer = false
            }

            return (older: hasLocalOlder, newer: hasLocalNewer)
        } catch {
            ChatArchiveDebugTrace.log("boundaryPagingAvailabilityError", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("error", error.localizedDescription)
            ])
            return (older: false, newer: false)
        }
    }

    private func boundaryPagingAvailability(
        boundaryContext: ChatHistoryPagingBoundaryContext
    ) -> BoundaryPagingAvailability {
        let archiveState = self.loadChatArchiveStateSnapshot()
        let localAvailability = self.localBoundaryPagingAvailability(boundaryContext: boundaryContext)
        return BoundaryPagingAvailability(
            hasLocalOlderAvailable: localAvailability.older,
            hasLocalNewerAvailable: localAvailability.newer,
            hasRemoteOlderAvailable: self.hasRemoteOlderHistoryAvailable(archiveState),
            hasRemoteNewerAvailable: archiveState.hasKnownNewerGap || !archiveState.newerLiveEdgeReached
        )
    }

    internal func interactiveBoundaryPagingDirection(
        isUserScrolling: Bool,
        gestureTranslationY: CGFloat,
        boundaryContext: ChatHistoryPagingBoundaryContext
    ) -> ChatHistoryPageDirection? {
        let availability = self.boundaryPagingAvailability(boundaryContext: boundaryContext)
        let residentCount = self.virtualTimelineState.residentPrimaryKeys.count
        let pageDirection = ChatHistoryPagingPolicy.triggerDirection(
            isUserScrolling: isUserScrolling,
            canLoadDatasource: self.canLoadDatasource,
            gestureTranslationY: gestureTranslationY,
            boundaryContext: boundaryContext,
            currentPageMinIndex: 0,
            currentPageMaxIndex: residentCount,
            totalCount: residentCount,
            hasLocalOlderAvailable: availability.hasLocalOlderAvailable,
            hasLocalNewerAvailable: availability.hasLocalNewerAvailable,
            hasRemoteOlderAvailable: availability.hasRemoteOlderAvailable,
            hasRemoteNewerAvailable: availability.hasRemoteNewerAvailable
        )
        self.logBoundaryPagingDecision(
            trigger: "interactive",
            boundaryContext: boundaryContext,
            availability: availability,
            residentCount: residentCount,
            gestureTranslationY: gestureTranslationY,
            selectedDirection: pageDirection
        )
        return pageDirection
    }

    private func fallbackBoundaryPagingDirection(
        gestureTranslationY: CGFloat,
        boundaryContext: ChatHistoryPagingBoundaryContext
    ) -> ChatHistoryPageDirection? {
        let availability = self.boundaryPagingAvailability(boundaryContext: boundaryContext)
        let residentCount = self.virtualTimelineState.residentPrimaryKeys.count
        let pageDirection = ChatHistoryPagingPolicy.fallbackDirectionForShortContentDrag(
            canLoadDatasource: self.canLoadDatasource,
            gestureTranslationY: gestureTranslationY,
            boundaryContext: boundaryContext,
            currentPageMinIndex: 0,
            currentPageMaxIndex: residentCount,
            totalCount: residentCount,
            hasLocalOlderAvailable: availability.hasLocalOlderAvailable,
            hasLocalNewerAvailable: availability.hasLocalNewerAvailable,
            hasRemoteOlderAvailable: availability.hasRemoteOlderAvailable,
            hasRemoteNewerAvailable: availability.hasRemoteNewerAvailable
        )
        self.logBoundaryPagingDecision(
            trigger: "dragEnd",
            boundaryContext: boundaryContext,
            availability: availability,
            residentCount: residentCount,
            gestureTranslationY: gestureTranslationY,
            selectedDirection: pageDirection
        )
        return pageDirection
    }

    private func logBoundaryPagingDecision(
        trigger: String,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        availability: BoundaryPagingAvailability,
        residentCount: Int,
        gestureTranslationY: CGFloat,
        selectedDirection: ChatHistoryPageDirection?
    ) {
        ChatArchiveDebugTrace.log("boundaryPagingDecision", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("trigger", trigger),
            ("selectedDirection", selectedDirection.map { "\($0)" } ?? "-"),
            ("firstRealSection", boundaryContext.firstRealSection ?? -1),
            ("lastRealSection", boundaryContext.lastRealSection ?? -1),
            ("visibleRealSections", boundaryContext.visibleRealSections.map(String.init).joined(separator: ",")),
            ("localOlder", availability.hasLocalOlderAvailable),
            ("localNewer", availability.hasLocalNewerAvailable),
            ("remoteOlder", availability.hasRemoteOlderAvailable),
            ("remoteNewer", availability.hasRemoteNewerAvailable),
            ("residentCount", residentCount),
            ("isResidentAtLiveTail", self.virtualTimelineState.isResidentAtLiveTail),
            ("canLoadDatasource", self.canLoadDatasource),
            ("gestureTranslationY", Int(gestureTranslationY))
        ])
    }

    private func triggerInteractiveBoundaryPagingIfNeeded(_ scrollView: UIScrollView) {
        let boundaryContext = self.pagingBoundaryContext(
            visibleSections: self.messagesCollectionView.indexPathsForVisibleItems.map(\.section)
        )
        let pageDirection = self.interactiveBoundaryPagingDirection(
            isUserScrolling: scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking,
            gestureTranslationY: scrollView.panGestureRecognizer.translation(in: scrollView).y,
            boundaryContext: boundaryContext
        )
        guard let pageDirection else {
            return
        }

        self.triggerPaging(pageDirection)
    }

    private func triggerBoundaryPagingAfterDragIfNeeded(_ scrollView: UIScrollView) {
        let boundaryContext = self.pagingBoundaryContext(
            visibleSections: self.messagesCollectionView.indexPathsForVisibleItems.map(\.section)
        )
        let pageDirection = self.fallbackBoundaryPagingDirection(
            gestureTranslationY: scrollView.panGestureRecognizer.translation(in: scrollView).y,
            boundaryContext: boundaryContext
        )
        guard let pageDirection else {
            return
        }

        self.triggerPaging(pageDirection)
    }
    
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.triggerBoundaryPagingAfterDragIfNeeded(scrollView)
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        self.triggerBoundaryPagingAfterDragIfNeeded(scrollView)
    }
    
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
//        if self.canLoadDatasource {
//            if (self.messagesCollectionView.contentSize.height - self.messagesCollectionView.contentOffset.y) < self.view.bounds.height {
//                self.canLoadDatasource = false
//                self.onTouchEndPage(direction: .up)
//            } 
//        }
//        if self.canLoadDatasource {
//            if self.currentPage.minIndex > 0 {
//                if let datasourcePrimary = self.datasource.first?.primary,
//                   let observerPrimary = self.messagesObserver.first?.primary,
//                   datasourcePrimary != observerPrimary {
//                    if self.messagesCollectionView.contentOffset.y < 0 {
//                        self.canLoadDatasource = false
//                        self.onTouchStartPage(direction: .down)
//                    }
//                }
//            }
//        }
        
        self.willUpdateFloatingDate()
        if !self.datasource[indexPath.section].isRead {
            var value = self.messagesToReadObserver.value
            value.insert(self.datasource[indexPath.section].primary)
            self.messagesToReadObserver.accept(value)
        }
        self.updateVisibleVoiceMessageQueue()
    }
    
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        self.willUpdateFloatingDate()
        if self.datasource.count > indexPath.section {
            if !self.datasource[indexPath.section].isRead {
                var value = self.messagesToReadObserver.value
                value.insert(self.datasource[indexPath.section].primary)
                self.messagesToReadObserver.accept(value)
            }
        }
        self.updateVisibleVoiceMessageQueue()
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let contentOffsetY = scrollView.contentOffset.y

        if self.currentPage.isUnlocked {
            let contentOffsetY = scrollView.contentOffset.y
            if contentOffsetY > self.previousContentOffsetY {
                self.chatScrollDirection = .down
            } else {
                self.chatScrollDirection = .up
            }
            self.contentOffsetObserver.accept(contentOffsetY)
            self.triggerInteractiveBoundaryPagingIfNeeded(scrollView)
        }
        if !self.preventHidingDate {
            self.pinnedDateView.hide()
        }
        self.previousContentOffsetY = contentOffsetY
        self.setFloatingDateVisible(true)
        
        self.messagesCollectionView.indexPathsForVisibleItems.forEach {
            indexPath in
            if !self.datasource[indexPath.section].isRead {
                var value = self.messagesToReadObserver.value
                value.insert(self.datasource[indexPath.section].primary)
                self.messagesToReadObserver.accept(value)
            }
        }
        self.updateVisibleVoiceMessageQueue()
    }
    
    
}
