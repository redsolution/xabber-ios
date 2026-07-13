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
    case unreadBoundaryAfter = "unread-boundary-after"
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

enum ChatAnchorContextPrefetchMode: Equatable {
    case blocking
    case background
}

enum ChatAnchorContextPrefetchModePolicy {
    static func mode(
        for source: ChatOpenMessageRequestSource,
        hasLocalMatch: Bool,
        isSynced: Bool
    ) -> ChatAnchorContextPrefetchMode {
        if source == .search {
            return hasLocalMatch ? .background : .blocking
        }

        if hasLocalMatch && isSynced {
            return .background
        }

        return .blocking
    }
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
        let olderLocalCount = max(0, observerIndex)
        let newerLocalCount = max(0, totalCount - observerIndex - 1)
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

        return .complete
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

        return .readyToPosition
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

enum ChatInitialAnchorBootstrapPolicy {
    static func shouldBlockBootstrap(
        source: ChatOpenMessageRequestSource,
        isSynced: Bool,
        messageCount: Int,
        hasLocalAnchor: Bool,
        isShowingBootstrapPlaceholder: Bool
    ) -> Bool {
        guard isShowingBootstrapPlaceholder else {
            return false
        }

        if source == .initialUnreadBoundary || source == .search {
            return !(isSynced && messageCount > 0 && hasLocalAnchor)
        }

        if isSynced,
           messageCount > 0 {
            return false
        }

        if source == .savedVisiblePosition,
           isSynced,
           messageCount > 0,
           hasLocalAnchor {
            return false
        }

        return true
    }

    static func needsLocalAnchorLookup(source: ChatOpenMessageRequestSource) -> Bool {
        source == .savedVisiblePosition || source == .initialUnreadBoundary || source == .search
    }
}

enum ChatUnreadBoundaryFirstFramePolicy {
    enum Decision: Equatable {
        case wait
        case unreadBoundary(anchorIndex: Int)
    }

    static func decision(
        requestSource: ChatOpenMessageRequestSource,
        isSynced: Bool,
        observerCount: Int,
        localAnchorIndex: Int?,
        isPageUnlocked: Bool
    ) -> Decision {
        guard requestSource == .initialUnreadBoundary,
              isSynced,
              observerCount > 0,
              let localAnchorIndex,
              localAnchorIndex >= 0,
              localAnchorIndex < observerCount,
              isPageUnlocked else {
            return .wait
        }

        return .unreadBoundary(anchorIndex: localAnchorIndex)
    }

    static func shouldApplySynchronously(
        bootstrapState: ChatBootstrapViewState,
        isShowingBootstrapPlaceholder: Bool,
        decision: Decision
    ) -> Bool {
        guard case .unreadBoundary = decision else {
            return false
        }

        return bootstrapState == .content && isShowingBootstrapPlaceholder
    }
}

enum ChatInitialAutomaticOpenPolicy {
    static func shouldOpenUnreadBoundaryOnChatOpen() -> Bool {
        true
    }

    static func shouldRestoreSavedVisiblePositionOnChatOpen() -> Bool {
        false
    }
}

enum ChatOpenMessageRequestHandlingPolicy {
    static func shouldHonorMessageAnchors() -> Bool {
        false
    }

    static func shouldForceLatestForDefaultOpen() -> Bool {
        true
    }

    static func shouldForceLatestOnOpen() -> Bool {
        shouldForceLatestForDefaultOpen()
    }

    static func shouldRestoreSavedFirstFramePosition() -> Bool {
        return shouldHonorMessageAnchors()
    }

    static func shouldHonorMessageAnchorRequest(source: ChatOpenMessageRequestSource) -> Bool {
        if source == .search || source == .initialUnreadBoundary || source == .mediaGallery {
            return true
        }

        return shouldHonorMessageAnchors()
    }

    static func effectiveScrollDownTarget(_ target: ChatScrollDownTargetPolicy.Target) -> ChatScrollDownTargetPolicy.Target {
        shouldHonorMessageAnchors() ? target : .latest
    }
}

enum ChatInitialPositionPolicy {
    enum Decision: Equatable {
        case open(ChatOpenMessageRequest)
        case bottom
    }

    struct ChatState: Equatable {
        let owner: String
        let jid: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let unread: Int
        let syncUnreadCount: Int
        let syncUnreadAfterId: String?
        let lastReadId: String?
        let lastMessageId: String
        let syncSnapshotLastArchiveId: String?
        let messageDate: Date
        let savedPosition: ChatSavedVisiblePosition?
        let savedAtLastMessageId: String?
        let savedAtSnapshotLastArchiveId: String?
    }

    static func decision(
        for chat: ChatState,
        explicitRequest: ChatOpenMessageRequest?
    ) -> Decision {
        if let explicitRequest,
           ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: explicitRequest.source) {
            return .open(explicitRequest)
        }

        if ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: .initialUnreadBoundary),
           ChatInitialAutomaticOpenPolicy.shouldOpenUnreadBoundaryOnChatOpen(),
           chat.syncUnreadCount > 0,
           let boundaryId = normalizedUnreadBoundaryId(chat.syncUnreadAfterId) {
            let sourceDate = archiveDate(from: boundaryId) ?? chat.messageDate
            return .open(
                ChatOpenMessageRequest(
                    chatJid: chat.jid,
                    owner: chat.owner,
                    conversationType: chat.conversationType,
                    anchor: ChatMessageAnchorRef(
                        messagePrimary: nil,
                        archivedId: boundaryId,
                        messageId: nil,
                        authorId: nil,
                        bodyFingerprint: nil,
                        sourceDate: sourceDate
                    ),
                    highlight: false,
                    markReadOnVisible: false,
                    source: .initialUnreadBoundary,
                    targetResolution: .firstIncomingAfterBoundary(boundaryId)
                )
            )
        }

        if ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: .savedVisiblePosition),
           ChatInitialAutomaticOpenPolicy.shouldRestoreSavedVisiblePositionOnChatOpen(),
           chat.unread == 0,
           let savedPosition = chat.savedPosition,
           savedPosition.hasAnchor,
           chat.savedAtLastMessageId == chat.lastMessageId,
           chat.savedAtSnapshotLastArchiveId == chat.syncSnapshotLastArchiveId {
            return .open(
                ChatOpenMessageRequest(
                    chatJid: chat.jid,
                    owner: chat.owner,
                    conversationType: chat.conversationType,
                    anchor: ChatMessageAnchorRef(
                        messagePrimary: normalizedId(savedPosition.messagePrimary),
                        archivedId: normalizedId(savedPosition.archivedId),
                        messageId: normalizedId(savedPosition.messageId),
                        authorId: nil,
                        bodyFingerprint: nil,
                        sourceDate: savedPosition.sourceDate
                    ),
                    highlight: false,
                    markReadOnVisible: false,
                    source: .savedVisiblePosition
                )
            )
        }

        return .bottom
    }

    static func normalizedUnreadBoundaryId(_ value: String?) -> String? {
        guard let normalized = normalizedId(value),
              let numericValue = Double(normalized),
              numericValue > 0 else {
            return nil
        }

        return normalized
    }

    static func archiveDate(from archivedId: String) -> Date? {
        guard let value = Double(archivedId) else {
            return nil
        }

        return Date(timeIntervalSince1970: value / 1_000_000)
    }

    static func normalizedId(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }

        return value
    }
}

enum ChatUnreadBoundaryTargetPolicy {
    struct Candidate: Equatable {
        let primary: String
        let archivedId: String?
        let messageId: String?
        let sourceDate: Date
        let isOutgoing: Bool
    }

    static func target(
        boundaryArchivedId: String,
        fallback: Candidate,
        loadedMessages: [Candidate]
    ) -> Candidate {
        guard let boundaryValue = Double(boundaryArchivedId) else {
            return fallback
        }

        return loadedMessages
            .filter { candidate in
                guard !candidate.isOutgoing,
                      let archivedId = candidate.archivedId,
                      let archivedValue = Double(archivedId) else {
                    return false
                }

                return archivedValue > boundaryValue
            }
            .min { lhs, rhs in
                (Double(lhs.archivedId ?? "") ?? .greatestFiniteMagnitude)
                    < (Double(rhs.archivedId ?? "") ?? .greatestFiniteMagnitude)
            } ?? fallback
    }
}

enum ChatVisiblePositionPolicy {
    enum RowKind {
        case message
        case date
        case unread
        case initial
        case skeleton
    }

    struct Candidate {
        let primary: String
        let archivedId: String?
        let messageId: String?
        let sentDate: Date
        let rowKind: RowKind
        let isFakeMessage: Bool
        let frame: CGRect?
    }

    static func rowKind(for kind: MessageKind) -> RowKind {
        switch kind {
        case .date:
            return .date
        case .unread:
            return .unread
        case .initial:
            return .initial
        case .skeleton:
            return .skeleton
        default:
            return .message
        }
    }

    static func savedPosition(
        candidates: [Candidate],
        viewportCenterY: CGFloat
    ) -> ChatSavedVisiblePosition? {
        let realCandidates = candidates
            .filter { candidate in
                guard !candidate.isFakeMessage else {
                    return false
                }

                switch candidate.rowKind {
                case .message:
                    return true
                case .date, .unread, .initial, .skeleton:
                    return false
                }
            }
            .filter { candidate in
                candidate.primary.isNotEmpty
                    || candidate.archivedId?.isNotEmpty == true
                    || candidate.messageId?.isNotEmpty == true
            }

        let framedCandidates = realCandidates.filter { $0.frame != nil }
        let selected: Candidate?
        if framedCandidates.isNotEmpty {
            selected = framedCandidates.min(by: { lhs, rhs in
                guard let lhsFrame = lhs.frame,
                      let rhsFrame = rhs.frame else {
                    return lhs.frame != nil
                }

                let lhsDistance = abs(lhsFrame.midY - viewportCenterY)
                let rhsDistance = abs(rhsFrame.midY - viewportCenterY)
                if lhsDistance == rhsDistance {
                    return lhsFrame.minY < rhsFrame.minY
                }

                return lhsDistance < rhsDistance
            })
        } else {
            selected = realCandidates.first
        }

        guard let selected = selected else {
            return nil
        }

        return ChatSavedVisiblePosition(
            messagePrimary: selected.primary.isNotEmpty ? selected.primary : nil,
            archivedId: selected.archivedId?.isNotEmpty == true ? selected.archivedId : nil,
            messageId: selected.messageId?.isNotEmpty == true ? selected.messageId : nil,
            sourceDate: selected.sentDate
        )
    }
}

enum ChatVisiblePositionPersistencePolicy {
    enum Action: Equatable {
        case skip
        case clearSavedPosition
        case saveAnchor(ChatSavedVisiblePosition)
    }

    static func isLiveBottom(
        isNearBottom: Bool,
        lastRealDatasourcePrimary: String?,
        observerPrimaryIndexMap: [String: Int],
        observerCount: Int
    ) -> Bool {
        guard isNearBottom,
              observerCount > 0,
              let lastRealDatasourcePrimary,
              let observerIndex = observerPrimaryIndexMap[lastRealDatasourcePrimary] else {
            return false
        }

        return observerIndex == observerCount - 1
    }

    static func action(
        candidates: [ChatVisiblePositionPolicy.Candidate],
        viewportCenterY: CGFloat,
        viewportHeight: CGFloat,
        isShowingSkeleton: Bool,
        isBlockedByAnchorNavigation: Bool,
        allowsBlockedLiveBottomClear: Bool,
        isLiveBottom: Bool
    ) -> Action {
        guard viewportHeight > 0,
              !isShowingSkeleton,
              candidates.contains(where: isRealMessageCandidate) else {
            return .skip
        }

        if isLiveBottom {
            guard !isBlockedByAnchorNavigation || allowsBlockedLiveBottomClear else {
                return .skip
            }

            return .clearSavedPosition
        }

        guard !isBlockedByAnchorNavigation,
              let position = ChatVisiblePositionPolicy.savedPosition(
                candidates: candidates,
                viewportCenterY: viewportCenterY
              ) else {
            return .skip
        }

        return .saveAnchor(position)
    }

    private static func isRealMessageCandidate(_ candidate: ChatVisiblePositionPolicy.Candidate) -> Bool {
        guard !candidate.isFakeMessage else {
            return false
        }

        switch candidate.rowKind {
        case .message:
            return candidate.primary.isNotEmpty
                || candidate.archivedId?.isNotEmpty == true
                || candidate.messageId?.isNotEmpty == true
        case .date, .unread, .initial, .skeleton:
            return false
        }
    }
}

enum ChatVisiblePositionPersistenceReason {
    case debouncedScroll
    case viewWillDisappear
    case programmaticBottom

    var allowsBlockedLiveBottomClear: Bool {
        switch self {
        case .debouncedScroll:
            return false
        case .viewWillDisappear, .programmaticBottom:
            return true
        }
    }
}

