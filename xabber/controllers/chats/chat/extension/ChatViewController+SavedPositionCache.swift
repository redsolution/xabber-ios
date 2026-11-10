import Foundation
import UIKit
import RealmSwift

/// Describes a rendering only. It is never installed as timeline/read proof.
struct ChatSavedPositionCachePresentationContext {
    let request: ChatOpenMessageRequest
    let intentID: UUID
    let locator: ArchiveWindowLocator
    let initialApplyGeneration: UInt64
}

private final class ChatSavedPositionCacheApplyReceipt {
    var didCommit = false
}

private func recordSavedCacheStage(
    _ stage: Int,
    rejectionMask: @autoclosure () -> Int = 0,
    conversation: ArchiveConversationKey,
    context: ChatOpenPerformanceTraceContext?
) {
    #if DEBUG
    guard DeviceQADiagnostics.shared.isEnabled else { return }
    DeviceQADiagnostics.shared.recordSavedCache(stage: stage,
        rejectionMask: rejectionMask(), conversation: conversation,
        contextCode: context?.traceID ?? 0, purposeCode: Int(context?.purposeCode ?? 0))
    #endif
}

extension ChatViewController {
    @discardableResult
    internal func loadSavedPositionCachePresentationIfEligible(
        request: ChatOpenMessageRequest,
        expectedIntentID: UUID,
        expectedApplyGeneration: UInt64
    ) -> Bool {
        enqueueSavedPositionCachePresentation(request: request,
            expectedIntentID: expectedIntentID, expectedApplyGeneration: expectedApplyGeneration) {
                guard let realm = try? WRealm.safe() else { return nil }
                return ChatSavedPositionPresentationCache.read(request: request, realm: realm)
            }
    }

    @discardableResult
    internal func presentSavedPositionCacheWindow(
        _ window: ChatSavedPositionPresentationWindow,
        expectedIntentID: UUID,
        expectedApplyGeneration: UInt64
    ) -> Bool {
        enqueueSavedPositionCachePresentation(request: window.request,
            expectedIntentID: expectedIntentID, expectedApplyGeneration: expectedApplyGeneration) { window }
    }

    private func ownsSavedPositionCachePresentation(
        request: ChatOpenMessageRequest,
        expectedIntentID: UUID,
        expectedApplyGeneration: UInt64,
        allowsPendingPreparationContext: Bool = false
    ) -> Bool {
        let ownsContext = initialTargetFirstFrameContext?.request == request ||
            (allowsPendingPreparationContext && initialTargetFirstFrameContext == nil &&
                isPreparingStackedNavigationPresentation)
        guard request.source == .savedVisiblePosition,
              case .anchor = request.targetResolution,
              request.owner == owner, request.chatJid == jid,
              request.conversationType == conversationType,
              pendingOpenMessageRequest == request,
              ownsContext,
              !isStackedNavigationPresentationPreparationCancelled,
              archiveWindowStateTask != nil,
              archiveWindowApplyGeneration == expectedApplyGeneration,
              archiveWindowIntent?.id == expectedIntentID,
              archiveWindowIntent?.conversation == archiveEngineConversationKey,
              case .skeleton(_, let target)? = archiveWindowState,
              target == archiveWindowIntent?.locator,
              archiveWindowCommittedCoverageGeneration == nil,
              timelineSession?.verifiedScope == nil,
              showSkeletonObserver.value else { return false }
        return true
    }

    /// Diagnostic mask only; the original ownership guard remains authoritative.
    private func savedCacheOwnershipRejectionMask(request: ChatOpenMessageRequest,
        expectedIntentID: UUID, expectedApplyGeneration: UInt64,
        allowsPendingPreparationContext: Bool = false) -> Int {
        var mask = 0
        if request.source != .savedVisiblePosition { mask |= 1 }
        if case .anchor = request.targetResolution {} else { mask |= 2 }
        if request.owner != owner || request.chatJid != jid || request.conversationType != conversationType { mask |= 4 }
        if pendingOpenMessageRequest != request { mask |= 8 }
        if initialTargetFirstFrameContext?.request != request &&
            !(allowsPendingPreparationContext && initialTargetFirstFrameContext == nil && isPreparingStackedNavigationPresentation) { mask |= 16 }
        if isStackedNavigationPresentationPreparationCancelled { mask |= 32 }
        if archiveWindowStateTask == nil { mask |= 64 }
        if archiveWindowApplyGeneration != expectedApplyGeneration { mask |= 128 }
        if archiveWindowIntent?.id != expectedIntentID { mask |= 256 }
        if archiveWindowIntent?.conversation != archiveEngineConversationKey { mask |= 512 }
        if case .skeleton(_, let target)? = archiveWindowState {
            if target != archiveWindowIntent?.locator { mask |= 2048 }
        } else { mask |= 1024 }
        if archiveWindowCommittedCoverageGeneration != nil { mask |= 4096 }
        if timelineSession?.verifiedScope != nil { mask |= 8192 }
        if !showSkeletonObserver.value { mask |= 16384 }
        return mask
    }

