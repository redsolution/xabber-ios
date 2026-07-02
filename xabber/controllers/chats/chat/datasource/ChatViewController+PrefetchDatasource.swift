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

    private struct BoundaryPagingSuppressionContext {
        let suppressRemoteBoundaryPaging: Bool
        let contentHeight: CGFloat
        let visibleHeight: CGFloat
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

    private func boundaryPagingAvailability() -> ChatScrollBoundaryAvailability {
        self.scrollBoundaryAvailabilityCache.availability(for: self.chatTimelineConversationKey) ?? .empty
    }

    private func shortContentRemotePagingSuppressionContext(
        availability: ChatScrollBoundaryAvailability
    ) -> BoundaryPagingSuppressionContext {
        let contentHeight = self.messagesCollectionView.collectionViewLayout.collectionViewContentSize.height
        let visibleHeight = max(
            0,
            self.messagesCollectionView.bounds.height -
                self.messagesCollectionView.adjustedContentInset.top -
                self.messagesCollectionView.adjustedContentInset.bottom
        )
        let hasRealMessages = self.datasource.contains { !$0.isFakeMessage }
        let shouldSuppress = ChatShortContentRemotePagingSuppressionPolicy.shouldSuppressRemoteBoundaryPaging(
            hasRealMessages: hasRealMessages,
            hasLocalOlderAvailable: availability.hasLocalOlderPage,
            hasLocalNewerAvailable: availability.hasLocalNewerPage,
            contentHeight: contentHeight,
            visibleHeight: visibleHeight
        )
        return BoundaryPagingSuppressionContext(
            suppressRemoteBoundaryPaging: shouldSuppress,
            contentHeight: contentHeight,
            visibleHeight: visibleHeight
        )
    }

    internal func interactiveBoundaryPagingDirection(
        isUserScrolling: Bool,
        gestureTranslationY: CGFloat,
        boundaryContext: ChatHistoryPagingBoundaryContext
    ) -> ChatHistoryPageDirection? {
        let availability = self.boundaryPagingAvailability()
        let suppressionContext = self.shortContentRemotePagingSuppressionContext(availability: availability)
        let residentCount = self.virtualTimelineState.residentPrimaryKeys.count
        let pageDirection = ChatHistoryPagingPolicy.triggerDirection(
            isUserScrolling: isUserScrolling,
            canLoadDatasource: self.canLoadDatasource,
            gestureTranslationY: gestureTranslationY,
            boundaryContext: boundaryContext,
            currentPageMinIndex: 0,
            currentPageMaxIndex: residentCount,
            totalCount: residentCount,
            hasLocalOlderAvailable: availability.hasLocalOlderPage,
            hasLocalNewerAvailable: availability.hasLocalNewerPage,
            hasRemoteOlderAvailable: availability.hasRemoteOlderPage,
            hasRemoteNewerAvailable: availability.hasRemoteNewerPage,
            suppressRemoteBoundaryPaging: suppressionContext.suppressRemoteBoundaryPaging
        )
        self.logBoundaryPagingDecision(
            trigger: "interactive",
            boundaryContext: boundaryContext,
            availability: availability,
            suppressionContext: suppressionContext,
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
        let availability = self.boundaryPagingAvailability()
        let suppressionContext = self.shortContentRemotePagingSuppressionContext(availability: availability)
        let residentCount = self.virtualTimelineState.residentPrimaryKeys.count
        let pageDirection = ChatHistoryPagingPolicy.fallbackDirectionForShortContentDrag(
            canLoadDatasource: self.canLoadDatasource,
            gestureTranslationY: gestureTranslationY,
            boundaryContext: boundaryContext,
            currentPageMinIndex: 0,
            currentPageMaxIndex: residentCount,
            totalCount: residentCount,
            hasLocalOlderAvailable: availability.hasLocalOlderPage,
            hasLocalNewerAvailable: availability.hasLocalNewerPage,
            hasRemoteOlderAvailable: availability.hasRemoteOlderPage,
            hasRemoteNewerAvailable: availability.hasRemoteNewerPage,
            suppressRemoteBoundaryPaging: suppressionContext.suppressRemoteBoundaryPaging
        )
        self.logBoundaryPagingDecision(
            trigger: "dragEnd",
            boundaryContext: boundaryContext,
            availability: availability,
            suppressionContext: suppressionContext,
            residentCount: residentCount,
            gestureTranslationY: gestureTranslationY,
            selectedDirection: pageDirection
        )
        return pageDirection
    }

    private func logBoundaryPagingDecision(
        trigger: String,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        availability: ChatScrollBoundaryAvailability,
        suppressionContext: BoundaryPagingSuppressionContext,
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
            ("localOlder", availability.hasLocalOlderPage),
            ("localNewer", availability.hasLocalNewerPage),
            ("gapAbove", availability.hasKnownArchiveGapAbove),
            ("gapBelow", availability.hasKnownArchiveGapBelow),
            ("remoteOlder", availability.hasRemoteOlderPage),
            ("remoteNewer", availability.hasRemoteNewerPage),
            ("remoteInFlight", availability.isRemotePageInFlight),
            ("suppressRemoteBoundaryPaging", suppressionContext.suppressRemoteBoundaryPaging),
            ("contentHeight", Int(suppressionContext.contentHeight)),
            ("visibleHeight", Int(suppressionContext.visibleHeight)),
            ("residentCount", residentCount),
            ("isResidentAtLiveTail", self.virtualTimelineState.isResidentAtLiveTail),
            ("canLoadDatasource", self.canLoadDatasource),
            ("gestureTranslationY", Int(gestureTranslationY))
        ])
    }

    private func triggerInteractiveBoundaryPagingIfNeeded(_ request: ChatScrollWorkRequest) {
        let boundaryContext = self.pagingBoundaryContext(
            visibleSections: request.visibleIndexPaths.map(\.section)
        )
        let pageDirection = self.interactiveBoundaryPagingDirection(
            isUserScrolling: request.isUserScrolling,
            gestureTranslationY: request.gestureTranslationY,
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

    private func currentVisibleIndexPaths(including indexPath: IndexPath? = nil) -> [IndexPath] {
        var indexPaths = self.messagesCollectionView.indexPathsForVisibleItems
        if let indexPath,
           !indexPaths.contains(indexPath) {
            indexPaths.append(indexPath)
        }
        return indexPaths
    }

    private func scrollWorkRequest(
        for scrollView: UIScrollView,
        visibleIndexPaths: [IndexPath],
        work: ChatScrollWorkOptions
    ) -> ChatScrollWorkRequest {
        ChatScrollWorkRequest(
            contentOffsetY: scrollView.contentOffset.y,
            gestureTranslationY: scrollView.panGestureRecognizer.translation(in: scrollView).y,
            isUserScrolling: scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking,
            visibleIndexPaths: visibleIndexPaths,
            work: work
        )
    }

    private func enqueueScrollWork(
        visibleIndexPaths: [IndexPath],
        work: ChatScrollWorkOptions
    ) {
        self.scrollWorkScheduler.enqueue(
            scrollWorkRequest(
                for: self.messagesCollectionView,
                visibleIndexPaths: visibleIndexPaths,
                work: work
            )
        )
    }

    internal func flushPendingScrollWork() {
        self.scrollWorkScheduler.flush()
    }

    internal func performCoalescedScrollWork(_ request: ChatScrollWorkRequest) {
        var scrollSignpost = ChatPerformanceSignposts.begin(.scrollProcessing)
        defer {
            scrollSignpost.end()
        }

        if request.work.contains(.updateScrollPosition) {
            if self.currentPage.isUnlocked {
                if request.contentOffsetY > self.previousContentOffsetY {
                    self.chatScrollDirection = .down
                } else {
                    self.chatScrollDirection = .up
                }
                self.contentOffsetObserver.accept(request.contentOffsetY)
            }
            self.previousContentOffsetY = request.contentOffsetY
        }

        if request.work.contains(.evaluateBoundaryPaging),
           self.currentPage.isUnlocked {
            self.triggerInteractiveBoundaryPagingIfNeeded(request)
        }

        if request.work.contains(.updateFloatingDate) {
            if !self.preventHidingDate {
                self.pinnedDateView.hide()
            }
            self.setFloatingDateVisible(true)
            self.willUpdateFloatingDate()
        }

        if request.work.contains(.advanceReadBoundary) {
            self.advanceReadBoundaryFromVisibleMessages(indexPaths: request.visibleIndexPaths)
        }

        if request.work.contains(.updateVoiceQueue) {
            self.updateVisibleVoiceMessageQueue()
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        collectionPrefetchCoordinator.prefetchItems(at: indexPaths)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        collectionPrefetchCoordinator.cancelPrefetchingForItems(at: indexPaths)
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.flushPendingScrollWork()
        self.triggerBoundaryPagingAfterDragIfNeeded(scrollView)
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        self.flushPendingScrollWork()
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
        
        self.enqueueScrollWork(
            visibleIndexPaths: self.currentVisibleIndexPaths(including: indexPath),
            work: [.updateFloatingDate, .advanceReadBoundary, .updateVoiceQueue]
        )
    }
    
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        self.enqueueScrollWork(
            visibleIndexPaths: self.currentVisibleIndexPaths(),
            work: [.updateFloatingDate, .advanceReadBoundary, .updateVoiceQueue]
        )
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.enqueueScrollWork(
            visibleIndexPaths: self.currentVisibleIndexPaths(),
            work: [
                .updateScrollPosition,
                .updateFloatingDate,
                .advanceReadBoundary,
                .updateVoiceQueue,
                .evaluateBoundaryPaging
            ]
        )
    }
    
    
}