enum ChatOpenReadMarkingPolicy {
    static func shouldReadLastMessageOnOpen(isSynced: Bool, unread: Int) -> Bool {
        false
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

struct ChatAnchorDatasourceApplyPlan {
    let mode: ChatDatasourceApplyMode
    let invalidateLayout: Bool
}

enum ChatAnchorDatasourceApplyPolicy {
    static func plan(for source: ChatOpenMessageRequestSource) -> ChatAnchorDatasourceApplyPlan {
        if source == .search {
            return ChatAnchorDatasourceApplyPlan(mode: .targetedDiff, invalidateLayout: false)
        }

        return ChatAnchorDatasourceApplyPlan(mode: .fullReload(), invalidateLayout: true)
    }
}

enum ChatAnchorFailureRecoveryPolicy {
    static func shouldReapplyBootstrapState(usesBootstrapLoading: Bool) -> Bool {
        usesBootstrapLoading
    }

    static func shouldRunDefaultFailurePresentation(
        requestSource: ChatOpenMessageRequestSource?,
        usesBootstrapLoading: Bool,
        hasFailureHook: Bool
    ) -> Bool {
        if requestSource == .savedVisiblePosition {
            return false
        }

        if requestSource == .composerReferencePreview || requestSource == .composerEditPreview {
            return false
        }

        if requestSource == .initialUnreadBoundary {
            return false
        }

        return !usesBootstrapLoading && !hasFailureHook
    }

    static func shouldRunDefaultFailurePresentation(
        usesBootstrapLoading: Bool,
        hasFailureHook: Bool
    ) -> Bool {
        return self.shouldRunDefaultFailurePresentation(
            requestSource: nil,
            usesBootstrapLoading: usesBootstrapLoading,
            hasFailureHook: hasFailureHook
        )
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
    var contextPrefetchExpectedMessageCount: Int = 0
    var contextPrefetchPersistedMessageCount: Int = 0
    var didObserveContextPostIdleTick: Bool = false
    var isPositioning: Bool = false
}

struct ChatAnchorExecutionHooks {
    let direction: ChatViewController.ChatDirection
    let animatedScroll: Bool
    let onPositioningStarted: (() -> Void)?
    let onFailed: (() -> Void)?
    let onPositioned: (() -> Void)?

    init(
        direction: ChatViewController.ChatDirection,
        animatedScroll: Bool,
        onPositioningStarted: (() -> Void)? = nil,
        onFailed: (() -> Void)?,
        onPositioned: (() -> Void)?
    ) {
        self.direction = direction
        self.animatedScroll = animatedScroll
        self.onPositioningStarted = onPositioningStarted
        self.onFailed = onFailed
        self.onPositioned = onPositioned
    }
}

enum ChatDirectionalScrollStagingPolicy {
    static func stagedOffsetY(
        currentOffsetY: CGFloat,
        targetOffsetY: CGFloat,
        direction: ChatViewController.ChatDirection,
        viewportHeight: CGFloat,
        minOffsetY: CGFloat,
        maxOffsetY: CGFloat
    ) -> CGFloat? {
        let distance = max(80, min(180, viewportHeight * 0.35))
        let stagedOffset: CGFloat
        switch direction {
        case .up:
            guard currentOffsetY <= targetOffsetY else {
                return nil
            }
            stagedOffset = min(maxOffsetY, targetOffsetY + distance)
            return stagedOffset > targetOffsetY ? stagedOffset : nil
        case .down:
            guard currentOffsetY >= targetOffsetY else {
                return nil
            }
            stagedOffset = max(minOffsetY, targetOffsetY - distance)
            return stagedOffset < targetOffsetY ? stagedOffset : nil
        }
    }
}

enum ChatAnchorExecutionAction: Equatable {
    case resolveLocally
    case startRemoteFetch(ChatAnchorRemoteFetchPlan)
    case waitForObserverSync
    case fail
    case none
}

enum ChatAnchorRemoteResultDeliveryPolicy {
    static func shouldWaitForDeliveredRows(
        remoteResultCount: Int,
        persistedMessageCount: Int
    ) -> Bool {
        remoteResultCount > 0 && persistedMessageCount < remoteResultCount
    }
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

        if ChatAnchorRemoteResultDeliveryPolicy.shouldWaitForDeliveredRows(
            remoteResultCount: remoteResultCount,
            persistedMessageCount: persistedMessageCount
        ) {
            return .waitForObserverSync
        }

        return nextRemotePlan(for: state, pageSize: pageSize).map(ChatAnchorExecutionAction.startRemoteFetch) ?? .fail
    }
}

enum ChatLoadedMessageNavigationPolicy {
    static func index(
        in items: [ChatViewController.Datasource],
        for request: ChatOpenMessageRequest
    ) -> Int? {
        if case .firstIncomingAfterBoundary(let boundaryArchivedId) = request.targetResolution,
           let target = firstIncomingAfterBoundaryIndex(in: items, boundaryArchivedId: boundaryArchivedId) {
            return target
        }

        if request.source == .search,
           let target = searchIndex(in: items, for: request.anchor) {
            return target
        }

        return index(in: items, for: request.anchor)
    }

    static func index(
        in items: [ChatViewController.Datasource],
        for anchor: ChatMessageAnchorRef
    ) -> Int? {
        let anchorableItems = items.enumerated().filter { _, item in
            isAnchorable(item)
        }

        if let messagePrimary = anchor.messagePrimary,
           messagePrimary.isNotEmpty,
           let match = anchorableItems.first(where: { $0.element.primary == messagePrimary }) {
            return match.offset
        }

        if let archivedId = anchor.archivedId,
           archivedId.isNotEmpty,
           let match = anchorableItems.first(where: { $0.element.archivedId == archivedId }) {
            return match.offset
        }

        if let messageId = anchor.messageId,
           messageId.isNotEmpty,
           let match = anchorableItems.first(where: { $0.element.messageId == messageId }) {
            return match.offset
        }

        return nil
    }

    private static func searchIndex(
        in items: [ChatViewController.Datasource],
        for anchor: ChatMessageAnchorRef
    ) -> Int? {
        let anchorableItems = items.enumerated().filter { _, item in
            isAnchorable(item)
        }

        if let archivedId = anchor.archivedId,
           archivedId.isNotEmpty,
           let match = anchorableItems.first(where: { $0.element.archivedId == archivedId }) {
            return match.offset
        }

        if let messageId = anchor.messageId,
           messageId.isNotEmpty,
           let match = anchorableItems.first(where: { $0.element.messageId == messageId }) {
            return match.offset
        }

        if let messagePrimary = anchor.messagePrimary,
           messagePrimary.isNotEmpty,
           let match = anchorableItems.first(where: { $0.element.primary == messagePrimary }) {
            return match.offset
        }

        return nil
    }

    private static func firstIncomingAfterBoundaryIndex(
        in items: [ChatViewController.Datasource],
        boundaryArchivedId: String
    ) -> Int? {
        guard let boundary = Double(boundaryArchivedId) else {
            return nil
        }

        return items.enumerated()
            .filter { _, item in
                guard isAnchorable(item),
                      !item.isOutgoing,
                      let archivedId = item.archivedId,
                      let value = Double(archivedId) else {
                    return false
                }

                return value > boundary
            }
            .min { lhs, rhs in
                (Double(lhs.element.archivedId ?? "") ?? .greatestFiniteMagnitude)
                    < (Double(rhs.element.archivedId ?? "") ?? .greatestFiniteMagnitude)
            }?
            .offset
    }

    private static func isAnchorable(_ item: ChatViewController.Datasource) -> Bool {
        guard !item.isFakeMessage else {
            return false
        }

        switch item.kind {
        case .date(_), .unread(_), .initial(_), .skeleton(_):
            return false
        default:
            return true
        }
    }
}

enum ChatForwardPreviewNavigationPolicy {
    static func loadedTargetIndex(
        in items: [ChatViewController.Datasource],
        attachedMessageIds: [String]
    ) -> Int? {
        guard attachedMessageIds.isNotEmpty else {
            return nil
        }

        let attachedIds = Set(attachedMessageIds)
        return items.enumerated().first { _, item in
            attachedIds.contains(item.primary) && isAnchorable(item)
        }?.offset
    }

    private static func isAnchorable(_ item: ChatViewController.Datasource) -> Bool {
        guard !item.isFakeMessage else {
            return false
        }

        switch item.kind {
        case .date(_), .unread(_), .initial(_), .skeleton(_):
            return false
        default:
            return true
        }
    }
}

enum ChatEditPreviewNavigationPolicy {
    static func loadedTargetIndex(
        in items: [ChatViewController.Datasource],
        editMessageId: String
    ) -> Int? {
        guard editMessageId.isNotEmpty else {
            return nil
        }

        return items.enumerated().first { _, item in
            item.primary == editMessageId && isAnchorable(item)
        }?.offset
    }

    private static func isAnchorable(_ item: ChatViewController.Datasource) -> Bool {
        guard !item.isFakeMessage else {
            return false
        }

        switch item.kind {
        case .date(_), .unread(_), .initial(_), .skeleton(_):
            return false
        default:
            return true
        }
    }
}

extension ChatViewController {
    @discardableResult
    internal func reduceSearchPresentationState(
        _ event: ChatSearchPresentationState.Event
    ) -> ChatSearchPresentationState {
        assert(Thread.isMainThread, "Chat search presentation events must be reduced on the main thread")
        searchPresentationState.reduce(event)
        if isViewLoaded {
            searchNavigationView.render(
                .init(
                    query: searchPresentationState.query,
                    isRemoteSearching: searchPresentationState.resultPhase == .searching
                )
            )
        }
        return searchPresentationState
    }

    internal func applyLegacySearchPanelStateFromPresentation() {
        assert(Thread.isMainThread, "Chat search UI state must be applied on the main thread")
        guard isViewLoaded else {
            return
        }

        let renderState: ModernXabberInputView.SearchPanel.RenderState
        switch searchPresentationState.legacyPanelState {
        case .idle:
            renderState = .idle
        case .loading:
            renderState = .loading
        case .emptyResults:
            renderState = .emptyResults
        case .results(let current, let total, let isLoadingContext):
            renderState = .results(
                current: current,
                total: total,
                isLoadingContext: isLoadingContext
            )
        }
        applyInChatSearchPanelRenderState(renderState)
    }

    internal func activateSearchModeFromExternalRoute(
        activateKeyboard: Bool = true,
        animated: Bool = true,
        initialQuery: String? = nil
    ) {
        let request = ChatSearchActivationRequest(
            activateKeyboard: activateKeyboard,
            animated: animated,
            initialQuery: initialQuery
        )
        pendingSearchActivationRequest = request
        reduceSearchPresentationState(.activate)

        if !inSearchMode.value {
            inSearchMode.accept(true)
        }

        guard isViewLoaded else {
            return
        }

        configureSearchModeForCurrentActivation(
            defaultActivateKeyboard: activateKeyboard,
            defaultAnimated: animated
        )
    }

    internal func configureSearchModeForCurrentActivation(
        defaultActivateKeyboard: Bool,
        defaultAnimated: Bool
    ) {
        reduceSearchPresentationState(.activate)
        let request = pendingSearchActivationRequest
        pendingSearchActivationRequest = nil

        if let initialQuery = request?.initialQuery {
            searchBar.text = initialQuery
            searchInputBar.text = initialQuery
        }

        configureSearchBar(
            activateKeyboard: request?.activateKeyboard ?? defaultActivateKeyboard,
            animated: request?.animated ?? defaultAnimated
        )

        if let initialQuery = request?.initialQuery {
            reduceSearchPresentationState(.queryChanged(initialQuery))
            searchTextObserver.accept(initialQuery)
        }
    }

    internal func submitSearchTextFromSearchInput(_ text: String?) {
        let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        searchBar.text = text
        if isViewLoaded {
            searchInputBar.text = text
        }

        if normalizedText.isEmpty {
            reduceSearchPresentationState(.queryChanged(""))
            applySearchSessionEffects(searchSession.cancel())
            clearInChatSearchQuery(clearResults: true, panelState: .idle)
            searchTextObserver.accept(nil)
            return
        }

        if showSkeletonObserver.value {
            return
        }

        if searchPresentationState.query != normalizedText {
            reduceSearchPresentationState(.queryChanged(normalizedText))
        }
        acceptSearchSessionQuery(normalizedText, flushImmediately: true)
        searchTextObserver.accept(normalizedText)
    }

    internal func acceptSearchSessionQuery(
        _ text: String?,
        flushImmediately: Bool
    ) {
        let normalizedText = ChatInChatSearchQueryContext.normalizedText(text ?? "")
        if normalizedText.isEmpty {
            reduceSearchPresentationState(.queryChanged(""))
            applySearchSessionEffects(searchSession.accept(query: text, scope: currentSearchSessionScope))
            clearInChatSearchQuery(clearResults: true, panelState: .idle)
            return
        }

        if !searchPresentationState.isActive {
            reduceSearchPresentationState(.activate)
        }
        if searchPresentationState.query != normalizedText {
            reduceSearchPresentationState(.queryChanged(normalizedText))
        }

        let previousGeneration = searchSession.generation
        let effects = searchSession.accept(query: normalizedText, scope: currentSearchSessionScope)
        applySearchSessionEffects(effects)
        if searchSession.generation != previousGeneration {
            clearInChatSearchQuery(clearResults: true, panelState: nil)
        }
        if flushImmediately {
            applySearchSessionEffects(searchSession.flush())
        }
    }

    internal func applySearchSessionEffects(_ effects: [ChatSearchSession.Effect]) {
        for effect in effects {
            switch effect {
            case .cancelDebounce(let generation):
                guard searchSessionDebounceGeneration == generation else {
                    continue
                }
                searchSessionDebounceWorkItem?.cancel()
                searchSessionDebounceWorkItem = nil
                searchSessionDebounceGeneration = nil
            case .scheduleDebounce(let request, let milliseconds):
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self,
                          self.searchSessionDebounceGeneration == request.generation else {
                        return
                    }
                    self.searchSessionDebounceWorkItem = nil
                    self.searchSessionDebounceGeneration = nil
                    self.applySearchSessionEffects(
                        self.searchSession.debounceElapsed(generation: request.generation)
                    )
                }
                searchSessionDebounceWorkItem = workItem
                searchSessionDebounceGeneration = request.generation
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(milliseconds),
                    execute: workItem
                )
            case .cancelProviderRequest(let generation):
                let queryIds = searchSessionGenerationByQueryId.compactMap { queryId, value in
                    value == generation ? queryId : nil
                }
                let cancelsCurrentQuery = currentSearchQueryId.map(queryIds.contains) == true
                queryIds.forEach { queryId in
                    _ = searchLocalProvider.cancel(queryId: queryId, generation: generation)
                    searchArchiveManagersByQueryId.removeValue(forKey: queryId)?.cancelSearch(
                        queryId: queryId
                    )
                    unregisterRemoteHistoryPersistenceSource(queryId: queryId)
                    searchSessionGenerationByQueryId.removeValue(forKey: queryId)
                }
                if cancelsCurrentQuery {
                    currentSearchQueryId = nil
                    currentInChatSearchQueryContext = nil
                }
            case .startProviderRequest(let request):
                guard searchSession.isCurrentRequest(request) else {
                    continue
                }
                setLoadingIndicatorVisible(true)
                executeSearchRequest(request)
            case .cancelDateResolver:
                break
            case .cancelPendingNavigation:
                cancelSearchResultNavigation()
            }
        }
    }

    private var currentSearchSessionScope: ChatSearchSession.Scope {
        ChatSearchSession.Scope(
            owner: owner,
            jid: jid,
            conversationTypeRawValue: conversationType.rawValue,
            isEncrypted: conversationType.isEncrypted
        )
    }