    private func savedPositionCacheWindowIsStillCurrent(_ window: ChatSavedPositionPresentationWindow) -> Bool {
        guard let realm = try? WRealm.safe(), !realm.isInWriteTransaction else { return false }
        realm.refresh()
        // Revalidate the bounded selection at the commit boundary: unread/edge
        // changes or a deletion while background mapping ran revoke rendering.
        guard let current = ChatSavedPositionPresentationCache.read(request: window.request, realm: realm),
              current.provenance == window.provenance,
              current.coverageGeneration == window.coverageGeneration,
              current.segment == window.segment,
              current.anchorPrimary == window.anchorPrimary,
              current.rows.map({ Data($0.primary.utf8) }) == window.rows.map({ Data($0.primary.utf8) }),
              current.rows.map({ Data($0.mamArchiveId.utf8) }) == window.rows.map({ Data($0.mamArchiveId.utf8) }) else { return false }
        return true
    }

    @discardableResult
    private func enqueueSavedPositionCachePresentation(
        request: ChatOpenMessageRequest,
        expectedIntentID: UUID,
        expectedApplyGeneration: UInt64,
        readWindow: @escaping () -> ChatSavedPositionPresentationWindow?
    ) -> Bool {
        assert(Thread.isMainThread)
        let diagnosticConversation = archiveEngineConversationKey
        let diagnosticContext = chatOpenPerformanceTraceContext
        recordSavedCacheStage(1, conversation: diagnosticConversation, context: diagnosticContext)
        guard ownsSavedPositionCachePresentation(request: request,
            expectedIntentID: expectedIntentID, expectedApplyGeneration: expectedApplyGeneration,
            allowsPendingPreparationContext: true) else {
            recordSavedCacheStage(2, rejectionMask: savedCacheOwnershipRejectionMask(request: request,
                expectedIntentID: expectedIntentID, expectedApplyGeneration: expectedApplyGeneration,
                allowsPendingPreparationContext: true), conversation: diagnosticConversation, context: diagnosticContext)
            return false
        }
        recordSavedCacheStage(2, conversation: diagnosticConversation, context: diagnosticContext)
        if initialTargetFirstFrameContext == nil {
            recordSavedCacheStage(3, conversation: diagnosticConversation, context: diagnosticContext)
            // Finish the synchronous preparation turn first: it installs the
            // matching context and final target bounds before layout mapping.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.ownsSavedPositionCachePresentation(request: request,
                        expectedIntentID: expectedIntentID,
                        expectedApplyGeneration: expectedApplyGeneration) else {
                    recordSavedCacheStage(18, rejectionMask: 1,
                        conversation: diagnosticConversation, context: diagnosticContext)
                    return
                }
                recordSavedCacheStage(18, conversation: diagnosticConversation, context: diagnosticContext)
                _ = self.enqueueSavedPositionCachePresentation(request: request,
                    expectedIntentID: expectedIntentID,
                    expectedApplyGeneration: expectedApplyGeneration,
                    readWindow: readWindow)
            }
            return true
        }
        let mappingJob = beginDatasetMappingJob()
        let mappingContext = captureDatasourceMappingContext()
        let expectedSession = timelineSession
        recordSavedCacheStage(4, conversation: diagnosticConversation, context: diagnosticContext)
        datasetMappingQueue.async { [weak self, weak expectedSession] in
            guard let self, !mappingJob.token.isCancelled else {
                recordSavedCacheStage(9, rejectionMask: 1,
                    conversation: diagnosticConversation, context: diagnosticContext)
                return
            }
            recordSavedCacheStage(5, conversation: diagnosticConversation, context: diagnosticContext)
            guard let window = readWindow(), window.request == request else {
                recordSavedCacheStage(7, rejectionMask: 1,
                    conversation: diagnosticConversation, context: diagnosticContext)
                return
            }
            recordSavedCacheStage(6, conversation: diagnosticConversation, context: diagnosticContext)
            let mapped = self.mapDataset(dataset: window.rows,
                context: mappingContext, cancellationToken: mappingJob.token)
            recordSavedCacheStage(8, rejectionMask: mapped.wasCancelled ? 1 : 0,
                conversation: diagnosticConversation, context: diagnosticContext)
            DispatchQueue.main.async { [weak self, weak expectedSession] in
                guard let self,
                      self.timelineSession === expectedSession,
                      self.datasetMappingGeneration == mappingJob.generation,
                      !mappingJob.token.isCancelled, !mapped.wasCancelled,
                      self.ownsSavedPositionCachePresentation(request: request,
                        expectedIntentID: expectedIntentID, expectedApplyGeneration: expectedApplyGeneration),
                      let target = self.archiveWindowIntent?.locator,
                      let anchorRow = window.rows.first(where: { $0.primary == window.anchorPrimary }),
                      let cursor = ArchiveCursor(rawValue: anchorRow.mamArchiveId),
                      target == .archiveID(cursor) else {
                    #if DEBUG
                    if DeviceQADiagnostics.shared.isEnabled {
                        var mask = 0
                        if let self {
                            if self.timelineSession !== expectedSession { mask |= 1 }
                            if self.datasetMappingGeneration != mappingJob.generation { mask |= 2 }
                            mask |= self.savedCacheOwnershipRejectionMask(request: request,
                                expectedIntentID: expectedIntentID,
                                expectedApplyGeneration: expectedApplyGeneration) << 8
                        } else { mask |= 16 }
                        if mappingJob.token.isCancelled { mask |= 4 }
                        if mapped.wasCancelled { mask |= 8 }
                        recordSavedCacheStage(10, rejectionMask: mask == 0 ? 32 : mask,
                            conversation: diagnosticConversation, context: diagnosticContext)
                    }
                    #endif
                    return
                }
                recordSavedCacheStage(10, conversation: diagnosticConversation, context: diagnosticContext)
                let plan = ChatInitialTargetFirstFramePolicy.plan(request: request,
                    owner: self.owner, jid: self.jid, conversationType: self.conversationType,
                    resolvedTargetPrimary: mapped.datasource.contains(where: {
                        $0.primary == window.anchorPrimary && !$0.isFakeMessage
                    }) ? window.anchorPrimary : nil,
                    viewportHeight: self.messagesCollectionView.bounds.height,
                    targetHeight: mapped.layoutSnapshot.layout(forPrimary: window.anchorPrimary)?.cellSize.height)
                guard plan.canCompletePreparation, let anchor = plan.restoreAnchor else {
                    recordSavedCacheStage(12, rejectionMask: 1,
                        conversation: diagnosticConversation, context: diagnosticContext)
                    return
                }
                recordSavedCacheStage(11, conversation: diagnosticConversation, context: diagnosticContext)
                let receipt = ChatSavedPositionCacheApplyReceipt()
                self.performArchiveEngineInitialPresentationTransactionIfNeeded(
                    for: target, receipt: .content,
                    onCommitted: { [weak self] in
                        guard receipt.didCommit else { return }
                        self?.completeInitialTargetFirstFrameIfNeeded(request: request,
                            applyGeneration: expectedApplyGeneration)
                    }
                ) {
                    self.applyChatDatasource(mapped.datasource,
                        mode: .fullReload(keepOffset: false), animated: false,
                        invalidateLayout: false, preparedLayouts: mapped.layoutSnapshot,
                        suppressDefaultBottomScroll: true,
                        anchorRestorePhase: .applyTransaction, anchorPrimary: anchor.primary,
                        restoreAnchor: anchor, presentationOwner: .archiveEngine,
                        presentationCommitMode: .atomicInitialFrame,
                        transactionCommitAuthorization: { [weak self, weak expectedSession] in
                            guard let self, self.timelineSession === expectedSession,
                                  self.ownsSavedPositionCachePresentation(request: request,
                                    expectedIntentID: expectedIntentID, expectedApplyGeneration: expectedApplyGeneration) else {
                                recordSavedCacheStage(13, rejectionMask: 1,
                                    conversation: diagnosticConversation, context: diagnosticContext)
                                return false
                            }
                            guard self.savedPositionCacheWindowIsStillCurrent(window) else {
                                recordSavedCacheStage(13, rejectionMask: 2,
                                    conversation: diagnosticConversation, context: diagnosticContext)
                                return false
                            }
                            guard self.datasetMappingGeneration == mappingJob.generation,
                                  !mappingJob.token.isCancelled else {
                                recordSavedCacheStage(13, rejectionMask: 4,
                                    conversation: diagnosticConversation, context: diagnosticContext)
                                return false
                            }
                            recordSavedCacheStage(13, conversation: diagnosticConversation, context: diagnosticContext)
                            return true
                        },
                        transactionCompletion: { result in
                            if case .committed = result {
                                receipt.didCommit = true
                                recordSavedCacheStage(14, conversation: diagnosticConversation, context: diagnosticContext)
                            } else {
                                recordSavedCacheStage(15, rejectionMask: 1,
                                    conversation: diagnosticConversation, context: diagnosticContext)
                            }
                        },
                        completion: { [weak self] in
                            guard let self, receipt.didCommit,
                                  self.ownsSavedPositionCachePresentation(request: request,
                                    expectedIntentID: expectedIntentID, expectedApplyGeneration: expectedApplyGeneration) else {
                                recordSavedCacheStage(17, rejectionMask: 1,
                                    conversation: diagnosticConversation, context: diagnosticContext)
                                return
                            }
                            recordSavedCacheStage(16, conversation: diagnosticConversation, context: diagnosticContext)
                            self.savedPositionCachePresentationContext = .init(request: request,
                                intentID: expectedIntentID, locator: target,
                                initialApplyGeneration: expectedApplyGeneration)
                            self.archiveHistoryFailureVisibleSnapshot = ChatArchiveFailureVisibleSnapshot(
                                conversation: self.chatTimelineConversationKey, items: mapped.datasource,
                                layouts: mapped.layoutSnapshot, persistedPrimaries: window.rows.map(\.primary))
                            self.archiveHistoryFailureFallbackIsVisible = true
                            self.initialTargetFirstFrameContext?.markAlignedFrameCommitted(
                                request: request, positionedPrimary: window.anchorPrimary,
                                applyGeneration: expectedApplyGeneration,
                                datasourceGeneration: self.scrollResidentMetadataGeneration)
                            self.recordArchiveSkeletonTerminalIfNeeded()
                            // Ordinary setSkeletonVisible(false) correctly rejects
                            // unverified .skeleton. Only this validated rendering
                            // bypasses it, with read/paging authority still blocked.
                            self.showSkeletonObserver.accept(false)
                            self.setDatasourceLoadingEnabled(true)
                            self.refreshArchiveHistoryRecoveryPresentation()
                            self.endArchiveInteractiveCriticalSection()
                        })
                }
            }
        }
        return true
    }

    internal func isRefreshingSavedPositionCache(_ snapshot: ArchiveWindowSnapshot) -> Bool {
        guard let context = savedPositionCachePresentationContext,
              context.intentID == archiveWindowIntent?.id,
              context.request == archiveWindowTargetOpenRequest,
              context.request.owner == owner, context.request.chatJid == jid,
              context.request.conversationType == conversationType,
              pendingOpenMessageRequest == nil,
              archiveHistoryFailureFallbackIsVisible, !showSkeletonObserver.value,
              context.locator == archiveWindowIntent?.locator,
              snapshot.target == context.locator else { return false }
        return true
    }

    /// Captured after background mapping so intervening manual reading wins.
    internal func savedPositionCacheRefreshAnchor(mappedPrimaries: Set<String>) -> ChatViewportAnchor? {
        messagesCollectionView.layoutIfNeeded()
        for index in messagesCollectionView.indexPathsForVisibleItems.sorted(by: { $0.section < $1.section }) {
            guard datasource.indices.contains(index.section),
                  !datasource[index.section].isFakeMessage,
                  mappedPrimaries.contains(datasource[index.section].primary) else { continue }
            switch datasource[index.section].kind {
            case .date, .unread, .initial, .skeleton: continue
            default: break
            }
            let frame = messagesCollectionView.layoutAttributesForItem(at: index)?.frame
                ?? messagesCollectionView.cellForItem(at: index)?.frame
            guard let frame else { continue }
            return .init(primary: datasource[index.section].primary,
                viewportRelativeMinY: frame.minY - messagesCollectionView.contentOffset.y)
        }
        return nil
    }
}
