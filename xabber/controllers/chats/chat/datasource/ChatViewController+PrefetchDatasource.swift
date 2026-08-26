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

    internal func interactiveBoundaryPagingDirection(
        isUserScrolling: Bool,
        gestureTranslationY: CGFloat,
        boundaryContext: ChatHistoryPagingBoundaryContext
    ) -> ChatHistoryPageDirection? {
        guard isUserScrolling,
              !boundaryContext.visibleRealSections.isEmpty,
              committedTimelineScope(
                allowingLocalPresentationID: timelineBoundaryRequest?.id,
                allowsPendingLiveEdgeAdmission:
                    timelineBoundaryRequest != nil
              ) != nil else {
            return nil
        }

        let minimumVisibleSection = boundaryContext.visibleRealSections.min()
        let maximumVisibleSection = boundaryContext.visibleRealSections.max()
        let isOlderBoundaryVisible = minimumVisibleSection.flatMap { visibleSection in
            boundaryContext.firstRealSection.map { visibleSection <= $0 }
        } ?? false
        let isNewerBoundaryVisible = maximumVisibleSection.flatMap { visibleSection in
            boundaryContext.lastRealSection.map { visibleSection >= $0 }
        } ?? false
        // Server edge flags describe the complete verified scope, not the
        // currently resident UIKit window. A direction may still be locally
        // pageable after the opposite edge was evicted from the bounded
        // resident window, even when the scope itself reaches the archive
        // edge. The session is the only owner of that distinction.
        let canRequestOlder = isOlderBoundaryVisible &&
            canRequestTimelineBoundary(direction: .older)
        let canRequestNewer = isNewerBoundaryVisible &&
            canRequestTimelineBoundary(direction: .newer)

        switch (canRequestOlder, canRequestNewer) {
        case (true, false):
            return .older
        case (false, true):
            return .newer
        case (true, true):
            if gestureTranslationY > 0 {
                return .older
            }
            if gestureTranslationY < 0 {
                return .newer
            }
            return nil
        case (false, false):
            return nil
        }
    }

    private func requestTimelineBoundaryIfNeeded(_ request: ChatScrollWorkRequest) {
        let boundaryContext = request.visibleMetadata.boundaryContext
        let pageDirection = self.interactiveBoundaryPagingDirection(
            isUserScrolling: request.isUserScrolling,
            gestureTranslationY: request.gestureTranslationY,
            boundaryContext: boundaryContext
        )
        guard let pageDirection else {
            return
        }

        self.requestTimelineBoundary(direction: pageDirection, visible: true)
    }

    private func requestTimelineBoundaryAfterDragIfNeeded(_ scrollView: UIScrollView) {
        let boundaryContext = self.pagingBoundaryContext(
            visibleSections: self.messagesCollectionView.indexPathsForVisibleItems.map(\.section)
        )
        let pageDirection = self.interactiveBoundaryPagingDirection(
            isUserScrolling: true,
            gestureTranslationY: scrollView.panGestureRecognizer.translation(in: scrollView).y,
            boundaryContext: boundaryContext
        )
        guard let pageDirection else {
            return
        }

        self.requestTimelineBoundary(direction: pageDirection, visible: true)
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
        self.synchronizeReadVisibleGeometryEpoch()
        let meaningfullyVisibleReadPrimaries =
            self.meaningfullyVisibleRealMessagePrimariesForRead(
                indexPaths: visibleIndexPaths
            )
        return ChatScrollWorkRequest(
            contentOffsetY: scrollView.contentOffset.y,
            gestureTranslationY: scrollView.panGestureRecognizer.translation(in: scrollView).y,
            isUserScrolling: scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking,
            visibleIndexPaths: visibleIndexPaths,
            visibleMetadata: self.scrollResidentMetadata.capture(indexPaths: visibleIndexPaths),
            meaningfullyVisibleReadPrimaries: meaningfullyVisibleReadPrimaries,
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
           request.isUserScrolling {
            self.requestTimelineBoundaryIfNeeded(request)
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
            self.advanceReadBoundaryIfStillMeaningfullyVisible(to: readTarget)
        }

        if ChatVisibleMentionReadScrollTriggerPolicy.shouldFlush(
            pendingMessagePrimaries:
                self.readVisiblePresentationCoordinator.pendingMessagePrimaries,
            meaningfullyVisibleMessagePrimaries:
                request.meaningfullyVisibleReadPrimaries,
            effectiveWork: effectiveWork
        ), self.canAdvanceReadStateFromVisiblePresentation() {
#if DEBUG || CHAT_PERFORMANCE_LAB
            self.visibleMentionReadScrollTriggerForTests?()
#endif
            // The request only provides a bounded trigger. The flush
            // synchronously re-samples exact row identity, geometry and
            // structural presentation before creating a mutation permit.
            self.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        }

        if effectiveWork.contains(.updateVoiceQueue),
           let voiceDescriptors = frameDecision.voiceDescriptors {
            VoiceMessagePlaybackCoordinator.shared.setVisibleVoiceMessages(voiceDescriptors)
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        collectionPrefetchCoordinator.prefetchItems(at: indexPaths)
        prefetchTimelineBoundaryIfNeeded(indexPaths: indexPaths)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        collectionPrefetchCoordinator.cancelPrefetchingForItems(at: indexPaths)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.retainedMessageAnchor = nil
        self.scrollFramePlanner.invalidateFloatingDate()
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.flushPendingScrollWork()
        self.requestTimelineBoundaryAfterDragIfNeeded(scrollView)
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        self.flushPendingScrollWork()
        guard !decelerate else { return }
        self.requestTimelineBoundaryAfterDragIfNeeded(scrollView)
    }
    
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ChatOffscreenWorkManaging)?.resumeOnscreenWork()

        self.enqueueScrollWork(
            visibleIndexPaths: self.currentVisibleIndexPaths(including: indexPath),
            work: [.updateFloatingDate, .advanceReadBoundary, .updateVoiceQueue]
        )
    }
    
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ChatOffscreenWorkManaging)?.cancelOffscreenWork()
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
