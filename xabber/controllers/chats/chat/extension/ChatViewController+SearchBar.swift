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
import RealmSwift
import MaterialComponents.MDCPalettes
import RxCocoa
import RxSwift
import RxRealm
import CocoaLumberjack
import XMPPFramework

enum ChatAnchorLookupMatchSource: String, Equatable {
    case primary = "primary"
    case archivedId = "archived-id"
    case messageId = "message-id"
    case metadataFallback = "metadata-fallback"
}

enum ChatAnchorRemoteFetchPlan: Equatable {
    case exactArchivedId(String)
    case dateWindow(start: Date, end: Date, max: Int)
}

enum ChatAnchorExecutionResumeTrigger: Equatable {
    case manual
    case observerRefresh
}

enum ChatAnchorFetchPolicy {
    static let windowPadding: TimeInterval = 60

    static func initialPlan(
        for anchor: ChatMessageAnchorRef,
        pageSize: Int
    ) -> ChatAnchorRemoteFetchPlan {
        if let archivedId = anchor.archivedId,
           archivedId.isNotEmpty {
            return .exactArchivedId(archivedId)
        }
        return dateWindowPlan(for: anchor, pageSize: pageSize)
    }

    static func fallbackPlan(
        after plan: ChatAnchorRemoteFetchPlan,
        anchor: ChatMessageAnchorRef,
        pageSize: Int
    ) -> ChatAnchorRemoteFetchPlan? {
        switch plan {
        case .exactArchivedId:
            return dateWindowPlan(for: anchor, pageSize: pageSize)
        case .dateWindow:
            return nil
        }
    }

    private static func dateWindowPlan(
        for anchor: ChatMessageAnchorRef,
        pageSize: Int
    ) -> ChatAnchorRemoteFetchPlan {
        let start = Date(timeIntervalSince1970: anchor.sourceDate.timeIntervalSince1970 - windowPadding)
        let end = Date(timeIntervalSince1970: anchor.sourceDate.timeIntervalSince1970 + windowPadding)
        return .dateWindow(start: start, end: end, max: pageSize)
    }
}

struct ChatAnchorContextPrefetchPlan: Equatable {
    let newerPageSize: Int?
    let olderPageSize: Int?

    var requiresRemoteFetch: Bool {
        newerPageSize != nil || olderPageSize != nil
    }
}

enum ChatAnchorContextPrefetchCompletionAction: Equatable {
    case waitForMoreQueries
    case waitForObserverSync
    case complete
}

enum ChatAnchorContextPrefetchResumeAction: Equatable {
    case waitForOutstandingQueries
    case waitForPendingMessagePersistence
    case waitForObserverSettle
    case readyToPosition
}

enum ChatAnchorContextPrefetchPolicy {
    static func plan(
        observerIndex: Int,
        totalCount: Int,
        pageSize: Int,
        archivedId: String?
    ) -> ChatAnchorContextPrefetchPlan {
        guard let archivedId,
              archivedId.isNotEmpty,
              totalCount > 0 else {
            return ChatAnchorContextPrefetchPlan(newerPageSize: nil, olderPageSize: nil)
        }

        let targetContextPerSide = max(1, pageSize / 2)
        let newerLocalCount = max(0, observerIndex)
        let olderLocalCount = max(0, totalCount - observerIndex - 1)
        let newerDeficit = newerLocalCount < targetContextPerSide
            ? min(targetContextPerSide - newerLocalCount, targetContextPerSide)
            : 0
        let olderDeficit = olderLocalCount < targetContextPerSide
            ? min(targetContextPerSide - olderLocalCount, targetContextPerSide)
            : 0

        return ChatAnchorContextPrefetchPlan(
            newerPageSize: newerDeficit > 0 ? newerDeficit : nil,
            olderPageSize: olderDeficit > 0 ? olderDeficit : nil
        )
    }

    static func completionAction(
        pendingQueryIds: Set<String>,
        totalPersistedMessageCount: Int
    ) -> ChatAnchorContextPrefetchCompletionAction {
        guard pendingQueryIds.isEmpty else {
            return .waitForMoreQueries
        }

        return totalPersistedMessageCount > 0 ? .waitForObserverSync : .complete
    }

    static func resumeAction(
        pendingQueryIds: Set<String>,
        totalPersistedMessageCount: Int,
        areMessagePipelinesIdle: Bool,
        didObservePostIdleTick: Bool
    ) -> ChatAnchorContextPrefetchResumeAction {
        guard pendingQueryIds.isEmpty else {
            return .waitForOutstandingQueries
        }

        guard totalPersistedMessageCount > 0 else {
            return .readyToPosition
        }

        guard areMessagePipelinesIdle else {
            return .waitForPendingMessagePersistence
        }

        return didObservePostIdleTick ? .readyToPosition : .waitForObserverSettle
    }
}

enum ChatInitialScrollPolicy {
    static func shouldDeferDefaultScroll(
        hasPendingAnchorRequest: Bool,
        isAnchorNavigationInFlight: Bool
    ) -> Bool {
        hasPendingAnchorRequest || isAnchorNavigationInFlight
    }
}