    internal func cancelSearchModeFromSearchUI() {
        if isViewLoaded && showSkeletonObserver.value {
            return
        }

        reduceSearchPresentationState(.cancelSearch)
        applySearchSessionEffects(searchSession.cancel())
        clearInChatSearchQuery(clearResults: true, panelState: .idle)
        pendingSearchActivationRequest = nil
        searchBar.text = nil
        inSearchMode.accept(false)
        searchTextObserver.accept(nil)

        guard isViewLoaded else {
            return
        }

        searchInputBar.text = nil
        searchBar.endEditing(true)
        searchInputBar.endEditing(true)
        hideSearchInputOverlay()
        xabberInputView.changeState(to: .normal)
        let inputHeight = updateChatInputViewForCurrentKeyboardLayout(visibleKeyboardHeight: 0)
        updateChatCollectionInsets(inputHeight: inputHeight)
        becomeFirstResponder()
        navigationItem.setHidesBackButton(false, animated: false)
        messagesCollectionView.reloadDataAndKeepOffset()
        UIView.performWithoutAnimation {
            configureNavbar()
        }
    }

    @discardableResult
    internal func beginInChatSearchQueryIfNeeded(
        text: String,
        queryId: String? = nil
    ) -> ChatInChatSearchQueryContext? {
        let normalizedText = ChatInChatSearchQueryContext.normalizedText(text)
        guard normalizedText.isNotEmpty else {
            clearInChatSearchQuery(clearResults: true, panelState: .idle)
            return nil
        }

        if let currentInChatSearchQueryContext,
           currentInChatSearchQueryContext.matchesSearchScope(
               owner: owner,
               jid: jid,
               conversationType: conversationType,
               text: normalizedText
           ) {
            return nil
        }

        clearInChatSearchQuery(clearResults: true, panelState: nil)

        let resolvedQueryId = queryId ?? "MAM search: \(NanoID.new(8))"
        let context = ChatInChatSearchQueryContext(
            queryId: resolvedQueryId,
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            text: normalizedText
        )
        currentSearchQueryId = context.queryId
        currentInChatSearchQueryContext = context
        selectedSearchResultId = nil
        return context
    }

    internal func clearInChatSearchQuery(
        clearResults: Bool,
        panelState: ModernXabberInputView.SearchPanel.RenderState? = nil,
        cancelResultNavigation: Bool = true
    ) {
        if let currentSearchQueryId {
            if let generation = searchSessionGenerationByQueryId[currentSearchQueryId] {
                _ = searchLocalProvider.cancel(
                    queryId: currentSearchQueryId,
                    generation: generation
                )
            }
            unregisterRemoteHistoryPersistenceSource(queryId: currentSearchQueryId)
            searchSessionGenerationByQueryId.removeValue(forKey: currentSearchQueryId)
            searchArchiveManagersByQueryId.removeValue(forKey: currentSearchQueryId)
        }
        currentSearchQueryId = nil
        currentInChatSearchQueryContext = nil
        if clearResults {
            selectedSearchResultId = nil
            searchMessagesQueue = []
            searchResultPresentations = []
        } else if searchMessagesQueue.isEmpty {
            selectedSearchResultId = nil
        }
        refreshVisibleSearchSelection()
        if clearResults {
            clearVisibleSearchTextHighlightsIfNeeded()
        }
        if cancelResultNavigation {
            cancelSearchResultNavigation()
            setLoadingIndicatorVisible(false)
        }
        guard isViewLoaded else {
            return
        }
        if let panelState {
            applyInChatSearchPanelRenderState(panelState)
        }
    }

    internal func applyInChatSearchPanelRenderState(
        _ renderState: ModernXabberInputView.SearchPanel.RenderState
    ) {
        xabberInputView.searchPanel.applyRenderState(renderState)
        hideDuplicateBottomSearchCancelIfNeeded()
    }

    internal func clearVisibleSearchTextHighlightsIfNeeded() {
        guard isViewLoaded,
              datasource.contains(where: { $0.searchString != nil }) else {
            return
        }
        applyChatDatasource(
            Self.datasourceByClearingSearchTextHighlights(datasource),
            mode: .fullReload(keepOffset: true),
            animated: false,
            invalidateLayout: true,
            suppressDefaultBottomScroll: true
        )
    }

