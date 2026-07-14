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

    private func boundaryPagingAvailability() -> ChatScrollBoundaryAvailability {
        self.scrollBoundaryAvailabilityCache.availability(for: self.chatTimelineConversationKey) ?? .empty
    }

    private func shortContentRemotePagingSuppressionContext(
        availability: ChatScrollBoundaryAvailability
    ) -> BoundaryPagingSuppressionContext {
        let contentHeight = self.messagesCollectionView.contentSize.height
        let visibleHeight = max(
            0,
            self.messagesCollectionView.bounds.height -
                self.messagesCollectionView.adjustedContentInset.top -
                self.messagesCollectionView.adjustedContentInset.bottom
        )
        let hasRealMessages = self.scrollResidentMetadata.firstRealSection != nil
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
        return pageDirection
    }

    private func triggerInteractiveBoundaryPagingIfNeeded(_ request: ChatScrollWorkRequest) {
        let boundaryContext = request.visibleMetadata.boundaryContext
        let pageDirection = self.interactiveBoundaryPagingDirection(
            isUserScrolling: request.isUserScrolling,
            gestureTranslationY: request.gestureTranslationY,
            boundaryContext: boundaryContext
        )
        guard let pageDirection else {
            return
        }

        self.handleBoundaryPagingCandidate(
            direction: pageDirection,
            boundaryContext: boundaryContext,
            motionState: self.currentScrollMotionState(),
            trigger: "interactive"
        )
    }

    private func triggerBoundaryPagingAfterDragIfNeeded(_ scrollView: UIScrollView) {
        if self.applyPendingBoundaryPagingAfterScrollRest(trigger: "dragEnd") {
            return
        }

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

        self.handleBoundaryPagingCandidate(
            direction: pageDirection,
            boundaryContext: boundaryContext,
            motionState: self.currentScrollMotionState(),
            trigger: "dragEnd"
        )
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
            visibleMetadata: self.scrollResidentMetadata.capture(indexPaths: visibleIndexPaths),
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
        let effectiveWork = request.effectiveWork(
            isInteractionGateActive: ChatUIResponsivenessGate.shared.isActive,
            currentVisibleMetadataGeneration: self.scrollResidentMetadata.generation
        )
        let frameDecision = self.scrollFramePlanner.plan(
            request: request,
            currentReadPosition: self.currentViewportReadBoundaryPosition(),
            effectiveWork: effectiveWork
        )

        if effectiveWork.contains(.updateScrollPosition) {
            if self.timelineInteractionState.isUnlocked {
                if request.contentOffsetY > self.previousContentOffsetY {
                    self.chatScrollDirection = .down
                } else {
                    self.chatScrollDirection = .up
                }
                self.contentOffsetObserver.accept(request.contentOffsetY)
            }
            self.previousContentOffsetY = request.contentOffsetY
        }

        if effectiveWork.contains(.evaluateBoundaryPaging),
           request.isUserScrolling,
           self.timelineInteractionState.isUnlocked {
            self.triggerInteractiveBoundaryPagingIfNeeded(request)
        }

        if effectiveWork.contains(.updateFloatingDate) {
            if let floatingDate = frameDecision.floatingDate {
                if !self.preventHidingDate {
                    self.pinnedDateView.hide()
                }
                self.setFloatingDateVisible(true)
                self.updateFloatingDate(floatingDate)
            }
        }

        if effectiveWork.contains(.advanceReadBoundary),
           let readTarget = frameDecision.readTarget {
            self.advanceReadBoundary(to: readTarget)
        }

        if effectiveWork.contains(.updateVoiceQueue),
           let voiceDescriptors = frameDecision.voiceDescriptors {
            VoiceMessagePlaybackCoordinator.shared.setVisibleVoiceMessages(voiceDescriptors)
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        collectionPrefetchCoordinator.prefetchItems(at: indexPaths)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        collectionPrefetchCoordinator.cancelPrefetchingForItems(at: indexPaths)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.scrollFramePlanner.invalidateFloatingDate()
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.flushPendingScrollWork()
        self.flushPendingArchiveObserverRefreshIfPossible(reason: "scrollDidEndDecelerating")
        self.triggerBoundaryPagingAfterDragIfNeeded(scrollView)
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        self.flushPendingScrollWork()
        guard !decelerate else { return }
        self.flushPendingArchiveObserverRefreshIfPossible(reason: "scrollDidEndDragging")
        self.triggerBoundaryPagingAfterDragIfNeeded(scrollView)
    }
    
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
//        if self.canLoadDatasource {
//            if (self.messagesCollectionView.contentSize.height - self.messagesCollectionView.contentOffset.y) < self.view.bounds.height {
//                self.canLoadDatasource = false
//                self.onTouchEndPage(direction: .up)
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