enum ChatMentionReadOnVisiblePolicy {
    static func notificationPrimariesToMarkRead(
        for request: ChatOpenMessageRequest,
        owner: String,
        chatJid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        positionedPrimary: String,
        visiblePrimaries: Set<String>,
        in realm: Realm
    ) -> Set<String> {
        guard request.markReadOnVisible,
              request.owner == owner,
              request.chatJid == chatJid,
              request.conversationType == conversationType,
              conversationType == .group,
              visiblePrimaries.contains(positionedPrimary) else {
            return []
        }

        return MentionNotificationSync.unreadMentionNotificationPrimaries(
            owner: owner,
            groupchatJid: chatJid,
            matchingMessagePrimary: positionedPrimary,
            in: realm
        )
    }
}

enum ChatAnchorLoadingPresentation: Equatable {
    case skeleton
    case activityIndicator
}

enum ChatAnchorLoadingPresentationPolicy {
    static func presentation(
        isBootstrapNavigation: Bool
    ) -> ChatAnchorLoadingPresentation {
        isBootstrapNavigation ? .skeleton : .activityIndicator
    }
}

enum ChatAnchorFailureRecoveryPolicy {
    static func shouldReapplyBootstrapState(usesBootstrapLoading: Bool) -> Bool {
        usesBootstrapLoading
    }

    static func shouldRunDefaultFailurePresentation(
        usesBootstrapLoading: Bool,
        hasFailureHook: Bool
    ) -> Bool {
        !usesBootstrapLoading && !hasFailureHook
    }
}

struct ChatAnchorExecutionState: Equatable {
    let request: ChatOpenMessageRequest
    var usesBootstrapLoading: Bool = false
    var lastAttemptedRemotePlan: ChatAnchorRemoteFetchPlan? = nil
    var remoteQueryId: String? = nil
    var isRemoteFetchInFlight: Bool = false
    var isWaitingForObserverSync: Bool = false
    var contextPrefetchAnchorKey: String? = nil
    var contextPrefetchQueryIds: Set<String> = []
    var contextPrefetchPendingQueryIds: Set<String> = []
    var contextPrefetchPersistedMessageCount: Int = 0
    var didObserveContextPostIdleTick: Bool = false
    var isPositioning: Bool = false
}

struct ChatAnchorExecutionHooks {
    let direction: ChatViewController.ChatDirection
    let animatedScroll: Bool
    let onFailed: (() -> Void)?
    let onPositioned: (() -> Void)?
}

enum ChatAnchorExecutionAction: Equatable {
    case resolveLocally
    case startRemoteFetch(ChatAnchorRemoteFetchPlan)
    case waitForObserverSync
    case fail
    case none
}

enum ChatAnchorExecutionPolicy {
    static func nextRemotePlan(
        for state: ChatAnchorExecutionState,
        pageSize: Int
    ) -> ChatAnchorRemoteFetchPlan? {
        if let lastAttemptedRemotePlan = state.lastAttemptedRemotePlan {
            return ChatAnchorFetchPolicy.fallbackPlan(
                after: lastAttemptedRemotePlan,
                anchor: state.request.anchor,
                pageSize: pageSize
            )
        }

        return ChatAnchorFetchPolicy.initialPlan(
            for: state.request.anchor,
            pageSize: pageSize
        )
    }

    static func resumeAction(
        state: ChatAnchorExecutionState,
        hasLocalMatch: Bool,
        trigger: ChatAnchorExecutionResumeTrigger,
        pageSize: Int
    ) -> ChatAnchorExecutionAction {
        if state.isPositioning || state.isRemoteFetchInFlight {
            return .none
        }

        if hasLocalMatch {
            return .resolveLocally
        }

        if state.isWaitingForObserverSync {
            if trigger != .observerRefresh {
                return .waitForObserverSync
            }
            return nextRemotePlan(for: state, pageSize: pageSize).map(ChatAnchorExecutionAction.startRemoteFetch) ?? .fail
        }

        return nextRemotePlan(for: state, pageSize: pageSize).map(ChatAnchorExecutionAction.startRemoteFetch) ?? .fail
    }

    static func remoteCompletionAction(
        state: ChatAnchorExecutionState,
        hasLocalMatch: Bool,
        persistedMessageCount: Int,
        remoteResultCount: Int,
        pageSize: Int
    ) -> ChatAnchorExecutionAction {
        if hasLocalMatch {
            return .resolveLocally
        }

        if persistedMessageCount > 0 || remoteResultCount > 0 {
            return .waitForObserverSync
        }

        return nextRemotePlan(for: state, pageSize: pageSize).map(ChatAnchorExecutionAction.startRemoteFetch) ?? .fail
    }
}

extension ChatViewController {
    private struct ResolvedJumpTarget {
        let primary: String
        let archivedId: String?
    }