    internal static func datasourceByClearingSearchTextHighlights(_ items: [Datasource]) -> [Datasource] {
        items.map { item in
            guard item.searchString != nil else {
                return item
            }
            var cleared = item
            cleared.searchString = nil
            if case .attributedText(let text) = item.kind {
                let mutable = NSMutableAttributedString(attributedString: text)
                if mutable.length > 0 {
                    mutable.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: mutable.length))
                }
                cleared.kind = .attributedText(mutable)
            }
            return cleared
        }
    }

    internal func isCurrentInChatSearchQuery(queryId: String) -> Bool {
        currentInChatSearchQueryContext?.queryId == queryId &&
        currentSearchQueryId == queryId &&
        currentInChatSearchQueryContext?.owner == owner &&
        currentInChatSearchQueryContext?.jid == jid &&
        currentInChatSearchQueryContext?.conversationType == conversationType
    }

    internal func acceptsInChatSearchResult(_ item: MessageStorageItem, queryId: String) -> Bool {
        guard isCurrentInChatSearchQuery(queryId: queryId),
              let currentInChatSearchQueryContext else {
            return false
        }
        return currentInChatSearchQueryContext.accepts(item)
    }

    @discardableResult
    internal func appendInChatSearchResultIfCurrent(_ item: MessageStorageItem, queryId: String) -> Bool {
        guard acceptsInChatSearchResult(item, queryId: queryId) else {
            return false
        }
        guard let result = ChatSearchResultMapper.map(
            item,
            context: inChatSearchResultMappingContext
        ) else {
            return false
        }
        if let generation = searchSessionGenerationByQueryId[queryId],
           !searchSession.receive(.result(generation: generation, id: result.id)) {
            return false
        }

        if let existingIndex = searchMessagesQueue.firstIndex(where: { existing in
            guard let existingResult = ChatSearchResultMapper.map(
                existing,
                context: inChatSearchResultMappingContext
            ) else {
                return false
            }
            return existingResult.id == result.id ||
                (existing.primary.isNotEmpty && existing.primary == item.primary)
        }),
           let existingResult = ChatSearchResultMapper.map(
               searchMessagesQueue[existingIndex],
               context: inChatSearchResultMappingContext
           ) {
            let shouldReplacePrimaryFallback = {
                if case .primary = existingResult.id,
                   case .archived = result.id {
                    return true
                }
                return false
            }()
            let preferred = ChatSearchResultCollection.preferred(existingResult, result)
            guard shouldReplacePrimaryFallback || preferred == result && preferred != existingResult else {
                return false
            }
            searchMessagesQueue[existingIndex] = item
            refreshSearchResultPresentations()
            return true
        }

        searchMessagesQueue.append(item)
        refreshSearchResultPresentations()
        return true
    }

    @discardableResult
    internal func appendDetachedInChatSearchResultsIfCurrent(
        _ results: [ChatSearchResult],
        queryId: String
    ) -> Bool {
        guard isCurrentInChatSearchQuery(queryId: queryId),
              let context = currentInChatSearchQueryContext,
              let generation = searchSessionGenerationByQueryId[queryId] else {
            return false
        }
        let expectedScope = ChatSearchResult.Scope(
            owner: context.owner,
            jid: context.jid,
            conversationTypeRawValue: context.conversationType.rawValue
        )
        let accepted = results.filter { result in
            result.scope == expectedScope &&
            searchSession.receive(.result(generation: generation, id: result.id))
        }
        guard accepted.isNotEmpty else {
            return false
        }
        searchResultPresentations = ChatSearchResultCollection.orderedAndDeduplicated(
            searchResultPresentations + accepted
        )
        searchMessagesQueue = searchResultPresentations.map(Self.legacySearchMessage)
        return true
    }

    private static func legacySearchMessage(_ result: ChatSearchResult) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = result.anchor.primary
        item.archivedId = result.anchor.archivedId
        item.messageId = result.anchor.messageId
        item.owner = result.scope.owner
        item.opponent = result.scope.jid
        item.conversationType_ = result.scope.conversationTypeRawValue
        item.body = result.body
        item.date = result.anchor.date
        item.outgoing = result.outgoing
        switch result.deliveryState {
        case .sent:
            item.state = .sended
        case .delivered:
            item.state = .deliver
        case .read:
            item.state = .read
        case .failed:
            item.state = .error
        case .pending:
            item.state = .none
        }
        return item
    }

    internal func normalizedInChatSearchResultsForDisplay(_ results: [MessageStorageItem]) -> [MessageStorageItem] {
        let mapped = results.compactMap { item -> (MessageStorageItem, ChatSearchResult)? in
            guard let result = ChatSearchResultMapper.map(
                item,
                context: inChatSearchResultMappingContext
            ) else {
                return nil
            }
            return (item, result)
        }
        let ordered = ChatSearchResultCollection.orderedAndDeduplicated(mapped.map(\.1))
        searchResultPresentations = ordered
        return ordered.compactMap { result in
            mapped.first(where: { $0.1 == result })?.0
        }
    }

    internal func refreshSearchResultPresentations() {
        searchResultPresentations = ChatSearchResultCollection.orderedAndDeduplicated(
            searchMessagesQueue.compactMap {
                ChatSearchResultMapper.map($0, context: inChatSearchResultMappingContext)
            }
        )
    }

    internal var inChatSearchResultMappingContext: ChatSearchResultMappingContext {
        let localizedYou = "You:".localizeString(id: "you", arguments: [])
            .trimmingCharacters(in: CharacterSet(charactersIn: ":： ").union(.whitespacesAndNewlines))
        return ChatSearchResultMappingContext(
            scope: ChatSearchResult.Scope(
                owner: owner,
                jid: jid,
                conversationTypeRawValue: conversationType.rawValue
            ),
            localizedYou: localizedYou,
            contactDisplayName: opponentSender.displayName.isNotEmpty
                ? opponentSender.displayName
                : jid
        )
    }

    internal func searchResultSelectionIdentity(for item: MessageStorageItem) -> String? {
        if item.archivedId.isNotEmpty {
            return item.archivedId
        }
        return item.primary.isNotEmpty ? item.primary : nil
    }

    internal func searchResultIdentity(for item: MessageStorageItem) -> ChatSearchResult.ID? {
        if item.archivedId.isNotEmpty {
            return .archived(item.archivedId)
        }
        return item.primary.isNotEmpty ? .primary(item.primary) : nil
    }

    internal func searchResultItem(
        _ item: MessageStorageItem,
        matchesSelection selectedId: String?
    ) -> Bool {
        guard let selectedId,
              selectedId.isNotEmpty else {
            return false
        }
        if item.archivedId.isNotEmpty,
           item.archivedId == selectedId {
            return true
        }
        return item.primary == selectedId
    }

    internal func chatDatasourceItem(
        _ item: Datasource,
        matchesSearchSelection selectedId: String?
    ) -> Bool {
        guard let selectedId,
              selectedId.isNotEmpty else {
            return false
        }

        if let archivedId = item.archivedId,
           archivedId.isNotEmpty,
           archivedId == selectedId {
            return true
        }
        return item.primary == selectedId
    }

    internal func refreshVisibleSearchSelection() {
        guard isViewLoaded else {
            return
        }

        let selectedId = (inSearchMode.value || xabberInputView.state == .search)
            ? selectedSearchResultId
            : nil
        messagesCollectionView.visibleCells
            .compactMap { $0 as? MessageContentCell }
            .forEach { cell in
                guard let indexPath = messagesCollectionView.indexPath(for: cell),
                      let item = datasourceItem(at: indexPath) else {
                    cell.setSelected(state: false)
                    return
                }
                cell.setSelected(
                    state: chatDatasourceItem(
                        item,
                        matchesSearchSelection: selectedId
                    )
                )
            }
    }

    @discardableResult
    internal func finishInChatSearchQueryIfCurrent(
        queryId: String,
        emptyList: Bool
    ) -> Bool {
        guard isCurrentInChatSearchQuery(queryId: queryId) else {
            return false
        }
        if let generation = searchSessionGenerationByQueryId[queryId],
           !searchSession.receive(.finished(generation: generation)) {
            return false
        }
        applySearchResults(emptyList: emptyList)
        clearInChatSearchQuery(clearResults: false, panelState: nil, cancelResultNavigation: false)
        return true
    }

    @discardableResult
    internal func handleInChatSearchQueryFailure(queryId: String) -> Bool {
        guard isCurrentInChatSearchQuery(queryId: queryId) else {
            return false
        }
        if let generation = searchSessionGenerationByQueryId[queryId],
           !searchSession.receive(.failed(generation: generation)) {
            return false
        }
        reduceSearchPresentationState(
            .failed(generation: searchPresentationState.generation)
        )
        clearInChatSearchQuery(clearResults: true, panelState: .emptyResults)
        return true
    }

    internal func applySearchResultsPanelState(isLoadingContext: Bool? = nil) {
        guard isViewLoaded else {
            return
        }

        let queryText = searchTextObserver.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasActiveQuery = queryText.isNotEmpty || currentSearchQueryId != nil

        guard hasActiveQuery else {
            applyInChatSearchPanelRenderState(.idle)
            return
        }

        guard searchMessagesQueue.isNotEmpty else {
            if xabberInputView.searchPanel.isInLoadingState {
                applyInChatSearchPanelRenderState(.loading)
            } else {
                applyInChatSearchPanelRenderState(.emptyResults)
            }
            return
        }

        let currentIndex = currentSearchResultIndexForPanel()
        applyInChatSearchPanelRenderState(
            .results(
                current: currentIndex,
                total: searchMessagesQueue.count,
                isLoadingContext: isLoadingContext ?? xabberInputView.searchPanel.renderState.isLoadingContext
            )
        )
    }

    private func currentSearchResultIndexForPanel() -> Int {
        if let selectedSearchResultId,
           let selectedIndex = searchMessagesQueue.firstIndex(where: {
               searchResultItem($0, matchesSelection: selectedSearchResultId)
           }) {
            return selectedIndex
        }

        return searchMessagesQueue.isEmpty ? -1 : 0
    }

    private func setSearchResultsPanelContextLoading(_ isLoadingContext: Bool) {
        guard isViewLoaded,
              inSearchMode.value || xabberInputView.state == .search else {
            return
        }

        applySearchResultsPanelState(isLoadingContext: isLoadingContext)
    }

    internal func cancelSearchResultNavigation() {
        searchResultNavigationState = .idle
        guard isViewLoaded else {
            return
        }
        applySearchResultsPanelState(isLoadingContext: false)
    }

    internal func nextSearchResultIndex(
        from index: Int,
        direction: ChatDirection
    ) -> Int? {
        guard searchMessagesQueue.count > 1,
              searchMessagesQueue.indices.contains(index) else {
            return nil
        }

        switch direction {
        case .up:
            let nextIndex = index + 1
            return nextIndex >= searchMessagesQueue.count ? 0 : nextIndex
        case .down:
            let nextIndex = index - 1
            return nextIndex < 0 ? searchMessagesQueue.count - 1 : nextIndex
        }
    }

    internal func scrollDirectionForSearchNavigation(
        from currentIndex: Int,
        to nextIndex: Int,
        requestedDirection: ChatDirection
    ) -> ChatDirection {
        guard searchMessagesQueue.count > 1 else {
            return requestedDirection
        }

        let lastIndex = searchMessagesQueue.count - 1
        switch requestedDirection {
        case .up:
            return currentIndex == lastIndex && nextIndex == 0 ? .down : .up
        case .down:
            return currentIndex == 0 && nextIndex == lastIndex ? .up : .down
        }
    }

    internal func consumePendingSearchResultNavigation(finishedIndex: Int) -> ChatSearchPendingNavigation? {
        guard case .pending(let pendingIndex, let scrollDirection) = searchResultNavigationState else {
            searchResultNavigationState = .idle
            return nil
        }

        searchResultNavigationState = .idle
        guard pendingIndex != finishedIndex,
              searchMessagesQueue.indices.contains(pendingIndex) else {
            return nil
        }
        return ChatSearchPendingNavigation(index: pendingIndex, scrollDirection: scrollDirection)
    }

    private func currentSearchResultNavigationBaseIndex() -> Int? {
        if case .pending(let index, _) = searchResultNavigationState,
           searchMessagesQueue.indices.contains(index) {
            return index
        }

        if let index = searchResultNavigationState.currentIndex,
           searchMessagesQueue.indices.contains(index) {
            return index
        }

        if let selectedSearchResultId,
           let selectedIndex = searchMessagesQueue.firstIndex(where: {
               searchResultItem($0, matchesSelection: selectedSearchResultId)
           }) {
            return selectedIndex
        }

        return searchMessagesQueue.isEmpty ? nil : 0
    }

    private func setSelectedSearchResultNavigationIndex(
        _ index: Int,
        isLoadingContext: Bool
    ) {
        guard searchMessagesQueue.indices.contains(index) else {
            return
        }

        selectedSearchResultId = searchResultSelectionIdentity(for: searchMessagesQueue[index])
        refreshVisibleSearchSelection()
        guard isViewLoaded else {
            return
        }
        applyInChatSearchPanelRenderState(
            .results(
                current: index,
                total: searchMessagesQueue.count,
                isLoadingContext: isLoadingContext
            )
        )
    }

    internal func markSearchResultNavigationPositioningStarted(index: Int) {
        reduceSearchPresentationState(
            .navigationStarted(
                index: index,
                generation: searchPresentationState.generation
            )
        )
        if searchMessagesQueue.indices.contains(index) {
            searchResultNavigationState = .positioning(index: index)
        }
        scheduleStaleSearchResultPositioningCompletionFallback(finishedIndex: index)
    }

    internal func commitSearchResultNavigationPositioned(index: Int) {
        guard searchMessagesQueue.indices.contains(index) else {
            if !completeSearchResultNavigation(index: index) {
                flushPendingArchiveObserverRefreshIfPossible(reason: "searchPositionedInvalidIndex")
            }
            return
        }

        reduceSearchPresentationState(
            .resultCommitted(
                index: index,
                generation: searchPresentationState.generation
            )
        )
        if let id = searchResultIdentity(for: searchMessagesQueue[index]) {
            _ = searchSession.positioningSucceeded(
                generation: searchSession.generation,
                id: id
            )
        }
        setSelectedSearchResultNavigationIndex(index, isLoadingContext: false)
        if !completeSearchResultNavigation(index: index) {
            flushPendingArchiveObserverRefreshIfPossible(reason: "searchPositioned")
        }
    }

    private func hasActiveSearchResultAnchorWork() -> Bool {
        currentPage.locked ||
        pendingOpenMessageRequest != nil ||
        activeAnchorExecutionState != nil ||
        isApplyingBootstrapAnchorWindow ||
        isMessageAnchorNavigationInFlight
    }

    @discardableResult
    internal func completeStaleSearchResultPositioningIfNeeded(finishedIndex: Int) -> Bool {
        guard !hasActiveSearchResultAnchorWork() else {
            return false
        }

        switch searchResultNavigationState {
        case .positioning(let currentIndex) where currentIndex == finishedIndex:
            completeSearchResultNavigation(index: finishedIndex)
            return true
        case .pending:
            completeSearchResultNavigation(index: finishedIndex)
            return true
        case .idle, .loadingContext, .positioning:
            return false
        }
    }

    private func scheduleStaleSearchResultPositioningCompletionFallback(finishedIndex: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.completeStaleSearchResultPositioningIfNeeded(finishedIndex: finishedIndex)
        }
    }

    private func scheduleInitialSearchResultOpenFallback(
        index: Int,
        direction: ChatDirection,
        attempt: Int = 0,
        onNavigationFinished: (() -> Void)? = nil
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self,
                  self.inSearchMode.value || self.xabberInputView.state == .search,
                  self.searchMessagesQueue.indices.contains(index),
                  self.selectedSearchResultId == nil,
                  self.currentSearchResultNavigationBaseIndex() == index else {
                return
            }

            guard !self.hasActiveSearchResultAnchorWork() else {
                if attempt < 4 {
                    self.scheduleInitialSearchResultOpenFallback(
                        index: index,
                        direction: direction,
                        attempt: attempt + 1,
                        onNavigationFinished: onNavigationFinished
                    )
                }
                return
            }

            self.openSearchResult(
                at: index,
                direction: direction,
                onNavigationFinished: onNavigationFinished
            )
        }
    }

    private func recordPendingSearchResultNavigation(
        index: Int,
        scrollDirection: ChatDirection
    ) {
        guard searchMessagesQueue.indices.contains(index) else {
            return
        }

        chatScrollDirection = scrollDirection
        searchResultNavigationState = .pending(index: index, scrollDirection: scrollDirection)
        if hasActiveSearchResultAnchorWork() ||
            xabberInputView.searchPanel.renderState.isLoadingContext {
            setSearchResultsPanelContextLoading(true)
        }
    }

    internal func markSearchResultNavigationLoadingContext(for request: ChatOpenMessageRequest) {
        guard request.source == .search,
              let index = searchMessagesQueue.firstIndex(where: { item in
                  item.archivedId == request.anchor.archivedId ||
                  item.primary == request.anchor.messagePrimary ||
                  (item.messageId.isNotEmpty && item.messageId == request.anchor.messageId)
              }) else {
            return
        }

        switch searchResultNavigationState {
        case .positioning:
            searchResultNavigationState = .loadingContext(index: index)
            searchSession.setContextLoading(true)
        case .loadingContext, .pending(_, _), .idle:
            return
        }
    }

    @discardableResult
    internal func completeSearchResultNavigation(index: Int) -> Bool {
        reduceSearchPresentationState(
            .navigationFinished(generation: searchPresentationState.generation)
        )
        let pendingNavigation = consumePendingSearchResultNavigation(finishedIndex: index)
        searchSession.setContextLoading(false)

        guard let pendingNavigation else {
            setSearchResultsPanelContextLoading(false)
            refreshVisibleSearchSelection()
            return false
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.openSearchResult(
                at: pendingNavigation.index,
                direction: pendingNavigation.scrollDirection
            )
        }
        return true
    }

    private func openSearchResult(
        at index: Int,
        direction: ChatDirection,
        onNavigationFinished: (() -> Void)? = nil
    ) {
        guard searchMessagesQueue.indices.contains(index) else {
            searchResultNavigationState = .idle
            onNavigationFinished?()
            return
        }

        let item = searchMessagesQueue[index]
        searchSession.beginPendingNavigation()
        chatScrollDirection = direction
        let archivedId = item.archivedId.isNotEmpty ? item.archivedId : nil
        let request = ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: archivedId == nil ? item.primary : nil,
                archivedId: archivedId,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: item.date
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .search
        )

        searchResultNavigationState = .positioning(index: index)
        reduceSearchPresentationState(
            .navigationStarted(
                index: index,
                generation: searchPresentationState.generation
            )
        )
        setSearchResultsPanelContextLoading(
            shouldShowSearchResultContextLoading(for: request)
        )

        queueOpenMessageRequest(
            request,
            hooks: ChatAnchorExecutionHooks(
                direction: direction,
                animatedScroll: true,
                onPositioningStarted: { [weak self] in
                    self?.markSearchResultNavigationPositioningStarted(index: index)
                },
                onFailed: { [weak self] in
                    self?.completeSearchResultNavigation(index: index)
                    onNavigationFinished?()
                },
                onPositioned: { [weak self] in
                    self?.commitSearchResultNavigationPositioned(index: index)
                    onNavigationFinished?()
                }
            )
        )
    }

    private func shouldShowSearchResultContextLoading(
        for request: ChatOpenMessageRequest
    ) -> Bool {
        guard request.source == .search else {
            return false
        }

        guard self.indexPathForLoadedMessage(request: request) != nil else {
            return true
        }

        return ChatAnchorContextPrefetchModePolicy.mode(
            for: request.source,
            hasLocalMatch: true,
            isSynced: self.currentChatIsSyncedForAnchorBootstrap()
        ) == .blocking
    }

    private func navigateSearchResult(direction: ChatDirection) {
        guard let baseIndex = currentSearchResultNavigationBaseIndex(),
              let nextIndex = nextSearchResultIndex(from: baseIndex, direction: direction) else {
            return
        }
        let scrollDirection = scrollDirectionForSearchNavigation(
            from: baseIndex,
            to: nextIndex,
            requestedDirection: direction
        )

        FeedbackManager.shared.generate(feedback: .success)

        if currentPage.locked || searchResultNavigationState.isBusy {
            recordPendingSearchResultNavigation(index: nextIndex, scrollDirection: scrollDirection)
            return
        }

        openSearchResult(at: nextIndex, direction: scrollDirection)
    }

    private struct ResolvedJumpTarget {
        let primary: String
        let archivedId: String?
    }

    internal func queueOpenMessageRequest(
        _ request: ChatOpenMessageRequest,
        hooks: ChatAnchorExecutionHooks? = nil
    ) {
        guard ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: request.source) else {
            self.handleSuppressedOpenMessageRequest(animated: hooks?.animatedScroll ?? false)
            return
        }

        if self.performLoadedOpenMessageRequestIfPossible(request, hooks: hooks) {
            return
        }
        if request.source == .search {
            self.markSearchResultNavigationLoadingContext(for: request)
            self.setSearchResultsPanelContextLoading(true)
        }
        if self.activeAnchorExecutionState?.request != request {
            self.activeAnchorExecutionState = nil
        }
        self.pendingOpenMessageRequest = request
        self.activeAnchorExecutionHooks = hooks
        self.syncAnchorExecutionFlags()
        self.performPendingOpenMessageRequestIfNeeded(trigger: .manual)
    }

    private func handleSuppressedOpenMessageRequest(animated: Bool) {
        self.requestForceLatestOpen(animated: animated)
    }

    internal func clearSuppressedOpenMessageRequestState() {
        if let executionState = self.activeAnchorExecutionState {
            if let remoteQueryId = executionState.remoteQueryId {
                self.unregisterRemoteHistoryPersistenceSource(queryId: remoteQueryId)
            }
            executionState.contextPrefetchQueryIds.forEach {
                self.unregisterRemoteHistoryPersistenceSource(queryId: $0)
            }
        }

        self.pendingOpenMessageRequest = nil
        self.activeAnchorExecutionState = nil
        self.activeAnchorExecutionHooks = nil
        self.isApplyingBootstrapAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setSearchAnchorNavigationScrollLocked(false)

        guard self.isViewLoaded else {
            return
        }

        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setDatasourceLoadingEnabled(true)
        self.currentPage.unlock()
    }

    private func syncAnchorExecutionFlags() {
        self.isExecutingOpenMessageRequest = self.activeAnchorExecutionState != nil
        self.isMessageAnchorNavigationInFlight = self.pendingOpenMessageRequest != nil || self.activeAnchorExecutionState != nil
    }

    private func setSearchAnchorNavigationScrollLocked(_ locked: Bool) {
        guard self.isViewLoaded else {
            return
        }

        if locked {
            if self.searchAnchorNavigationWasScrollEnabled == nil {
                self.searchAnchorNavigationWasScrollEnabled = self.messagesCollectionView.isScrollEnabled
            }
            self.messagesCollectionView.isScrollEnabled = false
        } else if let wasScrollEnabled = self.searchAnchorNavigationWasScrollEnabled {
            self.messagesCollectionView.isScrollEnabled = wasScrollEnabled
            self.searchAnchorNavigationWasScrollEnabled = nil
        }
    }

    private func setSearchAnchorNavigationScrollLockedIfNeeded(
        _ locked: Bool,
        for request: ChatOpenMessageRequest
    ) {
        guard request.source == .search else {
            return
        }

        self.setSearchAnchorNavigationScrollLocked(locked)
    }

    internal func saveCurrentVisibleMessagePositionIfNeeded(
        reason: ChatVisiblePositionPersistenceReason = .debouncedScroll
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.saveCurrentVisibleMessagePositionIfNeeded(reason: reason)
            }
            return
        }

        let candidates = self.visiblePositionPersistenceCandidates()
        let viewportCenterY = self.messagesCollectionView.contentOffset.y + (self.messagesCollectionView.bounds.height / 2)
        self.ensureObserverLookupMaps()
        let isLiveBottom = ChatVisiblePositionPersistencePolicy.isLiveBottom(
            isNearBottom: self.isNearBottom(),
            lastRealDatasourcePrimary: self.lastRealDatasourceMessagePrimary(),
            observerPrimaryIndexMap: self.observerPrimaryIndexMap,
            observerCount: self.messagesObserver?.count ?? 0
        )
        let isBlockedByAnchorNavigation = self.isApplyingBootstrapAnchorWindow
            || self.pendingOpenMessageRequest != nil
            || self.activeAnchorExecutionState != nil
            || self.isMessageAnchorNavigationInFlight
        let action = ChatVisiblePositionPersistencePolicy.action(
            candidates: candidates,
            viewportCenterY: viewportCenterY,
            viewportHeight: self.messagesCollectionView.bounds.height,
            isShowingSkeleton: self.showSkeletonObserver.value,
            isBlockedByAnchorNavigation: isBlockedByAnchorNavigation,
            allowsBlockedLiveBottomClear: reason.allowsBlockedLiveBottomClear,
            isLiveBottom: isLiveBottom
        )

        guard action != .skip else {
            return
        }

        do {
            let realm = try WRealm.safe()
            guard let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            ) else {
                return
            }

            let savedAtLastMessageId = chat.lastMessageId
            let savedAtSnapshotLastArchiveId = chat.syncSnapshotLastArchiveId
            try realm.write {
                switch action {
                case .skip:
                    break
                case .clearSavedPosition:
                    chat.lastVisibleMessagePrimary = nil
                    chat.lastVisibleMessageArchivedId = nil
                    chat.lastVisibleMessageId = nil
                    chat.lastVisibleMessageDate = nil
                case .saveAnchor(let position):
                    chat.lastVisibleMessagePrimary = position.messagePrimary
                    chat.lastVisibleMessageArchivedId = position.archivedId
                    chat.lastVisibleMessageId = position.messageId
                    chat.lastVisibleMessageDate = position.sourceDate
                }
                chat.lastVisiblePositionSavedAtLastMessageId = savedAtLastMessageId
                chat.lastVisiblePositionSavedAtSnapshotLastArchiveId = savedAtSnapshotLastArchiveId
                chat.lastVisiblePositionUpdatedAt = Date()
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }

    private func visiblePositionPersistenceCandidates() -> [ChatVisiblePositionPolicy.Candidate] {
        let layout = self.messagesCollectionView.collectionViewLayout
        let visibleIndexPaths = self.messagesCollectionView.indexPathsForVisibleItems.sorted {
            if $0.section != $1.section {
                return $0.section < $1.section
            }
            return $0.item < $1.item
        }

        return visibleIndexPaths.compactMap { indexPath in
            guard self.datasource.indices.contains(indexPath.section) else {
                return nil
            }

            guard let item = self.datasourceItem(at: indexPath) else {
                return nil
            }
            let frame = layout.layoutAttributesForItem(at: indexPath)?.frame
                ?? self.messagesCollectionView.cellForItem(at: indexPath)?.frame

            return ChatVisiblePositionPolicy.Candidate(
                primary: item.primary,
                archivedId: item.archivedId,
                messageId: item.messageId,
                sentDate: item.sentDate,
                rowKind: ChatVisiblePositionPolicy.rowKind(for: item.kind),
                isFakeMessage: item.isFakeMessage,
                frame: frame
            )
        }
    }

    private func lastRealDatasourceMessagePrimary() -> String? {
        self.datasource.last { item in
            guard !item.isFakeMessage,
                  item.primary.isNotEmpty else {
                return false
            }

            return ChatVisiblePositionPolicy.rowKind(for: item.kind) == .message
        }?.primary
    }

    internal func scheduleSavedVisiblePositionFlushAfterBottomScroll(animated: Bool) {
        let flush: () -> Void = { [weak self] in
            guard let self else { return }
            self.messagesCollectionView.layoutIfNeeded()
            self.saveCurrentVisibleMessagePositionIfNeeded(reason: .programmaticBottom)
        }

        DispatchQueue.main.async {
            flush()
        }

        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                flush()
            }
        }
    }

    internal func indexPathForLoadedMessage(anchor: ChatMessageAnchorRef) -> IndexPath? {
        guard let section = ChatLoadedMessageNavigationPolicy.index(in: self.datasource, for: anchor),
              section < self.datasource.count else {
            return nil
        }

        return IndexPath(row: 0, section: section)
    }

    internal func containsLoadedMessage(anchor: ChatMessageAnchorRef) -> Bool {
        self.indexPathForLoadedMessage(anchor: anchor) != nil
    }

    private func indexPathForLoadedMessage(request: ChatOpenMessageRequest) -> IndexPath? {
        guard let section = ChatLoadedMessageNavigationPolicy.index(in: self.datasource, for: request),
              section < self.datasource.count else {
            return nil
        }

        return IndexPath(row: 0, section: section)
    }

    @discardableResult
    internal func scrollToLoadedMessage(
        anchor: ChatMessageAnchorRef,
        centered: Bool,
        animated: Bool,
        highlight: Bool,
        completion: (() -> Void)? = nil
    ) -> Bool {
        self.scrollToLoadedMessage(
            anchor: anchor,
            centered: centered,
            animated: animated,
            highlight: highlight,
            retryIfNeeded: true,
            completion: completion
        )
    }

    @discardableResult
    private func scrollToLoadedMessage(
        anchor: ChatMessageAnchorRef,
        centered: Bool,
        animated: Bool,
        highlight: Bool,
        retryIfNeeded: Bool,
        completion: (() -> Void)? = nil
    ) -> Bool {
        _ = centered
        guard let indexPath = self.indexPathForLoadedMessage(anchor: anchor),
              indexPath.section < self.datasource.count else {
            return false
        }

        guard indexPath.section < self.messagesCollectionView.numberOfSections else {
            if retryIfNeeded {
                DispatchQueue.main.async { [weak self] in
                    self?.scrollToLoadedMessage(
                        anchor: anchor,
                        centered: centered,
                        animated: animated,
                        highlight: highlight,
                        retryIfNeeded: false,
                        completion: completion
                    )
                }
            } else {
                completion?()
            }
            return true
        }

        guard let item = self.datasourceItem(at: indexPath) else {
            completion?()
            return false
        }
        self.positionMessage(
            primary: item.primary,
            archivedId: item.archivedId,
            highlight: highlight,
            animated: animated,
            completion: completion
        )
        return true
    }

    @discardableResult
    private func performLoadedOpenMessageRequestIfPossible(
        _ request: ChatOpenMessageRequest,
        hooks: ChatAnchorExecutionHooks? = nil
    ) -> Bool {
        guard request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType,
              let indexPath = self.indexPathForLoadedMessage(request: request),
              indexPath.section < self.datasource.count else {
            return false
        }

        guard let target = self.datasourceItem(at: indexPath) else {
            return false
        }
        let activeHooks = hooks ?? self.activeAnchorExecutionHooks
        let usesTransientHighlight = request.source.usesTransientHighlight && request.highlight
        let contextPrefetchMode = ChatAnchorContextPrefetchModePolicy.mode(
            for: request.source,
            hasLocalMatch: true,
            isSynced: self.currentChatIsSyncedForAnchorBootstrap()
        )
        let resolvedTarget = ResolvedJumpTarget(
            primary: target.primary,
            archivedId: target.archivedId
        )

        if contextPrefetchMode == .blocking {
            self.pendingOpenMessageRequest = request
            if self.activeAnchorExecutionState?.request != request {
                self.activeAnchorExecutionState = self.initialAnchorExecutionState(for: request)
            }
            self.activeAnchorExecutionHooks = activeHooks
            self.syncAnchorExecutionFlags()
            if self.prepareContextPrefetchIfNeeded(around: resolvedTarget, request: request) {
                if request.source == .search {
                    self.markSearchResultNavigationLoadingContext(for: request)
                    self.setSearchResultsPanelContextLoading(true)
                }
                return true
            }
        }

        self.pendingOpenMessageRequest = nil
        self.activeAnchorExecutionState = nil
        self.activeAnchorExecutionHooks = nil
        self.isApplyingBootstrapAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setDatasourceLoadingEnabled(true)
        self.currentPage.unlock()

        activeHooks?.onPositioningStarted?()
        self.positionMessage(
            primary: target.primary,
            archivedId: target.archivedId,
            highlight: request.highlight && !usesTransientHighlight,
            animated: activeHooks?.animatedScroll ?? false,
            preferredScrollDirection: request.source == .search ? activeHooks?.direction : nil,
            completion: {
                if usesTransientHighlight {
                    self.applyTransientMessageHighlight(primary: target.primary)
                }
                self.scheduleMentionReadOnVisibleIfNeeded(
                    for: request,
                    positionedPrimary: target.primary
                )
                activeHooks?.onPositioned?()
                if contextPrefetchMode == .background {
                    self.startBackgroundContextPrefetchIfNeeded(
                        around: resolvedTarget,
                        request: request
                    )
                }
            }
        )
        return true
    }

    private func savedPositionFirstFrameObserverIndex(
        for request: ChatOpenMessageRequest
    ) -> Int? {
        guard request.source == .savedVisiblePosition,
              self.messagesObserver != nil else {
            return nil
        }

        do {
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            guard let message = provider.message(
                primary: request.anchor.messagePrimary,
                archivedId: request.anchor.archivedId,
                messageId: request.anchor.messageId
            ) else {
                return nil
            }
            return provider.index(of: message)
        } catch {
            DDLogDebug("ChatViewController.savedPositionFirstFrameObserverIndex: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    internal func applySavedPositionFirstFrameWindowIfNeeded(isSynced: Bool) -> Bool {
        guard ChatOpenMessageRequestHandlingPolicy.shouldRestoreSavedFirstFramePosition(),
              let request = self.pendingOpenMessageRequest,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType,
              self.messagesObserver != nil,
              self.currentPage.isUnlocked else {
            return false
        }

        let localAnchorIndex = self.savedPositionFirstFrameObserverIndex(for: request)
        let archiveCoverageContext = self.savedPositionFirstFrameArchiveCoverageContext(localAnchorIndex: localAnchorIndex)
        let decision = ChatSavedPositionFirstFramePolicy.decision(
            requestSource: request.source,
            isSynced: isSynced,
            observerCount: self.messagesObserver.count,
            localAnchorIndex: localAnchorIndex,
            pageSize: self.datasourcePageSize,
            isPageUnlocked: self.currentPage.isUnlocked,
            archivedIdsByIndex: archiveCoverageContext.archivedIdsByIndex,
            knownGaps: archiveCoverageContext.knownGaps
        )

        guard ChatSavedPositionFirstFramePolicy.shouldApplySynchronously(
                bootstrapState: self.currentBootstrapViewState(),
                isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder,
                decision: decision
              ),
              case .savedPosition(let anchorIndex, _) = decision,
              anchorIndex < self.messagesObserver.count else {
            return false
        }

        let message = self.messagesObserver[anchorIndex]
        let target = ResolvedJumpTarget(
            primary: message.primary,
            archivedId: message.archivedId.isNotEmpty ? message.archivedId : nil
        )
        let hooks = self.activeAnchorExecutionHooks

        return self.currentPage.setCustomPage(anchorIndex / self.datasourcePageSize) {
            var executionState = ChatAnchorExecutionState(
                request: request,
                usesBootstrapLoading: false
            )
            executionState.isPositioning = true
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            self.isApplyingBootstrapAnchorWindow = true
            self.setShouldShowInitialMessage(false)
            self.setLoadingIndicatorVisible(false)
            self.setArchiveLoading(false)
            self.setDatasourceLoadingEnabled(false)

            guard self.applyFirstFrameAnchorSnapshot(message: message, target: target),
                  ChatSavedPositionFirstFrameCompletionPolicy.renderedWindowAction(
                    requestSource: request.source,
                    targetExistsInSnapshot: self.datasourceSnapshotContainsTarget(target)
                  ) == .finishRequest else {
                self.recoverSavedPositionFirstFrameRequest(trigger: .manual)
                return
            }

            self.positionMessage(
                primary: target.primary,
                archivedId: target.archivedId,
                highlight: false,
                animated: false,
                completion: {
                    self.finishActiveAnchorExecution()
                    self.scheduleMentionReadOnVisibleIfNeeded(
                        for: request,
                        positionedPrimary: target.primary
                    )
                    hooks?.onPositioned?()
                    self.startBackgroundContextPrefetchIfNeeded(
                        around: target,
                        request: request
                    )
                }
            )
        }
    }

    @discardableResult
    internal func applyUnreadBoundaryFirstFrameWindowIfNeeded(isSynced: Bool) -> Bool {
        guard let request = self.pendingOpenMessageRequest,
              request.source == .initialUnreadBoundary,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType,
              self.messagesObserver != nil,
              self.currentPage.isUnlocked else {
            return false
        }

        guard let localAnchor = self.unreadBoundaryFirstFrameLocalAnchor(for: request) else {
            return false
        }

        let decision = ChatUnreadBoundaryFirstFramePolicy.decision(
            requestSource: request.source,
            isSynced: isSynced,
            observerCount: self.messagesObserver.count,
            localAnchorIndex: localAnchor.index,
            isPageUnlocked: self.currentPage.isUnlocked
        )

        guard ChatUnreadBoundaryFirstFramePolicy.shouldApplySynchronously(
                bootstrapState: self.currentBootstrapViewState(),
                isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder,
                decision: decision
              ),
              case .unreadBoundary(let anchorIndex) = decision else {
            return false
        }

        let message = localAnchor.message
        let target = ResolvedJumpTarget(
            primary: message.primary,
            archivedId: message.archivedId.isNotEmpty ? message.archivedId : nil
        )
        let hooks = self.activeAnchorExecutionHooks

        return self.currentPage.setCustomPage(anchorIndex / self.datasourcePageSize) {
            var executionState = ChatAnchorExecutionState(
                request: request,
                usesBootstrapLoading: false
            )
            executionState.isPositioning = true
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            self.isApplyingBootstrapAnchorWindow = true
            self.setShouldShowInitialMessage(false)
            self.setLoadingIndicatorVisible(false)
            self.setArchiveLoading(false)
            self.setSkeletonVisible(false)
            self.setDatasourceLoadingEnabled(false)

            guard self.applyFirstFrameAnchorSnapshot(message: message, target: target),
                  self.datasourceSnapshotContainsTarget(target) else {
                self.recoverUnreadBoundaryFirstFrameRequest(trigger: .manual)
                return
            }

            self.positionMessage(
                primary: target.primary,
                archivedId: target.archivedId,
                highlight: false,
                animated: false,
                completion: {
                    self.finishActiveAnchorExecution()
                    self.scheduleMentionReadOnVisibleIfNeeded(
                        for: request,
                        positionedPrimary: target.primary
                    )
                    hooks?.onPositioned?()
                    self.startBackgroundContextPrefetchIfNeeded(
                        around: target,
                        request: request
                    )
                }
            )
        }
    }

    @discardableResult
    internal func applySearchFirstFrameWindowIfNeeded(isSynced: Bool) -> Bool {
        guard let request = self.pendingOpenMessageRequest,
              request.source == .search,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType,
              self.messagesObserver != nil,
              self.currentPage.isUnlocked else {
            return false
        }

        guard isSynced,
              let localAnchor = self.searchFirstFrameLocalAnchor(for: request),
              self.messagesObserver.count > 0,
              localAnchor.index >= 0,
              localAnchor.index < self.messagesObserver.count else {
            return false
        }

        guard self.currentBootstrapViewState() == .content,
              self.isShowingBootstrapPlaceholder else {
            return false
        }

        let message = localAnchor.message
        let target = ResolvedJumpTarget(
            primary: message.primary,
            archivedId: message.archivedId.isNotEmpty ? message.archivedId : nil
        )
        let hooks = self.activeAnchorExecutionHooks

        return self.currentPage.setCustomPage(localAnchor.index / self.datasourcePageSize) {
            var executionState = ChatAnchorExecutionState(
                request: request,
                usesBootstrapLoading: false
            )
            executionState.isPositioning = true
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            self.isApplyingBootstrapAnchorWindow = true
            self.setShouldShowInitialMessage(false)
            self.setLoadingIndicatorVisible(false)
            self.setArchiveLoading(false)
            self.setSkeletonVisible(false)
            self.setDatasourceLoadingEnabled(false)

            guard self.applyFirstFrameAnchorSnapshot(message: message, target: target),
                  self.datasourceSnapshotContainsTarget(target) else {
                self.recoverSearchFirstFrameRequest(trigger: .manual)
                return
            }

            self.positionMessage(
                primary: target.primary,
                archivedId: target.archivedId,
                highlight: request.highlight,
                animated: false,
                completion: {
                    self.finishActiveAnchorExecution()
                    self.scheduleMentionReadOnVisibleIfNeeded(
                        for: request,
                        positionedPrimary: target.primary
                    )
                    hooks?.onPositioned?()
                    self.startBackgroundContextPrefetchIfNeeded(
                        around: target,
                        request: request
                    )
                }
            )
        }
    }

    private func applyFirstFrameAnchorSnapshot(
        message: MessageStorageItem,
        target: ResolvedJumpTarget
    ) -> Bool {
        do {
            self.datasetMappingGeneration += 1
            let boundaryPlaceholder = self.activeHistoryBoundaryPlaceholder
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            var engine = ChatVirtualTimelineEngine(
                provider: provider,
                pageSize: self.datasourcePageSize,
                state: self.virtualTimelineState.normalized(
                    owner: self.owner,
                    jid: self.jid,
                    conversationType: self.conversationType
                ),
                archiveState: self.loadChatArchiveStateSnapshot()
            )
            let snapshot = engine.openAround(
                anchor: ChatTimelineAnchor(
                    primary: message.primary,
                    archivedId: message.archivedId,
                    messageId: message.messageId,
                    date: message.date
                )
            )
            let frozenItems = snapshot.items.map { $0.freeze() }
            guard frozenItems.isNotEmpty else {
                return false
            }

            let nextVirtualState = snapshot.state.withRuntimePlaceholder(boundaryPlaceholder)
            var mappedDatasource = self.mapDataset(dataset: frozenItems)
            if let boundaryPlaceholder {
                mappedDatasource = self.datasourceByAddingHistoryBoundaryPlaceholder(
                    to: mappedDatasource,
                    position: boundaryPlaceholder
                )
            }

            self.virtualTimelineState = nextVirtualState
            self.boundedTimelineWindowState = ChatBoundedTimelineWindowState(virtualState: nextVirtualState)
            self.syncCurrentPage(with: ChatDatasetWindow(minIndex: 0, maxIndex: frozenItems.count))
            self.applyChatDatasource(
                mappedDatasource,
                mode: .fullReload(),
                animated: false,
                invalidateLayout: false
            )
            return self.datasourceSnapshotContainsTarget(target)
        } catch {
            DDLogDebug("ChatViewController.applyFirstFrameAnchorSnapshot: \(error.localizedDescription)")
            return false
        }
    }

    private func datasourceSnapshotContainsTarget(_ target: ResolvedJumpTarget) -> Bool {
        self.datasourceSnapshot.primaryIndex[target.primary] != nil
            || (target.archivedId.flatMap { self.datasourceSnapshot.archivedIdIndex[$0] } != nil)
    }

    private func recoverSavedPositionFirstFrameRequest(trigger: ChatAnchorExecutionResumeTrigger) {
        guard let state = self.activeAnchorExecutionState,
              state.request.source == .savedVisiblePosition else {
            self.failActiveAnchorExecution()
            return
        }

        var recoveredState = state
        recoveredState.isPositioning = false
        recoveredState.isRemoteFetchInFlight = false
        self.activeAnchorExecutionState = recoveredState
        self.isApplyingBootstrapAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setDatasourceLoadingEnabled(true)
        self.currentPage.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.pendingOpenMessageRequest == recoveredState.request else {
                return
            }
            self.performPendingOpenMessageRequestIfNeeded(trigger: trigger)
        }
    }

    private func recoverUnreadBoundaryFirstFrameRequest(trigger: ChatAnchorExecutionResumeTrigger) {
        guard let state = self.activeAnchorExecutionState,
              state.request.source == .initialUnreadBoundary else {
            self.failActiveAnchorExecution()
            return
        }

        var recoveredState = state
        recoveredState.usesBootstrapLoading = true
        recoveredState.isPositioning = false
        recoveredState.isRemoteFetchInFlight = false
        self.activeAnchorExecutionState = recoveredState
        self.isApplyingBootstrapAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setDatasourceLoadingEnabled(false)
        self.currentPage.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.pendingOpenMessageRequest == recoveredState.request else {
                return
            }
            self.performPendingOpenMessageRequestIfNeeded(trigger: trigger)
        }
    }

    private func recoverSearchFirstFrameRequest(trigger: ChatAnchorExecutionResumeTrigger) {
        guard let state = self.activeAnchorExecutionState,
              state.request.source == .search else {
            self.failActiveAnchorExecution()
            return
        }

        var recoveredState = state
        recoveredState.usesBootstrapLoading = true
        recoveredState.isPositioning = false
        recoveredState.isRemoteFetchInFlight = false
        self.activeAnchorExecutionState = recoveredState
        self.isApplyingBootstrapAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setDatasourceLoadingEnabled(false)
        self.currentPage.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.pendingOpenMessageRequest == recoveredState.request else {
                return
            }
            self.performPendingOpenMessageRequestIfNeeded(trigger: trigger)
        }
    }

    private func initialAnchorExecutionState(
        for request: ChatOpenMessageRequest
    ) -> ChatAnchorExecutionState {
        ChatAnchorExecutionState(
            request: request,
            usesBootstrapLoading: self.shouldUseBootstrapLoading(for: request)
        )
    }

    private func shouldUseBootstrapLoading(for request: ChatOpenMessageRequest) -> Bool {
        let hasLocalAnchor = ChatInitialAnchorBootstrapPolicy.needsLocalAnchorLookup(source: request.source)
            ? self.hasLocalAnchorForBootstrap(request)
            : false

        return ChatInitialAnchorBootstrapPolicy.shouldBlockBootstrap(
            source: request.source,
            isSynced: self.currentChatIsSyncedForAnchorBootstrap(),
            messageCount: self.localHistoryMessageCountForBootstrap(),
            hasLocalAnchor: hasLocalAnchor,
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
        )
    }

    private func currentChatIsSyncedForAnchorBootstrap() -> Bool {
        do {
            let realm = try WRealm.safe()
            return realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            )?.isSynced ?? false
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return false
        }
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
        if let executionState = self.activeAnchorExecutionState {
            if let remoteQueryId = executionState.remoteQueryId {
                self.unregisterRemoteHistoryPersistenceSource(queryId: remoteQueryId)
            }
            executionState.contextPrefetchQueryIds.forEach {
                self.unregisterRemoteHistoryPersistenceSource(queryId: $0)
            }
        }
        self.pendingOpenMessageRequest = nil
        self.activeAnchorExecutionState = nil
        self.activeAnchorExecutionHooks = nil
        self.isApplyingBootstrapAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setSearchAnchorNavigationScrollLocked(false)
        self.setLoadingIndicatorVisible(false)
        self.setDatasourceLoadingEnabled(true)
        self.setSearchResultsPanelContextLoading(false)
    }

    private func failActiveAnchorExecution() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.failActiveAnchorExecution()
            }
            return
        }

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
            requestSource: executionState?.request.source,
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
        self.setSearchAnchorNavigationScrollLockedIfNeeded(true, for: request)
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

        self.performArchiveAction(queryIds: [queryId], { stream, mam in
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
        queryIds: Set<String> = [],
        _ action: @escaping (XMPPStream, MessageArchiveManager) -> Void,
        unavailable: (() -> Void)? = nil
    ) {
        queryIds.forEach {
            self.registerRemoteHistoryEndPageDispatcher(queryId: $0)
        }
        let fallback = {
            guard let account = AccountManager.shared.find(for: self.owner) else {
                queryIds.forEach {
                    self.unregisterRemoteHistoryEndPageDispatcher(queryId: $0)
                }
                unavailable?()
                return
            }

            account.action { user, stream in
                queryIds.forEach {
                    self.registerRemoteHistoryPersistenceSource(user.messages, queryId: $0)
                }
                action(stream, user.mam)
            }
        }

        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            if let mam = session.mam {
                queryIds.forEach {
                    self.registerRemoteHistoryPersistenceSource(session.messages, queryId: $0)
                }
                action(stream, mam)
            } else {
                fallback()
            }
        } fail: {
            fallback()
        }
    }

    private func unreadBoundaryCandidate(for message: MessageStorageItem) -> ChatUnreadBoundaryTargetPolicy.Candidate {
        ChatUnreadBoundaryTargetPolicy.Candidate(
            primary: message.primary,
            archivedId: message.archivedId.isNotEmpty ? message.archivedId : nil,
            messageId: message.messageId.isNotEmpty ? message.messageId : nil,
            sourceDate: message.date,
            isOutgoing: message.outgoing
        )
    }

    private func firstLoadedIncomingMessageAfterUnreadBoundary(
        _ boundaryArchivedId: String
    ) -> MessageStorageItem? {
        do {
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            return provider.firstIncoming(afterArchiveBoundaryId: boundaryArchivedId)
                ?? provider.message(primary: nil, archivedId: boundaryArchivedId, messageId: nil)
        } catch {
            DDLogDebug("ChatViewController.firstLoadedIncomingMessageAfterUnreadBoundary: \(error.localizedDescription)")
            return nil
        }
    }

    private func unreadBoundaryFirstFrameLocalAnchor(
        for request: ChatOpenMessageRequest
    ) -> (message: MessageStorageItem, index: Int)? {
        guard request.source == .initialUnreadBoundary,
              case .firstIncomingAfterBoundary(let boundaryArchivedId) = request.targetResolution else {
            return nil
        }

        do {
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            guard let message = provider.firstIncoming(afterArchiveBoundaryId: boundaryArchivedId) else {
                return nil
            }

            return (message, provider.index(of: message))
        } catch {
            DDLogDebug("ChatViewController.unreadBoundaryFirstFrameLocalAnchor: \(error.localizedDescription)")
            return nil
        }
    }

    private func searchFirstFrameLocalAnchor(
        for request: ChatOpenMessageRequest
    ) -> (message: MessageStorageItem, index: Int)? {
        guard request.source == .search else {
            return nil
        }

        do {
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            let anchor = request.anchor
            guard let message = self.searchProviderMessage(for: anchor, provider: provider) else {
                return nil
            }

            return (message, provider.index(of: message))
        } catch {
            DDLogDebug("ChatViewController.searchFirstFrameLocalAnchor: \(error.localizedDescription)")
            return nil
        }
    }

    private func resolvedTargetAfterContextPrefetch(
        for request: ChatOpenMessageRequest,
        fallback: ResolvedJumpTarget
    ) -> ResolvedJumpTarget {
        guard case .firstIncomingAfterBoundary(let boundaryArchivedId) = request.targetResolution,
              let targetMessage = self.firstLoadedIncomingMessageAfterUnreadBoundary(boundaryArchivedId),
              let target = self.resolvedJumpTarget(for: targetMessage) else {
            return fallback
        }

        return target
    }

    private func localAnchorMessage(
        for request: ChatOpenMessageRequest
    ) -> (message: MessageStorageItem, matchSource: ChatAnchorLookupMatchSource)? {
        if let providerMatch = self.providerAnchorMessage(for: request) {
            return providerMatch
        }

        if let observerMatch = self.observerAnchorMessage(for: request) {
            return observerMatch
        }

        if let savedPositionMatch = self.savedVisiblePositionMessageFromLocalRealm(for: request) {
            return savedPositionMatch
        }

        guard request.source != .savedVisiblePosition else {
            return nil
        }

        return self.metadataFallbackAnchorMessage(for: request)
    }

    private func providerAnchorMessage(
        for request: ChatOpenMessageRequest
    ) -> (message: MessageStorageItem, matchSource: ChatAnchorLookupMatchSource)? {
        do {
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )

            if case .firstIncomingAfterBoundary(let boundaryArchivedId) = request.targetResolution,
               let message = provider.firstIncoming(afterArchiveBoundaryId: boundaryArchivedId)
                    ?? provider.message(primary: nil, archivedId: boundaryArchivedId, messageId: nil) {
                return (message, .unreadBoundaryAfter)
            }

            let anchor = request.anchor
            if request.source == .search,
               let message = self.searchProviderMessage(for: anchor, provider: provider) {
                if let archivedId = anchor.archivedId,
                   archivedId.isNotEmpty,
                   message.archivedId == archivedId {
                    return (message, .archivedId)
                }
                if let messageId = anchor.messageId,
                   messageId.isNotEmpty,
                   message.messageId == messageId {
                    return (message, .messageId)
                }
                return (message, .primary)
            }

            if let message = provider.message(
                primary: anchor.messagePrimary,
                archivedId: anchor.archivedId,
                messageId: anchor.messageId
            ) {
                if let messagePrimary = anchor.messagePrimary,
                   messagePrimary.isNotEmpty,
                   message.primary == messagePrimary {
                    return (message, .primary)
                }
                if let archivedId = anchor.archivedId,
                   archivedId.isNotEmpty,
                   message.archivedId == archivedId {
                    return (message, .archivedId)
                }
                if let messageId = anchor.messageId,
                   messageId.isNotEmpty,
                   message.messageId == messageId {
                    return (message, .messageId)
                }
                return (message, .metadataFallback)
            }
        } catch {
            DDLogDebug("ChatViewController.providerAnchorMessage: \(error.localizedDescription)")
        }

        return nil
    }

    private func searchProviderMessage(
        for anchor: ChatMessageAnchorRef,
        provider: ChatLocalHistoryPageProvider
    ) -> MessageStorageItem? {
        if let archivedId = anchor.archivedId,
           archivedId.isNotEmpty,
           let message = provider.message(primary: nil, archivedId: archivedId, messageId: nil) {
            return message
        }

        if let messageId = anchor.messageId,
           messageId.isNotEmpty,
           let message = provider.message(primary: nil, archivedId: nil, messageId: messageId) {
            return message
        }

        if let messagePrimary = anchor.messagePrimary,
           messagePrimary.isNotEmpty,
           let message = provider.message(primary: messagePrimary, archivedId: nil, messageId: nil) {
            return message
        }

        return nil
    }

    internal func hasLocalAnchorForBootstrap(_ request: ChatOpenMessageRequest) -> Bool {
        if request.source == .initialUnreadBoundary {
            return self.unreadBoundaryFirstFrameLocalAnchor(for: request) != nil
        }

        if request.source == .search {
            return self.searchFirstFrameLocalAnchor(for: request) != nil
        }

        guard self.localAnchorMessage(for: request) != nil else {
            return false
        }

        guard request.source == .savedVisiblePosition,
              self.messagesObserver != nil,
              let localAnchorIndex = self.savedPositionFirstFrameObserverIndex(for: request) else {
            return true
        }

        let archiveCoverageContext = self.savedPositionFirstFrameArchiveCoverageContext(localAnchorIndex: localAnchorIndex)
        guard archiveCoverageContext.knownGaps.isNotEmpty else {
            return true
        }

        if case .savedPosition = ChatSavedPositionFirstFramePolicy.decision(
            requestSource: request.source,
            isSynced: true,
            observerCount: self.messagesObserver.count,
            localAnchorIndex: localAnchorIndex,
            pageSize: self.datasourcePageSize,
            isPageUnlocked: true,
            archivedIdsByIndex: archiveCoverageContext.archivedIdsByIndex,
            knownGaps: archiveCoverageContext.knownGaps
        ) {
            return true
        }

        return false
    }

    private func savedPositionFirstFrameArchiveCoverageContext(localAnchorIndex: Int?) -> (
        archivedIdsByIndex: [Int: String],
        knownGaps: [RegularChatArchiveGap]
    ) {
        guard self.conversationType == .regular,
              self.messagesObserver != nil else {
            return ([:], [])
        }

        let archiveState = self.loadChatArchiveStateSnapshot()
        guard archiveState.knownGaps.isNotEmpty else {
            return ([:], [])
        }

        guard let localAnchorIndex,
              localAnchorIndex >= 0 else {
            return ([:], archiveState.knownGaps)
        }

        let window = ChatDatasetCoordinator(pageSize: self.datasourcePageSize)
            .replacementWindow(around: localAnchorIndex, totalCount: self.messagesObserver.count)
        let sampledIndices = Set([
            window.minIndex,
            localAnchorIndex,
            max(window.minIndex, window.maxIndex - 1)
        ])

        var archivedIdsByIndex: [Int: String] = [:]
        do {
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            for index in sampledIndices {
                if let archiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(provider.item(at: index)?.archivedId) {
                    archivedIdsByIndex[index] = archiveId
                }
            }
        } catch {
            DDLogDebug("ChatViewController.savedPositionFirstFrameArchiveCoverageContext: \(error.localizedDescription)")
        }

        return (archivedIdsByIndex, archiveState.knownGaps)
    }

    private func observerAnchorMessage(
        for request: ChatOpenMessageRequest
    ) -> (message: MessageStorageItem, matchSource: ChatAnchorLookupMatchSource)? {
        self.ensureObserverLookupMaps()
        let anchor = request.anchor

        if case .firstIncomingAfterBoundary(let boundaryArchivedId) = request.targetResolution,
           let message = self.firstLoadedIncomingMessageAfterUnreadBoundary(boundaryArchivedId) {
            return (message, .unreadBoundaryAfter)
        }

        if request.source == .search {
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
        }

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

        return nil
    }

    private func savedVisiblePositionMessageFromLocalRealm(
        for request: ChatOpenMessageRequest
    ) -> (message: MessageStorageItem, matchSource: ChatAnchorLookupMatchSource)? {
        guard request.source == .savedVisiblePosition else {
            return nil
        }

        let anchor = request.anchor

        do {
            let realm = try WRealm.safe()
            let messages = realm
                .objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@",
                    request.owner,
                    request.chatJid,
                    request.conversationType.rawValue
                )

            if let messagePrimary = anchor.messagePrimary,
               messagePrimary.isNotEmpty,
               let message = messages.filter("primary == %@", messagePrimary).first {
                self.ensureObserverLookupMaps(force: true)
                guard self.observerPrimaryIndexMap[message.primary] != nil else {
                    return nil
                }
                return (message, .primary)
            }

            if let archivedId = anchor.archivedId,
               archivedId.isNotEmpty,
               let message = messages.filter("archivedId == %@", archivedId).first {
                self.ensureObserverLookupMaps(force: true)
                guard self.observerPrimaryIndexMap[message.primary] != nil else {
                    return nil
                }
                return (message, .archivedId)
            }

            if let messageId = anchor.messageId,
               messageId.isNotEmpty,
               let message = messages.filter("messageId == %@", messageId).first {
                self.ensureObserverLookupMaps(force: true)
                guard self.observerPrimaryIndexMap[message.primary] != nil else {
                    return nil
                }
                return (message, .messageId)
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }

        return nil
    }

    private func metadataFallbackAnchorMessage(
        for request: ChatOpenMessageRequest
    ) -> (message: MessageStorageItem, matchSource: ChatAnchorLookupMatchSource)? {
        let anchor = request.anchor

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
        guard !message.isInvalidated,
              message.primary.isNotEmpty else {
            return nil
        }

        return ResolvedJumpTarget(
            primary: message.primary,
            archivedId: message.archivedId.isNotEmpty ? message.archivedId : nil
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
        preferredScrollDirection: ChatDirection? = nil,
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

        self.prepareDirectionalSearchScrollIfNeeded(
            to: indexPath,
            direction: preferredScrollDirection,
            animated: animated
        )
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
            if self.inSearchMode.value || self.xabberInputView.state == .search {
                self.refreshVisibleSearchSelection()
            }
            self.preventHidingDate = false
            self.currentPage.unlock()
            self.setFloatingDateVisible(true)
            self.setFloatingDateHidden(true)
            self.setDatasourceLoadingEnabled(true)
            completion?()
        }
    }

    private func prepareDirectionalSearchScrollIfNeeded(
        to indexPath: IndexPath,
        direction: ChatDirection?,
        animated: Bool
    ) {
        guard animated,
              let direction else {
            return
        }

        self.messagesCollectionView.layoutIfNeeded()
        guard let targetOffsetY = self.centeredContentOffsetY(for: indexPath) else {
            return
        }

        let insets = self.messagesCollectionView.adjustedContentInset
        let contentHeight = self.messagesCollectionView.collectionViewLayout.collectionViewContentSize.height
        let viewportHeight = self.messagesCollectionView.bounds.height
        let minOffsetY = -insets.top
        let maxOffsetY = max(minOffsetY, contentHeight - viewportHeight + insets.bottom)
        guard let stagedOffsetY = ChatDirectionalScrollStagingPolicy.stagedOffsetY(
            currentOffsetY: self.messagesCollectionView.contentOffset.y,
            targetOffsetY: targetOffsetY,
            direction: direction,
            viewportHeight: viewportHeight,
            minOffsetY: minOffsetY,
            maxOffsetY: maxOffsetY
        ) else {
            return
        }

        self.messagesCollectionView.setContentOffset(
            CGPoint(x: self.messagesCollectionView.contentOffset.x, y: stagedOffsetY),
            animated: false
        )
        self.messagesCollectionView.layoutIfNeeded()
    }

    private func centeredContentOffsetY(for indexPath: IndexPath) -> CGFloat? {
        guard let attributes = self.messagesCollectionView.layoutAttributesForItem(at: indexPath) else {
            return nil
        }

        let insets = self.messagesCollectionView.adjustedContentInset
        let contentHeight = self.messagesCollectionView.collectionViewLayout.collectionViewContentSize.height
        let viewportHeight = self.messagesCollectionView.bounds.height
        let minOffsetY = -insets.top
        let maxOffsetY = max(minOffsetY, contentHeight - viewportHeight + insets.bottom)
        let targetOffsetY = attributes.frame.midY - (viewportHeight / 2)
        return min(max(targetOffsetY, minOffsetY), maxOffsetY)
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
        state.contextPrefetchQueryIds.forEach {
            self.unregisterRemoteHistoryPersistenceSource(queryId: $0)
        }
        state.contextPrefetchAnchorKey = anchorKey
        state.contextPrefetchQueryIds = []
        state.contextPrefetchPendingQueryIds = []
        state.contextPrefetchExpectedMessageCount = 0
        state.contextPrefetchPersistedMessageCount = 0
        state.didObserveContextPostIdleTick = false
    }

    private func isMessagePipelineIdle(for queryIds: Set<String>) -> Bool {
        !queryIds.contains {
            ChatRemoteHistoryCompletionCoordinator.hasPendingMessages(owner: self.owner, queryId: $0)
        }
    }

    private func scheduleContextPrefetchObserverResumeIfNeeded(delay: TimeInterval = 0) {
        let work = { [weak self] in
            guard let self else {
                return
            }
            self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func scheduleAnchorObserverResumeIfNeeded(delay: TimeInterval = 0) {
        let work = { [weak self] in
            guard let self else {
                return
            }
            self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
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
        updatedState.contextPrefetchExpectedMessageCount = 0
        updatedState.contextPrefetchPersistedMessageCount = 0
        updatedState.didObserveContextPostIdleTick = false
        self.activeAnchorExecutionState = updatedState
        self.syncAnchorExecutionFlags()
        self.setSearchAnchorNavigationScrollLockedIfNeeded(true, for: request)

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
        self.performArchiveAction(queryIds: queryIds, { stream, mam in
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

    private func startBackgroundContextPrefetchIfNeeded(
        around target: ResolvedJumpTarget,
        request: ChatOpenMessageRequest
    ) {
        guard self.messagesObserver != nil else {
            return
        }

        self.ensureObserverLookupMaps()
        guard let observerIndex = self.observerPrimaryIndexMap[target.primary] else {
            return
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
            return
        }

        self.performArchiveAction({ stream, mam in
            if let newerPageSize = plan.newerPageSize {
                _ = mam.getPrevHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    messageId: archivedId,
                    pageSize: newerPageSize,
                    queryId: nil,
                    callback: nil,
                    requestCallbacks: .none
                )
            }

            if let olderPageSize = plan.olderPageSize {
                _ = mam.getNextHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    messageId: archivedId,
                    pageSize: olderPageSize,
                    queryId: nil,
                    callback: nil,
                    requestCallbacks: .none
                )
            }
        })
    }

    private func revealLocalContentForSavedPositionIfNeeded(
        request: ChatOpenMessageRequest,
        hasLocalMatch: Bool
    ) {
        guard request.source == .savedVisiblePosition,
              hasLocalMatch,
              self.currentChatIsSyncedForAnchorBootstrap(),
              self.localHistoryMessageCountForBootstrap() > 0 else {
            return
        }

        self.setShouldShowInitialMessage(false)
        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setSkeletonVisible(false)
        self.setDatasourceLoadingEnabled(true)
    }

    private func resumeAnchorExecutionIfNeeded(trigger: ChatAnchorExecutionResumeTrigger) {
        guard let request = self.pendingOpenMessageRequest,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType else {
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

            let contextPrefetchMode = ChatAnchorContextPrefetchModePolicy.mode(
                for: request.source,
                hasLocalMatch: true,
                isSynced: self.currentChatIsSyncedForAnchorBootstrap()
            )
            self.revealLocalContentForSavedPositionIfNeeded(
                request: request,
                hasLocalMatch: true
            )

            if contextPrefetchMode == .blocking,
               self.prepareContextPrefetchIfNeeded(around: resolved, request: request) {
                return
            }

            guard var resolvedExecutionState = self.activeAnchorExecutionState else {
                return
            }

            let positionTarget = self.resolvedTargetAfterContextPrefetch(
                for: request,
                fallback: resolved
            )
            let applyPlan = ChatAnchorDatasourceApplyPolicy.plan(for: request.source)
            resolvedExecutionState.isPositioning = true
            self.activeAnchorExecutionState = resolvedExecutionState
            self.syncAnchorExecutionFlags()
            self.beginBootstrapAnchorContentTransitionIfNeeded()
            let hooks = self.activeAnchorExecutionHooks
            let direction = hooks?.direction ?? .up
            self.chatScrollDirection = direction
            let timelineAnchor = ChatTimelineAnchor(
                primary: positionTarget.primary,
                archivedId: positionTarget.archivedId,
                messageId: request.anchor.messageId,
                date: localMatch.message.date
            )
            self.mapAndApplyTimelineAnchor(
                timelineAnchor,
                mode: applyPlan.mode,
                animated: false,
                invalidateLayout: applyPlan.invalidateLayout,
                completion: {
                    let usesTransientHighlight = request.source.usesTransientHighlight && request.highlight
                    hooks?.onPositioningStarted?()
                    self.positionMessage(
                        primary: positionTarget.primary,
                        archivedId: positionTarget.archivedId,
                        highlight: request.highlight && !usesTransientHighlight,
                        animated: hooks?.animatedScroll ?? false,
                        preferredScrollDirection: request.source == .search ? hooks?.direction : nil,
                        completion: {
                            if usesTransientHighlight {
                                self.applyTransientMessageHighlight(primary: positionTarget.primary)
                            }
                            self.finishActiveAnchorExecution()
                            self.scheduleMentionReadOnVisibleIfNeeded(
                                for: request,
                                positionedPrimary: positionTarget.primary
                            )
                            hooks?.onPositioned?()
                            if contextPrefetchMode == .background {
                                self.startBackgroundContextPrefetchIfNeeded(
                                    around: positionTarget,
                                    request: request
                                )
                            }
                        }
                    )
            }, cancelledCompletion: {
                self.failActiveAnchorExecution()
            })
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
        guard let request = self.pendingOpenMessageRequest else {
            return
        }
        if self.shouldDeferOpenMessageRequestsForNavigationTransition {
            guard !self.didDeferOpenMessageRequestForNavigationTransition else {
                return
            }
            self.didDeferOpenMessageRequestForNavigationTransition = true
            self.deferUntilNavigationTransitionCompletesIfNeeded { [weak self] in
                guard let self else { return }
                self.didDeferOpenMessageRequestForNavigationTransition = false
                self.performPendingOpenMessageRequestIfNeeded(trigger: trigger)
            }
            return
        }

        if self.performLoadedOpenMessageRequestIfPossible(request) {
            return
        }

        guard request.owner == self.owner,
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
                markReadOnVisible: false,
                source: .search
            ),
            hooks: ChatAnchorExecutionHooks(
                direction: .up,
                animatedScroll: true,
                onFailed: {},
                onPositioned: nil
            )
        )
    }
    
    internal func onSearchPanelSeekUp() {
        navigateSearchResult(direction: .up)
    }
    
    internal func onSearchPanelSeekDown() {
        navigateSearchResult(direction: .down)
    }
    
    internal func onSearchPanelChangeChatViewState() {
        reduceSearchPresentationState(.openList)
    }
    
    internal func scrollToSearchedMessage(primary: String) {
        self.positionMessage(primary: primary, highlight: true, animated: true)
    }

    internal func scrollToMessage(
        messagePrimary: String,
        archivedId: String?,
        date: Date,
        centered: Bool,
        animated: Bool,
        highlight: Bool
    ) {
        _ = centered
        self.queueOpenMessageRequest(
            ChatOpenMessageRequest(
                chatJid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType,
                anchor: ChatMessageAnchorRef(
                    messagePrimary: messagePrimary,
                    archivedId: archivedId,
                    messageId: nil,
                    authorId: nil,
                    bodyFingerprint: nil,
                    sourceDate: date
                ),
                highlight: highlight,
                markReadOnVisible: false,
                source: .voicePlayer
            ),
            hooks: ChatAnchorExecutionHooks(
                direction: .up,
                animatedScroll: animated,
                onFailed: nil,
                onPositioned: nil
            )
        )
    }

    internal func applyTransientMessageHighlight(primary: String) {
        guard let section = self.datasourceSnapshot.primaryIndex[primary],
              section < self.datasource.count else {
            return
        }

        let indexPath = IndexPath(row: 0, section: section)
        guard let cell = self.messagesCollectionView.cellForItem(at: indexPath) as? MessageContentCell else {
            return
        }

        let tag = 0xA11D10
        cell.contentView.subviews
            .filter { $0.tag == tag }
            .forEach { $0.removeFromSuperview() }

        let overlay = UIView(frame: cell.contentView.bounds)
        overlay.tag = tag
        overlay.isUserInteractionEnabled = false
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.18)
        cell.contentView.addSubview(overlay)

        UIView.animate(
            withDuration: 0.25,
            delay: 0.55,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: {
                overlay.alpha = 0
            },
            completion: { _ in
                overlay.removeFromSuperview()
            }
        )
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
            animated: true
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
            source: .search
        )
        self.queueOpenMessageRequest(
            request,
            hooks: ChatAnchorExecutionHooks(
                direction: .up,
                animatedScroll: true,
                onFailed: nil,
                onPositioned: nil
            )
        )
    }
    
    public final func scrollToMessageAtIndex(_ index: Int) {
        guard self.searchMessagesQueue.indices.contains(index) else {
            return
        }

        let item = self.searchMessagesQueue[index]
        self.selectedSearchResultId = self.searchResultSelectionIdentity(for: item)
        self.refreshVisibleSearchSelection()
        let archivedId = item.archivedId.isNotEmpty ? item.archivedId : nil
        self.queueOpenMessageRequest(
            ChatOpenMessageRequest(
                chatJid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType,
                anchor: ChatMessageAnchorRef(
                    messagePrimary: archivedId == nil ? item.primary : nil,
                    archivedId: archivedId,
                    messageId: item.messageId.isNotEmpty ? item.messageId : nil,
                    authorId: item.groupchatAuthorId,
                    bodyFingerprint: nil,
                    sourceDate: item.date
                ),
                highlight: true,
                markReadOnVisible: false,
                source: .search
            ),
            hooks: ChatAnchorExecutionHooks(
                direction: self.chatScrollDirection ?? .up,
                animatedScroll: true,
                onFailed: nil,
                onPositioned: nil
            )
        )
    }
    
    internal final func applySearchResults(emptyList: Bool = false) {
        self.preventHidingDate = true
        self.setLoadingIndicatorVisible(false)
        self.searchMessagesQueue = self.normalizedInChatSearchResultsForDisplay(self.searchMessagesQueue)
        if self.searchMessagesQueue.isEmpty {
            self.reduceSearchPresentationState(
                .emptyReceived(generation: self.searchPresentationState.generation)
            )
        } else {
            self.reduceSearchPresentationState(
                .resultsReceived(
                    count: self.searchMessagesQueue.count,
                    generation: self.searchPresentationState.generation
                )
            )
        }
        let newIndex = 0
        if self.searchMessagesQueue.isNotEmpty {
            self.searchResultNavigationState = .idle
            self.selectedSearchResultId = nil
            self.refreshVisibleSearchSelection()
            let onNavigationFinished: () -> Void = { [weak self] in
                self?.preventHidingDate = false
            }
            self.openSearchResult(
                at: newIndex,
                direction: .up,
                onNavigationFinished: onNavigationFinished
            )
            self.scheduleInitialSearchResultOpenFallback(
                index: newIndex,
                direction: .up,
                onNavigationFinished: onNavigationFinished
            )
        } else {
            self.searchResultNavigationState = .idle
            self.selectedSearchResultId = nil
            self.refreshVisibleSearchSelection()
            self.applySearchResultsPanelState(isLoadingContext: false)
        }
        self.setFloatingDateVisible(true)
    }
    
    func didReceiveEndPage(queryId: String, state: MessageArchivePageEndState, first: String, last: String, count: Int) {
        let enqueuedAt = Date()
        ChatArchiveDebugTrace.log("chatDidReceiveEndPageEnqueue", [
            ("owner", self.owner),
            ("jid", self.jid),
            ("conversationType", self.conversationType.rawValue),
            ("queryId", queryId),
            ("count", count),
            ("statePersisted", state.persistedMessageCount)
        ])
        DispatchQueue.main.async {
            let enteredAt = Date()
            ChatArchiveDebugTrace.log("chatDidReceiveEndPageEnter", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("waitMs", ChatArchiveDebugTrace.milliseconds(since: enqueuedAt)),
                ("count", count),
                ("statePersisted", state.persistedMessageCount),
                ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count),
                ("datasourceCount", self.datasource.count),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                ("currentPageLocked", self.currentPage.locked)
            ])
            if self.abortedRemoteHistoryQueryIds.contains(queryId),
               self.interactiveHistoryPageLoadContext?.queryId != queryId {
                self.abortedRemoteHistoryQueryIds.remove(queryId)
                self.unregisterRemoteHistoryPersistenceSource(queryId: queryId)
                ChatArchiveDebugTrace.log("chatDidReceiveEndPageStaleAfterAbort", [
                    ("owner", self.owner),
                    ("jid", self.jid),
                    ("conversationType", self.conversationType.rawValue),
                    ("queryId", queryId),
                    ("count", count),
                    ("statePersisted", state.persistedMessageCount),
                    ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-"),
                    ("coverageCommitted", false)
                ])
                return
            }
            let shouldDedupeCompletion = self.remoteHistoryEndPageDispatcherTokens[queryId] != nil ||
                self.completedRemoteHistoryEndPageQueryIds.contains(queryId)
            if shouldDedupeCompletion {
                guard self.markRemoteHistoryEndPageCompletionIfNeeded(queryId: queryId) else {
                    DDLogDebug("ChatViewController.remoteHistoryFinalDuplicate queryId=\(queryId)")
                    return
                }
            }
            let flushStartedAt = Date()
            let completion = ChatRemoteHistoryCompletionCoordinator.flushQueryMessages(
                owner: self.owner,
                queryId: queryId,
                state: state,
                conversationJid: self.jid,
                conversationType: self.conversationType
            )
            let flushDurationMs = ChatArchiveDebugTrace.milliseconds(since: flushStartedAt)
            let effectiveState = completion.state
            let visibleRows = completion.persistenceSummary.visibleRows(
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
            )
            ChatArchiveDebugTrace.log("chatDidReceiveEndPageAfterFlush", [
                ("owner", self.owner),
                ("jid", self.jid),
                ("conversationType", self.conversationType.rawValue),
                ("queryId", queryId),
                ("flushMs", flushDurationMs),
                ("flushed", completion.flushedMessageCount),
                ("effectivePersisted", effectiveState.persistedMessageCount),
                ("visibleRows", visibleRows),
                ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count),
                ("datasourceCount", self.datasource.count),
                ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-")
            ])
            DDLogDebug("ChatViewController.remoteHistoryFinal queryId=\(queryId) statePersisted=\(state.persistedMessageCount) flushed=\(completion.flushedMessageCount) effectivePersisted=\(effectiveState.persistedMessageCount) count=\(count) received=\(completion.persistenceSummary.received) queued=\(completion.persistenceSummary.queued) savedNew=\(completion.persistenceSummary.savedNew) updatedExisting=\(completion.persistenceSummary.updatedExisting) skipped=\(completion.persistenceSummary.skipped) failed=\(completion.persistenceSummary.failed) visibleRows=\(visibleRows)")
            if self.handleInitialBootstrapEndPageIfNeeded(
                queryId: queryId,
                state: effectiveState,
                count: count,
                persistedMessageCount: effectiveState.persistedMessageCount,
                persistedRowsForQuery: completion.persistenceSummary.persistedRows,
                visibleRowsForConversation: visibleRows
            ) {
                ChatArchiveDebugTrace.log("chatDidReceiveEndPageHandled", [
                    ("queryId", queryId),
                    ("handler", "initialBootstrap")
                ])
                return
            }
            if self.completeInteractiveHistoryPageLoadIfNeeded(
                queryId: queryId,
                state: effectiveState,
                first: first,
                last: last,
                count: count,
                persistedRowsForQuery: completion.persistenceSummary.persistedRows,
                visibleRowsForConversation: visibleRows
            ) {
                ChatArchiveDebugTrace.log("chatDidReceiveEndPageHandled", [
                    ("queryId", queryId),
                    ("handler", "interactivePaging")
                ])
                return
            }
            if self.handleAnchorContextPrefetchEndPageIfNeeded(queryId: queryId, state: effectiveState, count: count) {
                ChatArchiveDebugTrace.log("chatDidReceiveEndPageHandled", [
                    ("queryId", queryId),
                    ("handler", "anchorContextPrefetch")
                ])
                return
            }
            if self.handleAnchorRemoteFetchEndPageIfNeeded(queryId: queryId, state: effectiveState, count: count) {
                ChatArchiveDebugTrace.log("chatDidReceiveEndPageHandled", [
                    ("queryId", queryId),
                    ("handler", "anchorRemoteFetch")
                ])
                return
            }
            if self.finishInChatSearchQueryIfCurrent(queryId: queryId, emptyList: first == last) {
                ChatArchiveDebugTrace.log("chatDidReceiveEndPageHandled", [
                    ("queryId", queryId),
                    ("handler", "search")
                ])
                return
            }
            ChatArchiveDebugTrace.log("chatDidReceiveEndPageUnhandled", [
                ("queryId", queryId),
                ("count", count),
                ("effectivePersisted", effectiveState.persistedMessageCount)
            ])
        }
    }
    
    func didReceiveMessage(_ item: MessageStorageItem, queryId: String) {
        DispatchQueue.main.async {
            self.appendInChatSearchResultIfCurrent(item, queryId: queryId)
        }
    }
    
    func updateViewportDatasource(first oldestMessageId: String, last newestMessageId: String, count: Int) {
        
    }

    @discardableResult
    private func handleAnchorContextPrefetchEndPageIfNeeded(
        queryId: String,
        state: MessageArchivePageEndState,
        count: Int
    ) -> Bool {
        guard var executionState = self.activeAnchorExecutionState,
              executionState.contextPrefetchQueryIds.contains(queryId) else {
            return false
        }

        executionState.contextPrefetchPendingQueryIds.remove(queryId)
        executionState.contextPrefetchExpectedMessageCount += max(0, count)
        executionState.contextPrefetchPersistedMessageCount += state.persistedMessageCount
        self.activeAnchorExecutionState = executionState
        self.syncAnchorExecutionFlags()

        if executionState.contextPrefetchPendingQueryIds.isEmpty,
           ChatAnchorRemoteResultDeliveryPolicy.shouldWaitForDeliveredRows(
               remoteResultCount: executionState.contextPrefetchExpectedMessageCount,
               persistedMessageCount: executionState.contextPrefetchPersistedMessageCount
           ) {
            executionState.didObserveContextPostIdleTick = true
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            self.scheduleContextPrefetchObserverResumeIfNeeded(delay: 0.08)
            return true
        }

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

        if !hasLocalMatch,
           ChatAnchorRemoteResultDeliveryPolicy.shouldWaitForDeliveredRows(
               remoteResultCount: count,
               persistedMessageCount: state.persistedMessageCount
           ) {
            executionState.isWaitingForObserverSync = true
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            self.scheduleAnchorObserverResumeIfNeeded(delay: 0.08)
            return true
        }

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