    internal func queueOpenMessageRequest(
        _ request: ChatOpenMessageRequest,
        hooks: ChatAnchorExecutionHooks? = nil
    ) {
        if self.activeAnchorExecutionState?.request != request {
            self.activeAnchorExecutionState = nil
        }
        self.pendingOpenMessageRequest = request
        self.activeAnchorExecutionHooks = hooks
        self.syncAnchorExecutionFlags()
        self.performPendingOpenMessageRequestIfNeeded(trigger: .manual)
    }

    private func syncAnchorExecutionFlags() {
        self.isExecutingOpenMessageRequest = self.activeAnchorExecutionState != nil
        self.isMessageAnchorNavigationInFlight = self.pendingOpenMessageRequest != nil || self.activeAnchorExecutionState != nil
    }

    private func initialAnchorExecutionState(
        for request: ChatOpenMessageRequest
    ) -> ChatAnchorExecutionState {
        ChatAnchorExecutionState(
            request: request,
            usesBootstrapLoading: self.isShowingBootstrapPlaceholder
        )
    }

    private func beginBootstrapAnchorContentTransitionIfNeeded() {
        guard self.showSkeletonObserver.value,
              self.activeAnchorExecutionState?.usesBootstrapLoading == true else {
            return
        }

        self.isApplyingBootstrapAnchorWindow = true
        self.setShouldShowInitialMessage(false)
        self.setLoadingIndicatorVisible(false)
        self.setSkeletonVisible(false)
    }

    private func finishActiveAnchorExecution() {
        self.pendingOpenMessageRequest = nil
        self.activeAnchorExecutionState = nil
        self.activeAnchorExecutionHooks = nil
        self.isApplyingBootstrapAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setLoadingIndicatorVisible(false)
        self.setDatasourceLoadingEnabled(true)
    }

    private func failActiveAnchorExecution() {
        let executionState = self.activeAnchorExecutionState
        let onFailed = self.activeAnchorExecutionHooks?.onFailed
        self.finishActiveAnchorExecution()
        let usesBootstrapLoading = executionState?.usesBootstrapLoading == true
        let hasFailureHook = onFailed != nil
        if ChatAnchorFailureRecoveryPolicy.shouldReapplyBootstrapState(usesBootstrapLoading: usesBootstrapLoading) {
            let bootstrapState = self.currentBootstrapViewState()
            self.applyBootstrapViewState(bootstrapState, forceRender: true)
            if bootstrapState != .skeleton {
                DispatchQueue.main.async {
                    self.scrollToLastOrUnreadItem()
                }
            }
        }
        if let onFailed {
            onFailed()
            return
        }
        guard ChatAnchorFailureRecoveryPolicy.shouldRunDefaultFailurePresentation(
            usesBootstrapLoading: usesBootstrapLoading,
            hasFailureHook: hasFailureHook
        ) else { return }
        self.view.makeToast("Original message is no longer available")
    }

    @discardableResult
    private func startRemoteAnchorFetch(
        plan: ChatAnchorRemoteFetchPlan,
        for request: ChatOpenMessageRequest
    ) -> String? {
        let queryId: String
        switch plan {
        case .exactArchivedId:
            queryId = "MAM jump exact: \(NanoID.new(6))"
        case .dateWindow:
            queryId = "MAM jump window: \(NanoID.new(6))"
        }

        var state = self.activeAnchorExecutionState ?? self.initialAnchorExecutionState(for: request)
        state.lastAttemptedRemotePlan = plan
        state.remoteQueryId = queryId
        state.isRemoteFetchInFlight = true
        state.isWaitingForObserverSync = false
        state.isPositioning = false
        self.activeAnchorExecutionState = state
        self.syncAnchorExecutionFlags()
        self.setDatasourceLoadingEnabled(false)
        switch ChatAnchorLoadingPresentationPolicy.presentation(
            isBootstrapNavigation: state.usesBootstrapLoading
        ) {
        case .skeleton:
            self.setLoadingIndicatorVisible(false)
        case .activityIndicator:
            self.setLoadingIndicatorVisible(true)
        }

        let requestCallbacks = MessageArchiveManager.RequestCallbacks(
            onMessage: nil,
            onEndPage: { [weak self] queryId, state, first, last, count in
                self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
            }
        )

        self.performArchiveAction({ stream, mam in
            switch plan {
            case .exactArchivedId(let archivedId):
                _ = mam.fetchAnchorMessage(
                    stream,
                    jid: self.jid,
                    conversationType: self.conversationType,
                    archivedId: archivedId,
                    queryId: queryId,
                    callback: nil,
                    requestCallbacks: requestCallbacks
                )
            case .dateWindow(let start, let end, let max):
                _ = mam.fetchAnchorWindow(
                    stream,
                    jid: self.jid,
                    conversationType: self.conversationType,
                    start: start,
                    end: end,
                    max: max,
                    queryId: queryId,
                    callback: nil,
                    requestCallbacks: requestCallbacks
                )
            }
        }, unavailable: {
            self.failActiveAnchorExecution()
        })

        return queryId
    }

    private func performArchiveAction(
        _ action: @escaping (XMPPStream, MessageArchiveManager) -> Void,
        unavailable: (() -> Void)? = nil
    ) {
        let fallback = {
            guard let account = AccountManager.shared.find(for: self.owner) else {
                unavailable?()
                return
            }

            account.action { user, stream in
                action(stream, user.mam)
            }
        }

        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            if let mam = session.mam {
                action(stream, mam)
            } else {
                fallback()
            }
        } fail: {
            fallback()
        }
    }

    private func localAnchorMessage(
        for request: ChatOpenMessageRequest
    ) -> (message: MessageStorageItem, matchSource: ChatAnchorLookupMatchSource)? {
        self.ensureObserverLookupMaps()
        let anchor = request.anchor

        if let messagePrimary = anchor.messagePrimary,
           messagePrimary.isNotEmpty,
           let observerIndex = self.observerPrimaryIndexMap[messagePrimary],
           observerIndex < self.messagesObserver.count {
            return (self.messagesObserver[observerIndex], .primary)
        }

        if let archivedId = anchor.archivedId,
           archivedId.isNotEmpty,
           let observerIndex = self.observerArchivedIdIndexMap[archivedId],
           observerIndex < self.messagesObserver.count {
            return (self.messagesObserver[observerIndex], .archivedId)
        }

        if let messageId = anchor.messageId,
           messageId.isNotEmpty,
           let observerIndex = self.observerMessageIdIndexMap[messageId],
           observerIndex < self.messagesObserver.count {
            return (self.messagesObserver[observerIndex], .messageId)
        }

        do {
            let realm = try WRealm.safe()
            if let message = MentionNotificationSync.matchingMessage(
                owner: request.owner,
                sourceChatJid: request.chatJid,
                conversationType: request.conversationType,
                sourceArchivedId: anchor.archivedId,
                sourceMessageId: anchor.messageId,
                sourceMessageDate: anchor.sourceDate,
                sourceSenderId: anchor.authorId,
                sourceBodyFingerprint: anchor.bodyFingerprint,
                in: realm
            ) {
                return (message, .metadataFallback)
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }

        return nil
    }

    private func resolvedJumpTarget(
        primary: String? = nil,
        archivedId: String? = nil,
        messageId: String? = nil
    ) -> ResolvedJumpTarget? {
        self.ensureObserverLookupMaps()

        if let primary,
           let observerIndex = self.observerPrimaryIndexMap[primary],
           observerIndex < self.messagesObserver.count {
            let item = self.messagesObserver[observerIndex]
            return ResolvedJumpTarget(
                primary: item.primary,
                archivedId: item.archivedId.isNotEmpty ? item.archivedId : nil
            )
        }

        if let archivedId,
           archivedId.isNotEmpty,
           let observerIndex = self.observerArchivedIdIndexMap[archivedId],
           observerIndex < self.messagesObserver.count {
            let item = self.messagesObserver[observerIndex]
            return ResolvedJumpTarget(
                primary: item.primary,
                archivedId: item.archivedId.isNotEmpty ? item.archivedId : nil
            )
        }

        if let messageId,
           messageId.isNotEmpty,
           let observerIndex = self.observerMessageIdIndexMap[messageId],
           observerIndex < self.messagesObserver.count {
            let item = self.messagesObserver[observerIndex]
            return ResolvedJumpTarget(
                primary: item.primary,
                archivedId: item.archivedId.isNotEmpty ? item.archivedId : nil
            )
        }

        return nil
    }

    private func resolvedJumpTarget(for message: MessageStorageItem) -> ResolvedJumpTarget? {
        self.resolvedJumpTarget(
            primary: message.primary,
            archivedId: message.archivedId.isNotEmpty ? message.archivedId : nil,
            messageId: message.messageId
        )
    }

    private func logAnchorMatch(
        source: ChatAnchorLookupMatchSource,
        request: ChatOpenMessageRequest
    ) {
        DDLogDebug(
            "ChatViewController: resolved anchor via \(source.rawValue). source=\(request.source.rawValue) chat=\(request.chatJid) archivedId=\(request.anchor.archivedId ?? "nil") messageId=\(request.anchor.messageId ?? "nil")"
        )
    }

    private func applyWindowAndResolveJump(
        for target: ResolvedJumpTarget,
        direction: ChatDirection,
        completion: @escaping (ResolvedJumpTarget) -> Void
    ) {
        self.ensureObserverLookupMaps()
        guard let observerIndex = self.observerPrimaryIndexMap[target.primary] else {
            completion(target)
            return
        }

        let window = self.datasetCoordinator.replacementWindow(around: observerIndex, totalCount: self.messagesObserver.count)
        self.chatScrollDirection = direction
        self.currentPage.setCustomPage(observerIndex / self.datasourcePageSize) {
            self.syncCurrentPage(with: window)
            self.mapAndApplyWindow(window, mode: .fullReload(), completion: {
                completion(target)
            })
        }
    }

    private func positionMessage(
        primary: String,
        archivedId: String? = nil,
        highlight: Bool,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        self.preventHidingDate = true
        self.messagesCollectionView.layoutIfNeeded()
        if highlight {
            self.messagesCollectionView.visibleCells
                .compactMap { $0 as? MessageContentCell }
                .forEach { $0.setSelected(state: false) }
        }

        guard let scrollIndex = self.datasourceSnapshot.primaryIndex[primary]
            ?? archivedId.flatMap({ self.datasourceSnapshot.archivedIdIndex[$0] }) else {
            self.preventHidingDate = false
            self.setDatasourceLoadingEnabled(true)
            self.currentPage.unlock()
            completion?()
            return
        }
        let indexPath = IndexPath(row: 0, section: scrollIndex)

        self.messagesCollectionView.scrollToItem(
            at: indexPath,
            at: .centeredVertically,
            animated: animated
        )

        let finalizeDelay: TimeInterval = animated ? 0.35 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + finalizeDelay) {
            if let cell = self.messagesCollectionView.cellForItem(at: indexPath) as? MessageContentCell {
                cell.setSelected(state: highlight)
            }
            self.preventHidingDate = false
            self.currentPage.unlock()
            self.setFloatingDateVisible(true)
            self.setFloatingDateHidden(true)
            self.setDatasourceLoadingEnabled(true)
            completion?()
        }
    }

    private func scheduleMentionReadOnVisibleIfNeeded(
        for request: ChatOpenMessageRequest,
        positionedPrimary: String
    ) {
        DispatchQueue.main.async {
            do {
                let realm = try WRealm.safe()
                let notificationPrimaries = ChatMentionReadOnVisiblePolicy.notificationPrimariesToMarkRead(
                    for: request,
                    owner: self.owner,
                    chatJid: self.jid,
                    conversationType: self.conversationType,
                    positionedPrimary: positionedPrimary,
                    visiblePrimaries: self.visibleRealMessagePrimaries(),
                    in: realm
                )
                guard notificationPrimaries.isNotEmpty else {
                    return
                }

                // Anchor-opened mentions should clear only after the target message is actually visible.
                self.scheduleVisibleUnreadMentionReconciliation(notificationPrimaries: notificationPrimaries)
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }

    private func contextPrefetchAnchorKey(
        for target: ResolvedJumpTarget,
        request: ChatOpenMessageRequest
    ) -> String {
        request.anchor.archivedId ??
        target.archivedId ??
        request.anchor.messageId ??
        target.primary
    }

    private func resetContextPrefetchState(
        _ state: inout ChatAnchorExecutionState,
        anchorKey: String? = nil
    ) {
        state.contextPrefetchAnchorKey = anchorKey
        state.contextPrefetchQueryIds = []
        state.contextPrefetchPendingQueryIds = []
        state.contextPrefetchPersistedMessageCount = 0
        state.didObserveContextPostIdleTick = false
    }

    private func isMessagePipelineIdle(for queryIds: Set<String>) -> Bool {
        guard let messages = AccountManager.shared.find(for: self.owner)?.messages else {
            return true
        }

        return !queryIds.contains { messages.hasPendingMessages(forQueryId: $0) }
    }

    private func scheduleContextPrefetchObserverResumeIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            self?.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
        }
    }

    private func scheduleAnchorObserverResumeIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            self?.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
        }
    }

    private func prepareContextPrefetchIfNeeded(
        around target: ResolvedJumpTarget,
        request: ChatOpenMessageRequest
    ) -> Bool {
        guard var executionState = self.activeAnchorExecutionState else {
            return false
        }

        let anchorKey = self.contextPrefetchAnchorKey(for: target, request: request)

        if executionState.contextPrefetchAnchorKey == anchorKey {
            let action = ChatAnchorContextPrefetchPolicy.resumeAction(
                pendingQueryIds: executionState.contextPrefetchPendingQueryIds,
                totalPersistedMessageCount: executionState.contextPrefetchPersistedMessageCount,
                areMessagePipelinesIdle: self.isMessagePipelineIdle(for: executionState.contextPrefetchQueryIds),
                didObservePostIdleTick: executionState.didObserveContextPostIdleTick
            )

            switch action {
            case .waitForOutstandingQueries, .waitForPendingMessagePersistence:
                self.activeAnchorExecutionState = executionState
                self.syncAnchorExecutionFlags()
                return true
            case .waitForObserverSettle:
                executionState.didObserveContextPostIdleTick = true
                self.activeAnchorExecutionState = executionState
                self.syncAnchorExecutionFlags()
                self.scheduleContextPrefetchObserverResumeIfNeeded()
                return true
            case .readyToPosition:
                self.activeAnchorExecutionState = executionState
                self.syncAnchorExecutionFlags()
                return false
            }
        }

        self.resetContextPrefetchState(&executionState, anchorKey: anchorKey)
        self.activeAnchorExecutionState = executionState

        self.ensureObserverLookupMaps()
        guard let observerIndex = self.observerPrimaryIndexMap[target.primary] else {
            self.syncAnchorExecutionFlags()
            return false
        }

        let effectiveArchivedId = request.anchor.archivedId ?? target.archivedId
        let plan = ChatAnchorContextPrefetchPolicy.plan(
            observerIndex: observerIndex,
            totalCount: self.messagesObserver.count,
            pageSize: self.datasourcePageSize,
            archivedId: effectiveArchivedId
        )

        guard plan.requiresRemoteFetch,
              let archivedId = effectiveArchivedId,
              archivedId.isNotEmpty else {
            self.syncAnchorExecutionFlags()
            return false
        }

        let newerQueryId = plan.newerPageSize.map { _ in "MAM jump context newer: \(NanoID.new(6))" }
        let olderQueryId = plan.olderPageSize.map { _ in "MAM jump context older: \(NanoID.new(6))" }
        let queryIds = Set([newerQueryId, olderQueryId].compactMap { $0 })

        var updatedState = executionState
        updatedState.contextPrefetchQueryIds = queryIds
        updatedState.contextPrefetchPendingQueryIds = queryIds
        updatedState.contextPrefetchPersistedMessageCount = 0
        updatedState.didObserveContextPostIdleTick = false
        self.activeAnchorExecutionState = updatedState
        self.syncAnchorExecutionFlags()

        let requestCallbacks = MessageArchiveManager.RequestCallbacks(
            onMessage: nil,
            onEndPage: { [weak self] queryId, state, first, last, count in
                self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
            }
        )

        switch ChatAnchorLoadingPresentationPolicy.presentation(
            isBootstrapNavigation: updatedState.usesBootstrapLoading
        ) {
        case .skeleton:
            self.setLoadingIndicatorVisible(false)
        case .activityIndicator:
            self.setLoadingIndicatorVisible(true)
        }
        self.performArchiveAction({ stream, mam in
            if let newerPageSize = plan.newerPageSize,
               let newerQueryId {
                _ = mam.getPrevHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    messageId: archivedId,
                    pageSize: newerPageSize,
                    queryId: newerQueryId,
                    callback: nil,
                    requestCallbacks: requestCallbacks
                )
            }

            if let olderPageSize = plan.olderPageSize,
               let olderQueryId {
                _ = mam.getNextHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    messageId: archivedId,
                    pageSize: olderPageSize,
                    queryId: olderQueryId,
                    callback: nil,
                    requestCallbacks: requestCallbacks
                )
            }
        }, unavailable: { [weak self] in
            guard let self,
                  var state = self.activeAnchorExecutionState,
                  state.contextPrefetchAnchorKey == anchorKey else {
                return
            }
            self.resetContextPrefetchState(&state, anchorKey: anchorKey)
            self.activeAnchorExecutionState = state
            self.syncAnchorExecutionFlags()
            self.resumeAnchorExecutionIfNeeded(trigger: .manual)
        })

        return true
    }

    private func resumeAnchorExecutionIfNeeded(trigger: ChatAnchorExecutionResumeTrigger) {
        guard let request = self.pendingOpenMessageRequest,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType,
              self.messagesObserver != nil else {
            return
        }

        if self.activeAnchorExecutionState?.request != request {
            self.activeAnchorExecutionState = self.initialAnchorExecutionState(for: request)
        }

        guard var executionState = self.activeAnchorExecutionState else {
            return
        }

        let localMatch = self.localAnchorMessage(for: request)
        let action = ChatAnchorExecutionPolicy.resumeAction(
            state: executionState,
            hasLocalMatch: localMatch != nil,
            trigger: trigger,
            pageSize: self.datasourcePageSize
        )

        switch action {
        case .resolveLocally:
            guard let localMatch,
                  let resolved = self.resolvedJumpTarget(for: localMatch.message) else {
                return
            }
            self.logAnchorMatch(source: localMatch.matchSource, request: request)
            executionState.isWaitingForObserverSync = false
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()

            if self.prepareContextPrefetchIfNeeded(around: resolved, request: request) {
                return
            }

            guard var resolvedExecutionState = self.activeAnchorExecutionState else {
                return
            }

            resolvedExecutionState.isPositioning = true
            self.activeAnchorExecutionState = resolvedExecutionState
            self.syncAnchorExecutionFlags()
            self.beginBootstrapAnchorContentTransitionIfNeeded()
            let hooks = self.activeAnchorExecutionHooks
            let direction = hooks?.direction ?? .up
            self.chatScrollDirection = direction
            self.applyWindowAndResolveJump(
                for: resolved,
                direction: direction
            ) { target in
                self.positionMessage(
                    primary: target.primary,
                    archivedId: target.archivedId,
                    highlight: request.highlight,
                    animated: hooks?.animatedScroll ?? false,
                    completion: {
                        self.finishActiveAnchorExecution()
                        self.scheduleMentionReadOnVisibleIfNeeded(
                            for: request,
                            positionedPrimary: target.primary
                        )
                        hooks?.onPositioned?()
                    }
                )
            }
        case .startRemoteFetch(let plan):
            _ = self.startRemoteAnchorFetch(plan: plan, for: request)
        case .waitForObserverSync, .none:
            self.syncAnchorExecutionFlags()
            return
        case .fail:
            self.failActiveAnchorExecution()
            return
        }
    }

    internal func performPendingOpenMessageRequestIfNeeded(
        trigger: ChatAnchorExecutionResumeTrigger = .manual
    ) {
        guard let request = self.pendingOpenMessageRequest,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType,
              self.messagesObserver != nil else {
            return
        }

        if self.activeAnchorExecutionState?.request != request {
            self.activeAnchorExecutionState = self.initialAnchorExecutionState(for: request)
        }
        self.syncAnchorExecutionFlags()
        self.resumeAnchorExecutionIfNeeded(trigger: trigger)
    }
    
    internal final func scrollToMessage(
        archivedId: String,
        date: Date,
        direction: ChatDirection,
        callback: @escaping ((Array<MessageStorageItem>, Int) -> Void),
        notFound: (() -> Void)? = nil
    ) {
        func update() {
            self.setLoadingIndicatorVisible(false)
            self.ensureObserverLookupMaps()
            guard let index = self.observerArchivedIdIndexMap[archivedId] else {
                notFound?()
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
        self.queueOpenMessageRequest(
            ChatOpenMessageRequest(
                chatJid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType,
                anchor: ChatMessageAnchorRef(
                    messagePrimary: nil,
                    archivedId: archivedId,
                    messageId: nil,
                    authorId: nil,
                    bodyFingerprint: nil,
                    sourceDate: date
                ),
                highlight: true,
                markReadOnVisible: true,
                source: .external
            ),
            hooks: ChatAnchorExecutionHooks(
                direction: .up,
                animatedScroll: false,
                onFailed: {},
                onPositioned: nil
            )
        )
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
        self.queueOpenMessageRequest(
            ChatOpenMessageRequest(
                chatJid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType,
                anchor: ChatMessageAnchorRef(
                    messagePrimary: nil,
                    archivedId: archivedId,
                    messageId: nil,
                    authorId: nil,
                    bodyFingerprint: nil,
                    sourceDate: date
                ),
                highlight: true,
                markReadOnVisible: false,
                source: .search
            ),
            hooks: ChatAnchorExecutionHooks(
                direction: .up,
                animatedScroll: false,
                onFailed: {},
                onPositioned: nil
            )
        )
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
        self.queueOpenMessageRequest(
            ChatOpenMessageRequest(
                chatJid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType,
                anchor: ChatMessageAnchorRef(
                    messagePrimary: nil,
                    archivedId: archivedId,
                    messageId: nil,
                    authorId: nil,
                    bodyFingerprint: nil,
                    sourceDate: date
                ),
                highlight: true,
                markReadOnVisible: false,
                source: .search
            ),
            hooks: ChatAnchorExecutionHooks(
                direction: .down,
                animatedScroll: false,
                onFailed: {},
                onPositioned: nil
            )
        )
    }
    
    internal func onSearchPanelChangeChatViewState() {

    }
    
    internal func scrollToSearchedMessage(primary: String) {
        self.positionMessage(primary: primary, highlight: true, animated: false)
    }
    
    internal func scrollToSearchedMessage(archivedId: String) {
        guard let scrollIndex = self.datasourceSnapshot.archivedIdIndex[archivedId],
              scrollIndex < self.datasource.count else {
            return
        }
        self.positionMessage(
            primary: self.datasource[scrollIndex].primary,
            archivedId: archivedId,
            highlight: true,
            animated: false
        )
    }

    internal func navigateToNextUnreadMention() {
        guard let target = self.unreadMentionsState.jumpTarget else {
            return
        }
        let direction: ChatDirection = (target.observerIndex ?? Int.max) < (self.visibleRealMessagePrimaries().compactMap { self.observerPrimaryIndexMap[$0] }.min() ?? Int.max)
            ? .down
            : .up
        self.navigateToUnreadMention(target, direction: direction)
    }

    internal func navigateToUnreadMention(_ target: ChatUnreadMentionNavigationTarget, direction: ChatDirection) {
        if self.isUnreadMentionNavigationInFlight {
            self.pendingUnreadMentionNavigationRequest = ChatUnreadMentionNavigationRequest(
                target: target,
                direction: direction
            )
            return
        }

        guard self.currentPage.isUnlocked else {
            return
        }

        self.isUnreadMentionNavigationInFlight = true
        self.pendingUnreadMentionNavigationRequest = nil
        self.currentUnreadMentionNotificationPrimary = target.notificationPrimary
        FeedbackManager.shared.generate(feedback: .success)

        let finishNavigation: () -> Void = { [weak self] in
            guard let self else {
                return
            }
            self.isUnreadMentionNavigationInFlight = false
            self.refreshUnreadMentionsNavigatorState(animated: true)
            if let pendingRequest = self.pendingUnreadMentionNavigationRequest {
                self.pendingUnreadMentionNavigationRequest = nil
                DispatchQueue.main.async {
                    self.navigateToUnreadMention(pendingRequest.target, direction: pendingRequest.direction)
                }
            }
        }

        self.queueOpenMessageRequest(
            ChatOpenMessageRequest(
                chatJid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType,
                anchor: ChatMessageAnchorRef(
                    messagePrimary: target.messagePrimary,
                    archivedId: target.archivedId,
                    messageId: target.messageId,
                    authorId: target.authorId,
                    bodyFingerprint: nil,
                    sourceDate: target.date
                ),
                highlight: false,
                markReadOnVisible: false,
                source: .mentionNotification
            ),
            hooks: ChatAnchorExecutionHooks(
                direction: direction,
                animatedScroll: true,
                onFailed: finishNavigation,
                onPositioned: finishNavigation
            )
        )
    }
}

extension ChatViewController: TemporaryMessageReceiverProtocol {
    
    public final func scrollToMessageAtIndex(archivedId: String, date: Date) {
        let request = ChatOpenMessageRequest(
            chatJid: self.jid,
            owner: self.owner,
            conversationType: self.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: archivedId,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: date
            ),
            highlight: true,
            markReadOnVisible: true,
            source: .external
        )
        self.queueOpenMessageRequest(request)
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
            self.queueOpenMessageRequest(
                ChatOpenMessageRequest(
                    chatJid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType,
                    anchor: ChatMessageAnchorRef(
                        messagePrimary: nil,
                        archivedId: archivedId,
                        messageId: nil,
                        authorId: nil,
                        bodyFingerprint: nil,
                        sourceDate: date
                    ),
                    highlight: true,
                    markReadOnVisible: false,
                    source: .search
                ),
                hooks: ChatAnchorExecutionHooks(
                    direction: .up,
                    animatedScroll: false,
                    onFailed: { [weak self] in
                        self?.preventHidingDate = false
                    },
                    onPositioned: { [weak self] in
                        self?.preventHidingDate = false
                    }
                )
            )
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
            if self.handleAnchorContextPrefetchEndPageIfNeeded(queryId: queryId, state: state) {
                return
            }
            if self.handleAnchorRemoteFetchEndPageIfNeeded(queryId: queryId, state: state, count: count) {
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

    @discardableResult
    private func handleAnchorContextPrefetchEndPageIfNeeded(
        queryId: String,
        state: MessageArchivePageEndState
    ) -> Bool {
        guard var executionState = self.activeAnchorExecutionState,
              executionState.contextPrefetchQueryIds.contains(queryId) else {
            return false
        }

        executionState.contextPrefetchPendingQueryIds.remove(queryId)
        executionState.contextPrefetchPersistedMessageCount += state.persistedMessageCount
        self.activeAnchorExecutionState = executionState
        self.syncAnchorExecutionFlags()

        let action = ChatAnchorContextPrefetchPolicy.completionAction(
            pendingQueryIds: executionState.contextPrefetchPendingQueryIds,
            totalPersistedMessageCount: executionState.contextPrefetchPersistedMessageCount
        )

        switch action {
        case .waitForMoreQueries:
            return true
        case .waitForObserverSync:
            executionState.didObserveContextPostIdleTick = false
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            self.scheduleContextPrefetchObserverResumeIfNeeded()
            return true
        case .complete:
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            self.resumeAnchorExecutionIfNeeded(trigger: .manual)
            return true
        }
    }

    @discardableResult
    private func handleAnchorRemoteFetchEndPageIfNeeded(
        queryId: String,
        state: MessageArchivePageEndState,
        count: Int
    ) -> Bool {
        guard var executionState = self.activeAnchorExecutionState,
              executionState.remoteQueryId == queryId else {
            return false
        }

        executionState.isRemoteFetchInFlight = false
        executionState.remoteQueryId = nil
        executionState.isPositioning = false
        self.activeAnchorExecutionState = executionState
        self.syncAnchorExecutionFlags()

        let hasLocalMatch = self.pendingOpenMessageRequest
            .flatMap { self.localAnchorMessage(for: $0) } != nil

        let action = ChatAnchorExecutionPolicy.remoteCompletionAction(
            state: executionState,
            hasLocalMatch: hasLocalMatch,
            persistedMessageCount: state.persistedMessageCount,
            remoteResultCount: count,
            pageSize: self.datasourcePageSize
        )

        switch action {
        case .resolveLocally:
            executionState.isWaitingForObserverSync = false
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            self.resumeAnchorExecutionIfNeeded(trigger: .manual)
        case .waitForObserverSync:
            executionState.isWaitingForObserverSync = true
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            self.scheduleAnchorObserverResumeIfNeeded()
        case .startRemoteFetch(let plan):
            executionState.isWaitingForObserverSync = false
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            if let request = self.pendingOpenMessageRequest {
                _ = self.startRemoteAnchorFetch(plan: plan, for: request)
            } else {
                self.failActiveAnchorExecution()
            }
        case .fail:
            self.failActiveAnchorExecution()
        case .none:
            self.syncAnchorExecutionFlags()
        }

        return true
    }
}
